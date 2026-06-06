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
import resource
import sys
import time
import clingo

log = logging.getLogger("ooanalyzer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

from propagator.sameclass import SameClassPropagator
from propagator.conflict_profiler import ConflictProfiler

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_MAIN_LP = os.path.join(_SCRIPT_DIR, "ooanalyzer.lp")
_DEFAULT_PROFILE_PREDS = (
    "guessEnabled",
    "method",
    "constructor",
    "realDestructor",
    "deletingDestructor",
    "constructorDestructorKind",
    "vfTable",
    "vfTableSize",
    "vfTableEntry",
    "mergeClasses",
    "mergeCandidate",
    "strongMergeCandidate",
    "strongMergeReward",
    "weakMergeCandidate",
    "weakMergeReward",
    "weakG1Bonus",
    "notMergeUnsorted",
    "derivedClass",
    "embeddedObject",
    "objectInObject",
    "classRelationship",
    "knownVirtualMethod",
)


def parse_args():
    p = argparse.ArgumentParser(description="OOAnalyzer with &sameClass propagator")
    p.add_argument("files", nargs="+", help=".lp fact/example files to load")
    p.add_argument("-n", "--models", type=int,
                   help="number of models (0 = all, default: clingo default)")
    p.add_argument("-d", "--diff-models", action="store_true",
                   help="print delta between consecutive answer sets (requires -n 0)")
    p.add_argument("--stats", nargs="?", const=1, default=0, type=int,
                   help="print clingo stats (optionally pass a clingo stats level)")
    p.add_argument("--quiet", type=str, default="1,2",
                   help="clingo --quiet level (default 1,2)")
    p.add_argument("--opt-strategy", default="bb,lin")
    p.add_argument("--heuristic", default="vsids")
    p.add_argument("--sign-def", default="neg",
                   help="clingo default sign heuristic (default: neg for conservative guesses)")
    p.add_argument("--time-limit", type=int, default=0, dest="time_limit")
    p.add_argument("--benchmark", action="store_true",
                   help="log model timing/costs and stats without collecting or printing model atoms")
    p.add_argument("--debug-propagator", action="store_true")
    p.add_argument("-t", "--threads", type=str, default=None,
                   help="parallel search: N[,compete|split] (default: 1)")
    p.add_argument("--const", action="append", default=[], metavar="NAME=VAL",
                   help="pass --const to clingo (repeatable)")
    p.add_argument("--profile-conflicts", action="store_true",
                   help="register ConflictProfiler and print backtrack histogram after solving")
    p.add_argument("--profile-predicate", action="append", default=[],
                   help=("predicate to watch with --profile-conflicts; repeatable. "
                         "Defaults to core search predicates; use '*' to watch all atoms"))
    p.add_argument("--profile-max-atoms", type=int, default=10000,
                   help=("maximum number of symbolic atoms to watch with --profile-conflicts "
                         "(0 = no cap; default: 10000)"))
    p.add_argument("--profile-max-atoms-per-predicate", type=int, default=500,
                   help=("maximum watched atoms per predicate with --profile-conflicts "
                         "(0 = no per-predicate cap; default: 500)"))
    args, extra = p.parse_known_args()
    args.clingo_extra = extra
    return args


def format_model_diff(prev_shown, cur_shown, prev_cost, cur_cost):
    prev_s = set(str(a) for a in prev_shown)
    cur_s = set(str(a) for a in cur_shown)
    added = sorted(cur_s - prev_s)
    removed = sorted(prev_s - cur_s)
    if not added and not removed and list(prev_cost) == list(cur_cost):
        return ""
    lines = ["Δ vs. previous:"]
    for a in added:
        lines.append(f"+ {a}")
    for a in removed:
        lines.append(f"- {a}")
    if prev_cost and cur_cost and prev_cost != cur_cost:
        delta = [c2 - c1 for c1, c2 in zip(prev_cost, cur_cost)]
        prev_str = "[" + ",".join(str(c) for c in prev_cost) + "]"
        cur_str = "[" + ",".join(str(c) for c in cur_cost) + "]"
        d_str = "[" + ",".join(f"{'+' if d >= 0 else ''}{d}" for d in delta) + "]"
        lines.append(f"cost: {prev_str} -> {cur_str}  (Δ {d_str})")
    return "\n".join(lines)


def format_cost_values(values):
    formatted = []
    for value in values:
        if isinstance(value, float) and value.is_integer():
            formatted.append(str(int(value)))
        else:
            formatted.append(str(value))
    return " ".join(formatted)


def main():
    args = parse_args()
    print(f"% Command: {' '.join(sys.argv)}")

    if args.debug_propagator:
        import propagator.sameclass as _sc
        _sc.DEBUG = True

    ctl_args = [
        "--warn=none",
        f"--opt-strategy={args.opt_strategy}",
        f"--heuristic={args.heuristic}",
        f"--sign-def={args.sign_def}",
    ]
    if args.stats:
        ctl_args.append(f"--stats={args.stats}")
    if args.threads is not None:
        ctl_args.extend(["-t", args.threads])
    for c in args.const:
        ctl_args.append(f"--const={c}")
    ctl_args.extend(args.clingo_extra)

    prop = SameClassPropagator()
    profile_preds = args.profile_predicate or list(_DEFAULT_PROFILE_PREDS)
    if "*" in profile_preds:
        profile_preds = None
    profile_max_atoms = None if args.profile_max_atoms == 0 else args.profile_max_atoms
    profile_max_atoms_per_predicate = (
        None if args.profile_max_atoms_per_predicate == 0
        else args.profile_max_atoms_per_predicate
    )
    profiler = (
        ConflictProfiler(
            profile_preds,
            max_atoms=profile_max_atoms,
            max_atoms_per_predicate=profile_max_atoms_per_predicate,
        )
        if args.profile_conflicts else None
    )
    ctl = clingo.Control(ctl_args)
    if args.models is not None and args.models != -1:
        ctl.configuration.solve.models = args.models
    ctl.register_propagator(prop)
    if profiler:
        ctl.register_propagator(profiler)

    ctl.load(_MAIN_LP)
    for f in args.files:
        ctl.load(f)

    run_start = time.perf_counter()
    ground_start = run_start
    log.info("Grounding...")
    ctl.ground([("base", [])])
    ground_time = time.perf_counter() - ground_start
    log.info("Grounding done (%.2fs)", ground_time)

    defer_print = args.models == -1 or args.benchmark
    last_shown = []
    last_cost = []
    model_num = 0
    had_cost = False
    first_model_time = None
    last_model_time = None

    if args.diff_models and args.models != 0:
        log.info("--diff-models requires -n 0 to take effect; ignoring")

    def on_model(model):
        nonlocal first_model_time, last_model_time, model_num, last_shown, last_cost, had_cost
        now = time.perf_counter() - run_start
        shown = [] if args.benchmark else list(model.symbols(shown=True))
        cost = list(model.cost)
        cost_str = cost if cost else "0"
        if first_model_time is None:
            first_model_time = now
            log.info("Model found (%.2fs): %s", now, cost_str)
        else:
            log.info("Model found (%.2fs, +%.2fs): %s", now, now - last_model_time, cost_str)
        last_model_time = now
        model_num += 1
        if cost:
            had_cost = True
        if not defer_print:
            diff = format_model_diff(last_shown, shown, last_cost, cost) if args.diff_models and model_num > 1 else ""
            if diff:
                print(f"\nΔ Answer: {model_num}")
                print(diff)
            else:
                print(f"\nAnswer: {model_num}")
                print(" ".join(str(a) for a in shown))
                if cost:
                    print("Optimization:", format_cost_values(cost))
            sys.stdout.flush()
        if not args.benchmark:
            last_shown = shown
        last_cost = cost

    def on_unsat(lower):
        now = time.perf_counter() - run_start
        if last_cost:
            gap = [u - l for u, l in zip(last_cost, lower)]
            log.info("Lower bound: %s  upper: %s  gap: %s (%.2fs)", list(lower), last_cost, gap, now)
        else:
            log.info("Lower bound: %s (%.2fs)", list(lower), now)

    timed_out = False
    solve_start = time.perf_counter()
    log.info("Solving...")
    if args.time_limit:
        handle = ctl.solve(on_model=on_model, on_unsat=on_unsat, async_=True)
        if not handle.wait(args.time_limit):
            timed_out = True
            handle.cancel()
        result = handle.get()
    else:
        result = ctl.solve(on_model=on_model, on_unsat=on_unsat)
    solve_time = time.perf_counter() - solve_start

    def stat(path):
        cur = ctl.statistics
        for key in path.split("."):
            if not isinstance(cur, dict) or key not in cur:
                return None
            cur = cur[key]
        return cur

    final_lower_bound = stat("summary.lower")

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

    if defer_print and model_num > 0 and not args.benchmark:
        print(f"\nAnswer: {model_num}")
        print(" ".join(str(a) for a in last_shown))
        if last_cost:
            print("Optimization:", format_cost_values(last_cost))
            if final_lower_bound and not result.exhausted:
                print("Lower bound:", format_cost_values(final_lower_bound))

    if (
        not defer_print
        and model_num > 0
        and last_cost
        and final_lower_bound
        and not result.exhausted
        and not args.benchmark
    ):
        print("Lower bound:", format_cost_values(final_lower_bound))

    if profiler:
        profiler.report()

    # Print partition for the last model printed above. The propagator's live
    # union-find may have been undone by solver backtracking after on_model.
    if not args.benchmark:
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
            ("final_cost", "summary.costs"),
            ("lower_bound", "summary.lower"),
            ("total_time", "summary.times.total"),
            ("ground_time", None),
            ("time_to_first_model", None),
            ("max_rss_bytes", None),
            ("solve_time", "summary.times.solve"),
        )
        for name, path in fields:
            if name == "ground_time":
                val = ground_time
            elif name == "time_to_first_model":
                val = first_model_time
            elif name == "max_rss_bytes":
                max_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                val = max_rss if sys.platform == "darwin" else max_rss * 1024
            else:
                val = stat(path)
            if val is not None:
                print(f"%   {name}: {val}")

        if args.stats >= 2:
            print("\n% Full clingo statistics:")
            def dump(node, indent=2):
                if isinstance(node, dict):
                    for k, v in node.items():
                        if isinstance(v, (dict, list)):
                            print(f"%{' ' * indent}{k}:")
                            dump(v, indent + 2)
                        else:
                            print(f"%{' ' * indent}{k}: {v}")
                elif isinstance(node, list):
                    for i, v in enumerate(node):
                        if isinstance(v, (dict, list)):
                            print(f"%{' ' * indent}[{i}]:")
                            dump(v, indent + 2)
                        else:
                            print(f"%{' ' * indent}[{i}]: {v}")
            dump(ctl.statistics)


if __name__ == "__main__":
    main()
