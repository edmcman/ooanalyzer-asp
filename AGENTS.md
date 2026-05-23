# OOAnalyzer Clingo Prototype
<!-- Generated: 2026-05-23 | Commit: b532f2a | Branch: master -->

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).
This prototype captures the core ideas in ~700 lines of Clingo.

## Files

| File | Purpose |
|---|---|
| `ooanalyzer.lp` | Entry point: `#include`s the modules below |
| `src/facts.lp` | Input vocabulary and `#defined` directives |
| `src/guess.lp` | Guesses and merge-candidate domain restriction |
| `src/rules.lp` | Forward-reasoning rules (thunks, derived facts, ctor/dtor, inheritance, class computation) |
| `src/insanity.lp` | Sanity checks (integrity constraints) |
| `src/optimize.lp` | Lexicographic optimization directives |
| `src/output.lp` | `#show` directives |
| `src/initial.lp` | Derives simplified predicates from full-arity OOAnalyzer `.facts` |
| `facts2clingo.py` | Syntax adapter: converts `.facts` files to Clingo-compatible `.lp` |
| `examples/example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `examples/invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `examples/inherit_example.lp` | Single inheritance: Base + Derived, one vftable overwrite |
| `examples/rtti_example.lp` | Same as inherit but with RTTI facts driving the derivation |
| `examples/multi_inherit_example.lp` | Multiple inheritance: C : A(0), B(8) |
| `examples/inherited_entry_example.lp` | Derived inherits an un-overridden virtual method |
| `examples/virtual_base_example.lp` | Virtual inheritance: Derived : virtual Base via VBTable |
| `examples/selfdefeating.lp` | SAT demo: hard merge using `sameClass` avoids self-defeating loop |
| `examples/ooa/` | Real OOAnalyzer test files (`.facts`, `.symbols`, `.json`, `.results`) organized by build: `ooex_vs2008/Debug`, `ooex_vs2010/Lite`, etc.
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |

## Running

```sh
clingo ooanalyzer.lp examples/example.lp              # find optimal model
clingo ooanalyzer.lp examples/example.lp 0            # enumerate all models
clingo ooanalyzer.lp examples/invalid_example.lp      # should print UNSATISFIABLE
clingo ooanalyzer.lp examples/inherit_example.lp      # factDerivedClass(2300, 2100, 0)
clingo ooanalyzer.lp examples/rtti_example.lp         # same but RTTI-driven, fewer models
clingo ooanalyzer.lp examples/multi_inherit_example.lp  # C : A(0), B(8)
clingo ooanalyzer.lp examples/inherited_entry_example.lp  # derived inherits un-overridden entry
clingo ooanalyzer.lp examples/virtual_base_example.lp     # Derived : virtual Base via VBTable
```

Or use the Makefile:

```sh
make examples/ooa/ooex_vs2008/Debug/oo.lp   # convert one .facts file
make convert                                 # convert all examples/ooa/*/*/*.facts
make run                                     # convert and run clingo on all of them
make clean                                   # remove generated .lp/.out files
```

### From OOAnalyzer .facts files

```sh
python facts2clingo.py examples/ooa/ooex_vs2008/Debug/oo.facts > /tmp/oo.lp
clingo ooanalyzer.lp /tmp/oo.lp
```

`oo.facts` is the complete export with vftable writes, RTTI, symbols, and
`initialMemory`. `ooex0.facts` is an early-stage export that lacks these and
is not suitable for the prototype.

Clingo exit codes: 10 = SAT, 20 = UNSAT, 30 = OPTIMUM FOUND.

## Input fact vocabulary

The prototype accepts **two vocabularies**:

**(A) Simplified predicates** (hand-written examples like `examples/*.lp`):

