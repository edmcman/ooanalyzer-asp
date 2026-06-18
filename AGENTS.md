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
| `ooanalyzer.py` | Clingo driver that registers the `&sameClass/2` propagator |
| `src/util/config.lp` | Tunable `#const`s (e.g. `max_class_size`, `max_offset_depth`) — override on the command line |
| `src/util/theory.lp` | Clingo theory declaration for `&sameClass/2` |
| `src/util/facts.lp` | Input vocabulary and `#defined` directives |
| `src/util/initial.lp` | Derives simplified predicates from full-arity OOAnalyzer `.facts` |
| `propagator/sameclass.py` | Python union-find propagator implementing `&sameClass/2` |
| `propagator/conflict_profiler.py` | Propagator that counts per-predicate backtrack rates; use `--profile-conflicts` when solver performance is poor to identify which predicates drive the most search |
| `tests/test_propagator.py` | Focused regression harness for the propagator |
| `scripts/facts2clingo.py` | Syntax adapter: converts `.facts` files to Clingo-compatible `.lp` |
| `examples/manual/example.lp` | Valid 3-class example (expected: 3 separate classes) |
| `examples/manual/invalid_example.lp` | UNSAT demo: two real destructors forced into the same class |
| `examples/manual/inherit_example.lp` | Single inheritance: Base + Derived, one vftable overwrite |
| `examples/manual/rtti_example.lp` | Same as inherit but with RTTI facts driving the derivation |
| `examples/manual/multi_inherit_example.lp` | Multiple inheritance: C : A(0), B(8) |
| `examples/manual/inherited_entry_example.lp` | Derived inherits an un-overridden virtual method |
| `examples/manual/virtual_base_example.lp` | Virtual inheritance: Derived : virtual Base via VBTable |
| `examples/manual/selfdefeating.lp` | SAT demo: hard merge using `sameClass` avoids self-defeating loop |
| `examples/manual/merge_conditional_stress.lp` | TinyXml-like merge reward stress toy with mixed static, gated, and theory-shaped leaf mutexes hidden behind `&sameClass` |
| `examples/ooa/` | Real OOAnalyzer test files (`.facts`, `.symbols`, `.json`, `.results`) organized by build: `ooex_vs2008/Debug`, `ooex_vs2010/Lite`, etc. |
| `src/old/` | v1 Clingo modules (rules.lp, guess.lp, insanity.lp, optimize.lp, output.lp) — reference only |
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |
| `TODO.md` | Rule coverage tracker: all `reason*`/`guess*`/`insanity*` rules, sorted by entity, with port status |
| `NOTE.md` | Working notes on the current `sameClass`/merge optimization blocker and stress-toy measurements |
| `.state/NOTEBOOK.md` | Current porting session notes and next-rule queue |

## Running

Dependencies (notably `clingo`) live in the uv-managed `.venv`, so all commands
must be run through `uv run`. Bare `python`/`python3` will fail with
`ModuleNotFoundError: No module named 'clingo'`.

```sh
uv run python ooanalyzer.py examples/manual/example.lp              # find optimal model
uv run python ooanalyzer.py examples/manual/example.lp -n 0         # enumerate all models
uv run python ooanalyzer.py examples/manual/invalid_example.lp      # should print UNSATISFIABLE
uv run python ooanalyzer.py examples/manual/inherit_example.lp      # derivedClass(2300, 2100, 0)
uv run python ooanalyzer.py examples/manual/rtti_example.lp         # same but RTTI-driven, fewer models
uv run python ooanalyzer.py examples/manual/multi_inherit_example.lp  # C : A(0), B(8)
uv run python ooanalyzer.py examples/manual/inherited_entry_example.lp  # derived inherits an un-overridden entry
uv run python ooanalyzer.py examples/manual/virtual_base_example.lp     # Derived : virtual Base via VBTable
uv run python ooanalyzer.py examples/manual/merge_conditional_stress.lp # mixed static/conditional merge stress toy
uv run python tests/test_propagator.py                # focused &sameClass regression test
```

