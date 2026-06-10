"""
Minimal test harness for SameClassPropagator.

Tests:
  1. reflexive: &sameClass(a,a) always true
  2. direct: mergeClasses(a,b) → &sameClass(a,b); ¬merge → ¬same
  3. transitive: mergeClasses(a,b) ∧ mergeClasses(b,c) → &sameClass(a,c)
  4. cross: no path → &sameClass(a,d) always false
  5. rule-body-positive: a rule that requires &sameClass to be true fires correctly
  6. rule-body-negative: a rule using `not &sameClass` fires when they differ
  9. circular-cross: K-rule merge blocked when its only support is a circular sc atom
 10. legitimate-bridge: K-rule merge allowed when sc precondition has seed support
 11. within-component circular: foundedness check rejects self-justifying K-merge
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
    &sameClass/2         : t, body;
    &allWritersInClass/2 : t, body
}.
"""

CONTROL_MODES = [
    ("single", ["--warn=none", "0"]),
    ("threads=4", ["--warn=none", "0", "-t", "4"]),
]


def run(name, asp, expected_models, expected_atoms=None, ctl_args=None, foundedness=False):
    prog = THEORY + asp
    prop = SameClassPropagator(foundedness_check=foundedness)
    ctl = clingo.Control(ctl_args or ["--warn=none", "0"])
    ctl.register_observer(prop)
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
    ctl.register_observer(prop)
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

        # ── &allWritersInClass tests ──────────────────────────────────────────

        # ── 7a. Single writer in own class → AWC true ─────────────────────────
        ("awc: single writer in own class → awc true",
         """
         mergeEntity(m1).
         nonOverwritingWrite(m1, 0, vt1).
         allIn :- &allWritersInClass(vt1, m1).
         :- not allIn.
         #show allIn/0.
         """,
         1,
         frozenset(["allIn"])),

        # ── 7b. Out-of-class writer → AWC must be false ───────────────────────
        ("awc: out-of-class writer → constraint on awc-true is satisfiable",
         """
         mergeEntity(m1). mergeEntity(m2).
         nonOverwritingWrite(m1, 0, vt1).
         nonOverwritingWrite(m2, 0, vt1).
         :- &allWritersInClass(vt1, m1).
         """,
         1),   # 1 model: AWC is false (m2 out-of-class), constraint satisfied

        # ── 7c. Merging writers makes AWC true ────────────────────────────────
        ("awc: merging both writers makes awc true",
         """
         mergeEntity(m1). mergeEntity(m2).
         nonOverwritingWrite(m1, 0, vt1).
         nonOverwritingWrite(m2, 0, vt1).
         1 { mergeClasses(m1, m2) ; -mergeClasses(m1, m2) } 1.
         allIn :- &allWritersInClass(vt1, m1).
         :- allIn, not mergeClasses(m1, m2).
         :- not allIn, mergeClasses(m1, m2).
         #show mergeClasses/2. #show allIn/0.
         """,
         2,
         frozenset(["mergeClasses(m1,m2)", "allIn"])),

        # ── 7d. AWC requires ALL writers in class, not just one ───────────────
        # AWC can be true iff all three writers are merged (propagator blocks AWC=true
        # when any writer is out-of-class). We force allIn ↔ (m1-m2 ∧ m2-m3) via
        # two prevention constraints + one requirement constraint, giving 4 models.
        ("awc: blocked unless all three writers are merged (biconditional)",
         """
         mergeEntity(m1). mergeEntity(m2). mergeEntity(m3).
         nonOverwritingWrite(m1, 0, vt1).
         nonOverwritingWrite(m2, 0, vt1).
         nonOverwritingWrite(m3, 0, vt1).
         1 { mergeClasses(m1, m2) ; -mergeClasses(m1, m2) } 1.
         1 { mergeClasses(m2, m3) ; -mergeClasses(m2, m3) } 1.
         allIn :- &allWritersInClass(vt1, m1).
         :- allIn, not mergeClasses(m1, m2).
         :- allIn, not mergeClasses(m2, m3).
         :- mergeClasses(m1, m2), mergeClasses(m2, m3), not allIn.
         #show mergeClasses/2. #show allIn/0.
         """,
         4,
         frozenset(["mergeClasses(m1,m2)", "mergeClasses(m2,m3)", "allIn"])),

        # ── 7e. AWC per-vftable: separate vftables don't interfere ────────────
        ("awc: independent per-vftable — each vftable decided separately",
         """
         mergeEntity(m1). mergeEntity(m2).
         nonOverwritingWrite(m1, 0, vt1).
         nonOverwritingWrite(m2, 0, vt2).
         allIn1 :- &allWritersInClass(vt1, m1).
         allIn2 :- &allWritersInClass(vt2, m2).
         :- not allIn1.
         :- not allIn2.
         #show allIn1/0. #show allIn2/0.
         """,
         1,
         frozenset(["allIn1", "allIn2"])),

        # ── 8. Multi-thread transitive regression ─────────────────────────────
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

        # ── 9. Circular cross-component K-merge ──────────────────────────────
        # mergeClasses(a,b) has only one support rule: :- &sameClass(a,b).
        # With no seed edge, a and b start in different potential-UF components,
        # so mergeClasses(a,b) is never added to _potential_uf and &sameClass(a,b)
        # is forced permanently false at level 0.  The K-rule can never fire.
        ("circular-cross: K-merge with no seed support is blocked",
         """
         mergeEntity(a). mergeEntity(b).
         mergeClasses(a,b) :- &sameClass(a,b).
         got_merge :- mergeClasses(a,b).
         #show got_merge/0.
         """,
         1),   # 1 model, got_merge absent

        # ── 10. Legitimate K-bridge ───────────────────────────────────────────
        # mergeClasses(b,c) is derived by a K-rule conditioned on &sameClass(a,b).
        # mergeClasses(a,b) is a seed choice, so a-b are same in _potential_uf;
        # that makes mergeClasses(b,c) potentially derivable — it must NOT be
        # forced false at level 0.  In the model where mergeClasses(a,b) is true,
        # the K-rule fires and bridge must appear.
        ("legitimate-bridge: K-merge with seed-founded sc is allowed",
         """
         mergeEntity(a). mergeEntity(b). mergeEntity(c).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         mergeClasses(b,c) :- &sameClass(a,b).
         bridge :- mergeClasses(b,c).
         :- mergeClasses(a,b), not bridge.
         #show mergeClasses/2. #show bridge/0.
         """,
         2,
         frozenset(["mergeClasses(a,b)", "bridge"])),
    ]

    # Tests that require foundedness_check=True (run once, not per control mode).
    foundedness_tests = [
        # ── 11. Within-component circular K-merge ─────────────────────────────
        # Seeds: choices for a-b and b-c put a,b,c in the same potential component.
        # K-rule: mergeClasses(a,c) :- &sameClass(a,c).  Both a and c are same in
        # potential-UF (via seed choices), so the K-rule head is NOT pre-blocked.
        # Without foundedness check, the solver can produce a circular model where
        # mergeClasses(a,c)=true with both seed merges false.
        # With foundedness_check=True, that model is rejected: mergeClasses(a,c)
        # has no founded support when a-b and b-c are both false.
        ("within-component circular: foundedness check blocks self-justifying K-merge",
         """
         mergeEntity(a). mergeEntity(b). mergeEntity(c).
         1 { mergeClasses(a,b) ; -mergeClasses(a,b) } 1.
         1 { mergeClasses(b,c) ; -mergeClasses(b,c) } 1.
         mergeClasses(a,c) :- &sameClass(a,c).
         circular :- mergeClasses(a,c), not mergeClasses(a,b), not mergeClasses(b,c).
         #show mergeClasses/2. #show circular/0.
         """,
         4),   # 4 founded models; no model may contain "circular"
    ]

    for mode, ctl_args in CONTROL_MODES:
        print(f"\nMode: {mode}")
        for name, asp, expected_models, *rest in tests:
            expected_atoms = rest[0] if rest else None
            if run(name, asp, expected_models, expected_atoms, ctl_args):
                passed += 1
            else:
                failed += 1

    print("\nMode: foundedness check (single)")
    for name, asp, expected_models, *rest in foundedness_tests:
        expected_atoms = rest[0] if rest else None
        result = run(name, asp, expected_models, expected_atoms,
                     ctl_args=["--warn=none", "0"], foundedness=True)
        # Also verify no model contains "circular" (the key soundness property)
        prog = THEORY + asp
        prop = SameClassPropagator(foundedness_check=True)
        ctl = clingo.Control(["--warn=none", "0"])
        ctl.register_observer(prop)
        ctl.register_propagator(prop)
        ctl.add("base", [], prog)
        ctl.ground([("base", [])])
        all_atoms = []
        ctl.solve(on_model=lambda m: all_atoms.extend(m.symbols(shown=True)))
        circular_found = any(str(a) == "circular" for a in all_atoms)
        if circular_found:
            print(f"  FAIL  {name}  (circular model found despite foundedness check)")
            result = False
        if result:
            passed += 1
        else:
            failed += 1

    print("\nMode: heuristic reward consistency")
    finishing_heuristic_configs = [
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
            "example.lp optimal reward is stable across finishing heuristics",
            [ROOT / "examples" / "example.lp"],
            finishing_heuristic_configs,
        ),
        (
            "Lite/ooex0 optimal reward is stable across finishing heuristics",
            [ROOT / "examples" / "ooa" / "ooex_vs2010" / "Lite" / "ooex0.lp"],
            finishing_heuristic_configs,
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