| Predicate | Meaning |
|---|---|
| `possibleVFTableWrite(M, Off, V)` | Method M writes vftable V at object offset Off |
| `possibleVFTableEntry(V, Off, E)` | Entry E at offset Off in vftable V (E may be thunk) |
| `possibleVFTableOverwrite(M, Off, V1, V2)` | M overwrites V1 with V2 at Off (ctor sequence) |
| `returnsSelf(M)` | M returns the this-pointer (ECX -> EAX) |
| `noCallsBefore(M)` | No OO calls precede M (constructor hint) |
| `noCallsAfter(M)` | No OO calls follow M (destructor hint) |
| `callsDelete(M)` | M calls delete/free on the this-pointer |
| `uninitializedReads(M)` | M reads members before setting them (NOT-constructor signal) |
| `callTarget(Caller, Callee)` | Callee is directly called by Caller |
| `callAtOffset(Caller, Callee, Off)` | Callee is called by Caller passing this+Off |
| `thunk(Thunk, Target)` | Thunk is a JMP-only stub; Target is the real function |
| `purecall(M)` | M is a pure-virtual stub (included in `factMethod`; blocked from merge rules) |
| `symbolClass(M, Class)` | Debug symbol: M belongs to Class |
| `symbolProperty(M, Prop)` | Prop \in {constructor, realDestructor, deletingDestructor} |
| `rTTICompleteObjectLocator(V, TDA)` | COL at V-8: vftable V belongs to type TDA |
| `rTTITypeDescriptor(TDA, Name)` | Type descriptor TDA has mangled name Name |
| `rTTIInheritsFrom(DerivedTDA, BaseTDA, Off)` | DerivedTDA has a non-virtual base BaseTDA at byte Off |
| `possibleVBTableWrite(M, Off, V)` | Method M writes VBTable V at object offset Off |
| `possibleVBTableEntry(V, Off, Value)` | Entry Value at offset Off in VBTable V |
| `possibleMethod(M)` | At least some evidence that M is a function |
| `possibleConstructor(M)` | Candidate constructor evidence for M |
| `possibleDestructor(M)` | Candidate destructor evidence for M |

**(B) Full-arity OOAnalyzer .facts predicates** (from binary analysis):

| Predicate | Arity | Notes |
|---|---|---|
| `possibleVFTableWrite` | 6 | Drops Insn, ThisPtr, ExpandedThisPtr in `initial.lp` |
| `possibleVBTableWrite` | 6 | Same projection |
| `callTarget` | 3 | Drops instruction address |
| `insnCallsDelete` | 3 | Extracts function in `initial.lp` |
| `symbolClass` | 4 | Drops mangled name and method name |
| `rTTICompleteObjectLocator` | 6 | Computes V = Pointer + PtrSize |
| `rTTITypeDescriptor` | 4 | Drops VFTable check and demangled name |
| `rTTIClassHierarchyDescriptor` | 3 | List expanded by `facts2clingo.py` |
| `rTTIBaseClassDescriptor` | 8 | Drives `rTTIInheritsFrom` in `initial.lp` |
| `initialMemory` | 2 | Drives `possibleVFTableEntry` / `possibleVBTableEntry` |
| `thisPtrOffset` | 3 | Drives `callAtOffset` in `initial.lp` |
| `fileInfo` | 4 | Provides pointer size |
| `thunk` | 2 | Same as simplified |
| `symbolProperty` | 2 | Same as simplified |
| `purecall` | 1 | Same as simplified |
| `returnsSelf` | 1 | Same as simplified |
| `noCallsBefore` | 1 | Same as simplified |
| `noCallsAfter` | 1 | Same as simplified |
| `uninitializedReads` | 1 | Same as simplified |
| `possibleMethod` | 1 | Derived in `initial.lp` from `callingConvention`, `thunk`, `noCallsBefore`, `noCallsAfter`, `returnsSelf`, `purecall`, `callTarget` |
| `possibleConstructor` | 1 | Derived in `initial.lp` from `returnsSelf+noCallsBefore` or `symbolProperty(constructor)` |
| `possibleDestructor` | 1 | Derived in `initial.lp` from `noCallsAfter` or symbol properties |

See `src/initial.lp` for the exact derivation rules.

## Architecture

**Guesses** -- the five things the solver decides:
- `{ factVFTable(V) }` -- is candidate V actually a vftable? (RTTI confirms without guessing)
- `{ factVBTable(V) }` -- is candidate V actually a VBTable?
- `{ mergeClasses(M1, M2) }` -- should methods M1 and M2 be in the same class?
- `{ factDerivedClass(Outer, Inner, Off) }` -- is this ctor-calls-ctor relationship
  inheritance or composition? RTTI, vftable overwrites, and VBTables provide hard evidence.
- `{ factClassHasNoBase(C) }` -- does class C have no base class? RTTI overrides.