`ooanalyzer.lp` contains the `#theory` declaration, but solving must use
`ooanalyzer.py` for normal runs because the Python driver registers the
`&sameClass/2` propagator. Calling `clingo ooanalyzer.lp ...` directly leaves
the theory atoms uninterpreted.

Tune solver constants on the command line (see `src/util/config.lp` for the list):

```sh
# Tighter offset bounds — useful for very small classes.
uv run python ooanalyzer.py --const max_class_size=128 examples/ooa/ooex_vs2008/Debug/oo.lp

# Allow deeper transitive inheritance chains.
uv run python ooanalyzer.py --const max_offset_depth=6 examples/ooa/ooex_vs2008/Debug/oo.lp

# Disable dynamic guess gates for comparison/profiling.
uv run python ooanalyzer.py --const enable_dynamic_guess_gates=0 mysql.exe.lp
```

### Solver configuration constants

All solver configuration constants live in `src/util/config.lp`. Override them
with repeated `--const NAME=VALUE` arguments to `ooanalyzer.py`.

| Constant | Default | Meaning |
|---|---:|---|
| `max_offset_depth` | `4` | Maximum number of primitive offsets summed when building transitive offset domains |
| `max_class_size` | `256` | Maximum accumulated object offset admitted by `relevantOffset/1` |
| `enable_dynamic_guess_gates` | `1` | Guard guess families with `guessEnabled/1` atoms initially biased false |
| `enable_guess_method` | `1` | Enable `method/1` guessing from `possibleMethod/1` |
| `enable_guess_constructor` | `1` | Enable constructor guessing |
| `enable_guess_vftable` | `1` | Enable `vfTable/1` guessing |
| `enable_guess_vftable_size` | `1` | Enable `vfTableSize/2` exact-size choices |
| `enable_guess_merge` | `1` | Enable `mergeClasses/2` vs `-mergeClasses/2` choices |
| `enable_guess_derived_class` | `1` | Enable embedded-object vs derived-class choices |
| `enable_weak_g1_bonus` | `1` | Enable the `guessLateMergeClasses_G1` constructor bonus |
| `enable_merge_rewards` | `1` | Enable strong/weak/G1 merge rewards in optimization while leaving merge choices active |
| `min_vftable_size_total` | `0` | Optional staged-optimization floor on total selected `vfTableSize/2`; 0 disables |
| `max_vftable_size_total` | `0` | Optional staged-optimization ceiling on total selected `vfTableSize/2`; 0 disables |

`enable_guess_*` and `enable_weak_g1_bonus` are converted into `guessGate/1` facts in
`src/util/config.lp`; modules should consume `guessEnabled/1` gates, not read
the `enable_*` constants directly. The only normal direct `enable_*` references
should be in `src/util/config.lp`.

Or use the Makefile:

```sh
make examples/ooa/ooex_vs2008/Debug/oo.lp   # convert one .facts file
make convert                                 # convert all examples/ooa/*/*/*.facts
make run                                     # convert and run ooanalyzer.py on all of them
make propagator-run                          # alias for make run
make clean                                   # remove generated .lp/.out files
```

### From OOAnalyzer .facts files

