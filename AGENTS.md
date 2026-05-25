# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure (classes = sets of methods) from binary analysis facts.

Reference implementation: `pharos/share/prolog/oorules/` (SWI-Prolog, ~10k lines).

**v2 branch**: the solver modules (`src/guess.lp`, `src/rules.lp`,
`src/insanity.lp`, `src/optimize.lp`, `src/output.lp`) have been removed and
are being rewritten. Only `src/facts.lp` and `src/initial.lp` remain from the
original module set.

## Files

| File | Purpose |
|---|---|
| `ooanalyzer.lp` | Entry point: `#include`s the modules below |
| `src/facts.lp` | Input vocabulary and `#defined` directives |
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
| `examples/ooa/` | Real OOAnalyzer test files (`.facts`, `.symbols`, `.json`, `.results`) organized by build: `ooex_vs2008/Debug`, `ooex_vs2010/Lite`, etc. |
| `src/old/` | v1 Clingo modules (rules.lp, guess.lp, insanity.lp, optimize.lp, output.lp) — reference only |
| `pharos/` | Original Pharos/OOAnalyzer source (reference) |
| `TODO.md` | Rule coverage tracker: all `reason*`/`guess*`/`insanity*` rules, sorted by entity, with port status |

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

## Known limitations / future work

- No member access reasoning (`methodMemberAccess`).
- Virtual base inheritance offset resolution from RTTI is not yet handled. Virtual
  bases are filtered *out* of `rTTIInheritsFrom` (WhereP=0xffffffff, WhereV=0),
  which is correct behavior. Computing the actual offset from a virtual base's BCD
  entry (WhereP != -1) is future work.

See [TODO.md](TODO.md) for the full rule coverage tracker (217 rules across 12 entity groups).

## Porting guidelines

- **Never simplify a Prolog rule without asking first.** If a faithful translation
  is not straightforward (arity mismatch, missing predicate, etc.), surface the
  problem and the options — do not silently drop conditions.
- **Never merge distinct Prolog predicates into one.** If two predicates (e.g.
  `rTTIEnabled` and `rTTIValid`) appear separately in the Prolog, keep them
  separate in the ASP translation — even if they seem redundant.