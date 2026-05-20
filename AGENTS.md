# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).
This prototype captures the core ideas in ~300 lines of Clingo.

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
| `examples/example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `examples/invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `examples/inherit_example.lp` | Single inheritance: Base + Derived, one vftable overwrite |
| `examples/rtti_example.lp` | Same as inherit but with RTTI facts driving the derivation |
| `examples/multi_inherit_example.lp` | Multiple inheritance: C : A(0), B(8) |
| `examples/inherited_entry_example.lp` | Derived inherits an un-overridden virtual method |
| `examples/virtual_base_example.lp` | Virtual inheritance: Derived : virtual Base via VBTable |
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

Clingo exit codes: 10 = SAT, 20 = UNSAT, 30 = OPTIMUM FOUND.

## Input fact vocabulary

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
| `purecall(M)` | M is a pure-virtual stub (excluded from `factMethod`) |
| `symbolClass(M, Class)` | Debug symbol: M belongs to Class |
| `symbolProperty(M, Prop)` | Prop \in {constructor, realDestructor, deletingDestructor} |
| `rTTICompleteObjectLocator(V, TDA)` | COL at V-8: vftable V belongs to type TDA |
| `rTTITypeDescriptor(TDA, Name)` | Type descriptor TDA has mangled name Name |
| `rTTIInheritsFrom(DerivedTDA, BaseTDA, Off)` | DerivedTDA has a non-virtual base BaseTDA at byte Off |
| `possibleVBTableWrite(M, Off, V)` | Method M writes VBTable V at object offset Off |
| `possibleVBTableEntry(V, Off, Value)` | Entry Value at offset Off in VBTable V |

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
`factRealDestructor`, `factDeletingDestructor`, `factVFTableWrite`,
`factVFTableOverwrite`, `factVFTableEntry`, `factVFTableBelongsToClass`,
`objectInObject`, `factDerivedClass`, `factEmbeddedObject`, `factClassHasNoBase`,
`factClassCallsMethod`, `reasonMergeClasses`, `reasonNOTMergeClasses`,
`factVFTableSizeGTE`, `inheritedVftableEntry`,
`factVBTable`, `factVBTableWrite`, `factVBTableEntry`,
and the equivalence-class predicates (`sameClass`, `classRep`, `find`).

**factNOTConstructor** -- mirrors `reasonNOTConstructor_B/C/D` from rules.pl:
- `factRealDestructor(M)` or `factDeletingDestructor(M)` -> not a constructor
- `factVFTableEntry(_, _, M)` -> virtual methods cannot be constructors
- `uninitializedReads(M)` or `callsDelete(M)` -> not a constructor

**objectInObject** -- when a constructor calls another at `this+Off`, their classes
are distinct. The solver guesses `factDerivedClass` vs. `factEmbeddedObject`. The
vftable overwrite pattern and RTTI provide hard evidence for `factDerivedClass`.

**factVFTableBelongsToClass(V, Off, C)** -- maps vftable V (at object offset Off) to
class C. Mirrors `reasonVFTableBelongsToClass`. Derived from
`factVFTableWrite(M, Off, V), find(M, C)`.

**factVFTableSizeGTE** -- lower bound on vftable size (max entry offset + 4).
Used by a sanity check: a derived vftable must be at least as large as the base
vftable it overwrites.

**inheritedVftableEntry(Vderived, Off, M)** -- detects vftable slots in the derived
class where the same method pointer appears at the same offset in the base
vftable. Such entries belong to the base class; the vftable-entry merge rule
skips them to avoid incorrectly merging inherited methods into the derived class.

**factVBTable / factVBTableWrite / factVBTableEntry** -- virtual base tables. A VBTable
contains offsets from the VBTable pointer to virtual base subobjects. When a
constructor writes a VBTable and also calls another constructor, and a VBTable entry
(at offset > 0, i.e., not the self-offset) matches the call offset, the relationship
is virtual inheritance (`factDerivedClass`). This is `reasonDerivedClass_F` in the
original OOAnalyzer. The first VBTable entry (offset 0) is typically the self-offset
(offset from vbptr to complete object start).

**factClassHasNoBase** -- guessed, with hard derivation from RTTI. Enables
`reasonMergeClasses_C`: two no-base classes where one calls a method of the other
must be merged. Blocked when `factDerivedClass(M, _, _)` holds for a method in that class.

**factClassCallsMethod(C, M)** -- method M is called by class C passing the same
this-pointer (`callAtOffset(Caller, M, 0)`). Mirrors `factClassCallsMethod`.

**reasonMergeClasses** (`:- reasonMergeClasses, not mergeClasses`):
- Two methods writing the *same* vftable at the same offset
- Methods in a vftable + the method that writes it (at any offset)
- Debug symbols: same `symbolClass` annotation
- reasonMergeClasses_E: two bases of the same derived at the same offset
- Deleting destructor calls real destructor -> same class
- reasonMergeClasses_C: two no-base classes sharing a method call
- Inherited entries (`inheritedVftableEntry`) are excluded -- they belong to the base class

