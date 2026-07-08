#!/usr/bin/env python3
"""Stress the &classHasWitness support machinery of the Rust propagator.

Synthetic version of OOAnalyzer's classSizeGTE shape (the TinyXml feasibility
regression): every class carries a base size witness, containment edges
accumulate inner sizes through &classHasWitness(sizeGroup(S), Inner), and a
sprinkling of hard size caps is enforced across live components through
&sameClass. The objective wants every merge, so the solver drives components
straight into the caps and the propagator has to referee.

Every classSizeGTE flip is a witnessGroup flip, and every merge absorbs size
witnesses — with per-flip full-group rescans this costs
O(classes_in_group x witnesses_in_group) union-find probes per event, which is
what melted TinyXml's decision throughput. Incremental per-component support
counts make the same events O(1).

    uv run python scripts/chw_stress_demo.py --classes 240 --time-limit 60
"""

from __future__ import annotations

import argparse
import os
import time

THEORY = """
#theory sc {
    t {};
    &sameClass/2            : t, body;
    &allWritersInClass/2    : t, body;
    &classRelationship/2    : t, body;
    &classRelationshipVia/2 : t, body;
    &classHasWitness/2      : t, body
}.
"""

PROGRAM = """
#const n = {classes}.
#const capval = {cap}.

cls(1..n).

% Small static base sizes; a solver *choice* upgrades a class to a big object
% (like vfTableSize picking a large extent) — so size witnesses flip with
% solver decisions, not just merges.
baseSize(C, 4 + 4 * (C \\ 2)) :- cls(C).
{{ bigObject(C) }} :- cls(C).
classSizeGTE(C, S) :- baseSize(C, S).
classSizeGTE(C, 24) :- bigObject(C).
sizeVal(4). sizeVal(8). sizeVal(24).

% Containment chain: C contains C+1 at offset 4 (like objectInObject, but a
% private name so the &classRelationship machinery stays out of the picture).
inner(C, C + 1, 4) :- cls(C), cls(C + 1).

% Accumulate inner sizes across the live &sameClass classes: does inner's
% component carry a witness of size S right now? Derived values 12/28 fall
% outside sizeVal, so chains terminate; only 4+4=8 re-enters witnessGroup.
classSizeGTE(C, Off + S) :-
    inner(C, I, Off),
    sizeVal(S),
    &classHasWitness(sizeGroup(S), I).

witnessGroup(sizeGroup(S), C) :- classSizeGTE(C, S), sizeVal(S).

% Merge choices: even/odd interleave so components regroup constantly.
{{ mergeClasses(C, C + 2) }} :- cls(C), cls(C + 2).

% Hard caps on every 5th class: statically safe (base <= 8, one hop <= 12),
% violated only when a bigObject witness reaches the component via merges.
cap(C, capval) :- cls(C), C \\ 5 == 0.
:- cap(C, L), classSizeGTE(W, S), S > L, &sameClass(C, W).

#maximize {{ 1,big,C : bigObject(C); 1,mc,A,B : mergeClasses(A, B) }}.
#show mergeClasses/2.
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes", type=int, default=240)
    ap.add_argument("--cap", type=int, default=16)
    ap.add_argument("--time-limit", type=float, default=60.0)
    ap.add_argument("--no-eager", action="store_true", help="set OOA_NO_EAGER=1")
    ap.add_argument("--ground-only", action="store_true")
    args = ap.parse_args()

    if args.no_eager:
        os.environ["OOA_NO_EAGER"] = "1"

    import clingo
    from ooanalyzer_sameclass import SameClassPropagator

    prog = THEORY + PROGRAM.format(classes=args.classes, cap=args.cap)
    ctl = clingo.Control(["--warn=none", "--stats", "0", "--opt-mode=optN"])
    prop = SameClassPropagator()
    prop.register(ctl)
    ctl.add("base", [], prog)

    t0 = time.perf_counter()
    ctl.ground([("base", [])])
    t_ground = time.perf_counter() - t0
    print(f"ground: {t_ground:.2f}s")
    if args.ground_only:
        return

    costs: list[tuple[float, int]] = []

    def on_model(m: clingo.Model) -> None:
        costs.append((time.perf_counter() - t0, m.cost[0] if m.cost else 0))

    t0 = time.perf_counter()
    with ctl.solve(on_model=on_model, async_=True) as handle:
        if not handle.wait(args.time_limit):
            handle.cancel()
        result = handle.get()
    t_solve = time.perf_counter() - t0

    stats = ctl.statistics["solving"]["solvers"]
    choices, conflicts = stats["choices"], stats["conflicts"]
    print(f"result: {result}  solve: {t_solve:.2f}s")
    if costs:
        print(f"first model: {costs[0][0]:.2f}s (cost {costs[0][1]}), "
              f"best: cost {costs[-1][1]} @ {costs[-1][0]:.2f}s, models: {len(costs)}")
    else:
        print("no models")
    print(f"choices: {choices:,.0f} ({choices / max(t_solve, 1e-9):,.0f}/s)  "
          f"conflicts: {conflicts:,.0f} ({conflicts / max(t_solve, 1e-9):,.0f}/s)")


if __name__ == "__main__":
    main()
