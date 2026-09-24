"""Diff a candidate implementation against the AutoEq fixtures.

    python tools/parity/compare.py candidate.json
    python tools/parity/compare.py candidate.json --stage equalize -v
    python tools/parity/compare.py --self-test

The candidate file mirrors the fixture layout but carries only what the port
has implemented so far. Anything absent is reported as SKIP, not as a failure,
so a port can go green one stage at a time. See README.md for the schema.

Exit code is 0 when nothing failed, 1 otherwise. SKIPs never fail the run;
pass --strict to change that.
"""
import argparse
import json
import math
import os
import sys

import pin

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, 'fixtures')

# Per-stage absolute tolerance in the units of the stage, dB unless noted.
#
# Nothing here may go below 5e-10. Recorded outputs are rounded to
# ROUND=9 decimals in dump_fixtures.py, which puts that floor under every
# comparison no matter how exact the candidate is.
#
# The pipeline stages are deterministic arithmetic, so they are held as tight
# as that floor allows. smoothen is looser because Savitzky-Golay
# coefficients come out of a least squares solve whose last bits depend on
# the LAPACK build. equalize is looser still because it is smoothing stacked
# on peak detection, where a single index landing differently moves a whole
# region slightly.
TOLERANCES = {
    'biquad.coefficients': 1e-9,
    'biquad.fr': 1e-9,
    'biquad.penalties': 1e-9,
    'helpers.sigmoid': 1e-9,
    'helpers.frequencies': 1e-9,
    'interpolate': 1e-9,
    'center': 1e-9,
    'compensate': 1e-9,
    'smoothen': 1e-7,
    'equalize': 1e-6,
    'peq.init': 1e-6,
}

# The optimizer is compared on achieved loss, never on filter parameters.
# Different solvers land in different local minima of near-identical quality,
# so a parameter diff would fail for reasons that mean nothing. A candidate
# that lands a LOWER loss passes and is reported as an improvement.
PEQ_LOSS_RTOL = 0.02  # candidate may be up to 2% worse before it fails


class Report:
    def __init__(self, verbose=False):
        self.rows = []
        self.verbose = verbose

    def add(self, case, stage, status, detail=''):
        self.rows.append((case, stage, status, detail))
        if self.verbose or status != 'PASS':
            print('  {:22s} {:28s} {:6s} {}'.format(case, stage, status, detail))

    def counts(self):
        out = {'PASS': 0, 'FAIL': 0, 'SKIP': 0, 'BETTER': 0}
        for _, _, status, _ in self.rows:
            out[status] = out.get(status, 0) + 1
        return out


def cmp_array(report, case, stage, ref, cand, tol):
    """Compare two float arrays, tolerating None for non-finite entries."""
    if cand is None:
        report.add(case, stage, 'SKIP', 'not implemented')
        return
    if len(ref) != len(cand):
        report.add(case, stage, 'FAIL',
                   'length {} vs {}'.format(len(ref), len(cand)))
        return
    worst, worst_i, n_bad = 0.0, -1, 0
    for i, (a, b) in enumerate(zip(ref, cand)):
        if a is None or b is None:
            if a is not b:
                n_bad += 1
                if worst_i < 0:
                    worst_i = i
            continue
        d = abs(float(a) - float(b))
        if not math.isfinite(d):
            n_bad += 1
            continue
        if d > worst:
            worst, worst_i = d, i
        if d > tol:
            n_bad += 1
    if n_bad:
        report.add(case, stage, 'FAIL',
                   'max|d|={:.3e} at i={} tol={:.0e} ({} pts over)'.format(
                       worst, worst_i, tol, n_bad))
    else:
        report.add(case, stage, 'PASS', 'max|d|={:.2e}'.format(worst))


def cmp_scalar(report, case, stage, ref, cand, tol):
    if cand is None:
        report.add(case, stage, 'SKIP', 'not implemented')
        return
    d = abs(float(ref) - float(cand))
    if d > tol:
        report.add(case, stage, 'FAIL',
                   '{:.9g} vs {:.9g} (d={:.3e}, tol={:.0e})'.format(ref, cand, d, tol))
    else:
        report.add(case, stage, 'PASS', 'd={:.2e}'.format(d))


