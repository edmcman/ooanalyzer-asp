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
- `src/rules.lp` — reasonVFTable (843), dethunk/2, reasonMethod_B–H, reasonVFTableWrite (939), reasonVFTableOverwrite (962, 976), certainConstructorOrDestructor/1, vfTableEntry (1233, 1239, 1247)
- `src/insanity.lp` — insanityConstructorInVFTable
- `src/facts.lp` — #defined vfTableSizeGTE/2 (referenced by 1247, no rule yet)
- `src/guess.lp` — possibleVFTable/1, guessVFTable choice rule + heuristic
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

### insanity.lp
- `insanityConstructorInVFTable` (insanity.pl:49) — constructors cannot appear in confirmed vftable entries

## Where we are now
Last completed: **`insanityConstructorInVFTable` — constructors not in vftable entries**

```prolog
insanityConstructorInVFTable(Out) :-
    factVFTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Constructor),
    factConstructor(Constructor).
```

Current ASP:

```prolog
insanity(insanityConstructorInVFTable, (VFTable,Offset,Constructor)) :-
    vfTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Constructor),
    constructor(Constructor).
```

## Remaining VFTable rules
- `reasonVFTableBelongsToClass` (1007) — clause 1 (very complex, needs constructors/destructors)
- `insanityVFTableOnTwoClasses`

## Planned categories (not yet started)
- Basic merges — **next**
- Constructor
- Real/Deleting Destructor
