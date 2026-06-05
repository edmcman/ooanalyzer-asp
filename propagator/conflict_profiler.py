"""
ConflictProfiler: tracks which predicates are most frequently backtracked.

Hook into undo() — fires whenever the solver unassigns watched literals due to
backtracking.  Atoms that appear most often in undo() calls are the ones the
solver is spending the most time assigning and re-assigning, i.e. the hard core
of the search.

Usage:
    profiler = ConflictProfiler()
    ctl.register_propagator(profiler)
    ...solve...
    profiler.report()
"""

from collections import Counter, defaultdict


class ConflictProfiler:
    def __init__(self, watch_preds=None):
        # watch_preds: set of predicate names to restrict to, or None for all
        self._watch_preds = set(watch_preds) if watch_preds else None
        self._lit_to_pred = {}   # abs(solver_lit) -> predicate name
        self._lit_to_sym  = {}   # abs(solver_lit) -> symbol string (top-N atoms)
        self._undo_by_pred  = Counter()            # pred -> total undo count
        self._undo_by_atom  = Counter()            # symbol str -> total undo count
        self._level_by_pred = defaultdict(list)    # pred -> [decision_level, ...]
        self._total_undos   = 0

    # ------------------------------------------------------------------
    def init(self, init):
        for sym_atom in init.symbolic_atoms:
            pred = sym_atom.symbol.name
            if self._watch_preds and pred not in self._watch_preds:
                continue
            lit = init.solver_literal(sym_atom.literal)
            alit = abs(lit)
            self._lit_to_pred[alit] = pred
            self._lit_to_sym[alit]  = str(sym_atom.symbol)
            init.add_watch( lit)
            init.add_watch(-lit)

    def propagate(self, control, changes):
        pass

    def undo(self, thread_id, assignment, changes):
        level = assignment.decision_level
        for lit in changes:
            alit = abs(lit)
            pred = self._lit_to_pred.get(alit)
            if pred is None:
                continue
            self._undo_by_pred[pred] += 1
            self._undo_by_atom[self._lit_to_sym[alit]] += 1
            self._level_by_pred[pred].append(level)
            self._total_undos += 1

    def check(self, control):
        pass

    # ------------------------------------------------------------------
    def report(self, top_preds=25, top_atoms=15):
        T = max(self._total_undos, 1)
        print(f"\n=== Conflict Profile  ({self._total_undos:,} total backtracks) ===")
        print(f"\n{'Predicate':<42} {'Backtracks':>12} {'%':>6}  {'Avg Level':>10}")
        print("-" * 76)
        for pred, cnt in self._undo_by_pred.most_common(top_preds):
            levels = self._level_by_pred[pred]
            avg = sum(levels) / len(levels) if levels else 0.0
            pct = 100.0 * cnt / T
            print(f"  {pred:<40} {cnt:>12,} {pct:>5.1f}%  {avg:>10.1f}")

        print(f"\n  Top {top_atoms} individual atoms:")
        for sym, cnt in self._undo_by_atom.most_common(top_atoms):
            pct = 100.0 * cnt / T
            print(f"    {sym:<60} {cnt:>8,}  ({pct:.1f}%)")
