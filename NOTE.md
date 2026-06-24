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
