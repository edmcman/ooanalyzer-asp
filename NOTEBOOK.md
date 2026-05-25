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
- `src/modules/methods.lp` — `reasonMethod_B`–`H`, `guessMethod` (choose method or ¬method for each possibleMethod)
- `src/modules/ctorsdtors.lp` — constructor/destructor symbol rules, guessConstructor1/2, `certainConstructorOrDestructor/1` choice rule, sanity checks, `#maximize` constructor reward
- `src/modules/vftables.lp` — `reasonVFTable`, `reasonVFTableWrite`, `reasonVFTableOverwrite`, `vfTableEntry`, `guessVFTable`, `insanityConstructorInVFTable`, `#maximize` vfTable reward
- `src/modules/merges.lp` — `reasonMergeClasses_G/J`, `sortPair`/`mergeEntity`/`merged`/`sameClass`, `guessMergeClasses_B/D`, `#maximize` merge reward
- `src/util/sanity.lp` — `#show` and diagnostic infrastructure
- `examples/*.lp` — all hand-written examples rewritten to use Prolog-matching arities (possibleVFTableWrite/5, callTarget/3, insnCallsDelete/3, symbolClass/4, methodCallAtOffset/4, etc.)
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
- `reasonMergeClasses_G` (rules.pl:2881) — symbols with same class name
- `reasonMergeClasses_J` (rules.pl:2925) — RTTI says two VFTables belong to same class
- `sortPair`, `mergeEntity`, `merged`, `sameClass` — transitive closure over hard merges

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
- `insanityMultipleConstructorDestructorKinds` — at most one of constructor/realDestructor/deletingDestructor
- `insanityTwoRealDestructorsOnClass` (insanity.pl:253) — at most one real destructor per class

## Where we are now
Last completed batch:
1. **Migrate examples and solver to Prolog-matching predicate arities** — removed Clingo-only simplified projections (`/3`, `/2`, `/1`), updated solver modules and all hand-written examples to use the arities the Prolog actually uses.
2. **Add `#maximize` rewards** for vftables (`@2`), merges (`@2`), and constructors (`@0`).
3. **Add `insanityTwoRealDestructorsOnClass`** — `invalid_example.lp` and `strong_negation_contradiction.lp` now correctly UNSAT.
4. **Add `guessMethod`** — `possibleMethod` candidates now get method/¬method choices so examples produce non-empty models.

All 10 hand-written examples pass:
- SAT: `example.lp`, `inherit_example.lp`, `inherited_entry_example.lp`, `multi_inherit_example.lp`, `rtti_example.lp`, `selfdefeating.lp`, `synthetic_merge.lp`, `virtual_base_example.lp`
- UNSAT: `invalid_example.lp`, `strong_negation_contradiction.lp`

## Suggested next steps
- Propose `guessConstructor3` (guess.pl:612): normal non-virtual case, not in a vftable, doesn't write a vftable, and has no uninitialized reads.
- Propose `guessConstructor4` (guess.pl:631): normal virtual case, writes a vftable, has uninitialized reads, but is possibly virtual.
- Port `reasonMethod_I`–`O` (rules.pl:85–159) for broader method identification from call chains and this-pointer usage.
