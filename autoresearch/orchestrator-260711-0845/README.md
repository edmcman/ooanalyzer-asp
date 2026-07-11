# TinyXml long-horizon solver tuning

Goal: improve long-term TinyXml incumbent quality, focusing on objective-aware
phase heuristics and restart cadence.

Mode: `autoresearch` orchestrator, `optimize-metric` archetype, bounded loop.

## Experiment contract

- Input: `examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`
- Baseline: the exact `PROP_FLAGS` search configuration from `Makefile` at
  commit `4b73653ea4cbc595bcfb5452a91363eac4480ddf`.
- The 300-second runs are timing probes only and cannot eliminate a candidate.
  Broad comparison cutoff: 1,800 seconds. Finalist cutoff: 3,600 seconds.
- Metric: lexicographic Clingo cost. Priority 1 must remain `-704`; among such
  runs, a more-negative priority-0 cost is better.
- Primary long-horizon signal: priority-0 improvement after 600 seconds, time
  of the last improving model, and trailing/maximum plateau duration. Final
  cost is secondary: a slower trajectory with sustained late progress is
  preferred over a better early incumbent that freezes.
- Guard: `uv run --offline --no-sync python tests/test_propagator.py`, followed
  by `make verify-core` if a default change is selected.
- Acceptance: materially improve the baseline's late progress in the
  1,800-second comparison, then reproduce that behavior against the baseline
  in matched 3,600-second runs. Parameter-only screens do not mutate source.
- Terminal choice: stop at a verified local change; do not push or publish.

## Safety screen

Benchmark commands invoke only the repository's uv environment, driver, static
TinyXml input, and read-only Clingo flags. They contain no deletion, network,
credential, deployment, or outbound-write operation.

The skill package references `scripts/orchestrate.sh`, but that helper is not
present in the installed package. Its documented classify/screen/ledger steps
are therefore applied directly and recorded here.

## Result

The 1,800-second Domain matrix produced exactly one model in all eight runs.
The extended repeat was stopped by the user after roughly 2,800 seconds; all
seven remaining Domain runs still had exactly one model. Restart counts ranged
from 0 to 9,496 without changing the plateau shape.

- Baseline `sign,model`: `[-704,-46523]`.
- No optimization heuristic: `[-704,-46547]` (24-point endpoint improvement).
- Slow geometric restarts: `[-704,-46577]` (54-point endpoint improvement),
  but no model after 134 seconds and therefore no sustained-progress win.
- Zero/model-only restarts: `[-704,-46444..-46505]`, one model each.
- Non-Domain VSIDS with no optimization heuristic: 1,061 models, but only
  `[-656,-38696]`; its mechanical linear-descent burst ended at 361 seconds,
  followed by a roughly 1,998-second plateau without reaching `-704`.

The Domain final statistics support the existing contextual-learning diagnosis:
average conflict clauses remained 603--651 literals while average backjumps
fell to 4.39--6.31 levels by the interruption. Changing restart cadence changes
the first basin, but none of the tested settings improved traversal afterward.

At the user's direction, `Makefile` now removes
`--opt-heuristic=sign,model`, selecting the reproducible 24-point endpoint win.
This is explicitly not recorded as an anti-plateau fix. The exact revised flags
solve `examples/manual/example.lp` to `OPTIMUM FOUND` at `[-24,-330]`.
The propagator suite passed 62 checks before encountering a pre-existing missing
generated fixture, `examples/ooa/ooex_vs2010/Lite/ooex0.lp`.
