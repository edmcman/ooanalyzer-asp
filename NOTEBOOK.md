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
1. **`reasonDerivedClass_B` (1834)** — constructor call at object offset plus matching confirmed vftable writes derives a base/derived relationship. Primary non-RTTI inheritance detection mechanism; requires a faithful replacement for Prolog's `find/2`, `hasPendingVFTableMerge/1`, and `reasonClassRelationship/2` checks.
2. **`reasonNOTMergeClasses_K` (3222)** — symbol class names disagree, so the containing classes cannot merge. Available now with direct `sameClass/2` style, but TODO's existing description is stale.
3. **`reasonNOTMergeClasses_Q` (3352)** — if one method's symbol identifies class `C`, methods without a symbol for `C` cannot merge with it, except `type_info`. Available now with direct `sameClass/2` style.
4. **`reasonNOTMergeClasses_I` (3196)** — RTTI TDAs map to different classes. Depends on porting `rTTITDA2Class/2` faithfully; current v2 only has `rTTITDA2VFTable/2`.
5. **`reasonNOTMergeClasses_O` (3296)** — class with known maximum size calls a method whose member access would exceed that size. Delayed with class-size work because it depends on `classSizeLTE/2` and `validMethodMemberAccess/4`.

Delayed:
- **Class size rules** — useful later, but they are a bounds-and-constraints subsystem rather than the next inheritance/merge focus.
