# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).

**v2 branch**: the solver modules (`src/guess.lp`, `src/rules.lp`,
`src/insanity.lp`, `src/optimize.lp`, `src/output.lp`) have been removed and
are being rewritten. Only `src/util/facts.lp` and `src/util/initial.lp` remain from the
original module set.

## Files

| File | Purpose |
|---|---|
| `ooanalyzer.lp` | Entry point: `#include`s the modules below |
| `src/util/facts.lp` | Input vocabulary and `#defined` directives |
| `src/util/initial.lp` | Derives simplified predicates from full-arity OOAnalyzer `.facts` |
| `facts2clingo.py` | Syntax adapter: converts `.facts` files to Clingo-compatible `.lp` |
| `examples/example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `examples/invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `examples/inherit_example.lp` | Single inheritance: Base + Derived, one vftable overwrite |
| `examples/rtti_example.lp` | Same as inherit but with RTTI facts driving the derivation |
| `examples/multi_inherit_example.lp` | Multiple inheritance: C : A(0), B(8) |
| `examples/inherited_entry_example.lp` | Derived inherits an un-overridden virtual method |
| `examples/virtual_base_example.lp` | Virtual inheritance: Derived : virtual Base via VBTable |
| `examples/selfdefeating.lp` | SAT demo: hard merge using `sameClass` avoids self-defeating loop |
| `examples/ooa/` | Real OOAnalyzer test files (`.facts`, `.symbols`, `.json`, `.results`) organized by build: `ooex_vs2008/Debug`, `ooex_vs2010/Lite`, etc. |
| `src/old/` | v1 Clingo modules (rules.lp, guess.lp, insanity.lp, optimize.lp, output.lp) — reference only |
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |
| `TODO.md` | Rule coverage tracker: all `reason*`/`guess*`/`insanity*` rules, sorted by entity, with port status |
| `.state/NOTEBOOK.md` | Current porting session notes and next-rule queue |

## Running

```sh
clingo ooanalyzer.lp examples/example.lp              # find optimal model
clingo ooanalyzer.lp examples/example.lp 0            # enumerate all models
clingo ooanalyzer.lp examples/invalid_example.lp      # should print UNSATISFIABLE
clingo ooanalyzer.lp examples/inherit_example.lp      # derivedClass(2300, 2100, 0)
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
| `purecall(M)` | M is a pure-virtual stub (included in `method`; blocked from merge rules) |
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

See `src/util/initial.lp` for the exact derivation rules.

## Known limitations / future work

- No member access reasoning (`methodMemberAccess`).
- Virtual base inheritance offset resolution from RTTI is not yet handled. Virtual
  bases are filtered *out* of `rTTIInheritsFrom` (WhereP=0xffffffff, WhereV=0),
  which is correct behavior. Computing the actual offset from a virtual base's BCD
  entry (WhereP != -1) is future work.

See [TODO.md](TODO.md) for the full rule coverage tracker (217 rules across 12 entity groups).

## Class-level relations and `sameClass`

Prolog uses explicit class IDs; ASP uses `sameClass/2` to group methods into
classes. For class-level conclusions like `derivedClass(A, B, Off)`:

- **Defining rules** record concrete witness methods (the methods that provided
  evidence), without joining `sameClass`.
- **Close the relation** with a `_closed` variant using three rules immediately
  after the defining rules. The base predicate only ever accumulates raw witness
  facts; all closure writes to `_closed`:

```prolog
% seed
derivedClass_closed(A, B, Off) :- derivedClass(A, B, Off).
% close first argument
derivedClass_closed(B, C, Off) :- derivedClass_closed(A, C, Off), sameClass(A, B).
% close second argument
derivedClass_closed(A, C, Off) :- derivedClass_closed(A, B, Off), sameClass(B, C).
```

- **Querying rules** use `pred_closed` — never the base predicate — so no extra
  `sameClass` join is needed at the call site.
- **Declare `#defined pred_closed/N`** alongside `#defined pred/N` at the top of
  the module, so Clingo does not complain when the predicate is empty.

**Do not collapse the two propagation rules into one combined rule:**

```prolog
% BAD — O(N^4) grounding
derivedClass(MA, MB, Off) :- derivedClass(A, B, Off), sameClass(A, MA), sameClass(B, MB).
```

