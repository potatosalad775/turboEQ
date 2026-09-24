"""Time upstream's fit on the parity fixtures, and join it with turboEQ's.

    zig build bench-fit -Doptimize=ReleaseFast -- --csv 2> turboeq_fit.csv
    python tools/parity/time_upstream.py --turboeq turboeq_fit.csv

Each fixture case records the optimizer's 1.02 grid and target at full
precision. This rebuilds `PEQ.from_dict` on those numbers and times it
together with `PEQ.optimize` — the same span `tools/bench/fit.zig` times on
the turboEQ side, `init()` heuristics included and the perceptual stage not.

Upstream's loss is re-measured here rather than read from the fixture,
because `fmin_slsqp` lands in a different minimum on a different BLAS; the
turboEQ side stops at the fixture's recorded loss, so a large gap between the
two columns is worth a look before quoting the ratio.

Needs the AutoEq checkout, like dump_fixtures.py.
"""
import argparse
import copy
import csv
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, 'AutoEq'))
sys.path.insert(0, HERE)

import pin

if pin.head_commit() is None:
    sys.exit('AutoEq/ is not checked out. See tools/parity/README.md.')

import numpy as np
from autoeq.constants import PEQ_CONFIGS
from autoeq.peq import PEQ

# Keep in step with `timed` in tools/bench/fit.zig.
TIMED = ['4_PEAKING_WITH_SHELVES', '8_PEAKING_WITH_SHELVES', '10_PEAKING']


def fit(name, f, target, fs):
    peq = PEQ.from_dict(copy.deepcopy(PEQ_CONFIGS[name]), f, fs, target=target)
    peq.optimize()
    return peq


def loss_of(peq):
    params = [
        p for fl in peq.filters
        for p in (([float(np.log10(fl.fc))] if fl.optimize_fc else [])
                  + ([float(fl.q)] if fl.optimize_q else [])
                  + ([float(fl.gain)] if fl.optimize_gain else []))
    ]
    return float(peq._optimizer_loss(np.array(params)))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--fixtures', default=os.path.join(HERE, 'fixtures'))
    ap.add_argument('--reps', type=int, default=5)
    ap.add_argument('--turboeq', help="bench-fit's --csv output, to join against")
    args = ap.parse_args()

    with open(os.path.join(args.fixtures, 'manifest.json')) as fh:
        manifest = json.load(fh)
    for line in pin.check(manifest['meta'].get('autoeq_commit')):
        print('WARNING: ' + line, file=sys.stderr)
    fs = manifest['meta']['fs']

    ours = {}
    if args.turboeq:
        with open(args.turboeq) as fh:
            for row in csv.DictReader(fh):
                ours[(row['case'], row['config'])] = row

    if ours:
        print('| Case | Config | AutoEq | loss | turboEQ | Speedup | turboEQ, converged | loss |')
        print('|---|---|---|---|---|---|---|---|')
    else:
        print('| Case | Config | AutoEq | loss | recorded loss |')
        print('|---|---|---|---|---|')

    for entry in manifest['cases']:
        with open(os.path.join(args.fixtures, entry['file'])) as fh:
            case = json.load(fh)
        for name in TIMED:
            fixture = case['peq'].get(name)
            if fixture is None:
                continue
            f = np.array(fixture['frequency'])
            target = np.array(fixture['target'])

            times = []
            for _ in range(args.reps):
                started = time.perf_counter()
                peq = fit(name, f, target, fs)
                times.append((time.perf_counter() - started) * 1e3)
            ms = statistics.median(times)
            loss = loss_of(peq)

            row = ours.get((entry['id'], name))
            if row is None:
                print(f"| {entry['id']} | {name} | {ms:.1f} ms | {loss:.4f} "
                      f"| {fixture['optimized']['loss']:.4f} |")
            else:
                equal = float(row['equal_ms'])
                # turboEQ stopped at the fixture's loss; flag the rows where
                # upstream did better than that on this machine.
                mark = ' *' if float(row['equal_loss']) > loss else ''
                print(f"| {entry['id']} | {name} | {ms:.1f} ms | {loss:.4f} "
                      f"| {equal:.2f} ms{mark} | {ms / equal:.0f}x "
                      f"| {float(row['converged_ms']):.2f} ms | {float(row['converged_loss']):.4f} |")


if __name__ == '__main__':
    main()
