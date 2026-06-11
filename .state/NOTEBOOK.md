# Status

## What we're doing
Porting OOAnalyzer rules from SWI-Prolog to Clingo ASP (v2 branch).
Going rule by rule: present the name, Prolog code, and proposed ASP translation;
get approval; implement the approved translation; update `TODO.md` and this
notebook; add focused regression coverage when useful; run the relevant examples;
then commit the completed change.

## Porting guidelines (AGENTS.md)
- Update TODO.md immediately after porting each rule
- Never simplify a Prolog rule without asking first
- Never merge distinct Prolog predicates into one
- Never substitute a different predicate without asking
- Always keep as faithful as possible — use full arity
- Test every landed rule with a focused fixture or existing example coverage, plus
  a hand-written example sweep when the change affects solver behavior
- Commit each completed, tested rule port as its own focused commit

## Where we are now

No in-progress work. Recent sessions completed (in order):
- `reasonVFTableBelongsToClass` (1007 / 1118) — vftables.lp
- `reasonMergeVFTables` (2722) — merges.lp (vftable → its owning class)
- `reasonClassRelatedMethod_A` (2361) and `knownVirtualMethod` — classes.lp
- `guessLateMergeClasses_G2` (weakMergeCandidate) and `G1` (weakG1Bonus) — merges.lp
- `reasonNOTDeletingDestructor_F` (667) and `_H` (695) — ctorsdtors.lp
- `reasonMergeClasses_K` (2939) — merges.lp
- `reasonClassSizeGTE_B` / `_F` / `_G` — size.lp (`_C` dropped as subsumed by `_B`+`_F`)
- `reasonClassSizeGTE_D` (3609) + `reasonClassSizeLTE_C` (3703) — size.lp
- `reasonClassSizeLTE_B` (3693) — size.lp; `classSizeLTE(Ctor, 268435455)` (0x0fffffff)
  universal upper bound, constructor-gated (faithful to Prolog `factConstructor`).
  Verified on vs2008 oo.lp: 3 constructors → 3 LTE_B atoms coexisting with tighter
  LTE_C (84, 12); insanity stays satisfied; all 13 examples pass. **Then commented
  out** as inert: 0x0fffffff never violates the only consumer (insanity `L < GTE`),
  and `reasonMaximumPossibleClassSize` (its real purpose) isn't ported. Re-enable
  with that predicate; until then it was just `#show` noise.

Class size work is underway in `src/modules/size.lp`: GTE `_B/_D/_F/_G` and LTE `_A/_C`
are in (LTE `_B` ported-but-commented-out as inert); `_C`(GTE) dropped as subsumed;
`GTE_E` blocked on `validMethodMemberAccess`.
Queue: `reasonClassSizeLTE_D` (needs `reasonClassRelationship/2` closure first).

The diagnostic fixture (`--const diagnose=1` on `strong_negation_contradiction.lp`)
is pre-existing-broken: returns `SATISFIABLE` + `violate(...)` instead of `UNSATISFIABLE`.

All 13 hand-written examples pass:
- SAT: `constructor_vftable_entry_example.lp`, `example.lp`, `inherit_example.lp`,
  `inherited_entry_example.lp`, `multi_inherit_example.lp`, `rtti_example.lp`,
  `selfdefeating.lp`, `symbol_conflict_example.lp`, `symbol_missing_conflict_example.lp`,
  `synthetic_merge.lp`, `virtual_base_example.lp`
- UNSAT: `invalid_example.lp`, `strong_negation_contradiction.lp`

## Last completed batch

