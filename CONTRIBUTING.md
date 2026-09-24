# Contributing

turboEQ needs Zig 0.16.0 and Node. Python is only needed for the parity harness.

## Building and testing

```sh
zig build test                        # unit tests
zig build wasm                        # zig-out/bin/turboeq.wasm and turboeq-simd.wasm
node tools/wasm_smoke/smoke.mjs       # the wasm, end to end through the JS binding
npm pack                              # the npm tarball; `prepack` builds the wasm into js/
npm ci && npm run lint                # formatting; `zig fmt --check src tools build.zig` for Zig

npm run build && cd demo && npm install && npm run dev   # the demo site, against js/
```

CI runs all of the above, the parity check below, and a soak over the three committed real
measurements. It also installs the packed tarball and runs a fit through it.

Unit tests and the parity harness run on the host target. `smoke.mjs` and `soak.mjs` are
the only checks of the wasm a browser actually gets. `smoke.mjs` also fails if the SIMD and
plain builds disagree by a single bit.

## Formatting

JavaScript and Markdown are formatted by Prettier (`.prettierrc`: tabs, single quotes, no
trailing commas, 100 columns). Zig is formatted by `zig fmt`. CI checks both.

## Parity with AutoEq

```sh
zig build dump && python tools/parity/compare.py candidate.json
```

The fixtures are committed, so checking parity needs no AutoEq checkout. Regenerating them
does. [tools/parity/README.md](tools/parity/README.md) covers setup, tolerances and the
candidate schema.

Two rules for fixtures:

- **Add a case with `dump_fixtures.py --only <id>`, never a blanket regeneration.**
  Upstream's optimizer lands in a different local minimum depending on the BLAS underneath
  it, so regenerating everything would bury one real change in noise across every fixture.
- **Bump the upstream pin and regenerate together, never separately.** The pin is recorded
  in the `AutoEq` gitlink, in `tools/parity/fixtures/manifest.json` and in `CLAUDE.md`, and
  all three must agree.

[Fidelity](docs/fidelity.md) describes what the harness checks and why the optimizer is
judged on loss.

## Changing the solver or its kernel

The eight fixtures cannot judge a change to the optimizer. The fit is chaotic: moving the
last bit of one logarithm sends a third of 12-band fits more than 1% up or down in loss.
Judge such a change over a few hundred real measurements instead:

```sh
node tools/soak/soak.mjs --target TARGET --peaking 8,12,16,20 \
    --wasm BEFORE.wasm --tsv before.tsv MEASUREMENTS_DIR
node tools/soak/soak.mjs --target TARGET --peaking 8,12,16,20 \
    --wasm AFTER.wasm --tsv after.tsv MEASUREMENTS_DIR
node tools/soak/compare.mjs before.tsv after.tsv
```

A change that costs nothing shows a median loss ratio of 1.0000, and a p10 to p90 spread no
wider than a last-bit change alone produces. [BENCHMARKS.md](BENCHMARKS.md) has that
spread, and names a public measurement set to run it on.

## Benchmarks

```sh
zig build bench -Doptimize=ReleaseFast        # whole pipeline
zig build bench-fit -Doptimize=ReleaseFast    # fit only, on the parity fixtures
node tools/soak/soak.mjs --target TARGET DIR  # the wasm over a directory of measurements
```

Timing upstream for comparison needs the AutoEq checkout, via
`tools/parity/time_upstream.py`. `bench-fit` and `time_upstream.py` time the same span on the
same inputs; keep their config lists in step, and re-run both before quoting a ratio.
Every number quoted anywhere goes in [BENCHMARKS.md](BENCHMARKS.md) with the command that
produced it.

## Where things are

| Path                               | What it is                                                             |
| ---------------------------------- | ---------------------------------------------------------------------- |
| `src/`                             | The Zig implementation. `pipeline.zig` is the entry point.             |
| `src/wasm.zig`                     | The wasm interface. Positional and append-only.                        |
| `js/`                              | The JavaScript binding, its types, and the EqualizerAPO module.        |
| `tools/parity/`                    | Fixture generator and comparator: the port's ground truth.             |
| `tools/dump_candidate/`            | The Zig side of the parity harness.                                    |
| `tools/bench/`                     | `bench` and `bench-fit`.                                               |
| `tools/wasm_smoke/`, `tools/soak/` | Checks of the wasm artifact; `soak/compare.mjs` compares two soak runs |
| `demo/`                            | The GitHub Pages site. Vite, links the root package.                   |
| `AutoEq/`                          | Upstream, as a pinned submodule. Read-only.                            |

`CLAUDE.md` holds the project's invariants and the verified upstream gotchas in full. Read
it before changing anything under `src/`.

## Licence

turboEQ is MPL-2.0. AutoEq is MIT and SciPy is BSD-3-Clause. Keep the attribution line in
every file derived from either, and keep `NOTICE` in anything distributed.
