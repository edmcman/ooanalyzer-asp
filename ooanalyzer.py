#!/usr/bin/env python3
"""
ooanalyzer.py — OOAnalyzer ASP solver with &sameClass propagator.

Usage:
    python ooanalyzer.py examples/example.lp [clingo-flags]
    python ooanalyzer.py examples/ooa/ooex_vs2010/Lite/oo.lp --stats
"""

import argparse
import logging
import os
import sys
import time
import clingo

log = logging.getLogger("ooanalyzer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

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
    p.add_argument("-t", "--threads", type=str, default=None,
                   help="parallel search: N[,compete|split] (default: 1)")
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
    if args.threads is not None:
        ctl_args.extend(["-t", args.threads])
    for c in args.const:
        ctl_args.append(f"--const={c}")

    prop = SameClassPropagator()
    ctl = clingo.Control(ctl_args)
    if args.models is not None and args.models != -1:
        ctl.configuration.solve.models = args.models
    ctl.register_propagator(prop)

    ctl.load(_MAIN_LP)
    for f in args.files:
        ctl.load(f)

    run_start = time.perf_counter()
    ground_start = run_start
    log.info("Grounding...")
    ctl.ground([("base", [])])
    ground_time = time.perf_counter() - ground_start
    log.info("Grounding done (%.2fs)", ground_time)

    defer_print = args.models == -1
    last_shown = []
    last_cost = []
    model_num = 0
    had_cost = False
    first_model_time = None

    def on_model(model):
        nonlocal first_model_time, model_num, last_shown, last_cost, had_cost
        if first_model_time is None:
            first_model_time = time.perf_counter() - run_start
            log.info("Model found (%.2fs)", first_model_time)
        shown = list(model.symbols(shown=True))
        cost = list(model.cost)
        model_num += 1
        if cost:
            had_cost = True
        last_shown = shown
        last_cost = cost
        if not defer_print:
            print(f"\nAnswer: {model_num}")
            print(" ".join(str(a) for a in shown))
            if cost:
                print("Optimization:", " ".join(str(c) for c in cost))
            sys.stdout.flush()

    timed_out = False
    solve_start = time.perf_counter()
    log.info("Solving...")
    if args.time_limit:
        handle = ctl.solve(on_model=on_model, async_=True)
        if not handle.wait(args.time_limit):
            timed_out = True
            handle.cancel()
        result = handle.get()
    else:
        result = ctl.solve(on_model=on_model)
    solve_time = time.perf_counter() - solve_start

    if timed_out:
        print("% TIME LIMIT REACHED")
        log.info("Solving done: TIME LIMIT REACHED (%.2fs)", solve_time)
    elif result.unsatisfiable:
        print("UNSATISFIABLE")
        log.info("Solving done: UNSATISFIABLE (%.2fs)", solve_time)
    elif model_num == 0:
        print("UNKNOWN")
    elif result.exhausted:
        print("OPTIMUM FOUND" if had_cost else "SATISFIABLE")
        log.info("Solving done: %s (%.2fs)",
                 "OPTIMUM FOUND" if had_cost else "SATISFIABLE",
                 solve_time)
    elif result.satisfiable:
        print("SATISFIABLE")
        log.info("Solving done: SATISFIABLE (%.2fs)", solve_time)

    if defer_print and model_num > 0:
        print(f"\nAnswer: {model_num}")
        print(" ".join(str(a) for a in last_shown))
        if last_cost:
            print("Optimization:", " ".join(str(c) for c in last_cost))

    # Print partition for the last model printed above. The propagator's live
    # union-find may have been undone by solver backtracking after on_model.
    merge_pairs = []
    for atom in last_shown:
        if atom.name == "mergeClasses" and len(atom.arguments) == 2:
            merge_pairs.append(tuple(atom.arguments))
    parts = prop.partition(merge_pairs) if last_shown else {}
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
            ("time_to_first_model", None),
            ("solve_time", "summary.times.solve"),
        )
        for name, path in fields:
            if name == "ground_time":
                val = ground_time
            elif name == "time_to_first_model":
                val = first_model_time
            else:
                val = stat(path)
            if val is not None:
                print(f"%   {name}: {val}")


if __name__ == "__main__":
    main()
