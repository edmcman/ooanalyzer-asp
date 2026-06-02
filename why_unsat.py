#!/usr/bin/env python3
"""Explain why an ASP program is unsatisfiable using clingexplaid.

Usage:
    why_unsat.py program.lp [program2.lp ...]

Finds Minimal Unsatisfiable Subsets (MUS) of facts that make the program
UNSAT. Also identifies which constraints are violated.

Requires: clingexplaid (https://github.com/potassco/clingo-explaid)
"""

import sys
from pathlib import Path
from clingo import Control
from clingexplaid.preprocessors import AssumptionPreprocessor
from clingexplaid.mus import CoreComputer
from clingexplaid.unsat_constraints import UnsatConstraintComputer
from propagator.sameclass import SameClassPropagator


def read_program(files):
    parts = []
    for f in files:
        parts.append(Path(f).read_text())
    return "\n".join(parts)


def explain_unsat(program, max_mus=1):
    """Find MUS and unsat constraints for an ASP program."""

    # Unsat constraint identification first — fast, and often points directly
    # at the offending integrity constraint.
    any_finding = False
    print("Violated constraints:")
    print("=" * 40)
    try:
        ucc = UnsatConstraintComputer()
        ucc.parse_string(program)
        constraints = ucc.get_unsat_constraints()
        if constraints:
            any_finding = True
            for cid, body in sorted(constraints.items()):
                body = body.lstrip(": ").lstrip(":-").lstrip()
                print(f"  Constraint {cid}: :- {body}")
                loc = ucc.get_constraint_location(cid)
                if loc:
                    print(f"    at {loc.begin.filename}:{loc.begin.line}")
        else:
            print("  (none found)")
    except Exception as e:
        print(f"  Error identifying constraints: {e}")

    # MUS extraction via AssumptionPreprocessor
    ap = AssumptionPreprocessor()
    try:
        transformed = ap.process(program)
    except Exception as e:
        print(f"Error transforming program: {e}")
        return None

    ctl2 = Control(["0"])
    ctl2.register_propagator(SameClassPropagator())
    ctl2.add("base", [], transformed)
    ctl2.ground([("base", [])])

    # Drop assumptions whose symbol didn't survive grounding (e.g. facts whose
    # arguments are #const placeholders like `maxOffsetDepth(max_offset_depth)`
    # — the grounder substitutes the constant, so the original Symbol has no
    # matching atom and clingexplaid's symbol_lookup raises KeyError).
    grounded_symbols = {a.symbol for a in ctl2.symbolic_atoms}
    assumptions = {(sym, sign) for (sym, sign) in ap.assumptions
                   if sym in grounded_symbols}

    cc = CoreComputer(ctl2, assumptions)

    print()
    print("Minimal Unsatisfiable Subsets (MUS):")
    print("=" * 40)
    found = False
    try:
        for i, mus in enumerate(cc.get_multiple_minimal(max_mus=max_mus)):
            mus_strs = cc.mus_to_string(mus)
            print(f"  MUS {i+1}: {', '.join(sorted(mus_strs))}")
            found = True
            any_finding = True
    except Exception as e:
        print(f"  Error computing MUS: {e}")

    if not found:
        print("  (none found)")

    if not any_finding:
        print()
        print("No UNSAT findings — program may be SATISFIABLE,")
        print("or UNSAT may depend on a propagator the analyzers do not see.")


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='+', help='ASP program files')
    parser.add_argument('-n', '--num-mus', type=int, default=1, help='Number of MUS to find (default: 1, use 0 for all)')
    args = parser.parse_args()

    program = read_program(args.files)
    max_mus = None if args.num_mus == 0 else args.num_mus
    explain_unsat(program, max_mus=max_mus)


if __name__ == "__main__":
    main()