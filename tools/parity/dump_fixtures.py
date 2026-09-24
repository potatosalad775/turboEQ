"""Dump AutoEq's intermediate arrays to JSON, stage by stage.

These are the ground truth the Zig port is built against. Every stage is
independently checkable, so a port can go green one stage at a time instead
of only at the very end.

    python tools/parity/dump_fixtures.py [--out DIR] [--fs 44100]

Regenerate only when the upstream pin in CLAUDE.md moves. Fixtures are
deterministic: same input, same bytes.
"""
import argparse
import copy
import json
import os
import platform
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUTOEQ = os.path.join(REPO, 'AutoEq')
sys.path.insert(0, AUTOEQ)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pin

# AutoEq/ is a submodule, and only this script needs it — the fixtures it
# writes are committed, so everything else in the repo runs without it. Say
# so here rather than letting the import below raise.
if pin.head_commit() is None:
    sys.exit('AutoEq/ is not checked out. It is a submodule:\n'
             '  git submodule update --init --filter=blob:none AutoEq\n'
             '  git -C AutoEq sparse-checkout set autoeq')

import numpy as np
import scipy
from autoeq.frequency_response import FrequencyResponse
from autoeq.peq import PEQ, Peaking, LowShelf, HighShelf
from autoeq.constants import PEQ_CONFIGS
from autoeq.utils import smoothing_window_size, log_f_sigmoid

import curves

# Recorded OUTPUTS are rounded so fixtures stay diffable and stable across
# BLAS builds. The rounding is not free: it puts a 5e-10 floor under every
# comparison, so no tolerance in compare.py may sit below that.
ROUND = 9


def arr(a):
    """A recorded output array. Rounded."""
    a = np.asarray(a, dtype=float)
    return [None if not np.isfinite(x) else round(float(x), ROUND) for x in a]


def inarr(a):
    """An INPUT array, recorded at full precision.

    A candidate is fed these numbers and upstream was fed these numbers, so
    they have to be the same numbers. Rounding an input quantizes the
    candidate's starting point and the error compounds through every stage
    downstream, which showed up as ~1.1e-9 drift against a 1e-9 tolerance.
    Python's float repr is shortest-round-trip, so this stays deterministic.
    """
    a = np.asarray(a, dtype=float)
    return [None if not np.isfinite(x) else float(x) for x in a]


def iarr(a):
    return [int(x) for x in np.asarray(a).ravel()]


def barr(a):
    return [bool(x) for x in np.asarray(a).ravel()]


def upstream_commit():
    return pin.head_commit() or 'unknown'


# ---------------------------------------------------------------------------
# Stage: biquad. Pure filter math, no optimizer. Port this first.
# ---------------------------------------------------------------------------
FILTER_CLASSES = {'PEAKING': Peaking, 'LOW_SHELF': LowShelf, 'HIGH_SHELF': HighShelf}

BIQUAD_PROBES = [
    ('PEAKING', 100.0, 0.5, 6.0),
    ('PEAKING', 1000.0, 1.41, -6.0),
    ('PEAKING', 3000.0, 6.0, 12.0),
    ('PEAKING', 9000.0, 0.18248, -3.0),
    ('PEAKING', 20.0, 2.0, 20.0),
    ('PEAKING', 10000.0, 4.0, -20.0),
    ('LOW_SHELF', 105.0, 0.7, 6.0),
    ('LOW_SHELF', 40.0, 0.4, -9.0),
    ('LOW_SHELF', 300.0, 0.7, 12.0),
    ('HIGH_SHELF', 10000.0, 0.7, 6.0),
    ('HIGH_SHELF', 5000.0, 0.4, -9.0),
    ('HIGH_SHELF', 12000.0, 0.7, 3.0),
]


