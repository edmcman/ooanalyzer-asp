# Merge-reward optimization: status and experiment ledger

Reference input: `examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`.
Last updated 2026-07-08. Full history of this file (including superseded
measurement tables) is in git; per-experiment logs are in `autoresearch/` and
`.state/perf/`.

> **HOST WARNING.** Everything dated before 2026-07-02 was measured on a
> 32-core machine. The current host is a 4-core/8GB Raspberry Pi, and config
> rankings demonstrably do NOT transfer between them (the old 32-core champion
> stalls, loses, or OOMs here). Treat any pre-2026-07-02 config or cost number
> as historical context only — re-measure before relying on it.

## Current champion (2026-07-02, Pi — the Makefile PROP_FLAGS)

```
--opt-strategy=usc,oll,disjoint,succinct,stratify --heuristic=domain
--restart-on-model --decide-inputs        # single-threaded
```

- TinyXml 300s: `[-704, -44816]`, plateau ~160s; LB stalls at −46982
  (gap 2166, 4.6%). Fully seed-invariant — no restart/seed variance to exploit.
- ep_srv: **OPTIMUM FOUND** `[-644, -50669]` in ~62s.
- muparser NewDebug: `[-252, -58416]` by 192s.
- Accuracy (pairwise co-membership F1 vs name-derived ground truth, TinyXml):
  champion **0.59** ≈ Prolog reference **0.58** (old flags: 0.14). vs the
  Prolog partition directly: F1 0.76. The optimization win is an output-quality
  win, not just a cost number.

Fragile — all measured broken variants: any `-t N` threads (t4: one model;
also OOMs on muparser at 8GB), `--decide-outputs` (0 models), `bb,lin` +
decide-inputs (0 models), dropping `stratify` (−32943), `--restarts=F,512`
(worse both bounds), `--opt-usc-shrink=min` (bit-identical no-op),
`--save-progress=20` (helped pre-direct-edge, hurts after — re-sweep knobs
after any propagator change).