The combined form joins both `sameClass` dimensions simultaneously. With
semi-naive evaluation, the grounder re-instantiates it against the N² newly
derived facts with N×N fan-out each, giving O(N⁴) total groundings. The
two-rule form joins one dimension at a time — O(N³) total — and is strictly
better despite requiring one extra fixpoint round.

## Transitive closures with accumulated offsets

Prolog rules like `reasonDerivedClassRelationship(D, B, Off) :- ..., Off is Off1 + Off2.`
rely on SLG tabling to terminate. A literal ASP port hits **two** grounding traps:

1. **Symmetric recursion blowup.** A body of shape `pred(D, M1, Off1), sameClass(M1, M2), pred(M2, B, Off2)`
   with both arms recursive materializes a quadratic-in-fixpoint cross product per round.
   Make the recursion **linear**: one arm is the recursive predicate, the other is the witness
   one-edge predicate (e.g. `derivedClass`, not `derivedClassRelationship`).
2. **Unbounded `Off = Off1 + Off2`.** Because `not sameClass(...)` cannot prune at grounding
   time, the grounder must consider every potential cycle. With cycles open, `Off` ratchets
   upward and the fixpoint never closes. Measured: `derivedClassRelationship` on
   `examples/ooa/ooex_vs2008/Debug/oo.lp` grounded `Off ∈ {0, 12, …, 1536}` (129 values, ~53M
   ground rules).

**Fix pattern** — split into a `/2` reachability closure (no `Off`, naturally bounded by
methods²) and a `/3` whose head is constrained to a bounded `relevantOffset` domain:

```prolog
maxOffsetDepth(4).
primitiveOffset(0).
primitiveOffset(Off) :- derivedClass(_, _, Off).
relevantOffset(Off, 1) :- primitiveOffset(Off).
relevantOffset(Off1 + Off2, N + 1) :-
    relevantOffset(Off1, N), primitiveOffset(Off2),
    maxOffsetDepth(MaxD), N < MaxD.
relevantOffset(Off) :- relevantOffset(Off, _).

derivedClassRelationship(D, B, Off) :-
    derivedClass(D, M1, Off1),
    sameClass(M1, M2),
    derivedClassRelationship(M2, B, Off2),
    Off = Off1 + Off2,
    relevantOffset(Off),         % <-- bounds head to sum-of-primitives-up-to-depth-MaxD
    ...
```

`relevantOffset` is the grounding-time analog of Prolog's
`(integer(Off) -> Off1 < Off; true)` mode pruning — ASP has no modes, so the bound goes
in the body. The depth cap trades coverage for grounding cost; depth 4 handles
inheritance chains with up to 4 non-zero offset edges (the dominant case in real
binaries). Raising it widens coverage at quadratic-ish cost in grounding size.

**Anti-patterns to avoid:**

- **`_closed × _closed` recursion.** Tempting because both arms are already
  sameClass-closed, but `derivedClass_closed` contains atoms like `(B, B, 8)` (via
  the reflexive `sameClass(A, A) :- mergeEntity(A).`), which open self-cycles the
  grounder walks unboundedly accumulating `Off`. Measured to blow up to 13M+ ground
  rules on the tiny `multi_inherit_example`.
- **Bounding `relevantOffset` to `possibleVFTableWrite` offsets only.** Classes
  without vftables still legitimately participate in inheritance chains, and
  primitive offsets from `derivedClass` itself can fall outside the vftable-write
  offset set. Seed `primitiveOffset` from `derivedClass` (and any other source of
  primitive edges).

## Porting guidelines

- **Update `TODO.md` immediately after porting each rule** — mark it `[x]` as soon as it lands in a file.
- **Never simplify a Prolog rule without asking first.** If a faithful translation
  is not straightforward (arity mismatch, missing predicate, etc.), surface the
  problem and the options — do not silently drop conditions.
- **Never merge distinct Prolog predicates into one.** If two predicates (e.g.
  `rTTIEnabled` and `rTTIValid`) appear separately in the Prolog, keep them
  separate in the ASP translation — even if they seem redundant.
- **Translate Prolog body disjunctions with cardinality tests when possible.**
  For Prolog `(p(X); q(Y))` in a rule body, prefer `1 { p(X); q(Y) }` over adding
  a helper predicate solely to express the disjunction. Split into multiple rules
  only when the alternatives need different variable bindings or structure.