```sh
uv run python scripts/facts2clingo.py examples/ooa/ooex_vs2008/Debug/oo.facts > /tmp/oo.lp
uv run python ooanalyzer.py /tmp/oo.lp
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
| `rTTIClassHierarchyDescriptor` | 3 | List expanded by `scripts/facts2clingo.py` |
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

- Member access reasoning is partial: `validMethodMemberAccess/4` (initial.lp)
  feeds `reasonClassSizeGTE_E`, but broader consumers (e.g. `reasonObjectInObject`
  from member access) are not yet ported.
- Virtual base inheritance offset resolution from RTTI is not yet handled. Virtual
  bases are filtered *out* of `rTTIInheritsFrom` (WhereP=0xffffffff, WhereV=0),
  which is correct behavior. Computing the actual offset from a virtual base's BCD
  entry (WhereP != -1) is future work.

See [TODO.md](TODO.md) for the full rule coverage tracker (217 rules across 12 entity groups).

## Class-level relations and `&sameClass`

Prolog uses explicit class IDs. This ASP port represents class membership with
`mergeClasses/2` evidence and queries the induced equivalence relation through
the `&sameClass/2` theory atom. `propagator/sameclass.py` maintains a union-find
over true `mergeClasses/2` atoms, handles reflexive and disconnected cases, and
adds reason clauses for true/false theory decisions.

For class-level conclusions like `derivedClass(A, B, Off)`:

- **Defining rules record concrete witness entities only.** Do not close the
  base predicate over class membership in the head.
- **Querying rules join witnesses explicitly with `&sameClass(...)`.** If a use
  site needs "some member of this class", keep the witness predicate raw and add
  the theory atom in the body.
- **Do not reintroduce materialized `sameClass/2`, `merged/2`, or `_closed`
  variants** for the normal solver path. Those were removed to avoid large
  same-class closure groundings.

Example pattern:

```prolog
% Witness-only fact.
derivedClass(DerivedCtor, BaseCtor, Off) :- ... .

% Use site joins the caller's class witness to the derived-class witness.
-mergeClasses(A, B) :-
    classCallsMethod(DC1, CalledMethod),
    derivedClass(DC2, BaseClass, Off),
    &sameClass(DC1, DC2),
    not &sameClass(BaseClass, CalledMethod),
    sortPair(BaseClass, CalledMethod, A, B).
```

When adding theory atoms, remember that `not &sameClass(A, B)` is a solver-time
condition. It can reduce search but does not prune grounding the way a positive
ordinary predicate might.

### Performance blocker: merge optimization under `&sameClass`

This is currently a major project blocker. On TinyXml-like inputs, the solver
can find a conservative first model, but optimizing merge rewards becomes very
slow because the crucial mutual exclusions are hidden behind the `&sameClass`
theory propagator instead of appearing as ordinary Boolean clauses.

`examples/manual/merge_conditional_stress.lp` isolates this shape:

- each group has one rewarding hub `H` and many rewarding leaves `L1..Ln`
- leaf pairs are split between static `-mergeClasses` facts, ordinary gated
  `-mergeClasses` rules, and theory-shaped mutexes derived through `&sameClass`
- selecting both `mergeClasses(H, Li)` and `mergeClasses(H, Lj)` only becomes a
  conflict *after* the corresponding leaf-leaf mutex is active and transitive
  `&sameClass(Li, Lj)` is derived

So the real conflict is a conditional at-most-one relation per hub, but the
normal solver path only sees much of it through ordinary gates and theory
reasons.

Representative measurements:

- default mixed `8x16`: optimum `-80` eventually found, but USC
  lower bound advances in tiny steps; after local pruning it still takes about
  4.4s
- mostly static `8x16`: optimum `-80`, about 4.2s; this approximates the
  removed all-static stress toy
- conditional disabled `8x16`: optimum `-620`, about 4.0s; this is the
  soundness check that reward compression must not suppress raw edge rewards
  merely because a conditional `-mergeClasses/2` atom exists

Interpretation: CDCL/USC itself is not the main failure. The problem is that
the theory propagator hides the compact Boolean structure that the optimizer
needs to prove away impossible rewards.

What has and has not helped so far:

- `--opt-heuristic=sign` slightly reduces choices on the propagator path, but
  does not fix the proof bottleneck
- `--opt-usc-shrink={lin,bin,min}` does **not** help this pattern; it often
  finds one better model but makes lower-bound progress worse
- boundary-edge pruning inside `propagator/sameclass.py` helps local search by
  forcing open merge edges false when they would connect components already
  separated by a false `&sameClass`, but it still does not expose a compact
  global exclusion to USC

The most promising directions are:

- derive explicit Boolean pairwise exclusions or cardinality constraints for
  mutually-exclusive rewarded merges
- generate such exclusions lazily from ordinary ASP witnesses when possible
- use partial/targeted grounding of `sameClass`-style consequences in the hot
  merge-reward regions, instead of fully materializing the whole closure

Avoid assuming that more propagator-local pruning alone will solve TinyXml or
malware-scale optimization. The stress toy strongly suggests that exposing the
right Boolean structure matters more than shaving a few thousand bad guesses.
Because real inputs have many partial or conditional mutex neighborhoods rather
than complete static cliques, reward compression can only replace raw edge
rewards when the corresponding static or guarded mutex condition is active.

## Transitive closures with accumulated offsets

Prolog rules like `reasonDerivedClassRelationship(D, B, Off) :- ..., Off is Off1 + Off2.`
rely on SLG tabling to terminate. A literal ASP port hits **two** grounding traps:

1. **Symmetric recursion blowup.** A body of shape `pred(D, M1, Off1), &sameClass(M1, M2), pred(M2, B, Off2)`
   with both arms recursive materializes a quadratic-in-fixpoint cross product per round.
   Make the recursion **linear**: one arm is the recursive predicate, the other is the witness
   one-edge predicate (e.g. `derivedClass`, not `derivedClassRelationship`).
2. **Unbounded `Off = Off1 + Off2`.** Because `not &sameClass(...)` cannot prune at grounding
   time, the grounder must consider every potential cycle. With cycles open, `Off` ratchets
   upward and the fixpoint never closes. Measured: `derivedClassRelationship` on
   `examples/ooa/ooex_vs2008/Debug/oo.lp` grounded `Off ∈ {0, 12, …, 1536}` (129 values, ~53M
   ground rules).

**Fix pattern** — split into a `/2` reachability closure (no `Off`, naturally bounded by
methods²) and a `/3` whose head is constrained to a bounded `relevantOffset` domain:

```prolog
% From src/util/config.lp (overridable with --const at the command line).
#const max_offset_depth = 4.
#const max_class_size = 256.
maxOffsetDepth(max_offset_depth).
maxClassSize(max_class_size).

