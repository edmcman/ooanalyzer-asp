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
clingo ooanalyzer.lp example.lp          # find optimal model
clingo ooanalyzer.lp example.lp 0        # enumerate all models
clingo ooanalyzer.lp invalid_example.lp  # UNSATISFIABLE (contradictory facts)
```

## Files

| File | Purpose |
|---|---|
| [`ooanalyzer.lp`](ooanalyzer.lp) | Entry point: `#include`s the modules below |
| [`facts.lp`](facts.lp) | Input vocabulary and `#defined` directives |
| [`guess.lp`](guess.lp) | Guesses (`{ factVFTable }`, `{ mergeClasses }`, etc.) and merge-candidate domain restriction |
| [`rules.lp`](rules.lp) | Forward-reasoning rules: thunk resolution, derived facts, ctor/dtor identification, inheritance, merges, class computation |
| [`insanity.lp`](insanity.lp) | Sanity checks (integrity constraints) |
| [`optimize.lp`](optimize.lp) | Lexicographic optimization directives |
| [`output.lp`](output.lp) | `#show` directives |
| [`example.lp`](example.lp) | Valid 3-class example |
| [`inherit_example.lp`](inherit_example.lp) | Single inheritance: Base + Derived |
| [`multi_inherit_example.lp`](multi_inherit_example.lp) | Multiple inheritance: C : A(0), B(8) |
| [`rtti_example.lp`](rtti_example.lp) | RTTI facts drive the derivation |
| [`virtual_base_example.lp`](virtual_base_example.lp) | Virtual inheritance via VBTable |
| [`inherited_entry_example.lp`](inherited_entry_example.lp) | Derived inherits an un-overridden virtual method |
| [`invalid_example.lp`](invalid_example.lp) | UNSAT demo: contradictory facts |
| [`AGENTS.md`](AGENTS.md) | Detailed architecture and correspondence to OOAnalyzer |

## Background

The original OOAnalyzer is a ~10,000 line SWI-Prolog system in the Pharos
toolchain. This prototype captures the core ideas -- vftable analysis, constructor
heuristics, inheritance detection, RTTI integration, and VBTable support -- in
~350 lines of Clingo with declarative guessing and optimization.

See [AGENTS.md](AGENTS.md) for the full architecture, input fact vocabulary,
correspondence table, and known limitations.
