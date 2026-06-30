# Autoresearch: 5m Lexicographic Improvement on TinyXml-NewDebug
# Date: 2026-06-29
# Goal: Improve [comp1, comp2] in 5m vs domain baseline (user-noted winner)
# Guard: no ASP edits; tests/test_propagator.py must pass 45/45

## Baseline from last session (1h, crafty+F736):
## [-704, -42666] — comp2 froze at 63s, gap 7564, strategy-invariant plateau

## Known negatives (from loop-260626-0813):
## - opt-heuristic=sign: harms UB (-37710)
## - opt-heuristic=model: harms UB (-37942)
## - per-hub AMO (static or conditional): wreck comp1 or comp2
## - threads: don't help
## - usc variants: all same ceiling

## User finding: domain (no crafty) outperforms previous at 5m
## New rules since last session: reasonMergeClasses_B, reasonReusedImplementation_B
## These may have changed problem structure / optimal value

## Experiment plan (5m = --time-limit=300):
## iter0: domain (no crafty) — user-noted winner, establishes NEW baseline
## iter1: crafty+F736+domain — old champion, verify it still holds
## iter2: domain + save-progress=20 (helped UB in pre-lex experiments)
## iter3: crafty+F720+domain (alt F-value, was winner in sweep)
## iter4: crafty+F736+domain+save-progress=20
## iter5: domain + opt-strategy=usc,oll (vs default bb)
## iter6: crafty+F512+domain (shorter fixed restarts)
## iter7: domain + opt-strategy=usc,oll + save-progress=20

## Metric: grep "Optimization:" | tail -1 → parse comp1, comp2
## Champion: lower comp1 first, then lower comp2
## Scalar: comp1*1000000 + comp2 (lower is better)
