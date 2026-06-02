---
name: explain
description: Explain why an ASP atom is true/false or why a program is UNSAT. Uses scripts/why_unsat.py for unsatisfiability analysis and xclingo2 for trace-based explanations of derived atoms.
argument-hint: "[atom | files...]"
---

Explain the ASP reasoning for: $ARGUMENTS

You have two tools available. Choose the right one (or both) based on what the user is asking:

## 1. UNSAT explanation (`scripts/why_unsat.py`)

Use when the user asks why a program is unsatisfiable, or when `ooanalyzer.py` returns UNSAT.

```sh
python scripts/why_unsat.py <file.lp> [file2.lp ...] [-n NUM_MUS]
```

- Finds Minimal Unsatisfiable Subsets (MUS) — the smallest sets of facts that cause UNSAT.
- Identifies which constraints are violated.
- `-n 0` finds all MUS; `-n 3` finds up to 3 (default: 1).

## 2. Trace-based explanation (`xclingo2`)

Use when the user asks why a specific atom is (or isn't) in the answer set, or wants to understand how something was derived.

xclingo2 produces explanation trees from `#!trace_rule`, `#!trace`, and `#!show_trace` annotations in the ASP source. If the program lacks annotations, suggest adding them:

- `#!trace_rule {"text", args}` before a rule labels the head atom's derivation.
- `#!trace {"text", args} atom.` labels a set of atoms (conditional fact).
- `#!show_trace atom.` selects which atoms to explain.

```sh
cd xclingo2 && python -m xclingo -n 0 1 --only-last [--show-trace ATOM] [--auto-tracing {none,facts,all}] ../ooanalyzer.lp <facts.lp> --opt-mode=optN
```

- `-n 0 1` enumerates all optimal models, explaining the last (optimal) one per `--only-last`.
- `--opt-mode=optN` is a pass-through clingo flag — required for OOAnalyzer to find the correct (optimal) answer set.
- `--show-trace ATOM` trace a specific atom without modifying the source (repeatable). E.g. `--show-trace "constructor(4266080)."`.
- `--auto-tracing facts` auto-traces all facts; `--auto-tracing all` auto-traces everything.
- `--only-last` only explain the last/optimal answer set.
- The `&sameClass` propagator is registered automatically when `&sameClass` appears in the program.

## Workflow

1. Determine if the question is about UNSAT or about a specific atom's truth.
2. For UNSAT: run `scripts/why_unsat.py` and report MUS + violated constraints.
3. For atom truth: run xclingo2 with `--show-trace ATOM` to trace a specific atom. Use `--auto-tracing facts` if the program lacks annotations. If explanations are still thin, suggest adding `#!trace_rule` annotations to key rules.
4. If both apply (e.g., "why can't this atom be true?"), combine both tools — xclingo2 for the positive derivation path and `scripts/why_unsat.py` for the conflict.