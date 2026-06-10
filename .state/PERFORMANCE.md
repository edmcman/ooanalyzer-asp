# mysql.exe Performance Notes

## Current Recommendation

Best known 3-hour mysql.exe setting:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --heuristic=domain \
  --opt-strategy=usc,oll,disjoint,succinct,stratify \
  --restart-on-model \
  --time-limit 10800
```

Best incumbent found so far: `[-2576,-30947]`.

This came from `.state/perf/mysql_3h3_domain_usc_oll_alltactics_restart.log`.
The run found the usual `[-2576,-6116]`, improved to `[-2576,-7214]`, then made
a large late jump to `[-2576,-30947]` at 9959s. Final lower bound was
`[-2576,-33472]`, leaving a gap of 2525 on the low-priority objective.

Use `-t1` unless specifically testing parallel search. The best known incumbent
was found single-threaded; `-t4` and `-t8` did not reproduce the late jump in
their completed 3-hour probes.

## Latest Batch

Completed 2026-06-08:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python .state/perf/run_mysql_best_restart_batch.py
```

Summary TSV:

```text
.state/perf/mysql_3h4_best_restart_summary.tsv
```

Matrix:

| Group | Variants | Purpose |
|---|---|---|
| Repeatability | `--seed=1..8` | Test whether the `[-2576,-30947]` jump is consistent or a lucky tail |
| Threading | `--seed=1 -t8` | Check whether default parallel search preserves the late restart-on-model jump |
| Shrinking | `--seed=1 --opt-usc-shrink={lin,inv,bin,rgs,exp,min}` | Test whether core shrinking helps longer-tail proof/incumbent progress |

Conclusion: the late `[-2576,-30947]` jump is repeatable single-threaded. All
eight repeat seeds and all six shrink variants reached `[-2576,-7214]` within
about 5.0-5.6 minutes, then reached `[-2576,-30947]` after a long stall around
9206-9508s. The `-t8` run used clingo's default `compete` mode, reached
`[-2576,-7214]` much later, at 784.48s, and finished without the late jump.

| Group | Final result | Takeaway |
|---|---|---|
| 8 repeats, `-t1` | 8/8 at `[-2576,-30947]` | Late jump is not seed luck |
| Shrink variants | 6/6 at `[-2576,-30947]` | No shrink algorithm improved the incumbent or bound in 3h |
| `-t8` / `-t 8,compete` | `[-2576,-7214]`, lower `[-2576,-33717]` | Threads still hurt incumbent quality |

Model-inspection run:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  -n 0 -d --stats --heuristic=domain \
  --opt-strategy=usc,oll,disjoint,succinct,stratify \
  --restart-on-model --seed=1 --time-limit 10800 \
  > .state/perf/mysql_3h4_best_restart_modeldiff_seed1.log 2>&1
