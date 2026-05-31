# Propagator-backed `&sameClass` theory atom

Scaling idea for OOAnalyzer to large executables. The grounding cost on
Lite/ooex7 is dominated by closure rules over `sameClass` and pair-canonicalization
plumbing (~1.58M atoms, 854MB ground program). The closure rules are O(N²) in
the worst case and don't shrink with constant-factor encoding fixes.

## Approach

Define `&sameClass(A, B)` as a clingo theory atom decided by a Python propagator
that maintains a union-find structure over `mergeClasses` truth. The propagator
answers "are these two entities in the same class?" lazily during solving — no
N² closure materialization at grounding time.

## Why pair-based, not rep-based

`&sameClass(A, B)` works because both A and B are bound by other body literals
at use sites — the theory atom is a check on bound terms.

`&classRep(M, R)` is awkward: R isn't bound by anything except the theory atom
itself, and clingo theory atoms don't bind variables back into the surrounding
rule. The grounder would still need a domain predicate enumerating R candidates,
reintroducing the N² grounding the approach is meant to avoid.

The union-find lives inside the propagator regardless — the classOf/classRep
model is the right conceptual shift, but the *exposed interface* is the binary
equivalence query.

## Where it directly helps vs. doesn't

**Direct win — negative checks where both vars are bound:**
```
... not sameClass(M1, M2) ...   →   ... not &sameClass(M1, M2) ...
```
The `-mergeClasses_E/K/C/Q/R` family fits this exactly. Should eliminate the
266k `-mergeClasses` atoms via tighter grounding.

**Does NOT directly help — positive closure rules with one unbound variable:**
```
derivedClass_closed(B, C, Off) :- derivedClass_closed(A, C, Off), sameClass(A, B).
```
B is introduced by the closure. The grounder still enumerates B over all
mergeEntities even with `&sameClass(A, B)`. To win here, delete the closure
rules and rewrite *use sites* to query `&sameClass` directly between bound
terms from the underlying base predicate. Whether this saves grounding is
case-by-case and needs measurement — sometimes the closure version's natural
joins are cheaper than the refactored version.

## Witness-based class facts

The `&sameClass` propagator pairs naturally with a witness-based encoding of
class-indexed facts. Rather than tracking properties like vftable ownership via
a canonical class representative (which requires a dynamic domain) or closing
them over equivalence class members via O(N²) closure rules:

```
hasVftable(B, V) :- hasVftable(A, V), sameClass(A, B).
```

keep only the base witness fact and rewrite each use site to query `&sameClass`
directly:

```
classHasVftable(M, V) :- methodHasVftable(W, V), &sameClass(M, W).
```

This works because witness predicates are always grounded in EDB or base
derivations, so `W` is always grounding-time bound — satisfying the "both vars
bound" requirement for theory atoms. The closure rules that propagated class
properties across equivalence class members are eliminated entirely.

**Caveat:** use sites must have the non-witness variable `M` bound by some other
body literal. Any rule that iterates over "all classes with property P" without
a concrete anchor entity cannot be rewritten this way and may need special
handling.

## Optimization

`#minimize`/`#maximize` and `#heuristic` cannot reference theory atoms directly.
Route through a regular derived predicate whose body binds the vars:

```
sharesClass(A, B) :- mergeCandidate(A, B), &sameClass(A, B).
#maximize { 10@2, merge, A, B : sharesClass(A, B), strongMergeCandidate(A, B) }.
#heuristic sharesClass(A, B) : mergeCandidate(A, B). [1@1, true]
```

The intermediate is groundable (bounded by `mergeCandidate`) and its truth
mirrors the propagator's union-find decision. Same trick for all reward and
heuristic statements that currently target `mergeClasses`/`sameClass`.

## Trade-offs

- Loses ability to `#show sameClass` — propagator is opaque to clingo's output.
  Instrument with logging instead.
- Propagator runs on every solver assignment. Pure Python is slow; for
  production, the union-find should be C via `cffi` or accept some overhead.
- Debugging is harder — propagator-vs-solver consistency bugs are real.

## Suggested spike order

1. **Negative checks only.** Implement propagator. Swap `not sameClass` →
   `not &sameClass` in the negative-merge rules. Verify identical results on
   small examples and measure ground program size delta. Half a day each for
   propagator and encoding edits.
2. **Optimization predicates.** Wire `strongMergeReward`, `guessDerivedClassReward`,
   `purecallNotMostDerivedReward` through `sharesClass`-style regular predicates.
   Verify optimization still finds reasonable models.
3. **Positive closure rewrites.** Case-by-case for `derivedClass_closed`,
   `objectInObject_closed`, `classRelationship_closed`, `derivedClassRelationship_closed`.
   Keep some materialized if their natural joins are cheaper than the refactor.

If step 1 doesn't move grounding on ooex7 meaningfully, reassess — the closure
rewrites likely won't help either.

## Related ideas considered

- **Bounded `possibleRep`**: structurally cleaner but the orphan-method problem
  (entities lacking anchor evidence like vftables or symbols) brings
  `possibleRep` back to ~N on stripped Lite builds. Propagator approach
  sidesteps this — no rep enumeration needed.
- **DualGrounder**: only handles constraints, not derivations. OOAnalyzer's
  grounding cost is in derivation rules (closures, transitive closures).
  Doesn't address the hot spots.
- **Alpha**: would handle this natively but loses `#minimize`/`#heuristic` and
  is a much bigger commitment than a clingo propagator.
- **Multi-shot phasing**: complementary, not competing. Could stack on top of
  propagator approach to shrink the entity space before grounding each phase.