def cmp_exact(report, case, stage, ref, cand):
    if cand is None:
        report.add(case, stage, 'SKIP', 'not implemented')
        return
    if list(ref) == list(cand):
        report.add(case, stage, 'PASS', '{} entries'.format(len(ref)))
        return
    if len(ref) != len(cand):
        report.add(case, stage, 'FAIL',
                   'length {} vs {}'.format(len(ref), len(cand)))
        return
    diffs = [i for i, (a, b) in enumerate(zip(ref, cand)) if a != b]
    report.add(case, stage, 'FAIL',
               '{} differ, first at i={}'.format(len(diffs), diffs[0]))


def get(d, *path):
    """Walk a nested structure. Ints index lists, strings index dicts."""
    for key in path:
        if isinstance(d, dict):
            if key not in d:
                return None
            d = d[key]
        elif isinstance(d, list) and isinstance(key, int):
            if key >= len(d):
                return None
            d = d[key]
        else:
            return None
    return d


def check_shared(report, ref, cand):
    case = 'shared'
    for i, probe in enumerate(ref.get('biquad', [])):
        label = '{}@{:g}'.format(probe['type'][:4].lower(), probe['fc'])
        c = get(cand, 'biquad', i)
        if c is None:
            report.add(case, 'biquad ' + label, 'SKIP', 'not implemented')
            continue
        for key in ('a0', 'a1', 'a2', 'b0', 'b1', 'b2'):
            cmp_scalar(report, case, 'biquad {} {}'.format(label, key),
                       probe['coefficients'][key], get(c, 'coefficients', key),
                       TOLERANCES['biquad.coefficients'])
        cmp_array(report, case, 'biquad fr ' + label, probe['fr'], c.get('fr'),
                  TOLERANCES['biquad.fr'])
        for key in ('sharpness_penalty', 'band_penalty'):
            if c.get(key) is not None:
                cmp_scalar(report, case, 'biquad {} {}'.format(label, key),
                           probe[key], c.get(key), TOLERANCES['biquad.penalties'])

    helpers = ref.get('helpers', {})
    ch = cand.get('helpers', {}) if isinstance(cand, dict) else {}
    for name, tol in (('log_f_sigmoid_6k_8k', TOLERANCES['helpers.sigmoid']),
                      ('log_f_sigmoid_treble_gain_k_0p5', TOLERANCES['helpers.sigmoid']),
                      ('generate_frequencies_1p01', TOLERANCES['helpers.frequencies'])):
        if name in helpers:
            cmp_array(report, case, 'helper ' + name, helpers[name], ch.get(name), tol)
    if 'smoothing_window_size' in helpers:
        cw = ch.get('smoothing_window_size')
        if cw is None:
            report.add(case, 'helper smoothing_window', 'SKIP', 'not implemented')
        else:
            bad = [k for k, v in helpers['smoothing_window_size'].items()
                   if int(cw.get(k, -1)) != int(v)]
            report.add(case, 'helper smoothing_window',
                       'FAIL' if bad else 'PASS',
                       'mismatched octaves: ' + ', '.join(bad) if bad else 'exact')