def dump_biquad(f, fs):
    out = []
    for kind, fc, q, gain in BIQUAD_PROBES:
        filt = FILTER_CLASSES[kind](
            f, fs, fc=fc, optimize_fc=False, q=q, optimize_q=False,
            gain=gain, optimize_gain=False)
        a0, a1, a2, b0, b1, b2 = filt.biquad_coefficients()
        out.append({
            'type': kind, 'fc': fc, 'q': q, 'gain': gain, 'fs': fs,
            # As returned by biquad_coefficients(), before fr() negates a1/a2.
            'coefficients': {
                'a0': round(float(a0), ROUND), 'a1': round(float(a1), ROUND),
                'a2': round(float(a2), ROUND), 'b0': round(float(b0), ROUND),
                'b1': round(float(b1), ROUND), 'b2': round(float(b2), ROUND),
            },
            'fr': arr(filt.fr),
            'sharpness_penalty': round(float(filt.sharpness_penalty), ROUND),
            'band_penalty': round(float(filt.band_penalty), ROUND),
        })
    return out


# ---------------------------------------------------------------------------
# Stage: helpers. Small pure functions that are easy to get subtly wrong.
# ---------------------------------------------------------------------------
def dump_helpers(f):
    return {
        'smoothing_window_size': {
            str(octaves): int(smoothing_window_size(f, octaves))
            for octaves in [1 / 12, 1 / 5, 1 / 3, 2.0]
        },
        'log_f_sigmoid_6k_8k': arr(log_f_sigmoid(f, 6000.0, 8000.0)),
        'log_f_sigmoid_treble_gain_k_0p5': arr(
            log_f_sigmoid(f, 6000.0, 8000.0, a_normal=1.0, a_treble=0.5)),
        'generate_frequencies_1p01': arr(
            FrequencyResponse.generate_frequencies(f_step=1.01)),
    }


# ---------------------------------------------------------------------------
# Stages: the curve pipeline, captured one step at a time.
# ---------------------------------------------------------------------------
def dump_pipeline(src_f, src_raw, tgt_f, tgt_raw, fs, min_mean_error):
    """`tgt_f` is the target's own frequency axis, which for the real
    measurement cases is not the source's. `compensate` interpolates the
    target onto the source grid itself, so the two need not agree."""
    stages = {}

    fr = FrequencyResponse(name='case', frequency=src_f.copy(), raw=src_raw.copy())
    tgt = FrequencyResponse(name='target', frequency=tgt_f.copy(), raw=tgt_raw.copy())

    fr.interpolate()
    stages['interpolate'] = {'frequency': arr(fr.frequency), 'raw': arr(fr.raw)}

    shift = fr.center()
    stages['center'] = {'shift_db': round(float(shift), ROUND), 'raw': arr(fr.raw)}

    fr.compensate(tgt, fs=fs, min_mean_error=min_mean_error)
    stages['compensate'] = {
        'min_mean_error': min_mean_error,
        'target': arr(fr.target),
        'error': arr(fr.error),
    }

    fr.smoothen()
    stages['smoothen'] = {
        'window_size': 1 / 12,
        'treble_window_size': 2.0,
        'treble_f_lower': 6000.0,
        'treble_f_upper': 8000.0,
        'smoothed': arr(fr.smoothed),
        'error_smoothed': arr(fr.error_smoothed),
    }

    (eq, eq_smoothed_err, limited_ltr, clipped_ltr, limited_rtl, clipped_rtl,
     peak_inds, dip_inds, rtl_start, limit_free_mask) = fr.equalize()
    stages['equalize'] = {
        'params': {
            'max_gain': 6.0, 'max_slope': 18.0, 'concha_interference': False,
            'treble_f_lower': 6000.0, 'treble_f_upper': 8000.0, 'treble_gain_k': 1.0,
        },
        'equalization': arr(eq),
        'smoothed_error': arr(eq_smoothed_err),
        'peak_inds': iarr(peak_inds),
        'dip_inds': iarr(dip_inds),
        'rtl_start': int(rtl_start),
        'limit_free_mask': barr(limit_free_mask),
        'limited_ltr': arr(limited_ltr),
        'clipped_ltr': barr(clipped_ltr),
        'limited_rtl': arr(limited_rtl),
        'clipped_rtl': barr(clipped_rtl),
        # Scalar assertions a port can check without diffing whole arrays.
        'max_positive_gain': round(float(np.max(eq)), ROUND),
        'min_gain': round(float(np.min(eq)), ROUND),
    }
    return fr, stages


