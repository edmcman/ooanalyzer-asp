"""Implicit-hitting-set (MaxHS-style) optimality prover for the comp2 objective.

Oracle: the full ground program + &sameClass propagator, comp1 pinned to its
certified optimum, objectives ignored (decision mode), soft reward atoms forced
via assumptions. UNSAT cores over the softs feed an exact hitting-set solve
(small clingo instance); LB = pen_total - (trivial - min_hitting_cost) in
cost[1] terms. Loop ends when a proposal is SAT: its cost equals the LB.

Usage: uv run python ihs_prove.py INPUT.lp --comp1 704 [--budget 600]
"""
import argparse
import sys
import time

import clingo

sys.path.insert(0, "src")
from ooanalyzer_sameclass import SameClassPropagator

# (name, arity, prefer_truth, weight)
SOFT_FAMILIES = [
    ("strongMergeReward", 2, True, 10),
    ("weakMergeReward", 2, True, 8),
    ("weakG1Bonus", 2, True, 9),
    ("guessDerivedClassReward", 3, True, 10),
    ("purecallNotMostDerivedReward", 3, True, 40),
    ("embedsKnownBasePenalty", 3, False, 20),
    ("guessMethodReward", 1, True, 10),
    ("guessConstructor1Reward", 1, True, 10),
    ("guessConstructor2Reward", 1, True, 9),
    ("guessConstructor3Reward", 1, True, 8),
    ("guessConstructor4Reward", 1, True, 7),
]