def check_case(report, ref, cand, only_stage=None):
    case = ref['id']
    stages = ref['stages']
    cstages = cand.get('stages', {}) if isinstance(cand, dict) else {}

    def want(name):
        return only_stage is None or only_stage == name

    if want('interpolate'):
        s, c = stages['interpolate'], cstages.get('interpolate', {})
        cmp_array(report, case, 'interpolate freq', s['frequency'],
                  c.get('frequency'), TOLERANCES['interpolate'])
        cmp_array(report, case, 'interpolate raw', s['raw'],
                  c.get('raw'), TOLERANCES['interpolate'])

    if want('center'):
        s, c = stages['center'], cstages.get('center', {})
        cmp_scalar(report, case, 'center shift', s['shift_db'],
                   c.get('shift_db'), TOLERANCES['center'])
        cmp_array(report, case, 'center raw', s['raw'],
                  c.get('raw'), TOLERANCES['center'])

    if want('compensate'):
        s, c = stages['compensate'], cstages.get('compensate', {})
        cmp_array(report, case, 'compensate target', s['target'],
                  c.get('target'), TOLERANCES['compensate'])
        cmp_array(report, case, 'compensate error', s['error'],
                  c.get('error'), TOLERANCES['compensate'])

    if want('smoothen'):
        s, c = stages['smoothen'], cstages.get('smoothen', {})
        cmp_array(report, case, 'smoothen smoothed', s['smoothed'],
                  c.get('smoothed'), TOLERANCES['smoothen'])
        cmp_array(report, case, 'smoothen error', s['error_smoothed'],
                  c.get('error_smoothed'), TOLERANCES['smoothen'])

    if want('equalize'):
        s, c = stages['equalize'], cstages.get('equalize', {})
        tol = TOLERANCES['equalize']
        # Index and mask stages come first. When peak detection is wrong every
        # downstream array is wrong too, and this says so in one line.
        cmp_exact(report, case, 'equalize peak_inds', s['peak_inds'], c.get('peak_inds'))
        cmp_exact(report, case, 'equalize dip_inds', s['dip_inds'], c.get('dip_inds'))
        cmp_exact(report, case, 'equalize limit_free_mask',
                  s['limit_free_mask'], c.get('limit_free_mask'))
        cmp_exact(report, case, 'equalize clipped_ltr',
                  s['clipped_ltr'], c.get('clipped_ltr'))
        cmp_exact(report, case, 'equalize clipped_rtl',
                  s['clipped_rtl'], c.get('clipped_rtl'))
        if c.get('rtl_start') is not None:
            cmp_scalar(report, case, 'equalize rtl_start',
                       s['rtl_start'], c.get('rtl_start'), 0)
        else:
            report.add(case, 'equalize rtl_start', 'SKIP', 'not implemented')
        cmp_array(report, case, 'equalize limited_ltr',
                  s['limited_ltr'], c.get('limited_ltr'), tol)
        cmp_array(report, case, 'equalize limited_rtl',
                  s['limited_rtl'], c.get('limited_rtl'), tol)
        cmp_array(report, case, 'equalize curve',
                  s['equalization'], c.get('equalization'), tol)
        # The cap is a hard promise the pipeline makes. Check it directly.
        if c.get('equalization'):
            peak = max(v for v in c['equalization'] if v is not None)
            cap = s['params']['max_gain']
            report.add(case, 'equalize gain cap',
                       'PASS' if peak <= cap + 0.25 else 'FAIL',
                       'max +{:.2f} dB vs cap {:.1f}'.format(peak, cap))

    if want('peq'):
        for name, s in ref.get('peq', {}).items():
            c = get(cand, 'peq', name)
            if c is None:
                report.add(case, 'peq ' + name, 'SKIP', 'not implemented')
                continue
            if get(c, 'init', 'params') is not None:
                cmp_array(report, case, 'peq init ' + name,
                          s['init']['params'], c['init']['params'],
                          TOLERANCES['peq.init'])
            check_peq_config(report, case, name, s, c)
            check_peq_loss(report, case, name, s, c)

    if want('peq_cascade'):
        for name, s in ref.get('peq_cascade', {}).items():
            c = get(cand, 'peq_cascade', name)
            if c is None:
                report.add(case, 'peq_cascade ' + name, 'SKIP', 'not implemented')
                continue
            check_peq_cascade(report, case, name, s, c)


# Exact, unlike the fit itself: resolving a config is a lookup and a table of
# defaults, not an optimization, so there is no local minimum to land in. The
# only slack is the fixtures' own 9-decimal rounding.
CONFIG_TOL = 5e-10


def check_peq_config(report, case, name, ref, cand):
    """Did the port resolve `PEQ_CONFIGS[name]` the way `from_dict` does?

    Checked separately from the fit because the defaulting rules are easy to
    get subtly wrong — an unpinned parameter, a bound taken from the wrong
    filter type — and a wrong bank can still produce a plausible-looking EQ.
    """
    want_cfg = ref.get('config')
    got_cfg = get(cand, 'config')
    if want_cfg is None or got_cfg is None:
        report.add(case, 'peq config ' + name, 'SKIP', 'not recorded')
        return

    problems = []
    for key in ('min_f', 'max_f'):
        a, b = want_cfg.get(key), got_cfg.get(key)
        if a is None or b is None or abs(float(a) - float(b)) > CONFIG_TOL:
            problems.append('{} {} vs {}'.format(key, b, a))

    a_filters, b_filters = want_cfg['filters'], got_cfg.get('filters') or []
    if len(a_filters) != len(b_filters):
        report.add(case, 'peq config ' + name, 'FAIL',
                   '{} filters vs {}'.format(len(b_filters), len(a_filters)))
        return

    keys = ('type', 'optimize_fc', 'optimize_q', 'optimize_gain', 'fc', 'q', 'gain',
            'min_fc', 'max_fc', 'min_q', 'max_q', 'min_gain', 'max_gain')
    for i, (a, b) in enumerate(zip(a_filters, b_filters)):
        for key in keys:
            x, y = a.get(key), b.get(key)
            if isinstance(x, (int, float)) and isinstance(y, (int, float)):
                if abs(float(x) - float(y)) > CONFIG_TOL:
                    problems.append('#{} {} {} vs {}'.format(i, key, y, x))
            elif x != y:
                problems.append('#{} {} {!r} vs {!r}'.format(i, key, y, x))

    if problems:
        report.add(case, 'peq config ' + name, 'FAIL',
                   '; '.join(problems[:4]) + ('; ...' if len(problems) > 4 else ''))
    else:
        report.add(case, 'peq config ' + name, 'PASS',
                   '{} filters resolved identically'.format(len(a_filters)))