# ---------------------------------------------------------------------------
# Stage: the optimizer.
# Compared on achieved loss, never on filter parameters. See CLAUDE.md
# invariant 4.
# ---------------------------------------------------------------------------
# One per shape the port has to get right, not one per name upstream ships.
#   - the two shelved presets and the bare peaking one, as before;
#   - the halves of AutoEq's own CLI default, which are the only shipped
#     configs with a single shelf, and the only one that narrows `max_f`;
#   - a device preset, which is the only shape with per-filter bounds;
#   - a graphic EQ, which is the only one that pins fc and Q and optimizes
#     gain alone.
PEQ_CASES = [
    '4_PEAKING_WITH_SHELVES',
    '8_PEAKING_WITH_SHELVES',
    '10_PEAKING',
    '4_PEAKING_WITH_LOW_SHELF',
    '4_PEAKING_WITH_HIGH_SHELF',
    'QUDELIX_5K',
    '10_BAND_GRAPHIC_EQ',
]

# AutoEq's CLI default: two configs fitted in sequence, the second against the
# residual the first leaves. `_optimize_peq_filters` is the only place this
# happens and nothing else in the fixtures exercises it.
PEQ_CASCADES = {
    'CLI_DEFAULT': ['4_PEAKING_WITH_LOW_SHELF', '4_PEAKING_WITH_HIGH_SHELF'],
}


def resolved_filters(peq):
    """The filter bank `from_dict` produced, bounds and pins included.

    turboEQ resolves `PEQ_CONFIGS` itself rather than reading this back, so
    recording it is what lets `compare.py` check that resolution — the
    defaulting rules in `from_dict` are easy to get subtly wrong and nothing
    else would catch it.
    """
    return [
        {
            'type': fl.__class__.__name__,
            'optimize_fc': bool(fl.optimize_fc),
            'optimize_q': bool(fl.optimize_q),
            'optimize_gain': bool(fl.optimize_gain),
            # Only meaningful where the parameter is pinned; `from_dict` leaves
            # the others at whatever the constructor defaulted to.
            'fc': round(float(fl.fc), ROUND) if not fl.optimize_fc else None,
            'q': round(float(fl.q), ROUND) if not fl.optimize_q else None,
            'gain': round(float(fl.gain), ROUND) if not fl.optimize_gain else None,
            'min_fc': round(float(fl.min_fc), ROUND),
            'max_fc': round(float(fl.max_fc), ROUND),
            'min_q': round(float(fl.min_q), ROUND),
            'max_q': round(float(fl.max_q), ROUND),
            'min_gain': round(float(fl.min_gain), ROUND),
            'max_gain': round(float(fl.max_gain), ROUND),
        }
        for fl in peq.filters
    ]


def dump_peq(fr, fs):
    out = {}
    # Upstream optimizes against the equalization curve on its own 1.02 grid.
    work = FrequencyResponse(
        name='opt', frequency=fr.frequency, equalization=fr.equalization)
    work.interpolate(f_step=1.02)
    f = work.frequency
    target = work.equalization

    for name in PEQ_CASES:
        cfg = copy.deepcopy(PEQ_CONFIGS[name])
        peq = PEQ.from_dict(cfg, f, fs, target=target)

        init_params = peq._init_optimizer_params()
        init_loss = peq._optimizer_loss(init_params)
        init_filters = [
            {'type': fl.__class__.__name__, 'fc': round(float(fl.fc), ROUND),
             'q': round(float(fl.q), ROUND), 'gain': round(float(fl.gain), ROUND)}
            for fl in peq.filters
        ]

        peq.optimize()
        final_params = [
            p for fl in peq.filters
            for p in (([float(np.log10(fl.fc))] if fl.optimize_fc else [])
                      + ([float(fl.q)] if fl.optimize_q else [])
                      + ([float(fl.gain)] if fl.optimize_gain else []))
        ]
        final_loss = (float(peq._optimizer_loss(np.array(final_params)))
                      if final_params else float(init_loss))
        rmse = float(np.sqrt(np.mean((peq.fr - target) ** 2)))

        opt_block = PEQ_CONFIGS[name].get('optimizer', {})
        out[name] = {
            'frequency': inarr(f),
            'target': inarr(target),
            'config': {
                'filters': resolved_filters(peq),
                'min_f': float(opt_block.get('min_f', 20.0)),
                'max_f': float(opt_block.get('max_f', 20000.0)),
                'min_std': opt_block.get('min_std'),
            },
            'bounds': [[round(float(lo), ROUND), round(float(hi), ROUND)]
                       for lo, hi in peq._init_optimizer_bounds()],
            'init': {
                'params': arr(init_params),
                'loss': round(float(init_loss), ROUND),
                'filters': init_filters,
            },
            'optimized': {
                'filters': [
                    {'type': fl.__class__.__name__, 'fc': round(float(fl.fc), ROUND),
                     'q': round(float(fl.q), ROUND), 'gain': round(float(fl.gain), ROUND),
                     'optimize_fc': bool(fl.optimize_fc),
                     'optimize_q': bool(fl.optimize_q),
                     'optimize_gain': bool(fl.optimize_gain)}
                    for fl in peq.filters
                ],
                'fr': arr(peq.fr),
                'loss': round(final_loss, ROUND),
                'rmse': round(rmse, ROUND),
                'max_gain': round(float(peq.max_gain), ROUND),
            },
        }
    return out