1. **`reasonClassSizeGTE_D` (3609) + `reasonClassSizeLTE_C` (3703)** — exact class size from a
   heap allocation tracked to a constructor. Shared helpers in size.lp:
   `thisPtrConstructorCommon` (3534), `thisPtrAssociatedWithConstructor` clauses 1
   (inheritance-at-0 + ctor vftable write + no caller possibleVFTableWrite through ThisPtr)
   and 2 (`classHasNoBase`/`classHasNoDerived` joined via `&sameClass`, plus negated
   class-wide `ctorClassIsInnerAtZero`). The Prolog derivedClass disjunction became two
   `ctorClassInheritsAtZero` rules (theory atoms can't appear in cardinality literals).
   Verified on vs2010 oo.lp: `classSizeLTE(0x411830, 84)` / `classSizeLTE(0x411a40, 12)`
   matching the heap allocation facts, with equal GTE maxima (exact sizes).
2. **classes.lp `reasonClassRelatedMethod_B` faithfulness fix** — the two raw-witness
   `not objectInObject(X, _, 0)` literals were weaker than Prolog's class-wide
   `not((find(X, C), factObjectInObject(C, _, 0)))`. Replaced with negated
   `classHasInnerAtZero/1` helper (domain `thisPtrUsageEntity/1`, `&sameClass` join).
   Per user: class-wide joins wanted in both places, not the raw-witness shortcut.

3. **`insanityClassSizeInvalid` (insanity.pl:84)** — `:- classSizeGTE(W1, G), classSizeLTE(W2, L),
   &sameClass(W1, W2), L < G.` in size.lp. No negative (UNSAT) fixture yet: deriving
   `classSizeLTE` in a hand-written example needs the full thisPtrUsage/allocation chain
   plus clause-1 or clause-2 preconditions — noted as a coverage gap.

Next up: `reasonClassSizeLTE_B` (0x0fffffff ctor seed) and `reasonClassSizeLTE_D`
(base ≤ derived, via `classRelationship`).

## Previous completed batch

1. **`reasonMergeClasses_K` (2939)** — deterministic merge for class-related methods when
   both the source class and the method's class have no base. Uses `&sameClass(Class1, NoBase1)`
   and `&sameClass(Method, Class2)` to join witness-based no-base facts, then canonicalizes
   pair order.
2. **`reasonNOTDeletingDestructor_F` (667)** — delete() exists in program but method doesn't
   call delete(this). Two rule bodies translate the Prolog disjunction; conservatively skips
   methods with no this-pointer info.
3. **`reasonNOTDeletingDestructor_H` (695)** — thiscall method with >2 parameters cannot be
   a deleting destructor. Uses three distinct `funcParameter` checks to avoid grounding blowup.

## Older Completed Batch

1. **`reasonVFTableBelongsToClass` (1007 / 1118)** — both Prolog clauses collapsed into a unified
   rule set in `src/modules/vftables.lp`. Three ownership sub-cases (ancestor at Offset≠0,
   ancestor at 0, hierarchy root) × three additional checks (constructor, `&allWritersInClass`,
   `classHasNoBase`).
2. **`reasonMergeVFTables` (2722)** — deterministic: `vftableBelongsToClass(VFTable, _, Method)` → `mergeClasses(VFTable, Method)`.
3. **`reasonClassRelatedMethod_A` (2361)** — undirected `classRelatedMethod` from `classCallsMethod`.
   Also added `knownVirtualMethod/1` helper (from confirmed `vfTableEntry` or `symbolProperty(virtual)`).
4. **`guessLateMergeClasses_G2` / `G1`** — `weakMergeCandidate` from classRelatedMethod pairs;
   `weakG1Bonus` adds @0 weight-2 when either merged class has a confirmed constructor.
5. **Tier-3 VFTable accuracy** — `reasonNOTVFTableEntry_B/C/D/E` in vftables.lp.
6. **Class-call infrastructure** — `reasonClassCallsMethod_B/C` in classes.lp.
7. **`reasonMethod_J`** — `classCallsMethod(_, Method)` proves `method(Method)`.
8. **Negative merge signals** — `reasonNOTMergeClasses_E`, `K`, `Q` in merges.lp.

## Suggested next steps

Ranked by availability of required predicates and incremental impact:

1. **`reasonMergeClasses_H` (2895)** — derived constructor calls base constructor → they're in the
   same class hierarchy / need to merge. Uses `classCallsMethod` and `derivedClass`, both available.

2. **`reasonObjectInObject_C` (1577)** — VFTable write at non-zero offset → objectInObject. Uses
   `vfTableWrite` which is available; feeds `objectInObject` which feeds composition reasoning.

3. **`reasonNOTMergeClasses_A` (3073)** — two methods that have different base classes cannot merge.
   Uses `derivedClass`; no new predicates needed.

Delayed:
- **Class size rules** — useful later, but a bounds-and-constraints subsystem rather than the
  next inheritance/merge focus.
- **`reasonNOTMergeClasses_O` (3296)** — needs `classSizeLTE/2` and `validMethodMemberAccess/4`,
  neither of which is implemented yet.
