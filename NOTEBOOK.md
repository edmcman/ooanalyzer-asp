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

## Files created/modified
- `AGENTS.md` — porting guidelines
- `src/util/facts.lp` — input vocabulary and `#defined` directives; reorganized into Derived / Base / Not-yet-implemented sections
- `src/util/initial.lp` — projections and derivations from full-arity OOAnalyzer `.facts`:
  - `pointerSize/1` from `fileInfo`
  - `possibleVFTableWrite/5`, `possibleVBTableWrite/5` (drop ExpandedThisPtr from /6)
  - `possibleVFTableEntry/3` — recursive walk over `initialMemory` from confirmed writes and RTTI COLs
  - `possibleVBTableEntry/3` — recursive walk over `initialMemory` from confirmed writes
  - `possibleVFTableOverwrite/6` (initial.pl:383)
  - `rTTITDA2VFTable/2` (rtti.pl:19)
  - `rTTIEnabled` / `rTTIValid` and full RTTI validation chain (`rTTISelfRef`, `rTTIInvalidBaseAttributes`, `rTTIInvalidHierarchyAttributes`, `rTTIAncestorOf`, `rTTIInheritsIndirectlyFrom`, `rTTIDirectNonVirtual`, etc.)
  - `possibleMethod/1` — from callingConvention, thunk, noCallsAfter, noCallsBefore, returnsSelf, purecall, callTarget
  - `possibleConstructor/1` — from returnsSelf+noCallsBefore or symbolProperty(constructor)
  - `possibleDestructor/1` — from noCallsAfter or symbol properties
  - `thisPtrParam/2`, `thisParamFuncParameter/2`, `thisParamCallParameter/4`
  - `dethunk/2` (initial.pl:313) — thunk chain resolution
  - `possiblyVirtual/1` (initial.pl:338) — method appears, possibly via thunk, in a possible vftable entry
  - `methodCallAtOffset/4`, `validMethodCallAtOffset/4` (initial.pl:175-191)
  - `thisPtrUsage/4` (initial.pl:193-205)
- `src/modules/methods.lp` — `reasonMethod_B`–`H`, `reasonMethod_J`, `reasonMethod_L`, `guessMethod` (choose method or ¬method for each possibleMethod)
- `src/modules/ctorsdtors.lp` — constructor/destructor symbol rules, guessConstructor1/2, `certainConstructorOrDestructor/1` choice rule, sanity checks, `#maximize` constructor reward
- `src/modules/vftables.lp` — `reasonVFTable`, `reasonVFTableWrite`, `reasonVFTableOverwrite`, `vfTableEntry`, `reasonNOTVFTableEntry_B/C/D/E`, `guessVFTable`, `insanityConstructorInVFTable`, `#maximize` vfTable reward
- `src/modules/merges.lp` — `reasonMergeClasses_G/J`, `reasonNOTMergeClasses_E`, `sortPair`/`mergeEntity`/`merged`/`sameClass`, `guessMergeClasses_B/D`, `#maximize` merge reward
- `src/modules/classes.lp` — `reasonClassCallsMethod_B/C`, `classCallsMethod/2` output
- `src/util/sanity.lp` — `#show` and diagnostic infrastructure
- `examples/*.lp` — all hand-written examples rewritten to use Prolog-matching arities (possibleVFTableWrite/5, callTarget/3, insnCallsDelete/3, symbolClass/4, methodCallAtOffset/4, etc.)
- `examples/constructor_vftable_entry_example.lp` — regression for `reasonNOTVFTableEntry_E`
- `TODO.md` — rule coverage tracker

## Rules ported

