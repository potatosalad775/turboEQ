"""Upstream's achieved loss over a directory of real measurements, for turboEQ
to be held against on more curves than the fixtures have.

    python tools/parity/survey_upstream.py --target TARGET --out survey MEASUREMENTS_DIR
    zig build bench-fit -Doptimize=fast -- --reps 1 --csv --fixtures survey 2> survey.csv
    python tools/parity/survey_upstream.py --summarize survey.csv
    # and with --second-start after --reps 1, for what pipeline.run does by default

The first command runs AutoEq's pipeline and `PEQ.optimize` on every `.txt`
and `.csv` in the directory and writes, per file, the optimizer's 1.02 grid
and target at full precision and the loss upstream reached. The layout is the
one `tools/bench/fit.zig` reads, which is what lets the second command fit the
same numbers with turboEQ. The third counts how often turboEQ's converged loss
ended above upstream's.

These are not fixtures and nothing here is committed: upstream's optimizer
lands in a different minimum on a different BLAS, so the counts are a survey
of one machine, and BENCHMARKS.md records one. `bench-fit` fits from
upstream's start alone, as the parity harness does, unless given
`--second-start`.

Needs the AutoEq checkout, like dump_fixtures.py.
"""
import argparse
import copy
import csv
import json
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'AutoEq'))
sys.path.insert(0, HERE)

# Keep in step with `timed` in tools/bench/fit.zig.
TIMED = ['4_PEAKING_WITH_SHELVES', '8_PEAKING_WITH_SHELVES', '10_PEAKING']


def read_curve(path):
    """Frequency then dB, tab-, comma- or space-separated, header and comment
    lines skipped, further columns ignored."""
    f, db = [], []
    with open(path, encoding='utf-8-sig', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line or line[0] not in '0123456789.-+':
                continue
            parts = re.split(r'[\t, ]+', line)
            try:
                f.append(float(parts[0]))
                db.append(float(parts[1]))
            except (ValueError, IndexError):
                continue
    return f, db


def survey(args):
    import pin
    if pin.head_commit() is None:
        sys.exit('AutoEq/ is not checked out. See tools/parity/README.md.')
    import numpy as np
    from autoeq.constants import PEQ_CONFIGS
    from autoeq.frequency_response import FrequencyResponse
    from autoeq.peq import PEQ

    tgt_f, tgt_db = (np.array(v) for v in read_curve(args.target))
    names = sorted(n for n in os.listdir(args.dir) if n.lower().endswith(('.txt', '.csv')))
    names = names[::args.every]
    os.makedirs(args.out, exist_ok=True)

    cases = []
    for i, name in enumerate(names):
        try:
            f, db = (np.array(v) for v in read_curve(os.path.join(args.dir, name)))
            fr = FrequencyResponse(name='case', frequency=f, raw=db)
            tgt = FrequencyResponse(name='target', frequency=tgt_f.copy(), raw=tgt_db.copy())
            fr.interpolate()
            fr.center()
            fr.compensate(tgt, fs=args.fs, min_mean_error=True)
            fr.smoothen()
            fr.equalize()
            work = FrequencyResponse(
                name='opt', frequency=fr.frequency, equalization=fr.equalization)
            work.interpolate(f_step=1.02)
            grid, target = work.frequency, work.equalization

            fits = {}
            for config in TIMED:
                peq = PEQ.from_dict(copy.deepcopy(PEQ_CONFIGS[config]), grid, args.fs, target=target)
                peq.optimize()
                params = [
                    p for fl in peq.filters
                    for p in (([float(np.log10(fl.fc))] if fl.optimize_fc else [])
                              + ([float(fl.q)] if fl.optimize_q else [])
                              + ([float(fl.gain)] if fl.optimize_gain else []))
                ]
                fits[config] = {
                    'frequency': [float(v) for v in grid],
                    'target': [float(v) for v in target],
                    'optimized': {'loss': float(peq._optimizer_loss(np.array(params)))},
                }
        except Exception as e:  # a file upstream itself refuses
            print(f'skipped {name}: {e!r}', file=sys.stderr)
            continue
        case_id = f'c{i:04d}'
        with open(os.path.join(args.out, case_id + '.json'), 'w', encoding='utf-8') as fh:
            json.dump({'id': case_id, 'source': name, 'peq': fits}, fh)
        cases.append({'id': case_id, 'file': case_id + '.json', 'source': name})

    with open(os.path.join(args.out, 'manifest.json'), 'w', encoding='utf-8') as fh:
        json.dump({'meta': {'fs': args.fs}, 'cases': cases}, fh, indent=1)
    print(f'{len(cases)} of {len(names)} files -> {args.out}')


def summarize(path):
    by_config = {}
    with open(path, encoding='utf-8') as fh:
        for row in csv.DictReader(fh):
            ratio = float(row['converged_loss']) / float(row['upstream_loss'])
            by_config.setdefault(row['config'], []).append(ratio)
    print('| Config | Fits | Loss ratio, median | p90 | max | Above upstream | by >10% |')
    print('|---|---|---|---|---|---|---|')
    for config, ratios in by_config.items():
        ratios.sort()
        p90 = ratios[min(len(ratios) - 1, int(0.9 * len(ratios)))]
        print(f'| {config} | {len(ratios)} | {statistics.median(ratios):.3f} | {p90:.3f} '
              f'| {ratios[-1]:.2f} | {sum(r > 1.001 for r in ratios)} '
              f'| {sum(r > 1.10 for r in ratios)} |')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('dir', nargs='?', help='Directory of measurement files.')
    ap.add_argument('--target', help='Target curve file.')
    ap.add_argument('--out', help='Directory to write, in the fixtures layout.')
    ap.add_argument('--every', type=int, default=1, help='Take every Nth file.')
    ap.add_argument('--fs', type=float, default=44100.0)
    ap.add_argument('--summarize', metavar='CSV',
                    help="Count from bench-fit's --csv output instead of running upstream.")
    args = ap.parse_args()

    if args.summarize:
        summarize(args.summarize)
    elif args.dir and args.target and args.out:
        survey(args)
    else:
        ap.error('give MEASUREMENTS_DIR with --target and --out, or --summarize CSV')


if __name__ == '__main__':
    main()
