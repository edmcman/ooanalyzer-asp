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
- `src/initial.lp` — rTTITDA2VFTable/2, rTTIEnabled/rTTIValid flags, possibleVFTableWrite/5, possibleVFTableOverwrite/6, possibleConstructor/1, possibleDestructor/1
- `src/rules.lp` — reasonVFTable (843), dethunk/2, reasonMethod_B–H, reasonVFTableWrite (939), reasonVFTableOverwrite (962, 976), certainConstructorOrDestructor/1, vfTableEntry (1233, 1239, 1247), reasonMergeClasses_G/J, constructor/destructor symbol and delete(this) rules
- `src/insanity.lp` — insanityConstructorInVFTable, insanityMultipleConstructorDestructorKinds
- `src/facts.lp` — #defined vfTableSizeGTE/2 (referenced by 1247, no rule yet)
- `src/guess.lp` — possibleVFTable/1, guessVFTable choice rule + heuristic, guessMergeClasses_B/D
- `TODO.md` — rule coverage tracker

## Rules ported

### rules.lp
- `reasonVFTable` (rules.pl:843) — RTTI evidence
- `dethunk/2` — thunk chain resolution
- `reasonMethod_B/C/D/E/F/G/H` (rules.pl:52–80)
- `reasonVFTableWrite` (rules.pl:939)
- `reasonVFTableOverwrite` (rules.pl:962) — constructor direction
- `reasonVFTableOverwrite` (rules.pl:976) — destructor direction (uses `not constructor(Method)` as stand-in for `factNOTConstructor`)
- `certainConstructorOrDestructor/1` (rules.pl:731) — vftable/vbtable write into this-pointer
- `vfTableEntry` (rules.pl:1233) — offset 0 entry from confirmed VFTable
- `vfTableEntry` (rules.pl:1239) — propagation from known entry / vfTableSizeGTE bound
- `vfTableEntry` (rules.pl:1247) — from virtual function call evidence
- `reasonMergeClasses_G` (rules.pl:2881) — symbols with same class name
- `reasonMergeClasses_J` (rules.pl:2925) — RTTI says two VFTables belong to same class
- `reasonConstructor` (rules.pl:209) — symbolProperty(constructor)
- `reasonRealDestructor` (rules.pl:394) — symbolProperty(realDestructor)
- `reasonDeletingDestructor` (rules.pl:585) — delete(this) logic
- `reasonDeletingDestructor` (rules.pl:595) — symbolProperty(deletingDestructor)

### initial.lp
- `rTTITDA2VFTable/2` (rtti.pl:19)
- `rTTIEnabled` / `rTTIValid` — #const flags
- `possibleVFTableWrite/5` (initial.pl:13)
- `possibleVFTableOverwrite/6` (initial.pl:383)
- `possibleConstructor/1` (initial.pl) — from returnsSelf+noCallsBefore or symbolProperty
- `possibleDestructor/1` (initial.pl) — from noCallsAfter or symbol properties

### guess.lp
- `possibleVFTable/1` (guess.pl:175)
- `guessVFTable` (guess.pl:180)
- `guessMergeClasses_B` (guess.pl:1050) — vftable writer may merge with vftable entries
- `guessMergeClasses_D` (guess.pl:1215) — methods writing same vftable at same offset may merge

### insanity.lp
- `insanityConstructorInVFTable` (insanity.pl:49) — constructors cannot appear in confirmed vftable entries
- `insanityMultipleConstructorDestructorKinds` — user-approved ASP check: at most one of constructor/realDestructor/deletingDestructor

## Where we are now
Last completed: **basic constructor/destructor identification and combined kind sanity**

```prolog
reasonConstructor(Method) :-
    symbolProperty(Method, constructor).

reasonRealDestructor(Method) :-
    symbolProperty(Method, realDestructor).

reasonDeletingDestructor(Method) :-
    factMethod(Method),
    insnCallsDelete(_Insn, Method, ThisPtr),
    thisParamFuncParameter(Method, ThisPtr).

reasonDeletingDestructor(Method) :-
    symbolProperty(Method, deletingDestructor).
```

Current ASP:

```prolog
constructor(Method) :- symbolProperty(Method, constructor).              % rules.pl:209
realDestructor(Method) :- symbolProperty(Method, realDestructor).         % rules.pl:394

deletingDestructor(Method) :-
    method(Method),
    insnCallsDelete(_Insn, Method, ThisPtr),
    thisParamFuncParameter(Method, ThisPtr).                              % rules.pl:585

deletingDestructor(Method) :- symbolProperty(Method, deletingDestructor). % rules.pl:595

insanity(insanityMultipleConstructorDestructorKinds, (Method,Count)) :-
    method(Method),
    Count = #count { Kind : constructorDestructorKind(Method, Kind) },
    Count > 1.
```

## Remaining VFTable rules
- `reasonVFTableBelongsToClass` (1007) — clause 1 (very complex, needs constructors/destructors)
- `insanityVFTableOnTwoClasses`

## Planned categories (not yet started)
- Constructor/destructor elimination rules and/or classification guesses
