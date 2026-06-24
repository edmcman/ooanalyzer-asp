#!/usr/bin/env python3
"""
ooanalyzer.py — OOAnalyzer ASP solver with &sameClass propagator.

Usage:
    python ooanalyzer.py examples/manual/example.lp [clingo-flags]
    python ooanalyzer.py examples/ooa/ooex_vs2010/Lite/oo.lp --stats
"""

import argparse
import logging
import os
import resource
import sys
import textwrap
import time
import clingo

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

log = logging.getLogger("ooanalyzer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

from propagator.sameclass import LazySameClassConsistencyPropagator, SameClassPropagator
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

# Each family: (label, [candidate_preds], [(selected_pred, denominator_pred)])
# denominator_pred=None falls back to sum of candidate_preds for the family.
_GUESS_FAMILIES = [
    ("method",
     ["guessMethodDomain"],
     [("guessMethodReward",          "guessMethodDomain")]),
    ("constructor",
     ["guessConstructor1Domain", "guessConstructor2Domain",
      "guessConstructor3Domain", "guessConstructor4Domain"],
     [("guessConstructor1Reward",    "guessConstructor1Domain"),
      ("guessConstructor2Reward",    "guessConstructor2Domain"),
      ("guessConstructor3Reward",    "guessConstructor3Domain"),
      ("guessConstructor4Reward",    "guessConstructor4Domain")]),

    ("merge",
     ["strongMergeCandidate", "weakMergeCandidate"],
     [("strongMergeReward",         "strongMergeCandidate"),
      ("weakMergeReward",           "weakMergeCandidate"),
      ("weakG1Bonus",               "weakMergeCandidate")]),
    ("composition",
     ["objectInObject"],
     [("guessDerivedClassReward",       "objectInObject"),
      ("purecallNotMostDerivedReward",   "objectInObject"),
      ("embeddedObject",                 "objectInObject")]),
]


def print_guess_summary(atoms):
    by_pred: dict[str, list] = {}
    for a in atoms:
        key = ("-" if a.negative else "") + a.name
        by_pred.setdefault(key, []).append(a)

    def args_of(a):
        return tuple(str(x) for x in a.arguments)

    def group(pred):
        return sorted(str(a) for a in by_pred.get(pred, []))

    def emit(header, items):
        print(header)
        if items:
            for line in textwrap.wrap(" ".join(items), width=80,
                                      initial_indent="%       ",
                                      subsequent_indent="%       "):
                print(line)

    print("\n% Selected guesses:")
    for label, cands, sels in _GUESS_FAMILIES:
        n_family = sum(len(group(p)) for p in cands)
        print(f"%   [{label}]")
        for pred, denom_pred in sels:
            g = group(pred)
            n_denom = len(group(denom_pred)) if denom_pred else n_family
            emit(f"%     {pred}: {len(g)}/{n_denom}", g)
            # Not-selected: denom items whose args don't appear in selected set.
            if denom_pred:
                sel_args = {args_of(a) for a in by_pred.get(pred, [])}
                not_sel = sorted(
                    str(a) for a in by_pred.get(denom_pred, [])
                    if args_of(a) not in sel_args
                )
                emit(f"%     ~{pred}: {len(not_sel)}/{n_denom}", not_sel)
    sys.stdout.flush()


def parse_args():
    p = argparse.ArgumentParser(description="OOAnalyzer with &sameClass propagator")
    p.add_argument("files", nargs="+", help=".lp fact/example files to load")
    p.add_argument("-n", "--models", type=int,
                   help="number of models (0 = all, default: clingo default)")
    p.add_argument("-d", "--diff-models", action="store_true",
                   help="print delta between consecutive answer sets (requires -n 0)")
    p.add_argument("--stats", nargs="?", const=1, default=0, type=int,
                   help="print clingo stats (optionally pass a clingo stats level)")
    p.add_argument("--results", nargs="?", const="", default=None, metavar="FILE",
                   help="write .results file; omit FILE to auto-derive from first input")
    p.add_argument("--quiet", type=str, default="1,2",
                   help="clingo --quiet level (default 1,2)")
    p.add_argument("--configuration", default=None,
                   help="clingo solver configuration preset")
    p.add_argument("--opt-strategy", default="bb,lin")
    p.add_argument("--heuristic", default="vsids")
    p.add_argument("--sign-def", default="neg",
                   help="clingo default sign heuristic (default: neg for conservative guesses)")
    p.add_argument("--time-limit", type=int, default=0, dest="time_limit")
    p.add_argument("--benchmark", action="store_true",
                   help="log model timing/costs and stats without collecting or printing model atoms")
    p.add_argument("--debug-propagator", action="store_true")
    p.add_argument("--profile-propagator", action="store_true",
                   help="print sameClass propagator setup/worklist timing counters")
    p.add_argument("-t", "--threads", type=str, default=None,
                   help="parallel search: N[,compete|split] (default: 1)")
    p.add_argument("--const", action="append", default=[], metavar="NAME=VAL",
                   help="pass --const to clingo (repeatable)")
    p.add_argument("--profile-conflicts", action="store_true",
                   help="register ConflictProfiler and print backtrack histogram after solving")
    p.add_argument("--profile-after-first-model", action="store_true",
                   help=("with conflict profiling, reset counters at the first model and "
                         "report per-model search windows"))
    p.add_argument("--profile-predicate", action="append", default=[],
                   help=("predicate to watch with --profile-conflicts; repeatable. "
                         "Defaults to core search predicates; use '*' to watch all atoms"))
    p.add_argument("--profile-max-atoms", type=int, default=10000,
                   help=("maximum number of symbolic atoms to watch with --profile-conflicts "
                         "(0 = no cap; default: 10000)"))
    p.add_argument("--profile-max-atoms-per-predicate", type=int, default=500,
                   help=("maximum watched atoms per predicate with --profile-conflicts "
                         "(0 = no per-predicate cap; default: 500)"))
    p.add_argument("--profile-interval", type=float, default=0,
                   help=("seconds between periodic conflict profile reports during solving "
                         "(0 = no periodic output; default: 0)"))
    p.add_argument("--foundedness-check", action="store_true",
                   help=("at each total assignment, verify that every true mergeClasses "
                         "atom has a non-circular justification; rejects circularly-founded "
                         "models that survive the potential-UF seeding fix"))
    p.add_argument("--sameclass-mode", choices=("propagate", "lazy-check"), default="propagate",
                   help=("sameClass theory handling mode: normal eager propagator, or a "
                         "simple check-time consistency mode for diagnostics"))
    p.add_argument("--diagnose-vftable-objective", action="store_true",
                   help=("print selected vftable sizes/gaps and largest unselected "
                         "vftable candidates for each model"))
    p.add_argument("--diagnose-vftable-limit", type=int, default=25,
                   help="maximum rows per vftable objective diagnostic section (default: 25)")
    p.add_argument("--show-guesses", action="store_true",
                   help="print guess candidates (by tier) and selected guesses from the final model")
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


def _symbol_is_positive(sym):
    return getattr(sym, "positive", True)


def _symbol_number(sym):
    if sym.type == clingo.SymbolType.Number:
        return sym.number
    return None


def _sort_symbol(value):
    number = _symbol_number(value)
    return (0, number) if number is not None else (1, str(value))


def _format_vftable_rows(rows, limit):
    limited = rows[:limit]
    return "\n".join(
        f"%   {v}: size={size} max={max_size} gap={gap}"
        for v, size, max_size, gap in limited
    )


def report_vftable_objective(model, limit):
    selected_vftables = set()
    selected_sizes = {}
    selected_max_sizes = {}
    selected_gaps = {}
    possible_max_sizes = {}

    for sym in model.symbols(atoms=True):
        if sym.type != clingo.SymbolType.Function or not _symbol_is_positive(sym):
            continue
        name = sym.name
        args = sym.arguments
        if name == "vfTable" and len(args) == 1:
            selected_vftables.add(args[0])
        elif name == "vfTableSize" and len(args) == 2:
            selected_sizes[args[0]] = args[1]
        elif name == "maxCandidateVFTableSize" and len(args) == 2:
            selected_max_sizes[args[0]] = args[1]
        elif name == "vfTableSizeGap" and len(args) == 2:
            selected_gaps[args[0]] = args[1]
        elif name == "possibleVFTableMaxSize" and len(args) == 2:
            possible_max_sizes[args[0]] = args[1]

    selected_rows = []
    total_size = 0
    total_max_size = 0
    total_gap = 0
    for vftable in selected_vftables:
        size = _symbol_number(selected_sizes.get(vftable, clingo.Number(0))) or 0
        max_size = _symbol_number(
            selected_max_sizes.get(vftable, possible_max_sizes.get(vftable, clingo.Number(0)))
        ) or 0
        gap = _symbol_number(selected_gaps.get(vftable, clingo.Number(0))) or 0
        total_size += size
        total_max_size += max_size
        total_gap += gap
        selected_rows.append((vftable, size, max_size, gap))
    selected_rows.sort(key=lambda row: (-row[3], -row[2], _sort_symbol(row[0])))

    unselected_rows = []
    unselected_total_max = 0
    for vftable, max_size_sym in possible_max_sizes.items():
        if vftable in selected_vftables:
            continue
        max_size = _symbol_number(max_size_sym) or 0
        unselected_total_max += max_size
        unselected_rows.append((vftable, max_size))
    unselected_rows.sort(key=lambda row: (-row[1], _sort_symbol(row[0])))

    print("\n% VFTable objective diagnostics")
    print(f"%   selected_vftables: {len(selected_rows)}")
    print(f"%   selected_size_total: {total_size}")
    print(f"%   selected_candidate_max_total: {total_max_size}")
    print(f"%   selected_size_gap_total: {total_gap}")
    print(f"%   unselected_possible_vftables: {len(unselected_rows)}")
    print(f"%   unselected_possible_max_total: {unselected_total_max}")
    if selected_rows:
        print(f"%   selected vftables with largest chosen-size gaps (top {limit}):")
        rendered = _format_vftable_rows(selected_rows, limit)
        if rendered:
            print(rendered)
    if unselected_rows:
        print(f"%   unselected possible vftables by candidate max size (top {limit}):")
        for vftable, max_size in unselected_rows[:limit]:
            print(f"%   {vftable}: possible_max={max_size}")
    sys.stdout.flush()


def main():
    args = parse_args()
    print(f"% Command: {' '.join(sys.argv)}")

    if args.debug_propagator:
        import propagator.sameclass as _sc
        _sc.DEBUG = True
    if args.profile_propagator:
        import propagator.sameclass as _sc
        _sc.PROFILE = True

    ctl_args = ["--warn=none"]
    if args.configuration:
        # A portfolio/configuration controls per-thread search settings; the
        # command line would otherwise override them (clasp prefers CLI options
        # over config-file options), collapsing the portfolio to one config.
        ctl_args.append(f"--configuration={args.configuration}")
    else:
        ctl_args.extend([
            f"--opt-strategy={args.opt_strategy}",
            f"--heuristic={args.heuristic}",
            f"--sign-def={args.sign_def}",
        ])
    if args.stats:
        ctl_args.append(f"--stats={args.stats}")
    if args.threads is not None:
        ctl_args.extend(["-t", args.threads])
    for c in args.const:
        ctl_args.append(f"--const={c}")
    ctl_args.extend(args.clingo_extra)

    if args.sameclass_mode == "lazy-check":
        if args.foundedness_check:
            log.info("--foundedness-check is ignored by --sameclass-mode=lazy-check")
        prop = LazySameClassConsistencyPropagator()
    else:
        prop = SameClassPropagator(
            foundedness_check=args.foundedness_check,
        )
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
            interval=args.profile_interval,
        )
        if (args.profile_conflicts or args.profile_after_first_model) else None
    )
    ctl = clingo.Control(ctl_args)
    if args.models is not None and args.models != -1:
        ctl.configuration.solve.models = args.models
    if args.sameclass_mode == "propagate":
        ctl.register_observer(prop)
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
    last_all_atoms = []
    last_cost = []
    model_num = 0
    had_cost = False
    first_model_time = None
    last_model_time = None

    if args.diff_models and args.models != 0:
        log.info("--diff-models requires -n 0 to take effect; ignoring")

    def on_model(model):
        nonlocal first_model_time, last_model_time, model_num, last_shown, last_all_atoms, last_cost, had_cost
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
            if args.results is not None or args.show_guesses:
                last_all_atoms = list(model.symbols(atoms=True))
        last_cost = cost
        if args.diagnose_vftable_objective:
            report_vftable_objective(model, args.diagnose_vftable_limit)
        if profiler and args.profile_after_first_model:
            if model_num == 1:
                profiler.reset_counts("since model 1")
            else:
                profiler.report(title=f"Conflict Profile since model {model_num - 1}")
                profiler.reset_counts(f"since model {model_num}")

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
        remaining = args.time_limit - ground_time
        handle = ctl.solve(on_model=on_model, on_unsat=on_unsat, async_=True)
        if not handle.wait(max(remaining, 0)):
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
        sys.stdout.flush()

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
        if args.profile_after_first_model and model_num > 0:
            profiler.report(title=f"Conflict Profile since model {model_num}")
        else:
            profiler.report()

    # Print partition for the last model printed above. The propagator's live
    # union-find may have been undone by solver backtracking after on_model.
    if not args.benchmark:
        merge_pairs = []
        for atom in last_shown:
            if (
                atom.name == "mergeClasses"
                and len(atom.arguments) == 2
                and getattr(atom, "positive", True)
            ):
                merge_pairs.append(tuple(atom.arguments))
        parts = prop.partition(merge_pairs) if last_shown else {}
        if parts:
            print(f"\n% Equivalence classes ({len(parts)} classes, "
                  f"{sum(len(g) for g in parts.values())} entities):")
            for rep, members in sorted(parts.items(), key=lambda kv: min(kv[1])):
                print(f"%   {{{', '.join(str(m) for m in sorted(members))}}}")

        if args.show_guesses and last_all_atoms:
            print_guess_summary(last_all_atoms)

        if args.results is not None and last_all_atoms:
            from results import write_results
            if args.results == "":
                base = os.path.splitext(args.files[0])[0]
                results_path = base + ".results"
            else:
                results_path = args.results
            sys.stdout.flush()
            log.info("Writing results to %s", results_path)
            write_results(ctl, last_all_atoms, merge_pairs, results_path)

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