```

This is intentionally not `--benchmark`, so model atoms and diffs are available
for inspection. It has already captured the transition from `[-2576,-6116]` to
`[-2576,-7214]`, and then the late transition to `[-2576,-30947]` at 9213.32s.
That final transition kept the high-priority vftable objective fixed at `-2576`
and improved the low-priority objective by 23733. The delta was dominated by
class/role restructuring: `+2647/-33 mergeClasses`, `+77/-25 constructor`,
`+25/-77 realDestructor`, `+133/-25 vftableBelongsToClass`, and swapped
18 `vfTableOverwrite` atoms.

## Main Conclusions

### Domain + Stratified USC Is Best

Domain heuristic plus stratified OLL USC consistently starts on the good
high-priority layer (`-2576`). Plain Domain branch-and-bound also starts there,
but plateaus at `[-2576,-6116]`. Adding stratified USC finds better incumbents.

Completed 3-hour Domain USC results:

| Setting | Models | Final cost | Lower bound | Takeaway |
|---|---:|---:|---:|---|
| `usc,oll,disjoint,succinct,stratify --restart-on-model` | 3 | `[-2576,-30947]` | `[-2576,-33472]` | Best known incumbent; late jump |
| `usc,oll,disjoint,succinct,stratify` | 2 | `[-2576,-7214]` | `[-2576,-33772]` | Strong, but missed late jump |
| `usc,oll,disjoint,stratify` | 2 | `[-2576,-7214]` | `[-2576,-33772]` | Same incumbent as all-tactics |
| `usc,oll,stratify` | 2 | `[-2576,-7214]` | `[-2576,-33423]` | Same incumbent, better bound |
| `usc,oll,succinct,stratify` | 2 | `[-2576,-7214]` | `[-2576,-33423]` | Same incumbent, better bound |
| `usc,k` | 1 | `[-2576,-6116]` | `[-2576,-33026]` | Good proof progress, poor incumbent |
| `usc,pmres` | 1 | `[-2576,-6116]` | `[-2576,-33043]` | Good proof progress, poor incumbent |

Interpretation: `--restart-on-model` matters for escaping the `[-2576,-7214]`
plateau, and the effect is repeatable for single-threaded Domain + stratified
USC. It did not help branch-and-bound, but it did help the Domain + stratified
USC setting.

### Branch-And-Bound Is Still Not A Good Long-Run Option

The desired BB behavior was "many models, still climbing late, and eventually
on the `-2576` high-priority layer." No tested BB configuration achieved that.

| BB setting | Final behavior | Takeaway |
|---|---|---|
| `domain + bb,{lin,hier,inc,dec}` | One model at `[-2576,-6116]` | Good high-priority layer, no incumbent stream |
| `vsids + bb,*` | No model in loaded 3-hour batch | Poor model construction under load |
| `none + bb,lin` | 4642 models, final `[-844,-5340]` | Many models, wrong high-priority basin |
| `none + bb,lin --restart-on-model` | 1431 models, final `[-1456,-1915]` | Many models, still wrong basin |
| `none + bb,hier` | 83 models, final `[-1804,-557]` | Better high-priority progress, still far from `-2576` |

Raw model count is misleading. `heuristic=None` can stream models, but mostly
walks the low-priority objective while stuck far from the important vftable
objective layer.

### VSIDS Stalls Are Structural, Not Just Seed Luck

Short seed probes with plain VSIDS were very similar: all started in the same
bad high-priority region and made low-priority improvements without escaping.
Core-guided optimization fixes/proves the high-priority layer more reliably
than VSIDS branch-and-bound.

Earlier stable patterns:

| Setting | Typical result | Takeaway |
|---|---|---|
| `vsids + bb,lin` | Many models around `[-932,*]` to `[-1132,*]` | Active search, wrong objective basin |
| `vsids + usc,oll` | Fast `[-2576,-6048]` | Good sanity check, weak incumbent |
| `vsids + usc,k` | Best proof progress in earlier batch | Useful for lower-bound/proof comparisons |
| `vsids + stratified USC` | Up to `[-2576,-6398]` | Former best before Domain+restart result |

### Threads Are Not A Quality Win Yet

Completed thread probes for the best Domain+USC all-tactics setting:

| Threads | Final cost | Lower bound | Max RSS | Takeaway |
|---:|---:|---:|---:|---|
| `-t1 --restart-on-model` | `[-2576,-30947]` | `[-2576,-33472]` | 2.91 GB | Best known incumbent |
| `-t4` | `[-2576,-7214]` | `[-2576,-33772]` | 5.26 GB | No late jump |
| `-t8` / `-t 8,compete` | `[-2576,-7214]` | `[-2576,-33707]` | 8.41 GB | No late jump |
| `-t 8,compete --restart-on-model` | `[-2576,-7214]` | `[-2576,-33717]` | 8.41 GB | No late jump |

Parallel search changes the trajectory, not just the runtime. Plain `-t8`
means `-t 8,compete`; `-t 8,split` has not been tested yet.

### Shrinking Did Not Help The 3h Incumbent

All tested `--opt-usc-shrink` algorithms with `--restart-on-model` found the
same `[-2576,-30947]` incumbent as the default setting. Their final lower bound
was also `[-2576,-33452]`, so there is no 3-hour evidence yet that shrinking
improves mysql.exe on this configuration.

## Staged Optimization Diagnostics

Added optional constants for fixing the high-priority vftable-size layer:

```prolog
#const min_vftable_size_total = 0.
#const max_vftable_size_total = 0.
```

These constrain:

```prolog
vftableSizeTotal(Total) :-
    Total = #sum { Size, VFTable : vfTableSize(VFTable, Size) }.