**Thunk resolution** -- `dethunk/2` follows JMP-only stub chains to the real method;
`factVFTableEntry(V, Off, M)` gives the actual method at each confirmed vftable slot.

**Rules** derive `factMethod`, `factConstructor`, `factNOTConstructor`,
`factRealDestructor`, `factDeletingDestructor`, `factNOTRealDestructor`,
`factNOTDeletingDestructor`, `factVFTableWrite`,
`factVFTableOverwrite`, `factVFTableEntry`, `factVFTableBelongsToClass`,
`objectInObject`, `factDerivedClass`, `factEmbeddedObject`, `factClassHasNoBase`,
`factClassCallsMethod`, `reasonMergeClasses`, `reasonNOTMergeClasses`,
`factVFTableSizeGTE`,
`factVBTable`, `factVBTableWrite`, `factVBTableEntry`,
and the equivalence-class predicates (`sameClass`, `classRep`, `find`).

**factNOTConstructor** -- mirrors `reasonNOTConstructor_B/C/D` from rules.pl:
- `factRealDestructor(M)` or `factDeletingDestructor(M)` -> not a constructor
- `factVFTableEntry(_, _, M)` -> virtual methods cannot be constructors
- `uninitializedReads(M)` or `callsDelete(M)` -> not a constructor

**factRealDestructor** -- the Prolog `guessRealDestructor` only fires when a confirmed
`factDeletingDestructor` calls the method. The Clingo prototype matches this by using
an ASP choice rule `{ factRealDestructor(M) }` guarded by `callTarget(D, M),
factDeletingDestructor(D)`. Hard-deriving `factRealDestructor` from `noCallsAfter` alone
produces too many candidates and causes UNSAT on real binaries.

**factNOTRealDestructor / factNOTDeletingDestructor** -- basic versions mirroring
`reasonNOTRealDestructor_B/C/D`: constructors and deleting destructors are excluded
from being real destructors, and methods that are not `possibleDestructor` are excluded.

**objectInObject** -- when a constructor calls another at `this+Off`, their classes
are distinct. The solver guesses `factDerivedClass` vs. `factEmbeddedObject`. The
vftable overwrite pattern and RTTI provide hard evidence for `factDerivedClass`.

**factVFTableBelongsToClass(V, Off, M)** -- vftable V is written by method M at object
offset Off. Mirrors `reasonVFTableBelongsToClass`. Derived from
`factVFTableWrite(M, Off, V)`.

**factVFTableSizeGTE** -- lower bound on vftable size (max entry offset + 4).
Used by a sanity check: a derived vftable must be at least as large as the base
vftable it overwrites.

**inheritedVftableEntry(Vderived, Off, M)** -- DISABLED. This Clingo-specific predicate was intended to detect vftable slots in a derived class that reuse the same method from the base, so the vftable-entry merge rule could skip them. In practice it caused interaction problems on real binaries. Since `guessMergeClassesB` is a soft guess (via `mergeCandidate`) in both Prolog and this prototype, the predicate is not needed. See TODO.md.

**factVBTable / factVBTableWrite / factVBTableEntry** -- virtual base tables. A VBTable
contains offsets from the VBTable pointer to virtual base subobjects. When a
constructor writes a VBTable and also calls another constructor, and a VBTable entry
(at offset > 0, i.e., not the self-offset) matches the call offset, the relationship
is virtual inheritance (`factDerivedClass`). This is `reasonDerivedClass_F` in the
original OOAnalyzer. The first VBTable entry (offset 0) is typically the self-offset
(offset from vbptr to complete object start).

**factClassHasNoBase(M)** -- guessed for any method, with hard derivation from RTTI
(when a method writes a vftable with no inheritance entries). Enables
`reasonMergeClasses_C`: two no-base classes where one calls a method of the other
must be merged. Blocked when `factDerivedClass(M2, _, _)` and `sameClass(M1, M2)` holds.

**factClassCallsMethod(Caller, M)** -- Caller directly calls M passing the same
this-pointer (`callAtOffset(Caller, M, 0)`). Mirrors `factClassCallsMethod`.

