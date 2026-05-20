# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).
This prototype captures the core ideas in ~100 lines of Clingo.

## Files

| File | Purpose |
|---|---|
| `ooanalyzer.lp` | Main rules: guesses, rules, sanity checks, optimization |
| `example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |

## Running

```sh
clingo ooanalyzer.lp example.lp          # find optimal model
clingo ooanalyzer.lp example.lp 0        # enumerate all models
clingo ooanalyzer.lp invalid_example.lp  # should print UNSATISFIABLE
```

Clingo exit codes: 10 = SAT, 20 = UNSAT, 30 = OPTIMUM FOUND.

## Input fact vocabulary

| Predicate | Meaning |
|---|---|
| `poss_vftable_write(M, Off, V)` | Method M writes vftable V at object offset Off |
| `poss_vftable_entry(V, Off, M)` | Method M appears at offset Off in vftable V |
| `returns_self(M)` | M returns the this-pointer (ECX → EAX) |
| `no_calls_before(M)` | No OO calls precede M (constructor hint) |
| `no_calls_after(M)` | No OO calls follow M (destructor hint) |
| `calls_delete(M)` | M calls delete/free on the this-pointer |
| `call_target(Caller, Callee)` | Callee is called by Caller |
| `symbol_class(M, Class)` | Debug symbol: M belongs to Class |
| `symbol_property(M, Prop)` | Prop ∈ {constructor, realDestructor, deletingDestructor} |

## Architecture

**Guesses** — the two things the solver decides:
- `{ vftable(V) }` — is candidate V actually a vftable?
- `{ merge(M1, M2) }` — should methods M1 and M2 be in the same class?

**Rules** derive `method`, `constructor`, `real_destructor`, `deleting_destructor`,
`vftable_write`, `vftable_entry`, `forced_merge`, and the equivalence-class
predicates (`same_class`, `class_rep`, `class_of`).

Once a vftable is confirmed all its writes and entries are accepted (not separately
guessed) — this prevents the solver from cherry-picking entries to dodge forced merges.

**Forced merges** (hard constraints via `:- forced_merge, not merge`):
- Two methods writing the *same* vftable at the same offset
- Methods in a vftable + the method that writes it (at offset 0)
- Methods sharing a `symbol_class` annotation

**Class computation** — transitive closure of `merge` gives `same_class`; the
minimum-address method in each equivalence class is the `class_rep`.

**Sanity checks** (integrity constraints — any violation kills the model):
- Constructor cannot appear in a vftable (not virtual)
- Method cannot be both constructor and destructor
- At most one real destructor per class
- A vftable cannot be owned by two different classes at the same object offset
- Two constructors writing *different* vftables at the same object offset must be
  in different classes (the key rule separating distinct classes)

**Optimization** — two-level lexicographic:
1. `#maximize { 1@2, V : vftable(V) }` — confirm as many vftables as possible
2. `#maximize { 1@1, M1,M2 : merge(M1,M2) }` — then maximize merges (minimize classes)

Priority 2 before priority 1 mirrors OOAnalyzer's guess ordering (vftable guesses
precede merge guesses).

## Correspondence to OOAnalyzer (Prolog)

| OOAnalyzer concept | This prototype |
|---|---|
| `factVFTable` | `vftable(V)` (guessed) |
| `factVFTableWrite` / `factVFTableEntry` | derived from confirmed `vftable` |
| `factConstructor` / `factRealDestructor` | `constructor(M)` / `real_destructor(M)` |
| `reasonMergeClasses` | `forced_merge/2` → hard constraint on `merge` |
| `guessMergeClasses` | `{ merge(M1,M2) }` choice + `#maximize` |
| `find/union` (union-find) | `same_class` transitive closure + `class_rep` |
| `insanity*.pl` | `:- constraint.` rules |
| Guess priority ordering | `@2` / `@1` lexicographic optimization levels |

## Known limitations / future work

- No inheritance or embedded-object modeling (OOAnalyzer's `factDerivedClass`,
  `factEmbeddedObject`).
- No virtual base tables.
- Transitive closure of `same_class` is O(n²) in grounding — fine for small
  inputs; replace with a propagator or reification for scale.
- Without inheritance, two constructors overwriting vftables at offset 0 are
  always treated as distinct classes; relaxing this requires modeling `possibleVFTableOverwrite`.
