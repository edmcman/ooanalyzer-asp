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
python ooanalyzer.py examples/manual/example.lp              # find optimal model
python ooanalyzer.py examples/manual/example.lp -n 0         # enumerate all models
python ooanalyzer.py examples/manual/invalid_example.lp      # UNSATISFIABLE
python tests/test_propagator.py                       # propagator regression test
```

The ASP rules use the `&sameClass/2` theory atom, so normal solving should go
through [`ooanalyzer.py`](ooanalyzer.py). The wrapper loads
[`ooanalyzer.lp`](ooanalyzer.lp), registers the Python propagator, and then loads
the fact/example files passed on the command line.

Or use the Makefile:

```sh
make examples/ooa/ooex_vs2008/Debug/oo.lp  # convert one .facts file
make convert                                # convert all examples/ooa/*/*/*.facts
make run                                    # convert and run ooanalyzer.py on all of them
make propagator-run                         # alias for make run
make verify                                 # run marker checks for core fixtures
make clean                                  # remove generated .lp/.out files
```

`make run` is the current solver path for the `&sameClass/2` prototype and uses
the Python propagator driver.

`python tests/test_propagator.py` is the focused regression check for the
current theory path. `make verify` also uses the Python propagator driver.

## Configuration

Solver constants live in [`src/util/config.lp`](src/util/config.lp) and can be
overridden with repeated `--const` flags:

```sh
python ooanalyzer.py mysql.exe.lp --const enable_dynamic_guess_gates=0 --stats=1
python ooanalyzer.py mysql.exe.lp --const max_class_size=512 --const max_offset_depth=6
```

Core bounds:

| Constant | Default | Meaning |
|---|---:|---|
| `max_offset_depth` | `4` | Maximum number of primitive inheritance offsets summed for transitive offset domains |
| `max_class_size` | `256` | Maximum accumulated object offset admitted by `relevantOffset/1` |

Guess-family gates:

| Constant | Default | Meaning |
|---|---:|---|
| `enable_dynamic_guess_gates` | `1` | Guard each guess family with a `guessEnabled/1` atom initially biased false |
| `enable_guess_method` | `1` | Enable `method/1` guessing from `possibleMethod/1` |
| `enable_guess_constructor` | `1` | Enable constructor guessing from constructor candidates |
| `enable_guess_vftable` | `1` | Enable `vfTable/1` guessing from possible vftables |
| `enable_guess_vftable_size` | `1` | Enable exact `vfTableSize/2` choice per confirmed vftable |
| `enable_guess_merge` | `1` | Enable `mergeClasses/2` vs `-mergeClasses/2` choices for merge candidates |
| `enable_guess_derived_class` | `1` | Enable embedded-object vs derived-class choices for `objectInObject/3` |

Scoring and heuristic gates:

| Constant | Default | Meaning |
|---|---:|---|
| `enable_weak_g1_bonus` | `1` | Enable the `guessLateMergeClasses_G1` constructor bonus |

## Files

| File | Purpose |
|---|---|
| [`ooanalyzer.lp`](ooanalyzer.lp) | Entry point: `#include`s the modules below |
| [`ooanalyzer.py`](ooanalyzer.py) | Clingo driver that registers the `&sameClass/2` propagator |
| [`src/util/config.lp`](src/util/config.lp) | Tunable solver constants and guess-gate configuration |
| [`src/util/theory.lp`](src/util/theory.lp) | Clingo theory declaration for `&sameClass/2` |
| [`src/util/facts.lp`](src/util/facts.lp) | Input vocabulary and `#defined` directives |
| [`src/util/initial.lp`](src/util/initial.lp) | Derives simplified predicates from full-arity OOAnalyzer `.facts` |
| [`src/modules/methods.lp`](src/modules/methods.lp) | Method identification rules |
| [`src/modules/ctorsdtors.lp`](src/modules/ctorsdtors.lp) | Constructor/destructor identification and guessing |
| [`src/modules/vftables.lp`](src/modules/vftables.lp) | VFTable identification, entries, and guessing |
| [`src/modules/merges.lp`](src/modules/merges.lp) | Class merge and non-merge evidence |
| [`propagator/sameclass.py`](propagator/sameclass.py) | Union-find propagator for `&sameClass/2` |
| [`tests/test_propagator.py`](tests/test_propagator.py) | Focused propagator regression harness |
| [`src/old/`](src/old/) | v1 Clingo modules (reference only) |
| [`scripts/facts2clingo.py`](scripts/facts2clingo.py) | Syntax adapter: converts `.facts` files to Clingo-compatible `.lp` |
| [`examples/manual/example.lp`](examples/manual/example.lp) | Valid 3-class example |
| [`examples/manual/inherit_example.lp`](examples/manual/inherit_example.lp) | Single inheritance: Base + Derived |
| [`examples/manual/multi_inherit_example.lp`](examples/manual/multi_inherit_example.lp) | Multiple inheritance: C : A(0), B(8) |
| [`examples/manual/rtti_example.lp`](examples/manual/rtti_example.lp) | RTTI facts drive the derivation |
| [`examples/manual/virtual_base_example.lp`](examples/manual/virtual_base_example.lp) | Virtual inheritance via VBTable |
| [`examples/manual/inherited_entry_example.lp`](examples/manual/inherited_entry_example.lp) | Derived inherits an un-overridden virtual method |
| [`examples/manual/invalid_example.lp`](examples/manual/invalid_example.lp) | UNSAT demo: contradictory facts |
| [`examples/ooa/`](examples/ooa/) | Real OOAnalyzer `.facts` files (from `pharos/tools/ooanalyzer/tests`) |
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
