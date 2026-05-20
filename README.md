# OOAnalyzer Clingo Prototype

Prototype of OOAnalyzer in Clingo (Answer Set Programming). Recovers C++ class
structure from binary analysis facts: methods are grouped into classes,
constructors/destructors are identified, and inheritance relationships are
inferred.

The core logic is in [ooanalyzer.lp](ooanalyzer.lp) — ~350 lines of guesses,
derived facts, sanity checks, and lexicographic optimization. Everything else is
input examples or reference documentation.

## Quick Start

```sh
clingo ooanalyzer.lp example.lp          # find optimal model
clingo ooanalyzer.lp example.lp 0        # enumerate all models
clingo ooanalyzer.lp invalid_example.lp  # UNSATISFIABLE (contradictory facts)
```

## Files

| File | Purpose |
|---|---|
| [`ooanalyzer.lp`](ooanalyzer.lp) | Main rules: guesses, rules, sanity checks, optimization |
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
toolchain. This prototype captures the core ideas — vftable analysis, constructor
heuristics, inheritance detection, RTTI integration, and VBTable support — in
~350 lines of Clingo with declarative guessing and optimization.

See [AGENTS.md](AGENTS.md) for the full architecture, input fact vocabulary,
correspondence table, and known limitations.