Why decide-inputs works: it redirects fallback decisions from `&sameClass`
theory outputs to the free `mergeClasses` *input* literals (preferring the
fallback pair's own edge — the 2026-07-02 direct-edge refinement), so
branching/phase-saving/learning act on the reward-carrying choice atoms.

## Root cause of the remaining LB gap (established 2026-06, still true)

The merge mutual exclusions are **conditional**: `-mergeClasses(L1,L2)` mostly
holds only when some *other* merge/class condition is active (F/C/R/J-shaped
rules through `&sameClass`). In the reward-maximizing relaxation the condition
and the reward sit on different free merge choices, so the relaxation collects
a reward while leaving its conditioning merge false and never hits a Boolean
conflict. This is representation-independent — proven by materializing the
full ordinary `sameClass/2` closure (grounding feasible: 24.6s/3.4GB on the
32-core host) with **zero** effect on the LB. The conflict profile: ~89% of
backtracking on the merge cluster at average decision level ~4200; USC must
extract each uncollectible-reward core through a deep conditional search.

## Experiment ledger (all closed; details in git history of this file)

Negative / no-effect, with date and one-line verdict:

- **Materialized `sameClass/2` closure** (2026-06-26, iter20): LB unchanged
  (−50230), zero usc cores. Definitive "missing booleans" refutation.
- **Current-encoding grounded `sameClass/2` replay** (2026-07-08): mechanically
  replaced every `&sameClass(A,B)` use with the ordinary closure
  `merged(A,B) :- mergeClasses(A,B)` / symmetric `merged` /
  `sameClass(A,A) :- mergeEntity(A)` /
  `sameClass(A,C) :- sameClass(A,B), merged(B,C)`.  The manual suite passed.
  `&classRelationship` and `&classHasWitness` remained in the Rust propagator,
  so this isolates the main same-class union-find/reason path rather than the
  newer propagator services.  With the standard single-threaded USC/domain/
  decide-inputs flags, TinyXml at 300 s reached `[-704,-36826]`, LB −53262,
  versus the deterministic current propagator plateau `[-704,-36655]`,
  LB −53982.  The small objective/LB gain did **not** improve the recovered
  partition: pairwise co-membership against `.results.orig` on its 370 methods
  was F1 0.0780 (P .9919/R .0406), worse than the matched propagator model's
  F1 0.1175 (P .7328/R .0639), and far below the saved −44816 champion's
  F1 0.7435.  Grounding/preprocessing also turned the closure into a 1.14M-node
  non-tight SCC, 4.74M constraints, ~1.53M loop lemmas, and 2.05 GB peak RSS
  (propagator: 26.9k SCC nodes, 1.14M constraints, 1.19 GB).  Verdict: ordinary
  ASP changes the trajectory and slightly tightens the bound, but provides no
  evidence that the propagator causes the `.results.orig` quality deficit.
- **Entailed static transitivity constraint** (iter18): LB moved zero.
- **Spanning-tree propagator reasons** (iter17): lemma size unchanged — the
  CUT dominates learned clauses, not the reason chain; conflicts +14.5%.
- **Per-hub AMO as gated encoding** (`enable_merge_amo`, 2026-07-02, Pi):
  2387 static + 4453 conditional ground instances, sound, cheap — but no LB
  movement, no bounded-refutation help, slightly worse UB. Reverted. The
  static mutex structure is already exhausted by the lazy propagator clauses.
- **Dynamic hub collection + periodic ASP rewrite** (feasibility measured
  2026-07-03, not built): the idea was to harvest mutexes whose conditions
  become root-fixed during USC hardening and periodically rewrite the program
  with them as facts + native cardinality constraints. Instrumented `check()`
  to count root-fixed-false `&sameClass` literals during a 300s champion run:
  109,723/120,169 fixed at the first check (~12s, init + preprocessing) and
  **zero growth** for the remaining 288s. Hardening entails no new mutexes on
  TinyXml, so the rewrite loop has nothing to promote beyond init-visible
  structure — which the hub-amo test below already proved inert.
- **Per-element-guarded conditional counting** (`enable_vft0_count`, 2026-07-03,
  Pi): the E-family mutexes as an entailed per-hub aggregate — `soloWriter(M,V)`
  (M writes exactly one vftable at offset 0, making the cross-write exception
  impossible) and `:- 2 <= #count { V : mergedWithHub(L,H), soloWriter(L,V) }`.
  Sound (verify-core + manual suite pass), grounds in 5.7s. NEGATIVE: UB −44373
  (vs −44816), LB −47884@254s (behind control), still creeping 10/step.
  Reverted. **This run identified the algorithm-level reason ALL
  representation experiments fail: USC/OLL core width is set by conflict
  discovery, not constraint form. A violated at-most-one conflicts as soon as
  the SECOND element propagates true, so the minimal core has size 2 no matter
  whether the AMO is pairwise clauses, theory chains, or a native cardinality/
  aggregate. The n−1 accounting for an n-clique always takes ~n−1 core
  iterations; no re-encoding shortcuts it.** Stop testing representations.
- **Propagator-side per-hub cardinality** (`--hub-amo`, 2026-07-03, Pi):
  native `Σ mergeClasses(H,Li) ≤ 1` weight constraints at propagator init over
  greedy cliques of `-mergeClasses`-fact mutex leaves, via
  `clingo_propagate_init_add_weight_constraint` (TinyXml: 52 cardinality
  constraints + 13 binary clauses from 1325 static pairs, max clique 6).
  Hypothesis was that OLL would account an n-clique as one wide (n−1)-unit
  core instead of ~n/2 thin pairwise cores. NEGATIVE: LB frozen at exactly
  −46982 again; UB collapsed to −38563 (trajectory perturbation); ep_srv
  unchanged (same optimum, same time). Reverted (the ffi.rs weight-constraint
  and is_fact wrappers were kept as infrastructure). Combined with the AMO
  encoding verdict, this closes the whole "static mutex structure" family:
  pairwise clauses, native counting, eager or lazy — the LB does not move
  because the binding mass is in the *conditional* mutexes, and static cliques
  were already available to the relaxation from t=0. The "promote root-fixed
  mutexes during USC hardening" variant is de-prioritized accordingly.
- **Phase-2 bounded refutation** (`--opt-mode=opt,<incumbent>` + bb, 2026-07-02):
  0 models, no UNSAT in 300s, with or without AMO.
- **Threads** (32-core sweeps t2..t32, and Pi t4): choices scale, bounds don't;
  the LB proof is serial. GIL removal (Rust port) didn't change this.
- **bb vs usc**: usc wins decisively everywhere measured.
- **`--deletion` variants / clause retention**: no LB effect — the difficulty
  is finding cores, not keeping them.
- **Repeated-work hypotheses** (clause regeneration, pathological hub atom,
  lemma re-derivation): all rejected with instrumentation, ~1.0× regeneration.
- **Static candidate pruning**: only 39/1264 rewarded pairs are statically
  dead — ~3% ceiling, already neutralized by the encoding.
- **PyPy interpreter** (pre-Rust-port): superseded — the propagator is now the
  Rust cdylib; CPython 3.13 is the supported interpreter.
- **Old 32-core champions** (`crafty --restarts=F,736` → `[-704,-42666]`;
  later `domain -t4,compete F,512` → ~`[-704,-39253]`): SUPERSEDED, do not
  use — both lose badly to the decide-inputs champion and don't transfer to
  the Pi at all.

Positive, retained:

- **Deterministic clause-emission ordering** in the propagator (sorted
  iteration): load-bearing for reproducibility; keep when refactoring.
- **`--decide-inputs`** (2026-07-01) + **direct-edge refinement** (2026-07-02):
  the step change described above.
- **`--time-limit` interrupt fix** in ooanalyzer.py (2026-07-02): time-limited
  runs previously never wrote `--results`.

## VSIDS secondary-objective plateau (2026-07-08, not Pi)

Matched 600s run with the standard single-threaded USC/decide-inputs flags,
`--heuristic=vsids`, and the restored conservative merge phase directives:

- First model `[-616,-33248]` at 139.8s. Four rapid improvements reached
  `[-704,-33471]` at 141.2s; there was **no further incumbent improvement or
  printed lower-bound progress through 600s**.
- Final search: 69.51M choices, 360,120 conflicts, average backjump 97.70,
  average conflict-clause length 240.3. The solver remains active but its
  learned clauses have very weak leverage on sibling merge configurations.
- Cost `-704` is the sole high-priority vftable-size objective (`size.lp`);
  `-33471` is the broad priority-0 reward layer (methods/ctors/composition and
  strong/weak/late/G1 merges). The plateau begins exactly when search switches
  from the vftable objective to this conditional reward layer.

Strong-only VSIDS initialization was tested by adding, in parallel with the
existing positive phase directive:

```prolog
#heuristic mergeClasses(A, B) : strongMergeCandidate(A, B). [100@2, init]
```

NEGATIVE and reverted. It reproduced the exact five-cost sequence and final
incumbent, reaching `[-704,-33471]` at 141.8s. Final statistics were effectively
identical: 70.08M choices, 360,322 conflicts, average backjump 97.65, average
conflict clause 240.2. Initial VSIDS activity is not the missing lever (and in
any case decays before the priority-0 plateau).

Profiling interpretation:

- Existing long-window conflict profiles drift toward the weak merge family
  (`weakMergeCandidate`/`weakMergeReward`/`weakG1Bonus`), late-F2 rewards, and
  conditional `notMergeUnsorted` consequences. Aggregate aliases by family:
  multiple symbolic predicates can share a solver literal, so their individual
  undo percentages are not independent. `&classHasWitness`/class-size support
  is no longer the hot region after the incremental-support fix.
- ConflictProfiler counts watched-literal undo events, not direct conflict
  causes. Use targeted predicates with caps disabled, and run conflict counting
  separately from backjump tracing because tracing adds a Python `decide`
  callback and materially perturbs VSIDS.
- The first targeted delayed-profile attempt reproduced the same five costs
  (`[-704,-33471]` by 152.3s) but collected **no counts** because the delayed
  watch gate never activated across USC's lifecycle. Do not interpret that run
  as an empty profile. Commit `a87bde1` subsequently moved activation to the
  actual model callback and added duty-cycled watch windows; re-run plateau
  sampling with `--profile-after-first-model --profile-after=150` plus short
  `--profile-window`/`--profile-period` bursts.

## Search is the bottleneck, not the encoding — forced-partition proof (2026-07-08, i9-13900HX)

Host note: measured on a **32-thread i9-13900HX / 96 GB**, NOT the Raspberry Pi named
in the HOST WARNING at the top of this file — reconcile which host that warning refers
to before trusting cross-dated comparisons. TinyXml, current encoding (HEAD `7c2a1d6`),
single-threaded champion flags unless noted, 300 s anytime.

Same-host heuristic sweep (all fall short of the 2026-07-02 Pi champion `[-704,-44816]`):

- **domain** (Makefile PROP_FLAGS): `[-704,-36655]`. First model ~40 s; incumbent **and**
  LB both frozen by t≈51 s — the USC LB took only 7 core bumps (−54222→−53982) then did
  nothing for 249 s. 155M choices / 137k conflicts (~1130 choices/conflict: descends huge
  conflict-free trees).
- **bb,lin** (+domain, decide-inputs): `[-704,-37442]`. 8 improving models to t≈226 s then
  flat; prints **no** lower bound (bb gives no certificate). *Better* incumbent than USC.
  Plateau conflict profile shifts to `lateF2Candidate` (~46%) — bb explores the full
  structure for a better model instead of grinding one core.
- **vsids** (+usc, decide-inputs): `[-704,-33471]`. First model 141 s, 5 rapid models to
  142.8 s, then frozen 157 s — worst of the three. 35M choices / 136k conflicts. Plateau
  ~85–90% merge-reward family, incl. `strongMergeReward` ~19% (domain-USC had strong <1%).

All three plateau on the same conditional weak/strong-merge + `notMergeUnsorted` cluster
(duty-cycled `ConflictProfiler`, commit `a87bde1` — it collects counts now; the clean
no-profiler baseline also gives −36655, so profiling does not distort the score).

**Apparent regression is real, by a determinism argument.** The champion is single-threaded
and seed-invariant, hence deterministic: a faster host can only reach an equal-or-better
point on the *same* trajectory. This i9 is ~10× the Pi yet reaches a *worse* logical state
(−36655, LB −53982 vs the Pi champion −44816 / LB −46982) — only possible if the *program*
changed. ~15 encoding/propagator commits landed 2026-07-03→08 (`reasonObjectInObject_D/E`
grew `objectInObject` 14→286; `reasonMergeClasses_C/H`; `classRelationship`+`classHasWitness`
moved into the propagator; eager theory refutation; "Restore conservative merge phases").
Per the standing "re-sweep knobs after any propagator change" rule, the domain champion is
now stale.

**FORCED-PARTITION PROOF (decisive).** Overlay pinning the previous-good partition
(`.results.orig`, Jun-23 `finalClass`; 69 classes / 370 methods) — forbid cross-class
merges, require every within-class `mergeCandidate` merge — solved under the *current*
encoding + champion flags (`scratchpad/force_goodpartition.lp`):

- **SAT, comp2 −42590** (still improving at the 120 s cutoff; LB −51113, 16.7% error,
  *actively closing*) vs the free search's frozen −36655 (32% error).
- SAT (not UNSAT) ⇒ the current encoding does **not** forbid the good structure;
  ~−42.6K (not ~−36K) ⇒ the reward layer is still present. The free search simply fails
  to reach it, and pinning it also un-freezes the USC lower bound.
- Conclusion: the ~−46K deficit is a **search failure** (branching/heuristic not reaching
  the good partition), *not* encoding infeasibility or a lost reward layer — reproducing
  the earlier ground-truth-forcing finding on the current encoding. Caveat: the overlay
  pins only the 370 classified methods, so −42590 is a conservative floor.

Actionable: re-tune solver config against the current encoding (the domain `#heuristic`
false-biases in `merges.lp` are prime suspects — but vsids, which *ignores* them, scored
*worse*, so it is not simply "domain over-biases"); try warm-starting/seeding toward
candidate-dense partitions; note the LB moves once structure is pinned, so a better
incumbent may itself unblock the certificate.

### Why vsids underperforms domain (2026-07-08, i9) — it's `method`, not merges

Decomposing the comp2 gap by `--show-guesses` selection counts × objective weights
(domain −36655 vs vsids −33471, Δ=3184 in domain's favour):

| component | weight | domain sel | vsids sel | Δ reward (dom−vsids) |
|---|---|---:|---:|---:|
| **`guessMethodReward`** | 10 | **3164/3164** | **2562/3164** | **+6020** |
| constructors 1/3/4 | 10/8/7 | 40/16/11 | 34/1/0 | +257 |
| composition (derived/purecall) | 10/40 | 22/10 | 20/9 | +60 |
| strong/weak/g1/lateF2 merges | 10/8/9/8 | 298/82/50/13 | 239/376/66/153 | **−3113** |
| **net** | | | | **≈ +3224 ≈ Δ** |

The dominant term is `method`: domain takes **all 3164** method rewards (weight 10) via
`#heuristic method(M) [true]` (methods.lp:66); vsids, ignoring the directive, discovers
only 2562 through activity-based search and leaves **602 × 10 = 6020** reward on the floor.
vsids actually collects *more* merge reward (+3113, by over-merging: 2651 co-member pairs
vs domain's 1046, incl. 1411 spurious vs 242) but cannot offset the method loss, and also
loses on constructors/composition. So vsids is worse not because it under-merges but
because it squanders its search budget on the hard merge cluster and neglects the large,
cheap, near-unconditional structural reward pools that domain's `[true]` directives capture
wholesale. Corollary: the domain heuristic's value is the `[true]` captures (method /
strongMerge / embeddedObject), *not* the weak-merge `[false]` suppression — dropping domain
for vsids trades ~6K method reward to (over-)fix merges. The separable lever for the missing
large weak classes is the weak-merge sign bias alone (merges.lp:346 `[10@1, false]`), while
keeping every `[true]` capture.

**Causal summary:** merge decisions generate most of the conflicts, so VSIDS repeatedly
raises their activity and returns to them. Most `method` choices are comparatively quiet:
selecting them is profitable but produces little conflict evidence, so they become nearly
invisible to an activity-based heuristic. VSIDS therefore spends the time budget improving
the variables that explain conflicts, not necessarily the variables with the highest or
cheapest objective gain. This is an objective/heuristic mismatch, not evidence that the
missing method rewards are infeasible.

Two matched 300 s diagnostics confirm the distinction:

- Adding `#heuristic method(M) ... [100@0, init]` did not fix the mismatch. It finished at
  `[-704,-31405]`, worse than plain VSIDS `[-704,-33471]`; one-shot initial activity decays
  once the merge conflict cluster takes over.
- Adding a diagnostic method-only objective tier at `@2` (below vftable size `@3`, above
  the mixed structural/merge pool at `@0`) selected all **3164/3164** methods at 137.4 s
  and reached `[-704,-3164,-40459]` by 300 s. This is strong evidence for staging, but it
  changes the optimization semantics from a weighted mixture to lexicographic method-first.
  A persistent method-first decision callback is the semantics-preserving alternative to
  test if retaining the current objective is required.

Built-in objective-aware phase heuristics are a useful semantics-preserving middle ground
(matched 300 s, VSIDS + USC + `--decide-inputs`):

- `--opt-heuristic=sign`: `[-704,-37135]`, 6 models, first at 180.5 s, 45.99M choices /
  139,956 conflicts. This beats plain VSIDS `[-704,-33471]` without changing priorities.
- `--opt-heuristic=sign,model`: `[-704,-38129]`, 2 models, best at 181.1 s,
  **3157/3164 methods**, 67.67M choices / 40,484 conflicts. Reusing the incumbent's
  objective-improving phases recovers all but seven method rewards and is the strongest
  semantics-preserving built-in tested so far, though still behind lexicographic staging's
  `[-704,-3164,-40459]` and 3164/3164 methods.
- Domain + `--opt-heuristic=sign,model`: `[-704,-36693]`, one model at 55.4 s,
  **3164/3164 methods**, 39.95M choices / 1,114,043 conflicts. Domain's explicit true
  phases do recover every method, but adding objective phase guidance drives roughly 10x
  more conflicts than Domain alone and never improves the first incumbent. It is also
  materially worse overall than VSIDS `sign,model`, so it is not the new default.

## Diagnostic gotchas

- 2026-07-06: the propagator gained `&classRelationship/2`/`&classRelationshipVia/2`
  reachability (new watches on `objectInObject`, new reason clauses). Per the
  rule below, solver-knob rankings need a re-sweep before trusting old numbers.
- clingo resolves relative `#include` paths against the **CWD**, not the
  including file. Benchmarks of archived/other trees must run with the CWD
  inside that tree or they silently ground the current working tree's modules.

- The driver's `on_unsat` callback never fires for usc bound updates. Diagnose
  LB progress from clasp's `Progression : ...` lines (needs `--stats`).
- `usc,1`-style "zero cores" diagnostics disagree with `Progression` on the
  full usc config; trust Progression.
- Solver-knob rankings are trajectory-specific: re-sweep after ANY change to
  the propagator's decide/reason behavior (measured: save-progress flipped
  sign after the direct-edge change).

## Implicit hitting set prover (`scripts/ihs_prove.py`, 2026-07-03) — the
## first proof system that makes LB progress past the representation wall

MaxHS-style CEGAR: one multi-shot clingo oracle (full program + propagator,
comp1 pinned via a `#sum` mirror constraint, `opt_mode=ignore`) refutes
reward-assumption proposals; a fresh clingo instance per round solves the
exact min-weight hitting set over the accumulated cores; the proposal is
"all softs minus the hitting set"; SAT proposal + exact hitting set =
optimality certificate. Soundness anchor: certifies oo.lp at exactly the
usc optimum `[-28, -3523]` in ~1.4s (60–67 cores).

Why it evades the closed barriers: the pigeonhole counting happens in the
hitting-set *optimization* (not clause learning), and assuming the merges
resolves the mutex conditions by propagation (no 4200-level case splits) —
cores over conditional structure come out *wider* (the reward-vs-conditioning-
reward trade appears as a 3+-literal core; observed sizes 1–13).

TinyXml (Pi, 30-min budgets): 5381 softs, trivial=51691. Size-1 cores
(139×w9 + 125×w8 + 67×w7 …) discharge structurally-dead rewards first. Sound
exact-hitting-set LB trajectory: −50843@50s → −48041@211s → **−47300@456s
(1045 cores)** — still moving where USC freezes at −46982 forever, but not
past it yet: at ~1000 overlapping cores the clasp hitting-set solve exceeds
60–120s and exactness (hence LB updates) stops. Oracle-side per-call
timeouts (30s, escalating) and 150-core disjoint extraction per round are
required (first attempt hung 25 CPU-min in one near-feasible oracle call).
Incremental multi-shot hitting set tested and NEGATIVE (exactness dies at
900 cores vs 1045 fresh-per-round; usc re-derives more than it reuses).

Next steps if pursued: delegate the hitting set to a MIP solver (HiGHS /
python-mip — the standard MaxHS design; clasp is the wrong tool for weighted
set cover at this size), and/or run on a faster host. LB-per-minute was
~150–700 and decelerating; certification of −44816 plausibly needs the MIP
hitting set plus an hour-class budget.

## Open directions

1. IHS + MIP hitting set (above) is now the only live path to the TinyXml
   optimality certificate.
2. Close the remaining gap from above (UB search), or accept the anytime
   result — accuracy is already at Prolog parity. The clause-learning LB side
   is thoroughly closed empirically (see ledger); do not re-attempt
   representation changes.
3. Validate the champion on more/bigger inputs (mysql-scale) and run the
   proper edit-distance metric (needs `~/ooanalyzer-tests`, NOT on this host —
   don't search the filesystem for it).
