# Status

## What we're doing
Porting OOAnalyzer rules from SWI-Prolog to Clingo ASP (v2 branch).
Going rule by rule, presenting: name, Prolog code, proposed ASP translation, then getting approval before writing.

## Porting guidelines (AGENTS.md)
- Update TODO.md immediately after porting each rule
- Never simplify a Prolog rule without asking first
- Never merge distinct Prolog predicates into one
- Never substitute a different predicate without asking
- Always keep as faithful as possible — use full arity

## Where we are now
Last completed batch:
1. **Tier 3 VFTable accuracy** — added `reasonNOTVFTableEntry_D`, then `B`, `C`, and `E`; `C` intentionally uses `not vfTableEntry(...)` for the previous offset per approval.
2. **Class-call infrastructure** — added `src/modules/classes.lp` with `reasonClassCallsMethod_C` and `reasonClassCallsMethod_B`, both using direct `sameClass/2` checks instead of adding Prolog-style `find/2`.
3. **Method expansion from class calls** — added `reasonMethod_J`, so `classCallsMethod(_, Method)` proves `method(Method)`.
4. **Negative merge signal** — added `reasonNOTMergeClasses_E`; negative cross-write checks use anonymous `_` arguments so Clingo grounds safely.
5. **Bookkeeping** — updated `TODO.md` immediately after each approved rule; corrected the stale `reasonNOTVFTableEntry_D` description from "address is a constructor" to RTTI COL address exclusion.

All 11 hand-written examples pass:
- SAT: `constructor_vftable_entry_example.lp`, `example.lp`, `inherit_example.lp`, `inherited_entry_example.lp`, `multi_inherit_example.lp`, `rtti_example.lp`, `selfdefeating.lp`, `synthetic_merge.lp`, `virtual_base_example.lp`
- UNSAT: `invalid_example.lp`, `strong_negation_contradiction.lp`

Note: `make verify-core` currently reaches the final diagnostic-mode check and
fails there because `--const diagnose=1` returns `SATISFIABLE` with
`violate(insanityTwoRealDestructorsOnClass,(1300,1400))`, while the Makefile
still expects `UNSATISFIABLE`. This appears unrelated to `reasonNOTVFTableEntry_E`.

## Suggested next steps

Ranked candidates for next implementation (by complexity, predicate availability, and downstream impact):

### Current one-at-a-time queue
1. **`reasonClassSizeGTE_B` (3505)** — every proven method/vftable class has size at least 0. Low-risk size baseline.
2. **`reasonClassSizeGTE_E` (3624)** — `validMethodMemberAccess` at offset+size -> `classSizeGTE`. `methodMemberAccess/4` exists, but `validMethodMemberAccess/4` may need a faithful helper first.
3. **`reasonClassSizeGTE_G` (3653)** — confirmed vftable write at object offset implies class size at least `ObjectOffset + pointerSize`.
4. **`reasonClassSizeGTE_C` (3519)** — class relationship propagates base minimum size to derived/related class; depends on `reasonClassRelationship`.
5. **`reasonClassSizeGTE_D` (3609)** — heap allocation size associated with a constructor; higher complexity because it depends on `thisPtrAssociatedWithConstructor` helpers.
6. **`reasonClassSizeGTE_F` (3637)** — object-in-object containment propagates inner class size to outer class; depends on `objectInObject`.
7. **`reasonDerivedClass_B` (1834)** — VFTable overwrite in constructor call sequence (base -> derived). Primary non-RTTI inheritance detection mechanism; medium complexity.
8. **`reasonNOTMergeClasses_I` (3196)** — methods with conflicting symbol class names cannot merge.
9. **`reasonNOTMergeClasses_Q` (3352)** — symbol says methods belong to different classes.
10. **`reasonNOTMergeClasses_O` (3296)** — class-call method already belongs to a different symbol class.
11. **`reasonNOTMergeClasses_K` (3222)** — different real destructors block a merge.
