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

No in-progress work. Last session landed `reasonNOTDerivedClass` (identity, TODO only) and
`reasonMergeClasses_E` (2847) in `src/modules/merges.lp`. All 6 non-diagnostic regression
checks pass. The diagnostic fixture (`--const diagnose=1` on `strong_negation_contradiction.lp`)
remains pre-existing-broken: returns `SATISFIABLE` + `violate(...)` instead of `UNSATISFIABLE`.

Previous completed batch:
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

## Last completed batch

1. **`reasonNOTDerivedClass` (2025)** — identity rule; marked done in TODO.md (covered by input fact / strong-negation architecture, no code change needed).
2. **`reasonMergeClasses_E` (2847)** — two classes both direct bases of the same derived class at the same offset must merge. Added to `src/modules/merges.lp` using `derivedClass_closed` and `not sameClass`. All 6 non-diagnostic regression checks pass.

## Last completed batch

1. **`reasonVFTableBelongsToClass` (1007 / 1118)** — both Prolog clauses (binding-mode variants) collapsed into a single unified set of ASP rules. Added to `src/modules/vftables.lp`. Structure: `vftableBelongsToClassCandidate` (core thisptr check), three ownership sub-cases (A: ancestor at Offset!=0 + base-reuse check; B: ancestor at 0; C: hierarchy root, no embed), three additional-check sub-cases (constructor, destructor, hasnobase). `mergeEntity(Class)` added to ground `Class` in the `OtherWriter` helper. All 6 non-diagnostic regression checks pass; predicate fires on real `.facts` data.

## Suggested next steps

Ranked candidates for next implementation (by complexity, predicate availability, and downstream impact):

### Current one-at-a-time queue
1. **`reasonMergeVFTables` (2722)** — both vftable writes belong to the same class; uses `vftableBelongsToClass` which is now available.
2. **`reasonDerivedClass_B` (1834)** — constructor call at object offset plus matching confirmed vftable writes derives a base/derived relationship. Primary non-RTTI inheritance detection mechanism; requires a careful decision on `find/2`, `hasPendingVFTableMerge/1`, and `reasonClassRelationship/2` replacements.
3. **`reasonNOTMergeClasses_O` (3296)** — class with known maximum size calls a method whose member access would exceed that size. Delayed with class-size work because it depends on `classSizeLTE/2` and `validMethodMemberAccess/4`.

Delayed:
- **Class size rules** — useful later, but they are a bounds-and-constraints subsystem rather than the next inheritance/merge focus.
