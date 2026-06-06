"""
ConflictProfiler: tracks which predicates are most frequently backtracked.

Hook into undo() — fires whenever the solver unassigns watched literals due to
backtracking.  Atoms that appear most often in undo() calls are the ones the
solver is spending the most time assigning and re-assigning, i.e. the hard core
of the search.

Pass interval=N to get periodic reports every N seconds during solving.

Usage:
    profiler = ConflictProfiler(interval=30)
    ctl.register_propagator(profiler)
    ...solve...
    profiler.report()
"""

import sys
import time
from collections import Counter, defaultdict


class ConflictProfiler:
    def __init__(self, watch_preds=None, max_atoms=10000, max_atoms_per_predicate=500, interval=0):
        # watch_preds: set of predicate names to restrict to, or None for all
        self._watch_preds = set(watch_preds) if watch_preds else None
        self._max_atoms = max_atoms
        self._max_atoms_per_predicate = max_atoms_per_predicate
        self._interval = interval
        self._start_time = time.monotonic()
        self._last_report_time = self._start_time
        self._lit_to_pred = {}   # abs(solver_lit) -> predicate name
        self._lit_to_sym  = {}   # abs(solver_lit) -> symbol string (top-N atoms)
        self._undo_by_pred  = Counter()            # pred -> total undo count
        self._undo_by_atom  = Counter()            # symbol str -> total undo count
        self._level_by_pred = defaultdict(list)    # pred -> [decision_level, ...]
        self._watched_by_pred = Counter()
        self._total_undos   = 0
        self._watched_atoms  = 0
        self._skipped_atoms  = 0

    # ------------------------------------------------------------------
    def init(self, init):
        for sym_atom in init.symbolic_atoms:
            pred = sym_atom.symbol.name
            if self._watch_preds and pred not in self._watch_preds:
                continue
            if self._max_atoms is not None and self._watched_atoms >= self._max_atoms:
                self._skipped_atoms += 1
                continue
            if (
                self._max_atoms_per_predicate is not None
                and self._watched_by_pred[pred] >= self._max_atoms_per_predicate
            ):
                self._skipped_atoms += 1
                continue
            lit = init.solver_literal(sym_atom.literal)
            alit = abs(lit)
            self._lit_to_pred[alit] = pred
            self._lit_to_sym[alit]  = str(sym_atom.symbol)
            init.add_watch( lit)
            init.add_watch(-lit)
            self._watched_atoms += 1
            self._watched_by_pred[pred] += 1

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
        if self._interval > 0 and time.monotonic() - self._last_report_time >= self._interval:
            self._periodic_report()
            self._last_report_time = time.monotonic()

    def check(self, control):
        pass

    # ------------------------------------------------------------------
    def _periodic_report(self, top_preds=15):
        T = max(self._total_undos, 1)
        elapsed = time.monotonic() - self._start_time
        print(f"\n--- Conflict Profile @ {elapsed:.0f}s  ({self._total_undos:,} backtracks) ---")
        print(f"{'Predicate':<42} {'Backtracks':>12} {'%':>6}")
        for pred, cnt in self._undo_by_pred.most_common(top_preds):
            pct = 100.0 * cnt / T
            print(f"  {pred:<40} {cnt:>12,} {pct:>5.1f}%")
        sys.stdout.flush()

    def report(self, top_preds=25, top_atoms=15):
        T = max(self._total_undos, 1)
        print(f"\n=== Conflict Profile  ({self._total_undos:,} total backtracks; "
              f"{self._watched_atoms:,} watched atoms; "
              f"{self._skipped_atoms:,} skipped by cap) ===")
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
