# Merge-reward optimization: status and experiment ledger

Reference input: `examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`.
Last updated 2026-07-03. Full history of this file (including superseded
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