PIN = """
:- not #sum {{ MaxSize, ms, V : maxCandidateVFTableSize(V, MaxSize) ;
              -Gap, gap, V : vfTableSizeGap(V, Gap) }} >= {comp1}.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--comp1", type=int, required=True,
                    help="certified optimum of cost[0], sign-flipped (e.g. 704 for cost -704)")
    ap.add_argument("--budget", type=float, default=600.0)
    ap.add_argument("--trim-rounds", type=int, default=8)
    ap.add_argument("--call-timeout", type=float, default=30.0)
    ap.add_argument("--max-disjoint", type=int, default=150)
    args = ap.parse_args()
    t0 = time.perf_counter()

    ctl = clingo.Control(["--warn=none", "--heuristic=domain"])
    prop = SameClassPropagator()
    prop.register(ctl)
    ctl.load("ooanalyzer.lp")
    ctl.load(args.input)
    ctl.add("pin", [], PIN.format(comp1=args.comp1))
    print(f"[{time.perf_counter()-t0:6.1f}s] grounding...", flush=True)
    ctl.ground([("base", []), ("pin", [])])
    ctl.configuration.solve.opt_mode = "ignore"

    softs = []          # (symbol, prefer, weight)
    by_family = {}
    fact_max_w = 0      # fact rewards: always achieved, constant in clingo's cost
    fact_pen_w = 0      # fact penalties: unavoidable, constant in clingo's cost
    for name, arity, prefer, weight in SOFT_FAMILIES:
        n = 0
        for a in ctl.symbolic_atoms.by_signature(name, arity):
            if a.is_fact:
                if prefer:
                    fact_max_w += weight
                else:
                    fact_pen_w += weight
                continue
            softs.append((a.symbol, prefer, weight))
            n += 1
        by_family[name] = n
    trivial = sum(w for _, _, w in softs)
    pen_total = sum(w for s, p, w in softs if not p)
    const = fact_pen_w - fact_max_w

    def cost1_scale(v_achieved):
        return const + pen_total - v_achieved

    print(f"[{time.perf_counter()-t0:6.1f}s] softs: {len(softs)} "
          f"(trivial={trivial} pen_total={pen_total} fact_const={const}) {by_family}",
          flush=True)

    # assumption literal (signed program literal) -> soft index
    plit_of = {}
    for i, (sym, prefer, _) in enumerate(softs):
        plit = ctl.symbolic_atoms[sym].literal
        plit_of[plit if prefer else -plit] = i

    def oracle(selected, timeout):
        """Returns (True, achieved_value) | (False, core_indices) | (None, None)."""
        assumptions = [(softs[i][0], softs[i][1]) for i in selected]
        with ctl.solve(assumptions=assumptions, yield_=True, async_=True) as h:
            h.resume()
            if not h.wait(timeout):
                h.cancel()
                h.get()
                return None, None
            m = h.model()
            if m is not None:
                v = sum(w for sym, prefer, w in softs
                        if m.contains(sym) == prefer)
                return True, v
            core = h.core()
        sel = set(selected)
        idx = sorted(i for lit in core
                     if (i := plit_of.get(lit)) is not None and i in sel)
        return False, idx

    def trim(core, timeout):
        for _ in range(args.trim_rounds):
            ok, res = oracle(core, timeout)
            if ok is not False or len(res) >= len(core):
                break
            core = res
        return core

    cores = []
    hs_excluded = []
    hs_exact = True  # empty hitting set is trivially exact
    best_sat = None
    sound_lb = None
    rounds = 0
    call_timeout = args.call_timeout

    while time.perf_counter() - t0 < args.budget:
        rounds += 1
        # Proposal: everything except the current hitting set.
        excluded = set(hs_excluded)
        proposal = [i for i in range(len(softs)) if i not in excluded]
        # Disjoint core extraction on this proposal.
        new_cores = []
        while time.perf_counter() - t0 < args.budget and len(new_cores) < args.max_disjoint:
            ok, res = oracle(proposal, call_timeout)
            if ok is None:
                if not new_cores:
                    # Certification call timed out — escalate and retry once.
                    call_timeout *= 2
                    print(f"[{time.perf_counter()-t0:6.1f}s] oracle timeout on proposal; "
                          f"call-timeout -> {call_timeout:.0f}s", flush=True)
                else:
                    print(f"[{time.perf_counter()-t0:6.1f}s] oracle timeout; "
                          f"ending extraction with {len(new_cores)} new cores", flush=True)
                break
            if ok:
                if not new_cores:
                    v_model = res
                    model_cost1 = cost1_scale(v_model)
                    lb_cost1 = cost1_scale(trivial - sum(softs[i][2] for i in excluded))
                    print(f"[{time.perf_counter()-t0:6.1f}s] SAT proposal: model cost1={model_cost1}, "
                          f"hitting-set LB(cost1)={lb_cost1} (exact={hs_exact})", flush=True)
                    if hs_exact and model_cost1 <= lb_cost1:
                        print(f"OPTIMUM CERTIFIED: cost1={model_cost1} "
                              f"(rounds={rounds}, cores={len(cores)}, "
                              f"{time.perf_counter()-t0:.1f}s)")
                        return
                    best_sat = model_cost1
                break
            core = trim(res, call_timeout)
            if not core:
                print("empty core — comp1 pin or program UNSAT; aborting")
                return
            new_cores.append(core)
            cores.append(core)
            drop = set(core)
            proposal = [i for i in proposal if i not in drop]
            if len(cores) % 25 == 0 or len(core) > 1:
                print(f"[{time.perf_counter()-t0:6.1f}s] core #{len(cores)} size={len(core)} "
                      f"w={[softs[i][2] for i in core]}", flush=True)
        if not new_cores and best_sat is not None:
            print(f"[{time.perf_counter()-t0:6.1f}s] SAT but gap open; best={best_sat}; continuing")
        # Hitting set over all cores. Fresh control per round: measured faster
        # than incremental multi-shot (usc re-derives more than it reuses).
        hs = clingo.Control(["--warn=none",
                             "--opt-strategy=usc,oll,disjoint,succinct,stratify"])
        atoms = sorted({i for c in cores for i in c})
        prog = "".join(f"{{ x({i}) }}.\n" for i in atoms)
        for c in cores:
            prog += ":- " + ", ".join(f"not x({i})" for i in c) + ".\n"
        prog += "#minimize { " + "; ".join(
            f"{softs[i][2]},{i} : x({i})" for i in atoms) + " }.\n"
        hs.add("base", [], prog)
        hs.ground([("base", [])])
        sel = []
        def on_model(m):
            nonlocal sel
            sel = [s.arguments[0].number for s in m.symbols(shown=True) if s.name == "x"]
        with hs.solve(on_model=on_model, async_=True) as hh:
            exact = hh.wait(120.0)
            if not exact:
                hh.cancel()
            r = hh.get()
        if not sel and not r.satisfiable:
            print("hitting-set solve failed")
            return
        hs_excluded = sel
        hs_cost = sum(softs[i][2] for i in sel)
        hs_exact = exact and r.satisfiable
        if hs_exact:
            sound_lb = cost1_scale(trivial - hs_cost)
            print(f"[{time.perf_counter()-t0:6.1f}s] hitting set: cost={hs_cost} "
                  f"=> LB(cost1)={sound_lb} (cores={len(cores)})", flush=True)
        else:
            print(f"[{time.perf_counter()-t0:6.1f}s] hitting set TIMEOUT: best cost={hs_cost} "
                  f"(not exact; sound LB stays {sound_lb}; cores={len(cores)})", flush=True)

    print(f"budget exhausted: cores={len(cores)} sound LB(cost1)={sound_lb} "
          f"best_sat={best_sat}")


if __name__ == "__main__":
    main()
