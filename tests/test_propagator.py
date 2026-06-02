"""
Minimal test harness for SameClassPropagator.

Tests:
  1. reflexive: &sameClass(a,a) always true
  2. direct: mergeClasses(a,b) → &sameClass(a,b); ¬merge → ¬same
  3. transitive: mergeClasses(a,b) ∧ mergeClasses(b,c) → &sameClass(a,c)
  4. cross: no path → &sameClass(a,d) always false
  5. rule-body-positive: a rule that requires &sameClass to be true fires correctly
  6. rule-body-negative: a rule using `not &sameClass` fires when they differ
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import clingo
from propagator.sameclass import SameClassPropagator

ROOT = Path(__file__).resolve().parents[1]
MAIN_LP = ROOT / "ooanalyzer.lp"

THEORY = """
#theory sc {
    t {};
    &sameClass/2 : t, body
}.
"""

CONTROL_MODES = [
    ("single", ["--warn=none", "0"]),
    ("threads=4", ["--warn=none", "0", "-t", "4"]),
]


def run(name, asp, expected_models, expected_atoms=None, ctl_args=None):
    prog = THEORY + asp
    prop = SameClassPropagator()
    ctl = clingo.Control(ctl_args or ["--warn=none", "0"])
    ctl.register_propagator(prop)
    ctl.add("base", [], prog)
    ctl.ground([("base", [])])

    models = []
    def on_model(m):
        atoms = frozenset(str(a) for a in m.symbols(shown=True))
        models.append(atoms)

    ctl.solve(on_model=on_model)

    ok = len(models) == expected_models
    if expected_atoms is not None:
        ok = ok and any(expected_atoms.issubset(m) for m in models)

    status = "PASS" if ok else "FAIL"
    print(f"  {status}  {name}  (got {len(models)} models, want {expected_models})")
    if not ok:
        for m in models:
            print(f"       {sorted(m)}")
    return ok


def optimal_cost_for_files(files, ctl_args, timeout=10):
    prop = SameClassPropagator()
    ctl = clingo.Control(ctl_args)
    ctl.register_propagator(prop)
    ctl.load(str(MAIN_LP))
    for path in files:
        ctl.load(str(path))
    ctl.ground([("base", [])])

    costs = []

    def on_model(model):
        if model.cost:
            costs.append(tuple(model.cost))

    handle = ctl.solve(on_model=on_model, async_=True)
    if not handle.wait(timeout):
        handle.cancel()
        handle.get()
        raise AssertionError(f"solver did not finish within {timeout}s")
    result = handle.get()
    if not costs:
        raise AssertionError("no optimization cost reported")
    if not result.exhausted:
        raise AssertionError("solver did not exhaust optimization search")
    if result.unsatisfiable:
        raise AssertionError("case is unexpectedly unsatisfiable")
    return costs[-1]


def run_reward_consistency(name, files, configurations):
    costs = {}
    for config_name, ctl_args in configurations:
        costs[config_name] = optimal_cost_for_files(files, ctl_args)

    unique_costs = set(costs.values())
    ok = len(unique_costs) == 1
    status = "PASS" if ok else "FAIL"
    rendered = ", ".join(f"{h}={cost}" for h, cost in costs.items())
    print(f"  {status}  {name}  ({rendered})")
    return ok


def main():
    passed = failed = 0

    tests = [
        # ── 1. Reflexive ─────────────────────────────────────────────────────
        ("reflexive: always-true constraint satisfied",
         """
         mergeEntity(a).
         :- not &sameClass(a, a).
         """,
         1),

        # ── 2. Direct biconditional ───────────────────────────────────────────
        ("direct: one merge true → sameClass true in answer",
         """
         mergeEntity(a). mergeEntity(b).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1 :- mergeEntity(a), mergeEntity(b), a < b.
         inSameClass :- &sameClass(a, b).
         :- mergeClasses(a,b), not inSameClass.
         :- not mergeClasses(a,b), inSameClass.
         #show mergeClasses/2. #show inSameClass/0.
         """,
         2,                         # two models: merge=T and merge=F
         frozenset(["mergeClasses(a,b)", "inSameClass"])),

        # ── 3. Transitive ─────────────────────────────────────────────────────
        ("transitive: a-b-c path → &sameClass(a,c) when both merges true",
         """
         mergeEntity(a). mergeEntity(b). mergeEntity(c).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         1 { mergeClasses(b,c) ; -mergeClasses(b,c) } 1.
         transitive :- &sameClass(a, c).
         :- mergeClasses(a,b), mergeClasses(b,c), not transitive.
         :- not mergeClasses(a,b), transitive.
         :- not mergeClasses(b,c), transitive.
         #show mergeClasses/2. #show transitive/0.
         """,
         4,                         # 2×2 = 4 merge combinations
         frozenset(["mergeClasses(a,b)", "mergeClasses(b,c)", "transitive"])),

        # ── 4. Cross-component always false ───────────────────────────────────
        ("cross: no path → &sameClass(a,d) never true",
         """
         mergeEntity(a). mergeEntity(b). mergeEntity(d).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         crossed :- &sameClass(a, d).
         :- crossed.
         #show mergeClasses/2. #show crossed/0.
         """,
         2),   # 2 models (merge T/F), crossed never appears

        # ── 5. Constraint on sameClass ────────────────────────────────────────
        ("constraint: require a and b in same class → force merge",
         """
         mergeEntity(a). mergeEntity(b).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         :- not &sameClass(a, b).
         #show mergeClasses/2.
         """,
         1,                         # only the model where mergeClasses(a,b) is true
         frozenset(["mergeClasses(a,b)"])),

        # ── 6. Negative body ─────────────────────────────────────────────────
        ("not-sameClass body: fires when different class",
         """
         mergeEntity(a). mergeEntity(b).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         different :- not &sameClass(a, b).
         #show mergeClasses/2. #show -mergeClasses/2. #show different/0.
         """,
         2,
         frozenset(["-mergeClasses(a,b)", "different"])),

        # ── 7. Multi-thread transitive regression ─────────────────────────────
        ("multi-thread transitive: force a-d through a-b-c-d chain",
         """
         mergeEntity(a). mergeEntity(b). mergeEntity(c). mergeEntity(d).
         mergeEntity(e). mergeEntity(f). mergeEntity(g). mergeEntity(h).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         1 { mergeClasses(b,c) ; -mergeClasses(b,c) } 1.
         1 { mergeClasses(c,d) ; -mergeClasses(c,d) } 1.
         1 { mergeClasses(e,f) ; -mergeClasses(e,f) } 1.
         1 { mergeClasses(f,g) ; -mergeClasses(f,g) } 1.
         1 { mergeClasses(g,h) ; -mergeClasses(g,h) } 1.
         1 { mergeClasses(e,h) ; -mergeClasses(e,h) } 1.
         :- not &sameClass(a, d).
         #show mergeClasses/2.
         """,
         16,
         frozenset(["mergeClasses(a,b)", "mergeClasses(b,c)", "mergeClasses(c,d)"])),
    ]

    for mode, ctl_args in CONTROL_MODES:
        print(f"\nMode: {mode}")
        for name, asp, expected_models, *rest in tests:
            expected_atoms = rest[0] if rest else None
            if run(name, asp, expected_models, expected_atoms, ctl_args):
                passed += 1
            else:
                failed += 1

    print("\nMode: heuristic reward consistency")
    basic_heuristic_configs = [
        (
            "domain",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=domain"],
        ),
        (
            "berkmin",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=berkmin"],
        ),
        (
            "vmtf",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=vmtf"],
        ),
        (
            "vsids",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=vsids"],
        ),
    ]
    lite_heuristic_configs = [
        (
            "domain",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=domain"],
        ),
        (
            "vmtf",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=vmtf"],
        ),
        (
            "vsids",
            ["--warn=none", "--opt-strategy=bb,inc", "--heuristic=vsids"],
        ),
    ]
    reward_tests = [
        (
            "example.lp optimal reward is stable across heuristics",
            [ROOT / "examples" / "example.lp"],
            basic_heuristic_configs,
        ),
        (
            "Lite/ooex0 optimal reward is stable across finishing heuristics",
            [ROOT / "examples" / "ooa" / "ooex_vs2010" / "Lite" / "ooex0.lp"],
            lite_heuristic_configs,
        ),
    ]
    for name, files, configurations in reward_tests:
        if run_reward_consistency(name, files, configurations):
            passed += 1
        else:
            failed += 1

    print(f"\n{passed}/{passed+failed} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
