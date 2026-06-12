#!/usr/bin/env python3
"""Bounded ooex7 solve diagnostic.

Runs the ooex7 benchmark with the SameClass propagator, cancels after a fixed
number of seconds, and prints grounding, propagator, and clingo search stats.
"""

import argparse
import os
import sys
import time

import clingo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import propagator.sameclass as sameclass  # noqa: E402


class TimedSameClassPropagator(sameclass.SameClassPropagator):
    def __init__(self):
        self.t_init = 0.0
        self.t_propagate = 0.0
        self.n_propagate = 0
        self.n_changes = 0
        self.t_check = 0.0
        self.n_check = 0
        self.t_undo = 0.0
        self.n_undo = 0
        self.n_rebuild = 0

    def init(self, init):
        start = time.time()
        super().init(init)
        self.t_init = time.time() - start

    def propagate(self, ctl, changes):
        changes = list(changes)
        self.n_propagate += 1
        self.n_changes += len(changes)
        start = time.time()
        result = super().propagate(ctl, changes)
        self.t_propagate += time.time() - start
        return result

    def check(self, ctl):
        self.n_check += 1
        start = time.time()
        result = super().check(ctl)
        self.t_check += time.time() - start
        return result

    def undo(self, thread_id, assignment, changes):
        self.n_undo += 1
        start = time.time()
        result = super().undo(thread_id, assignment, changes)
        self.t_undo += time.time() - start
        return result

    def _rebuild(self, assignment):
        self.n_rebuild += 1
        return super()._rebuild(assignment)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seconds",
        type=float,
        default=20.0,
        help="solve timeout before canceling (default: 20)",
    )
    parser.add_argument(
        "--heuristic",
        default="domain",
        help="clingo heuristic option, or empty string for default",
    )
    parser.add_argument(
        "--opt-mode",
        default="ignore",
        help="clingo opt-mode option (default: ignore)",
    )
    parser.add_argument(
        "--models",
        type=int,
        default=1,
        help="number of models to request (default: 1)",
    )
    parser.add_argument(
        "--facts",
        default="examples/ooa/ooex_vs2010/Lite/ooex7.lp",
        help="fact file relative to repo root (default: ooex7.lp)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    ctl_args = ["--warn=none", "--stats=2"]
    if args.opt_mode:
        ctl_args.append(f"--opt-mode={args.opt_mode}")
    if args.heuristic:
        ctl_args.append(f"--heuristic={args.heuristic}")

    prop = TimedSameClassPropagator()
    ctl = clingo.Control(ctl_args)
    ctl.configuration.solve.models = args.models
    ctl.register_propagator(prop)
    ctl.load(os.path.join(ROOT, "ooanalyzer.lp"))
    ctl.load(os.path.join(ROOT, args.facts))

    start = time.time()
    ctl.ground([("base", [])])
    ground_elapsed = time.time() - start

    print(f"ground: {ground_elapsed:.3f}s")

    models = []

    def on_model(model):
        models.append(list(model.cost))
        print(f"model {len(models)} at {time.time() - solve_start:.3f}s cost={models[-1]}")

    solve_start = time.time()
    handle = ctl.solve(async_=True, on_model=on_model)
    completed = handle.wait(args.seconds)
    if not completed:
        handle.cancel()
    result = handle.get()
    solve_elapsed = time.time() - solve_start

    print(f"result: {result}")
    print(f"solve: {solve_elapsed:.3f}s completed={completed} models={len(models)}")
    print(
        "prop.init: "
        f"{prop.t_init:.3f}s "
        f"merge={sum(len(pairs) for pairs in prop._merge_lit_to_pairs.values())} "
        f"sameClass={len(prop._sc_to_lit)} "
        f"check_atoms={len(prop._check_atoms)} "
        f"entities={len(prop._entities)}"
    )
    print(
        "propagate: "
        f"calls={prop.n_propagate} "
        f"changes={prop.n_changes} "
        f"time={prop.t_propagate:.3f}s"
    )
    print(f"check: calls={prop.n_check} time={prop.t_check:.3f}s")
    print(
        "undo: "
        f"calls={prop.n_undo} "
        f"time={prop.t_undo:.3f}s "
        f"rebuilds={prop.n_rebuild}"
    )

    solvers = ctl.statistics.get("solving", {}).get("solvers", {})
    extra = solvers.get("extra", {})
    print(
        "search: "
        f"choices={solvers.get('choices')} "
        f"conflicts={solvers.get('conflicts')} "
        f"domain_choices={extra.get('domain_choices')}"
    )

    return 0 if completed else 124


if __name__ == "__main__":
    raise SystemExit(main())