**reasonNOTMergeClasses** (`:- reasonNOTMergeClasses, mergeClasses`):
- Outer and inner constructors of an `objectInObject` pair
- Base constructor (installs without overwriting) vs. derived (overwrites)
- reasonNOTMergeClasses_F: two bases of the same derived at *different* offsets
- RTTI: two vftables with different type descriptors

**Class computation** -- transitive closure of `mergeClasses` gives `sameClass`; the
minimum-address method in each equivalence class is the `classRep`. `find(M, R)`
mirrors Prolog's `find/2` (union-find lookup).

**Sanity checks** (integrity constraints -- any violation kills the model):
- Constructor cannot appear in a vftable (not virtual)
- Method cannot be both constructor and destructor
- Constructor cannot be `factNOTConstructor`
- At most one real destructor per class
- A vftable cannot be owned by two different classes at the same object offset
- Two constructors writing *different* vftables at the same offset -> different classes
- No circular inheritance
- `objectInObject` pairs must be in distinct classes
- Derived classes cannot be `factClassHasNoBase`
- Derived vftable size must be >= base vftable size (`factVFTableSizeGTE`)
- A constructor writing a VBTable cannot also embed the same base (virtual
  inheritance supersedes embedding)

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
| `factConstructor` / `factRealDestructor` | `factConstructor(M)` / `factRealDestructor(M)` |
| `factNOTConstructor` / `reasonNOTConstructor_B/C/D` | `factNOTConstructor(M)` |
| `factClassHasNoBase` / `guessClassHasNoBase` | `factClassHasNoBase(C)` (guessed; hard from RTTI) |
| `factClassCallsMethod` | `factClassCallsMethod(C, M)` |
| `reasonMergeClasses_C` | `reasonMergeClasses` from `factClassHasNoBase + factClassCallsMethod` |
| `reasonMergeClasses_E` | `reasonMergeClasses` from shared base at same offset |
| `reasonMergeClasses` (dtor pair) | `reasonMergeClasses` from `factDeletingDestructor -> callTarget -> factRealDestructor` |
| `guessNOTMergeClasses` / `reasonNOTMergeClasses_F` | `reasonNOTMergeClasses` from different-offset bases |
| `rTTIEnabled` / `rTTIInheritsFrom` | `rTTICompleteObjectLocator`, `rTTIInheritsFrom` |
| `factDerivedClass` / `factEmbeddedObject` | `factDerivedClass/3` / `factEmbeddedObject/3` |
| `reasonDerivedClass_B/D` | hard `factDerivedClass` from vftable overwrite / RTTI |
| `eventualThunk` / `dethunk` | `dethunk/2` + `factVFTableEntry/3` |
| `factObjectInObject` | `objectInObject/3` |
| `find/union` (union-find) | `sameClass` transitive closure + `classRep` + `find/2` |
| `insanity*.pl` | `:- constraint.` rules |
| `factClassSizeGTE` / `classSize` | `factVFTableSizeGTE` (lightweight version) |
| `inheritedVftableEntry` | `inheritedVftableEntry(V, Off, M)` -- detects re-used base slots |
| `factVBTable` / `factVBTableEntry` | `factVBTable`, `factVBTableWrite`, `factVBTableEntry` |
| `reasonDerivedClass_F` | `factDerivedClass` from `objectInObject + factVBTableEntry` |
| Guess priority ordering | `@2` / `@1` / `@0` lexicographic optimization levels |

## Known limitations / future work

- Transitive closure of `sameClass` is O(n^2) in grounding -- fine for small
  inputs; replace with a propagator or reification for scale.
  *Python propagator*: a script using Clingo's `clingo.propagator.Propagator` API
  that hooks into the solving process. It maintains a union-find (disjoint-set)
  structure in Python, watching `mergeClasses` literals as they become true in
  the solver trail. When `mergeClasses(1100, 1200)` is assigned, the propagator
  unions the two sets; on backtracking, it undoes the union (persistent
  union-find). Constraints like "at most one real destructor per class" are
  checked by querying the union-find instead of materializing `sameClass` pairs.
  This eliminates the O(k^2) per-component materialization, reducing complexity
  to O(k alpha(k)) -- effectively linear. `find/2` would be exposed as external atoms
  or custom theory atoms that the solver evaluates on demand rather than
  grounding as facts.
- `factVFTableSizeGTE` uses max entry offset (coarse); OOAnalyzer's `classSize{GTE,LTE}`
  also considers member accesses.
- No member access reasoning (`methodMemberAccess`).
- RTTI for virtual bases not yet handled (`rTTIInheritsFrom` with `WhereP != -1`).

See [TODO.md](TODO.md) for the full bidirectional coverage map: which OOAnalyzer rules
are not yet implemented and which Clingo constructs are ASP-specific.
