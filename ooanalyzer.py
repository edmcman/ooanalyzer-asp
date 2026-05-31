#!/usr/bin/env python3
"""
ooanalyzer.py — OOAnalyzer ASP solver with &sameClass propagator.

Usage:
    python ooanalyzer.py examples/example.lp [clingo-flags]
    python ooanalyzer.py examples/ooa/ooex_vs2010/Lite/oo.lp --stats
"""

import argparse
import os
import sys
import time
import clingo
from propagator.sameclass import SameClassPropagator

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_MAIN_LP = os.path.join(_SCRIPT_DIR, "ooanalyzer.lp")


def parse_args():
    p = argparse.ArgumentParser(description="OOAnalyzer with &sameClass propagator")
    p.add_argument("files", nargs="+", help=".lp fact/example files to load")
    p.add_argument("-n", "--models", type=int,
                   help="number of models (0 = all, default: clingo default)")
    p.add_argument("--stats", nargs="?", const=1, default=0, type=int,
                   help="print clingo stats (optionally pass a clingo stats level)")
    p.add_argument("--quiet", type=str, default="1,2",
                   help="clingo --quiet level (default 1,2)")
    p.add_argument("--opt-strategy", default="bb,inc")
    p.add_argument("--heuristic", default="domain")
    p.add_argument("--time-limit", type=int, default=0, dest="time_limit")
    p.add_argument("--debug-propagator", action="store_true")
    p.add_argument("--const", action="append", default=[], metavar="NAME=VAL",
                   help="pass --const to clingo (repeatable)")
    return p.parse_args()


def main():
    args = parse_args()

    if args.debug_propagator:
        import propagator.sameclass as _sc
        _sc.DEBUG = True

    ctl_args = [
        "--warn=none",
        f"--opt-strategy={args.opt_strategy}",
        f"--heuristic={args.heuristic}",
    ]
    if args.stats:
        ctl_args.append(f"--stats={args.stats}")
    for c in args.const:
        ctl_args.append(f"--const={c}")

    prop = SameClassPropagator()
    ctl = clingo.Control(ctl_args)
    if args.models is not None:
        ctl.configuration.solve.models = args.models
    ctl.register_propagator(prop)

    ctl.load(_MAIN_LP)
    for f in args.files:
        ctl.load(f)

    ground_start = time.perf_counter()
    ctl.ground([("base", [])])
    ground_time = time.perf_counter() - ground_start

    keep_all_models = args.models == 0 or (args.models is not None and args.models > 1)
    found = []

    def on_model(model):
        shown = list(model.symbols(shown=True))
        cost = list(model.cost)
        if keep_all_models:
            found.append((shown, cost))
        else:
            found[:] = [(shown, cost)]

    timed_out = False
    if args.time_limit:
        handle = ctl.solve(on_model=on_model, async_=True)
        if not handle.wait(args.time_limit):
            timed_out = True
            handle.cancel()
        result = handle.get()
    else:
        result = ctl.solve(on_model=on_model)

    if result.unsatisfiable:
        print("UNSATISFIABLE")
    elif not found:
        print("UNKNOWN")
    else:
        for i, (atoms, cost) in enumerate(found):
            print(f"\nAnswer: {i+1}")
            print(" ".join(str(a) for a in atoms))
            if cost:
                print("Optimization:", " ".join(str(c) for c in cost))
        if result.exhausted:
            print("OPTIMUM FOUND" if any(found[-1][1]) else "SATISFIABLE")
        elif result.satisfiable:
            print("SATISFIABLE")
    if timed_out:
        print("% TIME LIMIT REACHED")

    # Print partition
    parts = prop.partition()
    if parts:
        print(f"\n% Equivalence classes ({len(parts)} classes, "
              f"{sum(len(g) for g in parts.values())} entities):")
        for rep, members in sorted(parts.items(), key=lambda kv: min(kv[1])):
            print(f"%   {{{', '.join(str(m) for m in sorted(members))}}}")

    if args.stats:
        def stat(path):
            cur = ctl.statistics
            for key in path.split("."):
                if not isinstance(cur, dict) or key not in cur:
                    return None
                cur = cur[key]
            return cur

        print("\n% Stats:")
        fields = (
            ("atoms", "problem.lp.atoms"),
            ("bodies", "problem.lp.bodies"),
            ("rules", "problem.lp.rules"),
            ("variables", "problem.generator.vars"),
            ("constraints", "problem.generator.constraints"),
            ("choices", "solving.solvers.choices"),
            ("conflicts", "solving.solvers.conflicts"),
            ("models", "summary.models.enumerated"),
            ("optimal_models", "summary.models.optimal"),
            ("total_time", "summary.times.total"),
            ("ground_time", None),
            ("solve_time", "summary.times.solve"),
        )
        for name, path in fields:
            val = ground_time if path is None else stat(path)
            if val is not None:
                print(f"%   {name}: {val}")


if __name__ == "__main__":
    main()