# The whole-cascade RMSE is reported but not asserted on tightly, and the
# reason is invariant 4 one level up.
#
# `4_PEAKING_WITH_LOW_SHELF` is scored only to 10 kHz, so whatever it does
# above that is free. A solver that fits its own window *better* can leave a
# worse residual up there for bank two to inherit, and the whole-axis RMSE
# then moves against it. Measured on `gentle_vs_flat`, turboEQ reaches 0.2185
# below 10 kHz against upstream's 0.2193 and lands 0.9865 above it against
# 0.9391 — better on the objective, worse on the total, by 2.2%.
#
# So each bank is checked on the loss it actually minimized, at the same
# tolerance a single fit gets, and the total is a sanity bound rather than a
# parity claim.
CASCADE_RMSE_RTOL = 0.15


def check_peq_cascade(report, case, name, ref, cand):
    """A cascade is compared bank by bank, each on its own achieved loss."""
    want_banks = ref['banks']
    got_banks = get(cand, 'banks') or []
    if len(got_banks) != len(want_banks):
        report.add(case, 'peq_cascade ' + name, 'FAIL',
                   '{} banks vs {}'.format(len(got_banks), len(want_banks)))
        return

    for a, b in zip(want_banks, got_banks):
        label = 'peq_cascade {} {}'.format(name, a['name'])
        if a['name'] != b.get('name'):
            report.add(case, 'peq_cascade ' + name, 'FAIL',
                       'bank order: {} vs {}'.format(b.get('name'), a['name']))
            return
        if len(a['filters']) != len(b.get('filters') or []):
            report.add(case, label, 'FAIL', 'returned {} of {} bands'.format(
                len(b.get('filters') or []), len(a['filters'])))
            continue
        ref_loss, cand_loss = a.get('loss'), b.get('loss')
        if ref_loss is None or cand_loss is None:
            report.add(case, label, 'SKIP', 'no loss reported')
            continue
        ref_loss, cand_loss = float(ref_loss), float(cand_loss)
        if ref_loss <= 0:
            report.add(case, label, 'SKIP', 'reference loss is zero')
            continue
        ratio = cand_loss / ref_loss
        detail = 'loss {:.6f} vs {:.6f} ({:+.1f}%)'.format(
            cand_loss, ref_loss, (ratio - 1) * 100)
        if ratio < 1.0 - PEQ_LOSS_RTOL:
            report.add(case, label, 'BETTER', detail)
        elif ratio <= 1.0 + PEQ_LOSS_RTOL:
            report.add(case, label, 'PASS', detail)
        else:
            report.add(case, label, 'FAIL', detail)

    ref_rmse, cand_rmse = float(ref['rmse']), float(get(cand, 'rmse'))
    detail = 'total rmse {:.6f} vs {:.6f} ({:+.1f}%)'.format(
        cand_rmse, ref_rmse, (cand_rmse / ref_rmse - 1) * 100 if ref_rmse else 0.0)
    if ref_rmse <= 0:
        report.add(case, 'peq_cascade total ' + name, 'SKIP', 'reference rmse is zero')
    elif cand_rmse <= ref_rmse * (1.0 + CASCADE_RMSE_RTOL):
        report.add(case, 'peq_cascade total ' + name, 'PASS', detail)
    else:
        report.add(case, 'peq_cascade total ' + name, 'FAIL', detail)


