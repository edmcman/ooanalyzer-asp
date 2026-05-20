# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure from binary analysis facts: methods are grouped into classes,
constructors/destructors are identified, and inheritance relationships are
inferred.

The core logic is split across focused `.lp` modules (mirroring the original
OOAnalyzer Prolog file organization). [`ooanalyzer.lp`](ooanalyzer.lp) is the
thin entry point that includes them in order.

## Quick Start

```sh
clingo ooanalyzer.lp examples/example.lp          # find optimal model
clingo ooanalyzer.lp examples/example.lp 0        # enumerate all models
clingo ooanalyzer.lp examples/invalid_example.lp  # UNSATISFIABLE (contradictory facts)
```

## Files

| File | Purpose |
|---|---|
| [`ooanalyzer.lp`](ooanalyzer.lp) | Entry point: `#include`s the modules below |
| [`src/facts.lp`](src/facts.lp) | Input vocabulary and `#defined` directives |
| [`src/guess.lp`](src/guess.lp) | Guesses (`{ factVFTable }`, `{ mergeClasses }`, etc.) and merge-candidate domain restriction |
| [`src/rules.lp`](src/rules.lp) | Forward-reasoning rules: thunk resolution, derived facts, ctor/dtor identification, inheritance, merges, class computation |
| [`src/insanity.lp`](src/insanity.lp) | Sanity checks (integrity constraints) |
| [`src/optimize.lp`](src/optimize.lp) | Lexicographic optimization directives |
| [`src/output.lp`](src/output.lp) | `#show` directives |
| [`src/initial.lp`](src/initial.lp) | Derives simplified predicates from full-arity OOAnalyzer `.facts` |
| [`facts2clingo.py`](facts2clingo.py) | Syntax adapter: converts `.facts` files to Clingo-compatible `.lp` |
| [`examples/example.lp`](examples/example.lp) | Valid 3-class example |
| [`examples/inherit_example.lp`](examples/inherit_example.lp) | Single inheritance: Base + Derived |
| [`examples/multi_inherit_example.lp`](examples/multi_inherit_example.lp) | Multiple inheritance: C : A(0), B(8) |
| [`examples/rtti_example.lp`](examples/rtti_example.lp) | RTTI facts drive the derivation |
| [`examples/virtual_base_example.lp`](examples/virtual_base_example.lp) | Virtual inheritance via VBTable |
| [`examples/inherited_entry_example.lp`](examples/inherited_entry_example.lp) | Derived inherits an un-overridden virtual method |
| [`examples/invalid_example.lp`](examples/invalid_example.lp) | UNSAT demo: contradictory facts |
| [`AGENTS.md`](AGENTS.md) | Detailed architecture and correspondence to OOAnalyzer |

## Background

The original OOAnalyzer is a ~10,000 line SWI-Prolog system in the Pharos
toolchain. This prototype captures the core ideas -- vftable analysis, constructor
heuristics, inheritance detection, RTTI integration, and VBTable support -- in
~700 lines of Clingo with declarative guessing and optimization.

See [AGENTS.md](AGENTS.md) for the full architecture, input fact vocabulary,
correspondence table, and known limitations.

See [TODO.md](TODO.md) for a bidirectional coverage map: which OOAnalyzer rules are
not yet implemented and which Clingo constructs are ASP-specific.
