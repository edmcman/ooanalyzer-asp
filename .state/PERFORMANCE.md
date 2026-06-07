# Next Steps

## mysql.exe domain-heuristic plateau

Current `--heuristic=domain` behavior on `examples/ooa/mysql.exe.lp`:

- First model usually arrives around 50-52 seconds.
- First model cost is typically `[-2576, -6116]`.
- After that, solving can spend more than five minutes without a better model.
- The high-priority lower bound remains `-2720`, leaving a gap of `144`.

The long plateau is stable in the conflict profiler. After the first model, the
dominant backtracked predicates are usually:

- `constructorDestructorKind`: about 29%
- `mergeClasses`: about 29%
- `constructor`: about 15%
- `vfTableSize`: about 11%
- `strongMergeCandidate` / `vfTableEntry`: about 7% each

The hottest individual atoms repeatedly involve duplicate vftable writers and
constructor/destructor role choices, for example:

- `yaSSL::Data::Data@4553808` / `yaSSL::Data::Data@4553856` with
  `yaSSL::Data::vftable@7781660`
- `TaoCrypt::SHA512::SHA512@4597680` / `TaoCrypt::SHA512::SHA512@4672192`
  with `TaoCrypt::SHA512::vftable@7784432`
- `TaoCrypt::SHA384::SHA384@4597584` / `TaoCrypt::SHA384::SHA384@4672080`
  with `TaoCrypt::SHA384::vftable@7784472`

## Committed instrumentation

Opt-in diagnostics in `ooanalyzer.py` (committed in `973790c Add plateau profiling for optimization stalls`):

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --heuristic=domain --time-limit 70 \
  --profile-after-first-model --profile-conflicts \
  --diagnose-vftable-objective --diagnose-vftable-limit 20
```

Short run on 2026-06-06:

- First model: `[-2576, -6116]` at 50.75s.
- First-model vftable objective decomposition:
  - selected vftables: 82
  - selected size total: 2576
  - selected candidate max total: 2800
  - selected size gap total: 224
  - unselected possible vftables: 0
- Timeout lower bound: `[-2720, -34496]`, so the proven high-priority gap from
  the first model was 144, even though the selected-table local gap sum was 224.
- Post-first conflict window: 346,025 watched backtracks over 56.9s. Top
  predicates were `constructorDestructorKind` (18.6%), `weakMergeReward`
  (13.0%), `mergeClasses` (12.7%), `strongMergeReward` (11.0%),
  `constructor` (10.4%), `weakG1Bonus` (10.0%), and `vfTableSize` (8.5%).
- Largest individual atoms in this window involved ctor/dtor choices and
  merges for `4534528`/`4671968` with `7781352`, and `4553040`/`4553072`
  with `7781632`.

Interpretation so far: this does not look like a few large false vftable
candidates polluting the bound. The first model selected every possible vftable
candidate seen by `possibleVFTableMaxSize/2`; the remaining high-priority
improvement is spread across many selected tables that are each one pointer
short of their candidate maximum.

## Experiments that did not help

Do not commit these without new evidence:

- `--opt-strategy=bb,hier`: same first model, much worse conflict count.
- `--opt-strategy=bb,inc`: same first model, much worse conflict count.
- `--opt-heuristic=model`: no second model in the tested window.
- `--restart-on-model`: no second model in the tested window.
- `--const enable_weak_g1_bonus=0`: much slower first model.
- Biasing `guessEnabled(merge)` true: no model in 240 seconds.
- Heuristics for duplicate vftable writers or duplicate real destructors:
  either worse, or only tiny plateau savings without real progress.

## Additional heuristic/config probes

Short mysql probes on 2026-06-06 used:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --heuristic=domain --time-limit 240 \
  --diagnose-vftable-objective --diagnose-vftable-limit 5 ...
```

Results:

| Variant | First model | Models in window | Final/lower-bound notes |
|---|---:|---:|---|
| `--opt-heuristic=sign` | `[-2576, -6116]` at 49.59s | 1 | lower `[-2720, -34496]`; no improvement |
| `--opt-strategy=bb,dec` | `[-2576, -6116]` at 49.53s | 1 | lower `[-2719, -34496]`; much higher conflicts |
| `--opt-strategy=usc,oll` | `[-2576, -6116]` at 49.66s | 1 | quickly proves high-priority lower `[-2576, ...]`, then slowly raises low-priority bound |
| `--configuration=trendy --heuristic=domain` | `[-2576, -6116]` at 49.30s | 1 | lower `[-2720, -35130]`; no improvement |
| `--configuration=handy --heuristic=domain` | `[-2576, -6116]` at 49.51s | 1 | lower `[-2720, -35130]`; no improvement |

The configuration probes required a small driver option so presets are applied
before the explicit heuristic, preserving `--heuristic=domain`.

Interpretation: none of these is a better branch-and-bound heuristic for finding
a second model. `usc,oll` is the one useful signal: the first model's
high-priority vftable score appears provable quickly under core-guided
optimization, so the remaining pain is mostly the low-priority merge-reward
layer after the vftable bound is fixed.

## Bound-mode probes

Short mysql probe on 2026-06-07:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --heuristic=domain \
  --opt-mode=opt,-2576 --time-limit 300 \
  --diagnose-vftable-objective --diagnose-vftable-limit 5
```

Result:

- First model: `[-2576, -6116]` at 49.60s.
- Same vftable decomposition as the normal Domain first model:
  selected size total 2576, selected candidate max total 2800, selected gap
  total 224, no unselected possible vftables.
- No second model in the 300s window.
- Final lower bound remained `[-2720, -34496]`.
- Choices/conflicts: 295,292 choices, 83,649 conflicts.

Interpretation: `--opt-mode=opt,-2576` appears to seed an incumbent optimization
bound but does **not** constrain/prove the high-priority layer for branch-and-
bound. It behaved like the baseline Domain plateau, so it is not the staged
optimization mechanism we need.

## Non-Domain probes

Additional mysql probes on 2026-06-06 focused on understanding why plain VSIDS
gets stuck. These used the same 240s budget and vftable diagnostics.

| Variant | Models | Final result | VFTable diagnostic signal |
|---|---:|---:|---|
| `--heuristic=vsids` | 56 | `[-932, -6200]` | selected size total only 896 initially, 932 final; huge selected gaps remained; `8818788` and `8818780` unselected |
| `--heuristic=vsids --opt-heuristic=sign` | 0 | no model | 5.37M choices, only 1,231 conflicts; objective-sign pressure prevented first model |
| `--heuristic=vsids --opt-strategy=usc,oll` | 1 | `[-2576, -6048]` | reached Domain-quality vftable size total 2576 without `#heuristic` directives; high-priority bound proved quickly |
| `--heuristic=vmtf` | 0 | no model | 111.5M choices, only 2,327 conflicts; much worse first-model behavior |

Plain VSIDS result:

- First model: `[-896, -5809]` at 54.02s.
- First-model vftable decomposition:
  - selected vftables: 75
  - selected size total: 896
  - selected candidate max total: 2124
  - selected size gap total: 1228
  - unselected possible vftables: 2
  - unselected possible max total: 604
  - largest selected gaps: `7785000`, `7785108`, and `7785216` each
    `size=4 max=108 gap=104`
  - unselected candidates: `8818788` (`possible_max=596`) and `8818780`
- Final 240s model: `[-932, -6200]`; vftable size total only reached 932 and
  still had 1192 selected-table gap plus both unselected candidates.

Interpretation: plain branch-and-bound with VSIDS is not merely slow to improve
the vftable objective; it actively spends the window improving low-priority
merge reward inside a bad high-priority region. Core-guided optimization is the
best non-Domain explanation so far: it reaches and proves the high-priority
vftable score without `#heuristic` ordering, which suggests the bad VSIDS run is
mostly a branch-and-bound/model-guided optimization pathology rather than VSIDS
being unable to reason about vftables at all.

## Questions to answer next

- Which exact vftable candidates account for the high-priority gap of `144`?
- Are large false candidates such as `8818788` / `8818780` polluting the bound
  or merely appearing as harmless candidate atoms?
- Is `maxCandidateVFTableSize/2` grounding more broadly than the objective
  actually consumes?
- During the post-first-model plateau, are the hot constructor/merge atoms
  symptoms of proving the high-priority vftable bound, or are they blocking
  low-priority merge reward improvement?
