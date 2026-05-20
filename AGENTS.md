# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).
This prototype captures the core ideas in ~300 lines of Clingo.

## Files

| File | Purpose |
|---|---|
| `ooanalyzer.lp` | Main rules: guesses, rules, sanity checks, optimization |
| `example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `inherit_example.lp` | Single inheritance: Base + Derived, one vftable overwrite |
| `rtti_example.lp` | Same as inherit but with RTTI facts driving the derivation |
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |

## Running

```sh
clingo ooanalyzer.lp example.lp          # find optimal model
clingo ooanalyzer.lp example.lp 0        # enumerate all models
clingo ooanalyzer.lp invalid_example.lp  # should print UNSATISFIABLE
clingo ooanalyzer.lp inherit_example.lp  # derived_class(2300, 2100, 0)
clingo ooanalyzer.lp rtti_example.lp     # same but RTTI-driven, fewer models
```

Clingo exit codes: 10 = SAT, 20 = UNSAT, 30 = OPTIMUM FOUND.

## Input fact vocabulary

| Predicate | Meaning |
|---|---|
| `poss_vftable_write(M, Off, V)` | Method M writes vftable V at object offset Off |
| `poss_vftable_entry(V, Off, E)` | Entry E at offset Off in vftable V (E may be a thunk) |
| `poss_vftable_overwrite(M, Off, V1, V2)` | M overwrites V1 with V2 at Off (ctor sequence) |
| `returns_self(M)` | M returns the this-pointer (ECX → EAX) |
| `no_calls_before(M)` | No OO calls precede M (constructor hint) |
| `no_calls_after(M)` | No OO calls follow M (destructor hint) |
| `calls_delete(M)` | M calls delete/free on the this-pointer |
| `uninitialized_reads(M)` | M reads members before setting them (NOT-constructor signal) |
| `call_target(Caller, Callee)` | Callee is directly called by Caller |
| `call_at_offset(Caller, Callee, Off)` | Callee is called by Caller with this+Off |
| `thunk(Thunk, Target)` | Thunk is a JMP-only stub for Target |
| `purecall(M)` | M is a pure-virtual stub (excluded from `method`) |
| `symbol_class(M, Class)` | Debug symbol: M belongs to Class |
| `symbol_property(M, Prop)` | Prop ∈ {constructor, realDestructor, deletingDestructor} |
| `rtti_complete_object_locator(V, TDA)` | COL at V−8: vftable V belongs to type TDA |
| `rtti_type_descriptor(TDA, Name)` | Type descriptor TDA has mangled name Name |
| `rtti_inherits_from(DerivedTDA, BaseTDA, Off)` | DerivedTDA has a non-virtual base BaseTDA at byte Off |

## Architecture

**Guesses** — the four things the solver decides:
- `{ vftable(V) }` — is candidate V actually a vftable? (RTTI confirms without guessing)
- `{ merge(M1, M2) }` — should methods M1 and M2 be in the same class?
- `{ derived_class(Outer, Inner, Off) }` — is this ctor-calls-ctor relationship
  inheritance (derived_class) or composition (embedded_object)? RTTI overrides.
- `{ class_has_no_base(C) }` — does class C have no base class? RTTI overrides.

**Thunk resolution** — `dethunk/2` follows JMP-only stub chains to the real method;
`effective_entry(V, Off, M)` gives the actual method at each vftable slot.

**Rules** derive `method`, `constructor`, `not_constructor`, `real_destructor`,
`deleting_destructor`, `vftable_write`, `vftable_overwrite`, `effective_entry`,
`vftable_class`, `ctor_calls_ctor`, `derived_class`, `embedded_object`,
`class_has_no_base`, `class_calls_method`, `forced_merge`, `forced_not_merge`,
and the equivalence-class predicates (`same_class`, `class_rep`, `class_of`).

**not_constructor** — mirrors `reasonNOTConstructor_B/C/D` from rules.pl:
- `real_destructor(M)` or `deleting_destructor(M)` → not a constructor
- `effective_entry(_, _, M)` → virtual methods cannot be constructors
- `uninitialized_reads(M)` or `calls_delete(M)` → not a constructor

**ctor_calls_ctor** — when a constructor calls another at `this+Off`, their classes
are distinct. The solver guesses derived_class vs. embedded_object. The vftable
overwrite pattern and RTTI provide hard evidence for derived_class.

**vftable_class(V, Off, C)** — maps vftable V (at object offset Off) to class C.
Mirrors `reasonVFTableBelongsToClass`. Derived from `vftable_write(M, Off, V), class_of(M, C)`.

**class_has_no_base** — guessed, with hard derivation from RTTI. Enables
`reasonMergeClasses_C`: two no-base classes where one calls a method of the other
must be merged. Blocked when `derived_class(M, _, _)` holds for a method in that class.

**class_calls_method(C, M)** — method M is called by class C passing the same
this-pointer (`call_at_offset(Caller, M, 0)`). Mirrors `factClassCallsMethod`.

**Forced merges** (`:- forced_merge, not merge`):
- Two methods writing the *same* vftable at the same offset
- Methods in a vftable + the method that writes it (at offset 0)
- Debug symbols: same `symbol_class` annotation
- reasonMergeClasses_E: two bases of the same derived at the same offset
- Deleting destructor calls real destructor → same class
- reasonMergeClasses_C: two no-base classes sharing a method call

**Forced not-merges** (`:- forced_not_merge, merge`):
- Outer and inner constructors of a `ctor_calls_ctor` pair
- Base constructor (installs without overwriting) vs. derived (overwrites)
- reasonNOTMergeClasses_F: two bases of the same derived at *different* offsets
- RTTI: two vftables with different type descriptors

**Class computation** — transitive closure of `merge` gives `same_class`; the
minimum-address method in each equivalence class is the `class_rep`.

**Sanity checks** (integrity constraints — any violation kills the model):
- Constructor cannot appear in a vftable (not virtual)
- Method cannot be both constructor and destructor
- Constructor cannot be `not_constructor` (insanityContradictoryNOTConstructor)
- At most one real destructor per class
- A vftable cannot be owned by two different classes at the same object offset
- Two constructors writing *different* vftables at the same offset → different classes
- No circular inheritance
- Ctor-calls-ctor pairs must be in distinct classes
- Derived classes cannot be `class_has_no_base`

**Optimization** — three-level lexicographic:
1. `#maximize { 1@2, V : vftable(V) }` — confirm as many vftables as possible
2. `#maximize { 1@1, M1,M2 : merge(M1,M2) }` — maximize merges (minimize classes)
3. `#maximize { 1@0, ... }` — prefer `derived_class` at offset 0; prefer more `class_has_no_base`

