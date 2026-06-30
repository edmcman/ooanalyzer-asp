# Working notes: the merge-reward optimization blocker

Working notes on the `&sameClass`/merge optimization blocker. Reference input:
`examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`. Champion config (now the
Makefile default, see "Champion config" below):
`--configuration=crafty --restarts=F,736` (single-threaded). The earlier
`-n -1 --heuristic=domain --opt-strategy=usc,oll,disjoint,succinct,stratify --restart-on-model`
config is the pre-champion experiment baseline.

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

## Champion config (2026-06-25) — SUPERSEDED by 2026-06-30 entry below

Exhaustive option sweep under the correct **lexicographic** metric
`[comp1, comp2]` (comp1 = vftable MaxSize+gap `@3`, optimized first; comp2 =
merge/ctor/method rewards `@0`; lower = better). The earlier numbers in this file
were measured under the wrong metric (comp2-in-isolation while comp1 was
unproven) and are superseded here.

**Champion: `--configuration=crafty --restarts=F,736` → `[-704, -42666]`**
@ 120/300/600s (comp1 settled to its proven optimum -704; comp2 = -42666, proven
LB -50230, **gap 7564**). Single-threaded — threads break comp1.

Key facts (all single-trial, deterministic, lexicographic metric):
- Only `--configuration=crafty` settles comp1=-704; handy/jumpy/trendy/frumpy
  abandon comp1 (wreck lexicographically). `--restarts=F,<N>` is required; the
  default restart schedule never settles comp1 in 300s.
- comp1 settling is **sharp/quasi-periodic** in the F value: near F736 it
  alternates F720✓ F728✗ F736✓ F744✗ F752✓ (~16 apart); F744 collapses comp1 to
  -72. F736 is the comp2 peak among settlers.
- comp2=-42666 is a **strategy-invariant plateau**, not search luck: five
  opt-cores (bb,lin / bb,inc / bb,dec / usc / usc,1) AND four heuristics
  (vsids/berkmin/vmtf/eq3) all reproduce the identical incumbent at F736, and it
  is frozen across 120/300/600s. Every option that perturbs the restart trajectory
  (opt-heuristic=sign, save-progress, deletion=0, opt-mode=optN, threads) breaks
  comp1 and loses lexicographically.
- So the solver-option knob is **genuinely tapped**. The 7564 gap to the LB is
  encoding-level (conditional merge mutexes hidden behind `&sameClass`).

Lineage: default `bb,lin,vsids,neg` `[-636,-34521]` → `--restarts=F,256`
`[-704,-35832]` → `crafty+F512` `[-704,-42257]` → `crafty+F768` `[-704,-42450]`
→ **`crafty+F736` `[-704,-42666]`**. Logs: `autoresearch/classic-260625-0952/`.

## ASP-side experiments (2026-06-25/26, user lifted the "don't edit ASP" ban,
kept "must not change the results") — all NEGATIVE, all reverted

Four experiments attacked the AGENTS.md "expose the Boolean structure" direction.
All were sound (prune only already-forbidden assignments) and all reverted; the
champion `[-704,-42666]` source is the committed tree (no stash/branch).

1. **Spanning-tree reason** (iter17, Rust-only): replaced
   `component_reasons` (all internal merge edges, O(n²)) with a spanning-tree
   reason (n−1 edges) in `rust/src/uf.rs` → `component_cut_and_reasons`. NEGATIVE:
   lemma size unchanged (691 vs 693 lits/lemma); conflicts +14.5%. clingo
   re-minimizes the propagator nogood, and the **CUT** (all-false boundary merge
   edges of the dense ~14-method component) dominates the kept literal set, not
   the reason. Reason-set shaping is a dead end. Reverted to `component_reasons`.