**Hard merges** (direct `mergeClasses` derivation, no choice):
- `symbolClass`: same debug-symbol class annotation (reasonMergeClasses_G). Head uses raw method IDs (`M1 < M2`) to avoid the self-defeating `find` loop.
- `factDerivedClass`: two bases of the same derived at same offset (reasonMergeClasses_E). Head uses raw base-method IDs (`B1 < B2`).
- `factClassHasNoBase` + `callAtOffset`: two no-base classes sharing a method call (reasonMergeClasses_C). Body uses `sameClass` (monotonically growing) instead of `find` (which changes when reps merge); head uses raw method IDs.

**Soft merges** (via `mergeCandidate` + choice rule `{ mergeClasses }`):
All `mergeCandidate` rules use raw method IDs and `sortPair` for canonical ordering:
- Same vftable writers (guessMergeClassesD)
- Vftable writer + entries (guessMergeClassesB)
- Call relationships (guessMergeClassesC1-C4)
- Deleting destructor -> real destructor chain (guessMergeClasses)
- Late merge: singleton methods in confirmed vftables (guessLateMergeClassesF2)

**reasonNOTMergeClasses** (`:- reasonNOTMergeClasses, mergeClasses`):
- Outer and inner constructors of an `objectInObject` pair
- Base constructor (installs without overwriting) vs. derived (overwrites)
- reasonNOTMergeClasses_F: two bases of the same derived at *different* offsets
- RTTI: two vftables with different type descriptors

**Class computation** -- transitive closure of `mergeClasses` gives `sameClass`; the
minimum-address method in each equivalence class is the `classRep`. `find(M, R)`
is defined for debugging / `#show` but is **not used in any rule body** — all
rules operate on raw method IDs or `sameClass` directly.
To reduce grounding, `merged/2` serves as an undirected edge predicate for
the closure: `sameClass(M1, M3) :- sameClass(M1, M2), merged(M2, M3).`
This eliminates the explicit symmetry rule and cuts `sameClass` atoms from
~295k to ~16k on `oo.lp`.

**sortPair** -- canonical ordering helper for any pair of IDs, equivalent to Prolog's
`sort_tuple/2`. `sortPair(A, B, C1, C2)` produces `C1 < C2` without duplicating
rule bodies. Used throughout `reasonNOTMergeClasses` and `mergeCandidate`.

