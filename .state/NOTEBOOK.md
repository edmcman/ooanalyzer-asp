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
Current in-progress work:
- Added `src/modules/composition.lp` with the `classRelationship/2` helper:
  direct `objectInObject/3` and transitive composition through `objectInObject/3`.
  Per the class-fact guidance in `AGENTS.md`, `classRelationship/2` does not add
  its own `sameClass/2` closure because `objectInObject/3` will be closed once
  at its defining rules.
- Updated `TODO.md` for `reasonClassRelationship_internal` direct/transitive.
- Added `rTTIEnabledAndValid/0` in `src/util/initial.lp` for faithful ASP
  negation of Prolog's `(rTTIEnabled, rTTIValid)` conjunction.
- Added `reasonDerivedClass_B` in `src/modules/composition.lp`, with a helper
  for the base-side vftable/symbol disjunction and `derivedClass/3`
  sameClass-closure rules per `AGENTS.md`.
- Fixed the `possibleVFTable/1` Prolog-disjunction port in
  `src/modules/vftables.lp` by replacing `method(Func) ; method(Entry)` with
  `1 { method(Func); method(Entry) }`. `examples/inherit_example.lp` now derives
  `derivedClass(2300,2100,0)`, and the current v2 modules have no other
  body-level semicolon disjunctions outside intentional cardinality/choice
  constructs.

Last completed batch:
1. **Tier 3 VFTable accuracy** — added `reasonNOTVFTableEntry_D`, then `B`, `C`, and `E`; `C` intentionally uses `not vfTableEntry(...)` for the previous offset per approval.
2. **Class-call infrastructure** — added `src/modules/classes.lp` with `reasonClassCallsMethod_C` and `reasonClassCallsMethod_B`, both using direct `sameClass/2` checks instead of adding Prolog-style `find/2`.
3. **Method expansion from class calls** — added `reasonMethod_J`, so `classCallsMethod(_, Method)` proves `method(Method)`.
4. **Negative merge signals** — added `reasonNOTMergeClasses_E`, `K`, and `Q`; `E` negative cross-write checks use anonymous `_` arguments so Clingo grounds safely, `K` intentionally omits the redundant `Method1 != Method2` condition, and `Q` includes approved `method(MethodWithSymbol)` evidence.
5. **Bookkeeping** — updated `TODO.md` immediately after each approved rule; corrected the stale `reasonNOTVFTableEntry_D` description from "address is a constructor" to RTTI COL address exclusion.

All 13 hand-written examples pass:
- SAT: `constructor_vftable_entry_example.lp`, `example.lp`, `inherit_example.lp`, `inherited_entry_example.lp`, `multi_inherit_example.lp`, `rtti_example.lp`, `selfdefeating.lp`, `symbol_conflict_example.lp`, `symbol_missing_conflict_example.lp`, `synthetic_merge.lp`, `virtual_base_example.lp`
- UNSAT: `invalid_example.lp`, `strong_negation_contradiction.lp`

Note: `make verify-core` currently reaches the final diagnostic-mode check and
fails there because `--const diagnose=1` returns `SATISFIABLE` with
`violate(insanityTwoRealDestructorsOnClass,(1300,1400))`, while the Makefile
still expects `UNSATISFIABLE`.

## Suggested next steps

Ranked candidates for next implementation (by complexity, predicate availability, and downstream impact):

### Current one-at-a-time queue
1. **`reasonDerivedClass_B` (1834)** — constructor call at object offset plus matching confirmed vftable writes derives a base/derived relationship. Primary non-RTTI inheritance detection mechanism; requires a careful decision on `find/2`, `hasPendingVFTableMerge/1`, and `reasonClassRelationship/2` replacements.
2. **`reasonNOTMergeClasses_O` (3296)** — class with known maximum size calls a method whose member access would exceed that size. Delayed with class-size work because it depends on `classSizeLTE/2` and `validMethodMemberAccess/4`.

Delayed:
- **Class size rules** — useful later, but they are a bounds-and-constraints subsystem rather than the next inheritance/merge focus.
