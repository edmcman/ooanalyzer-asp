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

- The driver's `on_unsat` callback never fires for usc bound updates. Diagnose
  LB progress from clasp's `Progression : ...` lines (needs `--stats`).
- `usc,1`-style "zero cores" diagnostics disagree with `Progression` on the
  full usc config; trust Progression.
- Solver-knob rankings are trajectory-specific: re-sweep after ANY change to
  the propagator's decide/reason behavior (measured: save-progress flipped
  sign after the direct-edge change).

## Open directions

1. Close the remaining 2166 TinyXml gap from above (UB search), or accept the
   anytime result — accuracy is already at Prolog parity. The LB side is
   thoroughly closed empirically (see ledger); treat further LB attempts as
   requiring a genuinely new idea about the *conditional* mutex mass, not a
   new representation of the static part.
2. Validate the champion on more/bigger inputs (mysql-scale) and run the
   proper edit-distance metric (needs `~/ooanalyzer-tests`, NOT on this host —
   don't search the filesystem for it).
