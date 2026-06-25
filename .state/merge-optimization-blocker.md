# Working notes: the merge-reward optimization blocker

Working notes on the `&sameClass`/merge optimization blocker. Reference input:
`examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`. Standard config:
`-n -1 --heuristic=domain --opt-strategy=usc,oll,disjoint,succinct,stratify --restart-on-model`.

## The blocker, characterized

The high-priority vftable objective (`cost[0]`) is solved and fixed in the first
second. **All** difficulty is the priority-0 merge-reward objective (`cost[1]`).
On TinyXml the solver finds a good model (~−36.7k) in ~60–80s, then the lower
bound crawls (≈10/step) and never closes the gap to the optimistic bound
(~−47k) within 300s.

Problem size (from `--show-guesses` / grounded program):
- `strongMergeCandidate`: 513 (reward 10), `weakMergeCandidate`: 745/751
  (reward 8), `weakG1Bonus`: 745 (reward 9). ~1258 merge soft literals.
- The optimum is **sparse**: only ~45 of 751 weak merges are selectable. Most
  candidates are mutually exclusive.

Conflict profile (`--profile-conflicts`): ≈89% of backtracking is on the merge
cluster (`mergeClasses` ~44%, `notMergeUnsorted`, the three reward atoms,
`constructor`). The vftable objective is ~0%. Backtracks happen at an **average
decision level ~4,200** — the solver builds enormous merge assignments before
backjumping.

## It is intrinsic proof difficulty, NOT repeated/wasted work

Three "repeated work" hypotheses were tested and **rejected with data**:
1. **Propagator regenerating reason clauses** — no. Instrumented every
   `add_clause` site: ~25k clauses emitted in 90s, ~0 regeneration of the real
   mutex (`not_same_cut`) clauses (1.0×).
2. **A pathological hub atom** — no. Top individual churned atom is only 0.1%;
   churn is broadly distributed across thousands of merge atoms.
3. **CDCL deleting and re-deriving mutex lemmas** — no. `--deletion=no`,
   `--del-glue=2`, large `--del-max` make **no** difference to the lower bound;
   retaining clauses doesn't help.