**Sanity checks** (integrity constraints -- any violation kills the model):
- Constructor cannot appear in a vftable (not virtual)
- Method cannot be both constructor and destructor
- Constructor cannot be `factNOTConstructor`
- At most one real destructor per class
- A vftable cannot be owned by two different classes at the same object offset
- Two constructors writing *different* vftables at the same offset -> different classes
- No circular inheritance
- `objectInObject` pairs must not be directly merged (enforced via
  `reasonNOTMergeClasses`, matching Prolog's direct-conflict check only)
- Derived classes cannot be `factClassHasNoBase`
- Derived vftable size must be >= base vftable size (`factVFTableSizeGTE`)
- A constructor writing a VBTable cannot also embed the same base (virtual
  inheritance supersedes embedding)
- `reasonMergeClasses` must hold -> `mergeClasses` must be guessed (enforced in `insanity.lp`)
- `reasonNOTMergeClasses` and `mergeClasses` must not both hold (enforced in `insanity.lp`)

All sanity conditions are expressed as `insanity(Tag, Witness) :- condition.` with a single dispatch pair at the bottom of `insanity.lp`: a hard constraint in normal mode, or soft `violate(Tag, Witness)` atoms when running with `--const diagnose=1`.

**Optimization** -- three-level lexicographic:
1. `#maximize { 1@2, V : factVFTable(V); 1@2, V : factVBTable(V) }` -- confirm as many vftables and VBTables as possible
2. `#maximize { 1@1, M1,M2 : mergeClasses(M1,M2) }` -- maximize merges (minimize classes)
3. `#maximize { 1@0, ... }` -- prefer `factDerivedClass` at offset 0; prefer more `factClassHasNoBase`

## Correspondence to OOAnalyzer (Prolog)

| OOAnalyzer concept | This prototype |
|---|---|
| `factVFTable` | `factVFTable(V)` (guessed; confirmed by RTTI) |
| `factVFTableWrite` / `factVFTableEntry` | `factVFTableWrite`, `factVFTableEntry` (thunk-resolved) |
| `factVFTableOverwrite` | `factVFTableOverwrite` (from `possibleVFTableOverwrite`) |
| `reasonVFTableBelongsToClass` | `factVFTableBelongsToClass(V, Off, C)` |
| `factConstructor` | `factConstructor(M)` (guessed; hard from symbols) |
| `guessRealDestructor` | `{ factRealDestructor(M) }` ASP choice rule (guessed when called by deleting destructor) |
| `guessDeletingDestructor` | `factDeletingDestructor(M)` (guessed from `callsDelete`; hard from symbols) |
| `factNOTConstructor` / `reasonNOTConstructor_B/C/D` | `factNOTConstructor(M)` |
| `reasonNOTRealDestructor_B/C/D` | `factNOTRealDestructor(M)` (basic versions) |
| `reasonNOTDeletingDestructor` | `factNOTDeletingDestructor(M)` (basic versions) |
| `possibleMethod` / `possibleConstructor` / `possibleDestructor` | `possibleMethod(M)`, `possibleConstructor(M)`, `possibleDestructor(M)` (from `initial.pl`) |
| `factClassHasNoBase` / `guessClassHasNoBase` | `factClassHasNoBase(C)` (guessed; hard from RTTI) |
| `factMethod` / `factNOTMethod` | `factMethod(M)` (hard derivations: vftable, ctor/dtor, symbols, calls, thunks); `factNOTMethod(M)` (`possibleMethod` not confirmed). Purecall stubs are methods per Prolog `reasonMethod_G`, but blocked from merge rules. |
| `reasonMethod_J` | `factMethod(M) :- factClassCallsMethod(_, M)` |
| `reasonMethod_L` | `factMethod(M) :- methodCallAtOffset(_, Caller, M, 0), factMethod(Caller), thisParamFuncParameter(M, _)` |
| `reasonMethod_O` | `factMethod(M) :- factMethod(Proven), callingConvention(Proven, "__thiscall"), thisParamFuncParameter(Proven, ThisPtr), callParameter(Insn, Proven, 0, ThisPtr), callTarget(Insn, Proven, Target), dethunk(Target, M), callingConvention(M, "__cdecl")` |
| `reasonMethod_P` | `factMethod(M) :- callParameter(Insn1, Func, 0, ThisPtr), callTarget(Insn1, Func, Target1), dethunk(Target1, Proven), factMethod(Proven), callParameter(Insn2, Func, 0, ThisPtr), callTarget(Insn2, Func, Target2), dethunk(Target2, M), callingConvention(M, "__cdecl")` |
| `reasonMethod_K` | `factMethod(M) :- thisPtrUsage(_, Func, ThisPtr, Method1), factMethod(Method1), thisPtrUsage(_, Func, ThisPtr, M), Method1 != M` |
| `reasonMethod_M` | `factMethod(M) :- thisPtrAllocation(_, Func, ThisPtr, type_Heap, _), thisPtrUsage(_, Func, ThisPtr, M), thisParamFuncParameter(M, _)` (and `type_Global`) |
| `reasonMethod_N` | `factMethod(Func) :- thisPtrUsage(_, Func, ThisPtr, Method), factMethod(Method), thisParamFuncParameter(Func, ThisPtr)` |
| `reasonMethod_Q` | **Disabled.** Causes UNSAT on real binaries; the exact conflict is a mergeCandidate domain gap. Prolog also has this rule commented out. |
| `thisPtrUsage/4` | `thisPtrUsage(Insn, Function, ThisPtr, Method)` derived in `src/initial.lp` from `callTarget`, `dethunk`, `thisPtrParam`, `callParameter` |
| `thisPtrUsage/3` | `thisPtrUsage(Function, ThisPtr, Method)` projection in `src/rules.lp` |
| `factClassCallsMethod` | `factClassCallsMethod(C, M)` (no longer requires `factMethod(M)` — matches Prolog `reasonClassCallsMethod_C`) |
| `reasonMergeClasses_C` | `mergeClasses(Caller, M) :- sameClass(Caller, CR), factClassHasNoBase(CR), callAtOffset(Caller, M, 0), sameClass(M, MR), factClassHasNoBase(MR), not purecall(M), Caller < M.` (and symmetric `M < Caller` rule). Uses `sameClass` instead of `find` to avoid the self-defeating loop. |
| `reasonMergeClasses_E` | `mergeClasses(B1, B2) :- factDerivedClass(Derived, B1, Off), factDerivedClass(Derived, B2, Off), B1 < B2.` Head uses raw method IDs to avoid the self-defeating `find` loop. |
| `reasonMergeClasses_G` | `mergeClasses(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.` Head uses raw method IDs to avoid the self-defeating `find` loop. |
| `sort_tuple/2` (Prolog) | `sortPair/4` (Clingo helper: canonical ordering of class-rep pairs) |
| `guessNOTMergeClasses` / `reasonNOTMergeClasses_F` | `reasonNOTMergeClasses` from different-offset bases |
| `rTTIEnabled` / `rTTIInheritsFrom` | `rTTICompleteObjectLocator`, `rTTIInheritsFrom`. Derivation filters `rTTIBaseClassDescriptor` to WhereP=0xffffffff and WhereV=0 (non-virtual bases only). The CHDA field is deliberately ignored to handle binaries where shared BCDs point to their own CHD rather than the derived class's CHD. |
| `factDerivedClass` / `factEmbeddedObject` | `factDerivedClass/3` / `factEmbeddedObject/3` |
| `reasonDerivedClass_B/D` | hard `factDerivedClass` from vftable overwrite / RTTI |
| `eventualThunk` / `dethunk` | `dethunk/2` + `factVFTableEntry/3` (+ catch-all identity for non-thunks) |
| `factObjectInObject` | `objectInObject/3` |
| `find/union` (union-find) | `sameClass` transitive closure + `classRep` + `find/2`. Compact encoding with `merged/2` edge predicate reduces grounding ~7x on real binaries. |
| `insanity*.pl` | `:- constraint.` rules |
| `factClassSizeGTE` / `classSize` | `factVFTableSizeGTE` (lightweight version) |
| `inheritedVftableEntry` | DISABLED in this prototype. See `inheritedVftableEntry` description above and TODO.md. |
| `factVBTable` / `factVBTableEntry` | `factVBTable`, `factVBTableWrite`, `factVBTableEntry` |
| `reasonDerivedClass_F` | `factDerivedClass` from `objectInObject + factVBTableEntry` |
| `guessLateMergeClassesF2` | `mergeCandidate(M1, M2) :- factVFTableEntry(V, _, M2), factVFTableBelongsToClass(V, _, C), find(M1, C), M1 < M2` |
| Guess priority ordering | `@2` / `@1` / `@0` lexicographic optimization levels |

## Known limitations / future work

- Transitive closure of `sameClass` is O(n²) in grounding. The `merged/2`
  compact-encoding refactor (see Architecture above) mitigates this on real
  binaries, cutting `sameClass` atoms ~18x (e.g. `oo.lp`: ~295k → ~16k). For
  further scale, replace with a propagator or reification.
  *Python propagator*: a script using Clingo's `clingo.propagator.Propagator` API
  that hooks into the solving process. It maintains a union-find (disjoint-set)
  structure in Python, watching `mergeClasses` literals as they become true in
  the solver trail. When `mergeClasses(1100, 1200)` is assigned, the propagator
  unions the two sets; on backtracking, it undoes the union (persistent
  union-find). Constraints like "at most one real destructor per class" are
  checked by querying the union-find instead of materializing `sameClass` pairs.
  This eliminates the O(k²) per-component materialization, reducing complexity
  to O(k α(k)) — effectively linear. `find/2` would be exposed as external atoms
  or custom theory atoms that the solver evaluates on demand rather than
  grounding as facts.
- `factVFTableSizeGTE` uses max entry offset (coarse); OOAnalyzer's `classSize{GTE,LTE}`
  also considers member accesses.
- No member access reasoning (`methodMemberAccess`).
- Virtual base inheritance offset resolution from RTTI is not yet handled. Virtual bases are currently filtered *out* of `rTTIInheritsFrom` (WhereP=0xffffffff, WhereV=0 guard), which is correct behavior. Computing the actual offset from a virtual base's BCD entry (WhereP != -1) is future work.
- `reasonMethod_Q` (thunk to proven method -> method) is disabled. Confirmed to cause UNSAT on real binaries; Prolog reference also has this rule commented out.
- Diagnostic mode: run with `--const diagnose=1` to get soft `violate(Tag, Witness)` atoms instead of hard UNSAT, useful for identifying which constraint fires.

See [TODO.md](TODO.md) for the full bidirectional coverage map: which OOAnalyzer rules
are not yet implemented and which Clingo constructs are ASP-specific.