primitiveOffset(0).
primitiveOffset(Off) :- derivedClass(_, _, Off).

relevantOffset(Off, 1) :- primitiveOffset(Off).
relevantOffset(Off1 + Off2, N + 1) :-
    relevantOffset(Off1, N), primitiveOffset(Off2),
    maxOffsetDepth(MaxD), N < MaxD,
    maxClassSize(MaxS), Off1 + Off2 <= MaxS.
relevantOffset(Off) :- relevantOffset(Off, _).

derivedClassRelationship(D, B, Off) :-
    derivedClass(D, M1, Off1),
    &sameClass(M1, M2),
    derivedClassRelationship(M2, B, Off2),
    Off = Off1 + Off2,
    relevantOffset(Off),         % <-- bounds head; depth AND size bound intersected
    ...
```

`relevantOffset` is the grounding-time analog of Prolog's
`(integer(Off) -> Off1 < Off; true)` mode pruning — ASP has no modes, so the bound goes
in the body. The two caps trade off differently:

- **`max_offset_depth`** wins when primitive offsets are sparse and chains are shallow
  (e.g. `{0, 12}` → 5 sums at depth 4).
- **`max_class_size`** wins when primitives are dense (e.g. `{0, 4, 8, 12, 16}` →
  depthᴾ explodes faster than `S/g`).

Intersecting both gives the tighter of the two for any given input. Tune via
`uv run python ooanalyzer.py --const max_class_size=512 ...` when you encounter a
binary that needs more headroom; both constants live in `src/util/config.lp`.

**Anti-patterns to avoid:**

- **Reintroducing `_closed × _closed` recursion.** The old materialized
  same-class closure made predicates like `derivedClass_closed` contain atoms
  such as `(B, B, 8)`, which opened self-cycles the grounder walked unboundedly
  while accumulating `Off`. Measured to blow up to 13M+ ground rules on the tiny
  `multi_inherit_example`.
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