```

Use:

```sh
--const min_vftable_size_total=2576 \
--const max_vftable_size_total=2576
```

Important result: exact `vftableSizeTotal=2576` did **not** make VSIDS a good
lower-priority model constructor. Domain could still construct `[-2576,-6116]`,
but staged VSIDS BB/USC variants often found no model in 3h. This means Domain
is helping with coherent merge/constructor/model construction, not merely
forcing the vftable total.

Also note: `--opt-mode=opt,-2576` only seeds an incumbent bound; it does not
constrain/prove the high-priority layer. Use the LP constants above for staged
experiments.

## Diagnostic Signals

Conflict profiling after the old Domain plateau repeatedly pointed at:

| Predicate family | Rough role |
|---|---|
| `constructorDestructorKind` | Constructor/destructor role ambiguity |
| `mergeClasses` | Class merge decisions |
| `constructor` | Constructor selection |
| `vfTableSize` | Vftable-size choices |
| `strongMergeCandidate` / `vfTableEntry` | Merge/vftable evidence |

Hot individual atoms often involved duplicate vftable writers and
constructor/destructor role choices, including `yaSSL::Data` and
`TaoCrypt::SHA512/SHA384` vftables.

Useful profiling command:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --heuristic=domain --time-limit 70 \
  --profile-after-first-model --profile-conflicts \
  --diagnose-vftable-objective --diagnose-vftable-limit 20
```

## Evidence Index

| Artifact | Purpose |
|---|---|
| `.state/perf/mysql_3h3_domain_usc_oll_alltactics_restart.log` | Best known run, `[-2576,-30947]` |
| `.state/perf/mysql_3h2_summary.tsv` | Completed 28-way BB/USC comparison |
| `.state/perf/mysql_3h4_best_restart_summary.tsv` | Completed repeat/thread/shrink batch |
| `.state/perf/mysql_3h4_best_restart_modeldiff_seed1.log` | Completed `-n 0 -d` model-inspection run |
| `.state/perf/run_mysql_best_restart_batch.py` | Reproducible runner for current active batch |
| `.state/perf/run_mysql_longterm_batch.py` | Reproducible runner for completed 28-way comparison |

## Active Probe

Started 2026-06-08:

Default `-t8,split` / `-t 8,split` was not a valid split test: clingo printed
`Selected strategies imply Mode=compete` and followed the known compete-style
trajectory. Pinning the ASP preset explicitly did not help; the run below also
printed `Selected strategies imply Mode=compete` and was stopped after the first
model:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run python ooanalyzer.py \
  examples/ooa/mysql.exe.lp \
  --benchmark --stats --time-limit 10800 --configuration=tweety \
  --heuristic=domain --opt-strategy=usc,oll,disjoint,succinct,stratify \
  --restart-on-model -t 8,split \
  > .state/perf/mysql_3h5_domain_usc_oll_alltactics_t8_split_tweety_restart.log 2>&1
```

Conclusion: with the current `usc,oll,disjoint,succinct,stratify` optimization
strategy, clingo appears to force parallel mode back to `compete`. There is no
valid `split` result yet for the winning USC setup.

## Next Decisions

- Keep `--restart-on-model` in the recommended mysql command.
- Prefer multiple independent single-threaded runs over `-t8` for incumbent
  quality.
- Test `-t 8,split` separately before ruling out threaded search entirely.
- Treat shrink algorithms as proof/longer-run candidates only; they did not
  improve the 3-hour incumbent or bound in this batch.
- Inspect the `-n 0 -d` model for the `[-2576,-30947]` jump and compare it to
  `[-2576,-7214]` to understand which merge/constructor decisions changed.