USC extracts ~hundreds-to-thousands of *distinct* unsat cores (one per
unachievable reward unit), each requiring a deep (~4,200-level) search through
the **conditional** mutex structure. There is essentially no static skeleton to
exploit: the grounded program has **0 forced-merge facts**; the 1325 static
(fact-level) `-mergeClasses` mutexes mostly fall on non-candidate pairs (only 39
land on a rewarded candidate). The ~700 unselectable weak candidates are blocked
by *conditional* mutexes (depending on `&sameClass`/transitivity), which static
analysis cannot prune. Hence static candidate pruning ("kill statically-dead
candidates") caps out at 39/1264 (~3%) and is already neutralized by the
encoding — not worth pursuing.

## Levers tried and their verdicts

- **Heuristics** (`domain`/`vsids`/`vmtf`/`berkmin`): `domain` is best for the
  upper bound (−36792). `vmtf` gets the best *lower* bound (−48684) but a terrible
  UB — UB-search and LB-proving want opposite heuristics.
- **opt-strategy** (`bb,*` vs `usc`): `usc` wins decisively; all `bb` variants
  fall into a conflict-poor deep-dive (≈35k conflicts / 300M choices) and find
  worse models.
- **Boolean at-most-one mutex exclusions** (entailed nogood
  `:- mergedWith(H,A), mergedWith(H,B), -mergeClasses(A,B)`): a *huge* win on
  clean mutex-clique toys (`merge_conditional_stress.lp`: 22–39× fewer choices),
  and it genuinely **helps the lower bound** on TinyXml (−47904). But it **wrecks
  the upper-bound search** — starves the domain heuristic, deep-dives, regresses
  the best model. Reverted (gated `enable_merge_mutex_exclusions`, removed).
  Real inputs have partial/conditional mutex neighborhoods, not complete cliques.
- **Parallel portfolio** (`-t2`, domain-UB + vmtf-LB): regresses. The shared
  incumbent bound disrupts the domain thread's incremental climb, AND the Python
  propagator is **GIL-bound (140% CPU on 2 threads)**, so it can't scale anyway.

Takeaway: the two halves want opposite things — LB-proving wants the mutex
structure as Boolean clauses; UB-search wants the `domain` heuristic free. Any
fix must **decouple** them (e.g. sequential two-phase: find best model, then
re-solve with the bound + exclusions to prove optimality), not couple them in one
search.

## Performance: propagator speed and determinism

py-spy on the 92–300s window: ~38% native clingo, ~52% Python propagator.
Speeding the propagator helps throughput but does not close the (intrinsic) gap.

- The `_UF` was made union-by-size with O(1) component sets (committed) — speed
  only, behavior identical.
- **The search is pathologically sensitive to the propagator's clause-emission
  order.** Iterating Python sets (`absorbed`, `true_sc`, `_now_writers_by_vft`,
  `_awc_by_vft`, clause `reason`/`cut`) used hash order, which differs between
  CPython and PyPy and shifts under refactors → divergent trajectories. Fixed by
  sorting those iterations (`_okey` helper) so clause emission is deterministic
  and interpreter-independent.

### PyPy spike (see ~/.claude/plans/plan-for-3-splendid-quail.md)

clingo (cffi-based) builds and runs on PyPy via `uv venv --python pypy3.11`;
45/45 propagator tests pass; manual examples match. Interpreter is ~1.3× faster
grounding and ~2.66× more choices/sec.

- **Before the determinism fix**: PyPy diverged → `ep_srv` took 314M choices /
  192.9s vs CPython 26M / 48.4s (PyPy ~4× *slower* despite the faster
  interpreter), and TinyXml found a worse model.
- **After the determinism fix**: CPython and PyPy run the **identical** search
  (`ep_srv`: 28,132,286 choices / 15,244 conflicts, bit-identical), and PyPy
  proves the same optimum in **29.9s vs 50.5s — 1.69× faster**.

So the determinism fix both removes a real fragility and unlocks PyPy as a
near-free single-thread throughput win. PyPy gives no parallelism (still a GIL);
a C++/cffi propagator remains the only path to true multi-core scaling, and is
viable (pyclingo exposes `._rep` C handles; cffi/g++/clang/cmake all present) —
but only worth it once a parallel strategy that actually helps exists.

## Most promising next steps

1. Adopt the determinism fix (+ optionally PyPy) for throughput and
   reproducibility.
2. Sequential two-phase LB/UB decoupling to actually attack the gap.
3. Consider whether the optimality certificate even matters: check if the best
   model already matches the Prolog/ground-truth recovery; if so, cap the time
   budget and ship the anytime result.

## Rust propagator re-analysis (2026-06-25)

Re-ran the TinyXml sweep now that the live propagator is the Rust cdylib
(`ooanalyzer_sameclass`, CPython 3.13, no GIL on the hot path — `propagate`
locks only the calling thread's `ThreadState`; `Shared` is read-only `Arc`).
All runs: `examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`, 300s time limit,
`--benchmark --stats=1 -n -1`. cost[1] is the merge-reward objective (minimize;
more-negative = better model, **higher LB = better**). No config proved optimum;
the ~10k gap in cost[1] never closed for any configuration.

| config | thr | best model | LB | choices | conflicts | tBest |
|---|--:|--:|--:|--:|--:|--:|
| **saveprog20** (baseline +`--save-progress=20`) | 1 | **−36954** | −46991 | 480M | 197k | 24s |
| saveprog20 +`-t2,compete` | 2 | −36954 | −47018 | 1299M | 441k | 106s |
| t2,compete | 2 | −36937 | −47000 | 933M | 640k | 237s |
| baseline (domain, USC, restart-on-model) | 1 | −36877 | −46973 | 367M | 704k | 37s |
| usc-min (+`--opt-usc-shrink=min`) | 1 | −36877 | −46973 | 338M | 700k | 46s |
| h-vsids | 1 | −36688 | −46982 | 332M | 329k | 46s |
| h-berkmin | 1 | −36634 | −47009 | 408M | 102k | 23s |
| t2,split | 2 | −36496 | −46991 | 993M | 1047k | 18s |
| t4,compete | 4 | −36442 | −46991 | 1918M | 669k | 21s |
| no-restart (baseline −`--restart-on-model`) | 1 | −36416 | −46991 | 355M | 471k | 6s |
| bb,lin | 1 | −32943 | −49774 | 993M | 120k | 3s |
| trendy (`--configuration=trendy`) | 1 | −31897* | −50237 | 671M | 153k | 37s |
| h-vmtf | 1 | −2330 | −48694 | 829M | 113k | 4s |

\* trendy under-solves the vftable objective: cost[0] drops to −76 (vs the
fixed −704 everywhere else), so its cost[1] is not comparable.

### Answers

1. **Do threads help?** No (the Rust port answers the open question above).
   The GIL ceiling is gone — throughput scales: t2 did 2.5× choices, t4 did
   5.2×. But it does not translate into results: t2,compete's UB win is +60
   (−36937 vs −36877, within noise), t4,compete is *worse* (−36442), t2,split
   is worse still (−36496), and no threaded run improved the LB. The bottleneck
   is the LB *proof* (serial USC core extraction through ~4200-level
   conditional-mutex searches), not search throughput — exactly the blocker
   this file documents. Removing the GIL unblocked throughput; the algorithm
   still can't use extra threads. saveprog+t2 matched saveprog alone (−36954)
   with 2.7× the choices — pure waste.

2. **BB vs USC.** USC wins decisively. `bb,lin` finds a far worse model
   (−32943) and a worse LB (−49774), with a conflict-poor deep dive: 993M
   choices but only 120k conflicts — it wanders without learning the merge
   mutex cores. USC's 704k conflicts are the core-extraction work that matters.

3. **Heuristics.** domain is best (best UB among single-thread, tied-best LB).
   vsids a close second (−36688). berkmin close (−36634). vmtf catastrophic
   (−2330 — diverges). domain recommended, confirming the pre-Rust finding.

4. **Everything else.**
   - `--save-progress=20` is the one new win: best UB of any config (−36954),
     found fast (24s), and with only 197k conflicts (vs baseline 704k). With
     `--restart-on-model` the LB visibly re-climbs after each incumbent model
     (seen in the live logs: LB drops from −47864 to −47216 right after the
     36.8s model, then re-creeps). Retaining assignments across restarts
     mitigates this. Worth promoting into the default `PROP_FLAGS`.
   - `--opt-usc-shrink=min`: bit-identical to baseline (no help) — confirms
     the earlier verdict.
   - Dropping `--restart-on-model`: slightly worse UB (−36416); restart-on-model
     is net positive for the upper bound.
   - `--configuration=trendy`: not viable (breaks cost[0]).
   - `-t2,split`: worse than `-t2,compete`.

### Takeaway

The Rust propagator succeeded at its stated goal (remove the GIL, speed the
hot path) but did **not** move the optimization blocker — confirming the
prediction in the section above. The only solver-knob that helped at all is
`--save-progress=20` (a modest UB gain). The gap remains intrinsic and
encoding-level: expose the conditional merge mutexes as Boolean structure so
USC can extract a compact bound. Solver knobs are exhausted on this input.

Raw logs: `.state/perf/*.log`, summary: `python3 .state/perf/sum.py`.

### Diverse-heuristic ensemble (added 2026-06-25)

The `-t N` runs above are *homogeneous*: one `--heuristic`/`--opt-strategy`
applied to every thread (threads differ only by seed/restart), because clasp
prefers CLI options over config-file options. A true ensemble needs a
different heuristic per thread, set via the `configuration.solver[i].heuristic`
array with `--heuristic` omitted from the CLI (harness:
`.state/perf/ensemble.py`).

| config | thr (per-thread heuristic) | best model | LB | choices | conflicts | tBest |
|---|--:|--:|--:|--:|--:|--:|
| ens2-dv (domain,vmtf) | 2 | −36941 | −46991 | 1004M | 387k | 77s |
| ens4-dvvb (domain,vmtf,vsids,berkmin) | 4 | −35868 | −47864 | 2716M | 425k | — |

The 2-thread domain+vmtf ensemble (the combo speculated about above) lands at
−36941 — statistically indistinguishable from homogeneous t2,compete (−36937),
a marginal +64 over baseline. The 4-thread diverse ensemble is *worse* on both
UB (−35868) and LB (−47864): adding vmtf/berkmin threads that wander produces
no usable diversity — they burn cores the domain thread could have used, and
the shared incumbent still disrupts the incremental climb. So a real ensemble
does not beat a homogeneous portfolio here, and neither beats `--save-progress=20`
single-threaded (−36954). Confirms: the bottleneck is not search diversity.

### Thread-scaling sweep (homogeneous domain+USC, added 2026-06-25)

Pushed thread count up to 32 (the auto-portfolio mis-assigns a no-lookback
thread ≥16, so t16/t32 use `--configuration=handy` as a lookback base with
`opt_strategy=usc,…` and `heuristic=domain` forced per-thread via the solver
template; cost[0] stays −704, so comparable).

| threads | best model | LB | choices | conflicts |
|--:|--:|--:|--:|--:|
| 1 | −36877 | −46973 | 367M | 704k |
| 2 | **−36937** (peak) | −47000 | 933M | 640k |
| 4 | −36442 | −46991 | 1918M | 669k |
| 8 | −36662 | −47009 | 4563M | 1.42M |
| 16 | −36702 | −47009 | 5206M | 3.55M |
| 32 | −36668 | −46991 | 4843M | 5.27M |

Best model peaks at **t2** and then degrades; the LB is **flat** (−46973→−47009)
across every thread count. The tell: choices scale ~linearly (12× at t8) and
conflicts climb 7.5× (704k→5.27M), yet the bound does not move — the extra
learning is not landing on the deep serial cores the proof needs. So more
threads buy redundant wandering plus incumbent/restart disruption and
clause-sharing pollution, not progress. t32's choices drop below t16's
(4843M < 5206M): 32 threads on 32 cores hit memory-bandwidth / propagator
contention. The GIL was never the limiter; removing it let the machine do more
redundant decisions, which is the wrong thing for a serial-proof bottleneck.
