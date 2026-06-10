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

Since the last rule-porting commit (`784e0cd`), work has been performance tooling only:
plateau profiling (`--profile-after-first-model`, `--diagnose-vftable-objective`),
`--results` output, and symbolize script improvements. No outstanding rule ports.

The diagnostic fixture (`--const diagnose=1` on `strong_negation_contradiction.lp`)
is pre-existing-broken: returns `SATISFIABLE` + `violate(...)` instead of `UNSATISFIABLE`.

All 13 hand-written examples pass:
- SAT: `constructor_vftable_entry_example.lp`, `example.lp`, `inherit_example.lp`,
  `inherited_entry_example.lp`, `multi_inherit_example.lp`, `rtti_example.lp`,
  `selfdefeating.lp`, `symbol_conflict_example.lp`, `symbol_missing_conflict_example.lp`,
  `synthetic_merge.lp`, `virtual_base_example.lp`
- UNSAT: `invalid_example.lp`, `strong_negation_contradiction.lp`

## Last completed batch

1. **`reasonMergeClasses_K` (2939)** — deterministic merge for class-related methods when
   both the source class and the method's class have no base. Uses `&sameClass(Class1, NoBase1)`
   and `&sameClass(Method, Class2)` to join witness-based no-base facts, then canonicalizes
   pair order.

## Previous completed batch

1. **`reasonNOTDeletingDestructor_F` (667)** — delete() exists in program but method doesn't
   call delete(this). Two rule bodies translate the Prolog disjunction; conservatively skips
   methods with no this-pointer info.
2. **`reasonNOTDeletingDestructor_H` (695)** — thiscall method with >2 parameters cannot be
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