2. **Entailed transitivity constraint** (iter18, ASP): added the ordinary entailed
   clause `:- mergeClasses(A,B), mergeClasses(B,C), -mergeClasses(A,C).` to
   `src/modules/merges.lp` (sound: &sameClass is the closure of mergeClasses, so
   mc(A,B)&mc(B,C) ⇒ &sameClass(A,C), already forbidden by line 163). NEGATIVE:
   LB stayed **exactly -50230** in every run (default + `bb,hier`); best comp2
   regressed to -42353 (the constraint perturbed the F736 trajectory, F736 now
   breaks comp1). The static-mutex part being exposed didn't move the LB because
   the reward-maximizing relaxation evades static mutexes by choosing
   theory-mutex leaves whose `-mergeClasses` isn't active without the propagator.

3. **LB-proof profiling** (iter19, diagnostic): three independent diagnostics
   confirm theory-shaped merge mutexes are the **SOLE** limiter. (a) `usc,1` →
   `lower.unsat=0` (zero tightening cores). (b) iter18's static constraint moved
   the LB by zero. (c) Merge-rewards-REMOVED (temporarily commented the three
   `#maximize`) → `[-704,-32705]` with LB==incumbent, gap=0, **OPTIMUM FOUND in
   27.79s**. Arithmetic: merge trivial sum=17525, optimum collects=9961,
   uncollectible=7564 = exactly the gap. So merge rewards are the *entire* 7564
   gap; without them comp2 is provably optimal in 28s.
   **Side finding:** `enable_merge_rewards` is documented in AGENTS.md but NOT
   implemented (absent from `config.lp`/`merges.lp`; the `#maximize` are ungated)
   — `--const enable_merge_rewards=0` is a silent no-op.

