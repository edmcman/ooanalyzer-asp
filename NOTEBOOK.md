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
- `src/facts.lp` — input vocabulary and `#defined` directives for full-arity and simplified predicates
- `src/initial.lp` — projections and derivations from full-arity OOAnalyzer `.facts`:
  - `pointerSize/1` from `fileInfo`
  - `possibleVFTableWrite/3`, `possibleVBTableWrite/3` (drop Insn, ThisPtr, ExpandedThisPtr)
  - `possibleVFTableEntry/3` — recursive walk over `initialMemory` from confirmed writes and RTTI COLs
  - `possibleVBTableEntry/3` — recursive walk over `initialMemory` from confirmed writes
  - `possibleVFTableOverwrite/6` (initial.pl:383)
  - `callTarget/2`, `callsDelete/1`, `symbolClass/2` — arity reductions
  - `rTTITDA2VFTable/2` (rtti.pl:19)
  - `rTTIEnabled` / `rTTIValid` and full RTTI validation chain (`rTTISelfRef`, `rTTIInvalidBaseAttributes`, `rTTIInvalidHierarchyAttributes`, `rTTIAncestorOf`, `rTTIInheritsIndirectlyFrom`, `rTTIDirectNonVirtual`, etc.)
  - `possibleMethod/1` — from callingConvention, thunk, noCallsAfter, noCallsBefore, returnsSelf, purecall, callTarget
  - `possibleConstructor/1` — from returnsSelf+noCallsBefore or symbolProperty(constructor)
  - `possibleDestructor/1` — from noCallsAfter or symbol properties
  - `thisPtrParam/2`, `thisParamFuncParameter/2`, `thisParamCallParameter/4`
  - `dethunk/2` (initial.pl:313) — thunk chain resolution
  - `possiblyVirtual/1` (initial.pl:338) — method appears, possibly via thunk, in a possible vftable entry
  - `methodCallAtOffset/4`, `validMethodCallAtOffset/4`, `callAtOffset/3` (initial.pl:175-191)
  - `thisPtrUsage/4` (initial.pl:193-205)
- `src/rules.lp` — `reasonVFTable` (843), `reasonMethod_B`–`H`, `reasonVFTableWrite` (939), `reasonVFTableOverwrite` (962, 976), `certainConstructorOrDestructor/1` (731), `vfTableEntry` (1233, 1239, 1247), `reasonMergeClasses_G/J`, constructor/destructor symbol and delete(this) rules, `sortPair`/`mergeEntity`/`merged`/`sameClass` infrastructure
- `src/insanity.lp` — `insanityConstructorInVFTable`, `insanityMultipleConstructorDestructorKinds`
- `src/guess.lp` — `possibleVFTable/1`, `guessVFTable` choice rule + heuristic, `guessMergeClasses_B/D`
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
- `possibleVFTableWrite/5` and `possibleVBTableWrite/5` projections, plus simplified `possibleVFTableWrite/3`, `possibleVBTableWrite/3`
- `possibleVFTableEntry/3` — base cases from writes/RTTI COL + recursive walk
- `possibleVBTableEntry/3` — base case from writes + recursive walk
- `possibleVFTableOverwrite/6`
- `callTarget/2`, `callsDelete/1`, `symbolClass/2`
- `rTTITDA2VFTable/2` (rtti.pl:19)
- `rTTIEnabled` / `rTTIValid` and full validation chain (self-reference, base attributes, hierarchy attributes, direct inheritance P/V checks)
- `possibleMethod/1`
- `possibleConstructor/1`, `possibleDestructor/1`
- `thisPtrParam/2`, `thisParamFuncParameter/2`, `thisParamCallParameter/4`
- `dethunk/2` (initial.pl:313)
- `possiblyVirtual/1` (initial.pl:338)
- `methodCallAtOffset/4`, `validMethodCallAtOffset/4`, `callAtOffset/3`
- `thisPtrUsage/4`

### guess.lp
- `possibleVFTable/1` (guess.pl:175)
- `guessVFTable` (guess.pl:180)
- `guessMergeClasses_B` (guess.pl:1050) — vftable writer may merge with vftable entries
- `guessMergeClasses_D` (guess.pl:1215) — methods writing same vftable at same offset may merge

### insanity.lp
- `insanityConstructorInVFTable` (insanity.pl:49) — constructors cannot appear in confirmed vftable entries
- `insanityMultipleConstructorDestructorKinds` — user-approved ASP check: at most one of constructor/realDestructor/deletingDestructor

## Where we are now
Last completed: **guessConstructor1 and guessConstructor2** (src/ctorsdtors.lp)

```prolog
guessConstructor1Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method),
    possibleVFTableWrite(_, Method, _, _, _),
    not uninitializedReads(Method).

guessConstructor2Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method),
    possibleVFTableWrite(_, Method, _, _, _).

guessConstructorDomain(Method) :- guessConstructor1Domain(Method).
guessConstructorDomain(Method) :- guessConstructor2Domain(Method).

1 { constructor(Method) ; -constructor(Method) } 1 :- guessConstructorDomain(Method).

#heuristic constructor(Method) : guessConstructor1Domain(Method). [2@0, true]
#heuristic constructor(Method) : guessConstructor2Domain(Method). [1@0, true]
```

## Suggested next steps
- Propose `guessConstructor3` (guess.pl:612): normal non-virtual case, not in a vftable, doesn't write a vftable, and has no uninitialized reads.
- Propose `guessConstructor4` (guess.pl:631): normal virtual case, writes a vftable, has uninitialized reads, but is possibly virtual.
