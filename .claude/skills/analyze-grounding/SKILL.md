---
name: analyze-grounding
description: Measure the grounding footprint of the ASP program on a real input, break it down by predicate, and optionally compare against a baseline git ref to find which rule caused a blowup. Use after porting rules or when grounding/solving gets slow.
argument-hint: "[input.lp] [baseline-ref]  e.g. examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp HEAD~1"
---

Analyze grounding for: $ARGUMENTS

## Goal

Quantify how large the ground program is, which predicates dominate it, and —
if a baseline ref is given — which commit/rule caused the growth. Grounding
size is the first-order performance signal in this project: theory atoms
(`&sameClass`) cannot prune grounding, so bad rule shapes show up here before
they show up in solve time.

## Inputs

- Default input if none given: `examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp`
  (mid-size, ~7s to ground on the Pi). Use
  `examples/ooa/ooex_vs2008/Debug/oo.lp` for a quick small-input check (~1.5s).
- Baseline ref is optional; without it, just profile the working tree.

## Step 1 — Overall size and time

```sh
time uv run clingo --mode=gringo ooanalyzer.lp <input> 2>/dev/null | wc -cl
```

Record aspif lines, bytes, and wall time.

## Step 2 — Per-predicate breakdown

Ground once to text and keep it in the scratchpad for the remaining steps:

```sh
uv run clingo --mode=gringo --text ooanalyzer.lp <input> 2>/dev/null > $SCRATCH/ground.txt
```

Histogram of ground rules by head predicate (misses choice-rule and
constraint heads, which is fine for finding offenders):

```sh
grep -oE '^-?[a-zA-Z][a-zA-Z0-9_]*' $SCRATCH/ground.txt | sort | uniq -c | sort -rn | head -20
```

For a specific predicate, distinguish **rule instances** (grounding cost) from
**distinct atoms** (domain size) — addresses are plain integers here, so the
regex is safe:

```sh
grep -c '^pred(' $SCRATCH/ground.txt                      # rule instances
grep -o 'pred([0-9][^)]*)' $SCRATCH/ground.txt | sort -u | wc -l   # distinct atoms
```

## Step 3 — Theory-atom load

```sh
grep -o '&sameClass([^)]*)' $SCRATCH/ground.txt | sort -u | wc -l  # distinct atoms
grep -c '&sameClass' $SCRATCH/ground.txt                           # rules containing one
```

Distinct atoms ≈ propagator watch-set size (Rust propagator load). Lines
containing `&sameClass` ≈ clasp clause-database load. A rule change that adds
many *occurrences* but few *distinct atoms* hurts clasp, not the propagator.

## Step 4 — Baseline comparison (if a ref was given)

```sh
git worktree add $SCRATCH/base <ref>
```

**Critical gotcha:** clingo resolves `#include` relative to the *cwd*, not the
including file. Grounding `$SCRATCH/base/ooanalyzer.lp` from the main repo
directory silently includes the main repo's `src/` — you get a byte-identical
"comparison". Always `cd` into the worktree and point at the main venv:

```sh
cd $SCRATCH/base && uv run --project <main-repo> clingo --mode=gringo ooanalyzer.lp <abs-input> 2>/dev/null | wc -cl
```

Repeat steps 2–3 there, diff the histograms, and attribute the delta to
specific predicates. Clean up with `git worktree remove --force $SCRATCH/base`.

## Step 5 — Diagnose blowup shapes

When one predicate dominates the delta, look for these known causes:

- **Cross products through `&sameClass`.** Body atoms linked only by theory
  atoms ground as a full cross product (grounder can't evaluate them). The fix
  is never to materialize the closure — factor instead.
- **Choice-predicate multipliers.** Joining a choice predicate with many
  candidates (e.g. `vfTableSize` over `candidateVFTableSize`) against another
  per-entity predicate multiplies candidates × instances. Factor the
  comparison into a small helper keyed by one entity (see
  `vfTableEntryBeyondSize` in `src/modules/merges.lp`).
- **Unbounded accumulated offsets.** See the "Transitive closures with
  accumulated offsets" section of AGENTS.md; bound heads with `relevantOffset`.
- **Unused body arguments.** `pred(X, Y, _)` with many values of the ignored
  argument grounds once per value; project to `predPair(X, Y)` first.
- **Missing implied inequalities.** An inequality that is semantically implied
  (e.g. two vftable arguments that can never be equal in a model) still prunes
  grounding — add it with a comment saying it is implied.

Helper domains must be *static* (fact-level, e.g. `possibleVFTableEntry`
projections), and must be verified to cover the derived predicate's values —
check every derivation rule of the derived predicate before substituting.

## Step 6 — Report

1. Total ground size (lines/bytes/time), and delta vs baseline if compared
2. Top offending predicates with instance counts, and the body join structure
   that produces the product (name the multiplying factors with their sizes)
3. Theory-atom load change (distinct vs occurrences)
4. Proposed rewrite using the patterns above, written out in full
5. If a rewrite is applied, verify with `tests/test_propagator.py` and by
   diffing solver output on the manual examples (skip
   `merge_conditional_stress.lp` — it is the optimization-blocker stress toy
   and can run very long); normalize away timestamps/timings before diffing