4. **sameClass materialization** (iter20, ASP — the "missing booleans" test the
   user asked for): added an ordinary `sameClass/2` closure
   (refl+sym+trans over `mergeEntity`) to `src/modules/merges.lp` and substituted
   `&sameClass → sameClass` in the theory-gated `-mergeClasses` rules F (line 87),
   C (98-99), R (142,144); kept `&sameClass`+propagator for line 163 and the
   merge/reward rules. Grounding **feasible** (the cubic-blowup fear did not hit
   on TinyXml): 24.6s, 3.4GB, 101,756 sameClass atoms (sparse — 3190 entities
   would be ~10M as a full clique; not the `_closed×_closed` anti-pattern;
   `derivedClass/3` only 14 so F's domain is tiny). NEGATIVE and **definitive**:
   LB stayed **exactly -50230**, `usc,1` `lower.unsat=0` (zero cores even with the
   full ordinary Boolean closure visible to the relaxation); comp1 broke
   -704→-80 (trajectory perturbed). **This falsifies the "missing booleans"
   hypothesis.** The merge mutexes are **CONDITIONAL**, not static:
   `-mc(W1,W2) :- derivedClass(DC1,W1,_), derivedClass(DC2,W2,_),
   sameClass(DC1,DC2), …` forbids merging W1,W2 only when DC1,DC2 are same-class.
   In the reward-maximizing LB relaxation the merges are free, so it collects the
   W1-W2 reward while leaving the conditioning `mergeClasses(DC1,DC2)` (and its
   path) **false** to avoid firing the `-mc`. The condition and the reward sit on
   different free merge choices, so the relaxation never hits a Boolean conflict
   — whether the condition is ordinary `sameClass` or theory-gated `&sameClass`.
   **Theory-gating was a red herring: the booleans were never missing, they were
   conditional, and conditionality is representation-independent.** Strictly
   stronger than iter18/19: full ordinary closure exposed, LB still cannot see the
   at-most-one.

### Refined root cause and the only remaining direction

The blocker is the **conditional** structure of the merge mutexes (condition and
reward on different free merge choices), not their representation as theory
atoms. Exposing the closure, entailed static transitivity, or spanning-tree
reasons all fail for the same reason: none breaks the condition/reward
separation. The only untried sound direction is to break that separation
directly — per-hub explicit at-most-one `:- mergeClasses(H,Li), mergeClasses(H,Lj)`
keyed **only** on *statically-known* (unconditional) mutex leaf pairs (where the
leaf-leaf mutex is `reasonNOTMergeClasses_E/I/K`-shaped — ordinary, no
`&sameClass` in the body — not F/C/R/J-shaped conditional ones), or a
propagator-side reformulation that emits the per-hub at-most-one as a learned
cardinality rather than a transitive-chain reason. Both are strictly harder than
"materialize the closure" and out of scope of the "don't change results"
constraint. Until then the champion `[-704,-42666]` stands and the 7564 gap is
intrinsic.

## Champion config (2026-06-30) — current Makefile default

After adding `reasonMergeClasses_B` + `reasonReusedImplementation_B`, the old
champion `crafty+F,736` no longer settles `comp1=-704` (gets -656 instead). The
problem structure shifted: the `reusedImplementation` rule creates new evidence
that changes the vftable objective's achievable optimum under the crafty
restart trajectory. `--heuristic=domain` with default `bb,lin` recovers
`comp1=-704` trivially on the first model (~5-6s) but produces a weaker `comp2`
than the old champion.

Key discovery from 31-iteration sweep (see `autoresearch/improve-260629-2245/`):
`-t4,compete --restarts=F,512` with `--heuristic=domain` is the new champion.

**Why threads + F-restarts**: 4 threads each explore different regions and
periodically sync via shared-clause learning. The geometric F-restart schedule
(F,512 → 1024 → 2048...) produces burst-pattern improvement: a fast initial
burst (5-20s) and a second burst around 200-225s when the schedule reaches its
5th-6th cycle. The diversity from 4 thread seeds is what enables the second
burst — single-thread F,512 only gains +221 over baseline.

**Thread count sensitivity** (domain heuristic, 300s, F,512):
- t2: 1-2 models only, terrible (-32977); thread diversity too low
- t4: 4 threads, excellent (-39253 to -39582)
- t8: mediocre (-36213 without F, terrible -32943 with F,512); overhead+interference
- t16+: FAILS — domain heuristic requires lookback; clasp auto-assigns a
  no-lookback thread at position ≥14 → `RuntimeError: Heuristic requires lookback`

**F-value sweep** (t4,compete, 300s):

| F value | comp2 | notes |
|--:|--:|---|
| F,128 | -38999 | good but leaves money on table |
| F,192 | -37777 | mediocre |
| F,256 | -39582 / -38266 | best peak, high variance (±656) |
| F,320 | -35482 | poor |
| F,448 | -37494 | mediocre |
| **F,512** | **-39253 / -38971** | **best avg, tight variance (±141)** |
| F,736 | -35771 | too long; restarts rarely fire |
| F,1024 | -33198 | effectively no restarts |

Recommendation: **F,512** for production (avg -39112, tighter variance). F,256
achieves the best single run (-39582) but variance is 4.6× wider.

**Things that hurt with t4**:
- `--save-progress=20`: −35482 (retaining assignments disrupts thread diversity)
- Luby restarts: −35798 (geometric F beats Luby with threads)
- USC strategies: `usc,oll` consistently hurts both UB and LB; threads don't change this

**New gap analysis**: LB for domain+bb,lin on this problem is -49774.
Champion finds -39582 (best single) or avg -39112 (F,512). Gap: 10192 (best) to
10662 (avg). The gap is *larger* than old (-7564) because the new rules raised the
optimal and the conditional-mutex LB-proof bottleneck is unchanged. The
`notMergeUnsorted` predicate (29.4% backtracks, avg level 4540) is still the dominant
backtracking site; method 4948404 appears in 8207 backtracking pairs as a hub.

**What was NOT tried** (viable next ideas):
- Per-solver-thread template config to allow t16 with domain (set heuristic
  per-thread via JSON template rather than CLI `--heuristic=domain`)
- `--no-inter-learn` disable clause sharing (option not available in this clingo)
- Staged optimization: find best UB with domain/t4, re-solve with tight bound +
  Boolean AMO exclusions to close the LB gap

Logs: `autoresearch/improve-260629-2245/` (31 iterations, iter0-iter31).