def dump_peq_cascade(fr, fs):
    """`_optimize_peq_filters` over a list of configs, which is what the CLI
    runs by default. Each config fits the residual the last one left."""
    out = {}
    for name, config_names in PEQ_CASCADES.items():
        work = FrequencyResponse(
            name='opt', frequency=fr.frequency, equalization=fr.equalization)
        work.interpolate(f_step=1.02)
        f = np.array(work.frequency)
        target = np.array(work.equalization)

        residual = np.array(target)
        banks, combined = [], np.zeros(len(f))
        for config_name in config_names:
            cfg = copy.deepcopy(PEQ_CONFIGS[config_name])
            peq = PEQ.from_dict(cfg, f, fs, target=residual)
            peq.optimize()
            # Each bank's own achieved loss, on its own min_f/max_f window.
            # This is what the bank actually minimized, and so the only thing
            # it is fair to compare it on — see CLAUDE.md invariant 4.
            bank_params = [
                p for fl in peq.filters
                for p in (([float(np.log10(fl.fc))] if fl.optimize_fc else [])
                          + ([float(fl.q)] if fl.optimize_q else [])
                          + ([float(fl.gain)] if fl.optimize_gain else []))
            ]
            banks.append({
                'name': config_name,
                'loss': round(float(peq._optimizer_loss(np.array(bank_params))), ROUND)
                        if bank_params else None,
                'filters': [
                    {'type': fl.__class__.__name__, 'fc': round(float(fl.fc), ROUND),
                     'q': round(float(fl.q), ROUND), 'gain': round(float(fl.gain), ROUND)}
                    for fl in peq.filters
                ],
            })
            combined = combined + peq.fr
            residual = residual - peq.fr

        out[name] = {
            'frequency': inarr(f),
            'target': inarr(target),
            'configs': config_names,
            'banks': banks,
            # The whole cascade against the original target, which is what
            # turboEQ's `Result.rmse` and `max_gain` describe.
            'fr': arr(combined),
            'rmse': round(float(np.sqrt(np.mean(residual ** 2))), ROUND),
            'max_gain': round(float(np.max(combined)), ROUND),
        }
    return out