### rules.lp
- `certainConstructorOrDestructor/1` (rules.pl:731) — vftable/vbtable write into this-pointer
- `constructor(Method) :- symbolProperty(Method, constructor).` (rules.pl:209)
- `realDestructor(Method) :- symbolProperty(Method, realDestructor).` (rules.pl:394)
- `deletingDestructor(Method) :- method(Method), insnCallsDelete(...), thisParamFuncParameter(...).` (rules.pl:585)
- `deletingDestructor(Method) :- symbolProperty(Method, deletingDestructor).` (rules.pl:595)
- `reasonVFTable` (rules.pl:843) — RTTI evidence
- `reasonVFTableWrite` (rules.pl:939) — `possibleVFTableWrite` + confirmed `vfTable`
- `reasonVFTableOverwrite` (rules.pl:962) — constructor direction (base -> derived)
- `reasonVFTableOverwrite` (rules.pl:976) — destructor direction (derived -> base; uses `not constructor(Method)` as stand-in for `factNOTConstructor`)
- `vfTableEntry` (rules.pl:1233) — offset 0 entry from confirmed VFTable
- `vfTableEntry` (rules.pl:1239) — propagation from known entry / vfTableSizeGTE bound
- `vfTableEntry` (rules.pl:1247) — from virtual function call evidence
- `reasonMethod_B`–`H` (rules.pl:52–80) — constructors, destructors, symbolClass, symbolProperty, vfTableEntry, vfTableWrite -> method
- `reasonMethod_J` (rules.pl:99) — `classCallsMethod` -> method
- `reasonMethod_L` (rules.pl:109) — method call at offset 0 -> method
- `reasonMergeClasses_G` (rules.pl:2881) — symbols with same class name
- `reasonMergeClasses_J` (rules.pl:2925) — RTTI says two VFTables belong to same class
- `reasonNOTMergeClasses_E` (rules.pl:3123) — different confirmed vftable writes at object offset 0 block class merge
- `sortPair`, `mergeEntity`, `merged`, `sameClass` — transitive closure over hard merges
- `reasonNOTVFTableEntry_B` (rules.pl:1282) — vftables cannot overlap
- `reasonNOTVFTableEntry_C` (rules.pl:1292) — later entries are invalid after the previous possible entry is not confirmed
- `reasonNOTVFTableEntry_D` (rules.pl:1303) — RTTI COL addresses are not vftable entries
- `reasonNOTVFTableEntry_E` (rules.pl:1313) — entries dethunking to constructors are not vftable entries
- `reasonClassCallsMethod_B` (rules.pl:2462) — vftable entry method is callable by that vftable's class
- `reasonClassCallsMethod_C` (rules.pl:2481) — same-this valid call at offset 0 creates a class-call relation

### initial.lp
- `pointerSize/1`
- `possibleVFTableWrite/5` and `possibleVBTableWrite/5` projections (drop ExpandedThisPtr from /6)
- `possibleVFTableEntry/3` — base cases from writes/RTTI COL + recursive walk
- `possibleVBTableEntry/3` — base case from writes + recursive walk
- `possibleVFTableOverwrite/6`
- `rTTITDA2VFTable/2` (rtti.pl:19)
- `rTTIEnabled` / `rTTIValid` and full validation chain (self-reference, base attributes, hierarchy attributes, direct inheritance P/V checks)
- `possibleMethod/1`
- `possibleConstructor/1`, `possibleDestructor/1`
- `thisPtrParam/2`, `thisParamFuncParameter/2`, `thisParamCallParameter/4`
- `dethunk/2` (initial.pl:313)
- `possiblyVirtual/1` (initial.pl:338)
- `methodCallAtOffset/4`, `validMethodCallAtOffset/4`
- `thisPtrUsage/4`

### guess.lp
- `possibleVFTable/1` (guess.pl:175)
- `guessVFTable` (guess.pl:180) with `#maximize` reward
- `guessMergeClasses_B` (guess.pl:1050) — vftable writer may merge with vftable entries, with `#maximize` reward
- `guessMergeClasses_D` (guess.pl:1215) — methods writing same vftable at same offset may merge
- `guessMethod` (guess.pl:382) — choose method or ¬method for each possibleMethod
- `guessConstructor1` / `guessConstructor2` (guess.pl:574, 592) with `#maximize` rewards

### insanity.lp
- `insanityConstructorInVFTable` (insanity.pl:49) — constructors cannot appear in confirmed vftable entries
- `insanityMultipleConstructorDestructorKinds` — at most one of constructor/realDestructor/deletingDestructor; also covers `reasonConstructor` (rules.pl:192), `reasonRealDestructor` (rules.pl:388), `reasonDeletingDestructor` (rules.pl:575), `reasonNOTConstructor_B/C` (rules.pl:281,288), `reasonNOTRealDestructor_B/C` (rules.pl:443,448), and `reasonNOTDeletingDestructor_B/C` (rules.pl:632,637)
- `reasonNOTDeletingDestructor_G` (rules.pl:687) — deleting destructors must be virtual; uses strong negation `-deletingDestructor/1`
- `insanityTwoRealDestructorsOnClass` (insanity.pl:253) — at most one real destructor per class

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