def check_peq_loss(report, case, name, ref, cand):
    """Optimizer parity: achieved loss, not filter parameters."""
    ref_loss = ref['optimized']['loss']
    cand_loss = get(cand, 'optimized', 'loss')
    if cand_loss is None:
        report.add(case, 'peq loss ' + name, 'SKIP', 'no loss reported')
        return
    ref_loss, cand_loss = float(ref_loss), float(cand_loss)
    n_ref = len(ref['optimized']['filters'])
    n_cand = len(get(cand, 'optimized', 'filters') or [])
    if n_cand and n_cand != n_ref:
        report.add(case, 'peq bands ' + name, 'FAIL',
                   'returned {} of {} bands'.format(n_cand, n_ref))
    if ref_loss <= 0:
        report.add(case, 'peq loss ' + name, 'SKIP', 'reference loss is zero')
        return
    ratio = cand_loss / ref_loss
    detail = 'loss {:.6f} vs {:.6f} ({:+.1f}%)'.format(
        cand_loss, ref_loss, (ratio - 1) * 100)
    if ratio < 1.0 - PEQ_LOSS_RTOL:
        report.add(case, 'peq loss ' + name, 'BETTER', detail)
    elif ratio <= 1.0 + PEQ_LOSS_RTOL:
        report.add(case, 'peq loss ' + name, 'PASS', detail)
    else:
        report.add(case, 'peq loss ' + name, 'FAIL', detail)


def load(path):
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('candidate', nargs='?',
                    help='JSON produced by the port. Omit with --self-test.')
    ap.add_argument('--fixtures', default=FIXTURES)
    ap.add_argument('--stage', help='Check only this stage.')
    ap.add_argument('--case', help='Check only this case id.')
    ap.add_argument('-v', '--verbose', action='store_true',
                    help='Print passing checks too.')
    ap.add_argument('--strict', action='store_true',
                    help='Treat SKIP as failure.')
    ap.add_argument('--self-test', action='store_true',
                    help='Diff the fixtures against themselves. Everything must pass.')
    args = ap.parse_args()

    if not os.path.isdir(args.fixtures):
        sys.exit('No fixtures at {}. Run dump_fixtures.py first.'.format(args.fixtures))
    manifest = load(os.path.join(args.fixtures, 'manifest.json'))

    if args.self_test:
        candidate = None
    elif not args.candidate:
        ap.error('candidate is required unless --self-test is given')
    else:
        candidate = load(args.candidate)
        cmeta = candidate.get('meta', {})
        rmeta = manifest['meta']
        for key in ('autoeq_commit', 'fs'):
            if key in cmeta and cmeta[key] != rmeta[key]:
                print('WARNING: candidate {} is {!r}, fixtures were built with {!r}'
                      .format(key, cmeta[key], rmeta[key]))

    # Fixtures are committed and AutoEq/ need not be checked out at all, so
    # this is silent on the usual path. It fires only when a checkout exists
    # and has drifted from what the fixtures were built against.
    for line in pin.check(manifest['meta'].get('autoeq_commit')):
        print('WARNING: ' + line)

    report = Report(verbose=args.verbose)
    print('Fixtures: AutoEq {} @ {}, fs={:.0f}'.format(
        manifest['meta']['autoeq_version'],
        manifest['meta']['autoeq_commit'][:12], manifest['meta']['fs']))
    print()

    shared_ref = load(os.path.join(args.fixtures, 'shared.json'))
    shared_cand = shared_ref if args.self_test else (candidate.get('shared') or {})
    if args.stage in (None, 'biquad', 'helpers'):
        check_shared(report, shared_ref, shared_cand)

    for entry in manifest['cases']:
        if args.case and entry['id'] != args.case:
            continue
        ref = load(os.path.join(args.fixtures, entry['file']))
        if args.self_test:
            cand = ref
        else:
            cand = (candidate.get('cases') or {}).get(entry['id'])
            if cand is None:
                report.add(entry['id'], 'all', 'SKIP', 'case absent from candidate')
                continue
        stage = args.stage if args.stage not in ('biquad', 'helpers') else None
        check_case(report, ref, cand, only_stage=stage)

    counts = report.counts()
    print()
    print('{} pass, {} better, {} fail, {} skip'.format(
        counts['PASS'], counts.get('BETTER', 0), counts['FAIL'], counts['SKIP']))
    failed = counts['FAIL'] > 0 or (args.strict and counts['SKIP'] > 0)
    if not failed and not args.verbose and counts['PASS'] + counts.get('BETTER', 0):
        print('All implemented stages match.')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
