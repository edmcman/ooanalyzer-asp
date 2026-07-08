#!/usr/bin/env python3
"""
ooanalyzer.py — OOAnalyzer ASP solver with &sameClass propagator.

Usage:
    python ooanalyzer.py examples/manual/example.lp [clingo-flags]
    python ooanalyzer.py examples/ooa/ooex_vs2010/Lite/oo.lp --stats
"""

import logging
import os
import sys
import textwrap
import time
import clingo

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

log = logging.getLogger("ooanalyzer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

# The native Rust propagator (built via `make rust`) is the live &sameClass
# implementation; there is no pure-Python fallback.
from ooanalyzer_sameclass import SameClassPropagator
from propagator.sameclass import LazySameClassConsistencyPropagator
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
    "lateF2Candidate",
    "lateF2Reward",
    "weakG1Bonus",
    "notMergeUnsorted",
    "derivedClass",
    "embeddedObject",
    "objectInObject",
    "knownVirtualMethod",
)

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
     ["strongMergeCandidate", "weakMergeCandidate", "lateF2Candidate"],
     [("strongMergeReward",         "strongMergeCandidate"),
      ("weakMergeReward",           "weakMergeCandidate"),
      ("lateF2Reward",              "lateF2Candidate"),
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
            if denom_pred:
                sel_args = {args_of(a) for a in by_pred.get(pred, [])}
                not_sel = sorted(
                    str(a) for a in by_pred.get(denom_pred, [])
                    if args_of(a) not in sel_args
                )
                emit(f"%     ~{pred}: {len(not_sel)}/{n_denom}", not_sel)
    sys.stdout.flush()


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


class OOAnalyzerApp(clingo.Application):
    program_name = "ooanalyzer"
    version = "2.0"

    def __init__(self):
        self.diff_models = clingo.Flag(False)
        self.results = None
        self.benchmark = clingo.Flag(False)
        self.profile_conflicts = clingo.Flag(False)
        self.profile_after_first_model = clingo.Flag(False)
        self.profile_predicate = []
        self.profile_max_atoms = 10000
        self.profile_max_atoms_per_predicate = 500
        self.profile_interval = 0.0
        self.profile_after = 0.0
        self.profile_window = 0.0
        self.profile_period = 0.0
        self.trace_backjumps = 0
        self.trace_backjump_limit = 10
        self.foundedness_check = clingo.Flag(False)
        self.dump_lemmas = clingo.Flag(False)
        self.decide_outputs = clingo.Flag(False)
        self.decide_inputs = clingo.Flag(False)
        self.sameclass_mode = "propagate"
        self.diagnose_vftable_objective = clingo.Flag(False)
        self.diagnose_vftable_limit = 25
        self.show_guesses = clingo.Flag(False)

    def register_options(self, options):
        def str_parser(setter):
            def f(x):
                setter(x)
                return True
            return f

        def int_parser(setter):
            def f(x):
                try:
                    setter(int(x) if x else 0)
                    return True
                except ValueError:
                    return False
            return f

        def float_parser(setter):
            def f(x):
                try:
                    setter(float(x) if x else 0.0)
                    return True
                except ValueError:
                    return False
            return f

        options.add_flag("OOAnalyzer", "diff-models", "print delta between consecutive answer sets (requires -n 0)",
                         self.diff_models)
        options.add("OOAnalyzer", "results", "write .results file; omit VALUE to auto-derive from first input",
                    str_parser(lambda x: setattr(self, 'results', x if x else "")), argument="VALUE")
        options.add_flag("OOAnalyzer", "benchmark", "log model timing/costs without collecting atoms",
                         self.benchmark)
        options.add_flag("OOAnalyzer", "profile-conflicts", "register ConflictProfiler and print backtrack histogram",
                         self.profile_conflicts)
        options.add_flag("OOAnalyzer", "profile-after-first-model", "start profiling and tracing after the first model",
                         self.profile_after_first_model)
        options.add("OOAnalyzer", "profile-after", "start profiling and tracing after SEC of solving",
                    float_parser(lambda x: setattr(self, 'profile_after', x)), argument="SEC")
        options.add("OOAnalyzer", "profile-predicate", "predicate to watch with --profile-conflicts (repeatable)",
                    str_parser(lambda x: self.profile_predicate.append(x)), multi=True, argument="NAME")
        options.add("OOAnalyzer", "profile-max-atoms", "max symbolic atoms to watch (0 = no cap)",
                    int_parser(lambda x: setattr(self, 'profile_max_atoms', x)), argument="N")
        options.add("OOAnalyzer", "profile-max-atoms-per-predicate", "max watched atoms per predicate (0 = no cap)",
                    int_parser(lambda x: setattr(self, 'profile_max_atoms_per_predicate', x)), argument="N")
        options.add("OOAnalyzer", "profile-interval", "seconds between periodic conflict profile reports",
                    float_parser(lambda x: setattr(self, 'profile_interval', x)), argument="SEC")
        options.add("OOAnalyzer", "profile-window", "duty-cycle: profile for SEC out of each --profile-period, removing watches in between",
                    float_parser(lambda x: setattr(self, 'profile_window', x)), argument="SEC")
        options.add("OOAnalyzer", "profile-period", "duty-cycle: full cycle length in seconds (must exceed --profile-window)",
                    float_parser(lambda x: setattr(self, 'profile_period', x)), argument="SEC")
        options.add("OOAnalyzer", "trace-backjumps", "trace decisions for backjumps of at least N levels (0 disables)",
                    int_parser(lambda x: setattr(self, 'trace_backjumps', x)), argument="N")
        options.add("OOAnalyzer", "trace-backjump-limit", "maximum number of large backjumps to print",
                    int_parser(lambda x: setattr(self, 'trace_backjump_limit', x)), argument="N")
        options.add_flag("OOAnalyzer", "foundedness-check", "verify mergeClasses atoms have non-circular justification",
                         self.foundedness_check)
        options.add_flag("OOAnalyzer", "dump-lemmas", "print each &sameClass reason clause to stderr (propagate mode only)",
                         self.dump_lemmas)
        options.add_flag("OOAnalyzer", "decide-outputs", "branch on &sameClass outputs instead of mergeClasses inputs (propagate mode only)",
                         self.decide_outputs)
        options.add_flag("OOAnalyzer", "decide-inputs", "branch on mergeClasses inputs instead of &sameClass outputs (propagate mode only)",
                         self.decide_inputs)
        options.add("OOAnalyzer", "sameclass-mode", "sameClass theory handling: propagate or lazy-check",
                    str_parser(lambda x: setattr(self, 'sameclass_mode', x)), argument="MODE")
        options.add_flag("OOAnalyzer", "diagnose-vftable-objective", "print vftable size/gap diagnostics per model",
                         self.diagnose_vftable_objective)
        options.add("OOAnalyzer", "diagnose-vftable-limit", "max rows per vftable diagnostic section",
                    int_parser(lambda x: setattr(self, 'diagnose_vftable_limit', x)), argument="N")
        options.add_flag("OOAnalyzer", "show-guesses", "print guess candidates and selected guesses from final model",
                         self.show_guesses)

    def validate_options(self):
        if self.sameclass_mode not in ("propagate", "lazy-check"):
            print(f"error: invalid --sameclass-mode: {self.sameclass_mode}", file=sys.stderr)
            return False
        if bool(self.decide_outputs) and bool(self.decide_inputs):
            print("error: --decide-outputs and --decide-inputs are mutually exclusive", file=sys.stderr)
            return False
        return True

    def print_model(self, model, printer):
        # In defer mode (-n -1), suppress ALL clingo's native model printing
        # since we handle output via on_model callback
        if hasattr(self, '_defer_output_mode') and self._defer_output_mode:
            pass  # Suppress output entirely in defer mode
        else:
            # Otherwise use clingo's default printing
            printer()

    def main(self, ctl, files):
        print(f"% Command: {' '.join(sys.argv)}")

        if not files:
            self.logger(clingo.MessageCode.RuntimeError, "no files provided")
            return

        # Detect -n -1 in command line (clingo won't accept -1 natively)
        defer_output_mode = False
        for i in range(len(sys.argv) - 1):
            if sys.argv[i] == '-n' and sys.argv[i + 1] == '-1':
                defer_output_mode = True
                self._defer_output_mode = True
                # Set clingo to enumerate all models
                ctl.configuration.solve.models = 0
                break

        diff_models = bool(self.diff_models)
        benchmark = bool(self.benchmark)
        profile_conflicts = bool(self.profile_conflicts)
        profile_after_first_model = bool(self.profile_after_first_model)
        foundedness_check = bool(self.foundedness_check)
        dump_lemmas = bool(self.dump_lemmas)
        decide_outputs = bool(self.decide_outputs)
        decide_inputs = bool(self.decide_inputs)
        diagnose_vftable_objective = bool(self.diagnose_vftable_objective)
        show_guesses = bool(self.show_guesses)

        if self.sameclass_mode == "lazy-check":
            if foundedness_check:
                log.info("--foundedness-check is ignored by --sameclass-mode=lazy-check")
            if dump_lemmas:
                log.info("--dump-lemmas is ignored by --sameclass-mode=lazy-check")
            if decide_outputs:
                log.info("--decide-outputs is ignored by --sameclass-mode=lazy-check")
            if decide_inputs:
                log.info("--decide-inputs is ignored by --sameclass-mode=lazy-check")
            prop = LazySameClassConsistencyPropagator()
        else:
            prop = SameClassPropagator(
                foundedness_check=foundedness_check,
                dump_lemmas=dump_lemmas,
                decide_outputs=decide_outputs,
                decide_inputs=decide_inputs,
            )

        profile_preds = self.profile_predicate or list(_DEFAULT_PROFILE_PREDS)
        if "*" in profile_preds:
            profile_preds = None
        profile_max_atoms = None if self.profile_max_atoms == 0 else self.profile_max_atoms
        profile_max_atoms_per_predicate = (
            None if self.profile_max_atoms_per_predicate == 0
            else self.profile_max_atoms_per_predicate
        )
        profiler = (
            ConflictProfiler(
                profile_preds,
                max_atoms=profile_max_atoms,
                max_atoms_per_predicate=profile_max_atoms_per_predicate,
                interval=self.profile_interval,
                trace_backjumps=self.trace_backjumps,
                trace_backjump_limit=self.trace_backjump_limit,
                profile_after=self.profile_after,
                after_first_model=profile_after_first_model,
                count_conflicts=profile_conflicts,
                profile_window=self.profile_window,
                profile_period=self.profile_period,
            )
            if (profile_conflicts or self.trace_backjumps) else None
        )

        if self.sameclass_mode == "lazy-check":
            ctl.register_propagator(prop)
        else:
            prop.register(ctl, foundedness_check=foundedness_check, dump_lemmas=dump_lemmas,
                          decide_outputs=decide_outputs, decide_inputs=decide_inputs)

        # Profiling goes after semantic propagators so its first-total-assignment
        # check cannot activate before Rust accepts the first model.
        if profiler:
            ctl.register_propagator(profiler.callbacks())

        ctl.load(_MAIN_LP)
        for f in files:
            ctl.load(f)

        run_start = time.perf_counter()
        ground_start = run_start
        log.info("Grounding...")
        ctl.ground([("base", [])])
        ground_time = time.perf_counter() - ground_start
        log.info("Grounding done (%.2fs)", ground_time)

        defer_print = defer_output_mode or ctl.configuration.solve.models == -1 or benchmark
        last_shown = []
        last_all_atoms = []
        last_cost = []
        model_num = 0
        had_cost = False
        first_model_time = None
        last_model_time = None

        if diff_models and ctl.configuration.solve.models != 0:
            log.info("--diff-models requires -n 0 to take effect; ignoring")

        def on_model(model):
            nonlocal first_model_time, last_model_time, model_num, last_shown, last_all_atoms, last_cost, had_cost
            now = time.perf_counter() - run_start
            shown = [] if benchmark else list(model.symbols(shown=True))
            cost = list(model.cost)
            cost_str = cost if cost else "0"
            if first_model_time is None:
                first_model_time = now
                log.info("Model found (%.2fs): %s", now, cost_str)
                if profiler:
                    profiler.model_found()
            else:
                log.info("Model found (%.2fs, +%.2fs): %s", now, now - last_model_time, cost_str)
            last_model_time = now
            model_num += 1
            if cost:
                had_cost = True
            if not defer_print:
                diff = format_model_diff(last_shown, shown, last_cost, cost) if diff_models and model_num > 1 else ""
                if diff:
                    print(f"\nΔ Answer: {model_num}")
                    print(diff)
                else:
                    print(f"\nAnswer: {model_num}")
                    print(" ".join(str(a) for a in shown))
                    if cost:
                        print("Optimization:", format_cost_values(cost))
                sys.stdout.flush()
            if not benchmark:
                last_shown = shown
                if self.results is not None or show_guesses:
                    last_all_atoms = list(model.symbols(atoms=True))
            last_cost = cost
            if diagnose_vftable_objective:
                report_vftable_objective(model, self.diagnose_vftable_limit)

        def on_unsat(lower):
            now = time.perf_counter() - run_start
            if last_cost:
                gap = [u - l for u, l in zip(last_cost, lower)]
                log.info("Lower bound: %s  upper: %s  gap: %s (%.2fs)", list(lower), last_cost, gap, now)
            else:
                log.info("Lower bound: %s (%.2fs)", list(lower), now)

        solve_start = time.perf_counter()
        log.info("Solving...")
        # --time-limit interrupts surface as RuntimeError; keep going so the
        # incumbent model still gets printed and written to --results.
        try:
            result = ctl.solve(on_model=on_model, on_unsat=on_unsat)
        except RuntimeError as e:
            if "stopped by signal" not in str(e):
                raise
            result = None
            log.info("Solving interrupted by signal/time limit; reporting incumbent")
        solve_time = time.perf_counter() - solve_start

        if result is None:
            print("INTERRUPTED")
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

        if defer_print and model_num > 0 and not benchmark:
            print(f"\nAnswer: {model_num}")
            print(" ".join(str(a) for a in last_shown))
            if last_cost:
                print("Optimization:", format_cost_values(last_cost))
            sys.stdout.flush()

        if profiler and profile_conflicts:
            profiler.report()

        if not bool(self.benchmark):
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

            if show_guesses and last_all_atoms:
                print_guess_summary(last_all_atoms)

            if self.results is not None and last_all_atoms:
                from results import write_results
                if self.results == "":
                    base = os.path.splitext(files[0])[0]
                    results_path = base + ".results"
                else:
                    results_path = self.results
                sys.stdout.flush()
                log.info("Writing results to %s", results_path)
                write_results(ctl, last_all_atoms, merge_pairs, results_path)


if __name__ == "__main__":
    clingo.clingo_main(OOAnalyzerApp(), sys.argv[1:])