## Correspondence to OOAnalyzer (Prolog)

| OOAnalyzer concept | This prototype |
|---|---|
| `factVFTable` | `vftable(V)` (guessed; confirmed by RTTI) |
| `factVFTableWrite` / `factVFTableEntry` | `vftable_write`, `effective_entry` (thunk-resolved) |
| `factVFTableOverwrite` | `vftable_overwrite` (from `poss_vftable_overwrite`) |
| `reasonVFTableBelongsToClass` | `vftable_class(V, Off, C)` |
| `factConstructor` / `factRealDestructor` | `constructor(M)` / `real_destructor(M)` |
| `factNOTConstructor` / `reasonNOTConstructor_B/C/D` | `not_constructor(M)` |
| `factClassHasNoBase` / `guessClassHasNoBase` | `class_has_no_base(C)` (guessed; hard from RTTI) |
| `factClassCallsMethod` | `class_calls_method(C, M)` |
| `reasonMergeClasses_C` | `forced_merge` from `class_has_no_base + class_calls_method` |
| `reasonMergeClasses_E` | `forced_merge` from shared base at same offset |
| `reasonMergeClasses` (dtor pair) | `forced_merge` from `deleting_destructor → call_target → real_destructor` |
| `guessNOTMergeClasses` / `reasonNOTMergeClasses_F` | `forced_not_merge` from different-offset bases |
| `rTTIEnabled` / `rTTIInheritsFrom` | `rtti_complete_object_locator`, `rtti_inherits_from` |
| `factDerivedClass` / `factEmbeddedObject` | `derived_class/3` / `embedded_object/3` |
| `reasonDerivedClass_B/D` | hard `derived_class` from vftable overwrite / RTTI |
| `eventualThunk` / `dethunk` | `dethunk/2` + `effective_entry/3` |
| `find/union` (union-find) | `same_class` transitive closure + `class_rep` |
| `insanity*.pl` | `:- constraint.` rules |
| Guess priority ordering | `@2` / `@1` / `@0` lexicographic optimization levels |

## Known limitations / future work

- No virtual base tables (OOAnalyzer's `factVBTable`, `factVBTableEntry`).
- Transitive closure of `same_class` is O(n²) in grounding — fine for small
  inputs; replace with a propagator or reification for scale.
- `vftable_class` / vftable-entry forced-merge does not yet restrict inherited
  entries when a class has a base (needs vftable size bounds: `classSize{GTE,LTE}`).
- No member access reasoning (`methodMemberAccess`, `classSize{GTE,LTE}`).
- RTTI for virtual bases not yet handled (`rtti_inherits_from` with `WhereP ≠ -1`).