def _write(path, obj):
    with open(path, 'w', encoding='utf-8') as fh:
        json.dump(obj, fh, indent=1, sort_keys=True)
        fh.write('\n')


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--out', default=os.path.join(here, 'fixtures'))
    ap.add_argument('--fs', type=float, default=44100.0,
                    help="Sample rate. Upstream's default, and turboEQ's.")
    ap.add_argument('--only', help='Comma-separated case ids to regenerate. The '
                                   'rest keep their committed fixtures, which is '
                                   'what you want when adding a case.')
    ap.add_argument('--no-min-mean-error', dest='min_mean_error',
                    action='store_false', default=True,
                    help='Align at 1 kHz only, instead of minimizing mean error '
                         'across 100 Hz to 10 kHz.')
    args = ap.parse_args()

    for line in pin.check():
        print('WARNING: ' + line)

    os.makedirs(args.out, exist_ok=True)
    meta = {
        'autoeq_commit': upstream_commit(),
        'autoeq_version': '4.1.2',
        'fs': args.fs,
        'min_mean_error': args.min_mean_error,
        'python': platform.python_version(),
        'numpy': np.__version__,
        'scipy': scipy.__version__,
        'round_digits': ROUND,
    }

    grid = curves.log_grid()
    # shared.json holds the case-independent stages, so --only leaves it as it
    # is: rewriting it would change nothing but the recorded environment.
    shared_path = os.path.join(args.out, 'shared.json')
    _write_shared = (lambda *a: None) if (args.only and os.path.exists(shared_path)) else _write
    _write_shared(shared_path, {
        'meta': meta,
        'frequency': inarr(grid),
        'biquad': dump_biquad(grid, args.fs),
        'helpers': dump_helpers(grid),
    })

    # Every case, synthetic and real, as (id, source axis, source dB, target
    # axis, target dB, manifest entry). Real cases carry two axes because a
    # measurement and a target do not share one.
    work = []
    for case_id, src_name, tgt_name, step in curves.CASES:
        f = curves.log_grid(step=step)
        work.append((case_id, f, curves.SOURCES[src_name](f), f,
                     curves.TARGETS[tgt_name](f),
                     {'source': src_name, 'target': tgt_name, 'grid_step': step}))
    for case_id, src_file, tgt_file in curves.REAL_CASES:
        f, src = curves.read_measurement(src_file)
        if tgt_file is None:
            tgt_f, tgt = f, curves.flat(f)
            tgt_name = 'flat'
        else:
            tgt_f, tgt = curves.read_measurement(tgt_file)
            tgt_name = tgt_file
        work.append((case_id, f, src, tgt_f, tgt,
                     {'source': src_file, 'target': tgt_name}))

    order = [w[0] for w in work]   # canonical case order, --only or not

    if args.only:
        wanted = set(args.only.split(','))
        unknown = wanted - {w[0] for w in work}
        if unknown:
            sys.exit('No such case: ' + ', '.join(sorted(unknown)))
        work = [w for w in work if w[0] in wanted]

    # With --only, the cases left alone keep their recorded entries. Rewriting
    # the whole manifest would drop them, and regenerating them to get them
    # back would move every filter upstream's optimizer places — see the
    # reproducibility note in README.md.
    manifest = {'meta': meta, 'cases': []}
    manifest_path = os.path.join(args.out, 'manifest.json')
    if args.only and os.path.exists(manifest_path):
        with open(manifest_path, encoding='utf-8') as fh:
            manifest = json.load(fh)

    for case_id, f, src, tgt_f, tgt, desc in work:
        fr, stages = dump_pipeline(f, src, tgt_f, tgt, args.fs, args.min_mean_error)
        path = os.path.join(args.out, case_id + '.json')
        _write(path, {
            'meta': meta,
            'id': case_id,
            'input': dict(desc, frequency=inarr(f), raw=inarr(src),
                          target_frequency=inarr(tgt_f), target_raw=inarr(tgt)),
            'stages': stages,
            'peq': dump_peq(fr, args.fs),
            'peq_cascade': dump_peq_cascade(fr, args.fs),
        })
        entry = {'id': case_id, 'file': case_id + '.json',
                 'source': desc['source'], 'target': desc['target'],
                 'points': len(f)}
        manifest['cases'] = [c for c in manifest['cases'] if c['id'] != case_id]
        manifest['cases'].append(entry)
        print('  {:22s} {:5d} pts -> {} ({:.0f} KB)'.format(
            case_id, len(f), os.path.basename(path),
            os.path.getsize(path) / 1024))

    manifest['cases'].sort(key=lambda c: order.index(c['id']) if c['id'] in order
                           else len(order))

    _write(os.path.join(args.out, 'manifest.json'), manifest)
    print('\nWrote {} of {} cases to {}{}'.format(
        len(work), len(manifest['cases']), args.out,
        '' if args.only else ' + shared.json'))
    print('AutoEq {} @ {}, fs={:.0f}'.format(
        meta['autoeq_version'], meta['autoeq_commit'][:12], args.fs))


if __name__ == '__main__':
    main()
