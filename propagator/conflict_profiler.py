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

import clingo


class _ConflictCounterCallbacks:
    """Profiler callbacks without a per-decision Python crossing."""

    def __init__(self, profiler):
        self._profiler = profiler

    def init(self, init):
        self._profiler.init(init)

    def undo(self, thread_id, assignment, changes):
        self._profiler.undo(thread_id, assignment, changes)

    def check(self, control):
        self._profiler.check(control)


class ConflictProfiler:
    def __init__(self, watch_preds=None, max_atoms=10000, max_atoms_per_predicate=500,
                 interval=0, trace_backjumps=0, trace_backjump_limit=10,
                 profile_after=0, after_first_model=False,
                 count_conflicts=True):
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
        self._window_label = "solve start"
        self._trace_backjumps = trace_backjumps
        self._trace_backjump_limit = trace_backjump_limit
        self._profile_after = profile_after
        self._after_first_model = after_first_model
        self._count_conflicts = count_conflicts
        self._model_gate_open = not after_first_model
        self._active = False
        self._defer_watches = after_first_model
        self._watch_lits = set()
        self._watched_threads = set()
        self._trace_start_time = None
        self._trace_count = 0
        self._large_jump_count = 0
        self._decision_info = defaultdict(list)  # abs(solver_lit) -> aliases
        self._decisions = defaultdict(dict)  # thread -> level -> signed literal
        self._last_abandoned = defaultdict(set)  # thread -> signed decision literals
        self._abandoned_counts = defaultdict(Counter)  # thread -> signed literal -> jumps
        self._pending_backjump = {}

    def callbacks(self):
        """Return callbacks omitting `decide` when tracing is disabled."""
        return self if self._trace_backjumps else _ConflictCounterCallbacks(self)

    # ------------------------------------------------------------------
    def init(self, init):
        self._start_time = time.monotonic()
        self._last_report_time = self._start_time
        self._trace_start_time = self._start_time
        if self._after_first_model:
            init.check_mode = clingo.PropagatorCheckMode.Total
        for sym_atom in init.symbolic_atoms:
            pred = sym_atom.symbol.name
            lit = init.solver_literal(sym_atom.literal)
            if self._trace_backjumps:
                self._decision_info[abs(lit)].append((lit, pred, str(sym_atom.symbol)))
            if not self._count_conflicts and not self._trace_backjumps:
                continue
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
            alit = abs(lit)
            if self._count_conflicts:
                self._lit_to_pred[alit] = pred
                self._lit_to_sym[alit] = str(sym_atom.symbol)
            self._watch_lits.add(lit)
            self._watch_lits.add(-lit)
            if not self._defer_watches:
                init.add_watch(lit)
                init.add_watch(-lit)
            self._watched_atoms += 1
            self._watched_by_pred[pred] += 1

        if self._trace_backjumps:
            for atom in init.theory_atoms:
                lit = init.solver_literal(atom.literal)
                term = atom.term
                pred = f"&{term.name}"
                args = ",".join(str(arg) for arg in term.arguments)
                text = f"&{term.name}({args})"
                self._decision_info[abs(lit)].append((lit, pred, text))

        self._maybe_activate()

    def _maybe_activate(self, control=None):
        if self._active:
            self._add_watches(control)
            return True
        if not self._model_gate_open:
            return False
        now = time.monotonic()
        if now - self._start_time < self._profile_after:
            return False
        if self._defer_watches:
            if control is None:
                return False
            self._add_watches(control)
        self._active = True
        if self._after_first_model:
            label = "since model 1"
        elif self._profile_after:
            label = f"after {self._profile_after:g}s"
        else:
            label = "solve start"
        self.reset_counts(label)
        self._trace_start_time = now
        return True

    def _add_watches(self, control):
        if not self._defer_watches or control is None:
            return
        thread_id = control.thread_id
        if thread_id not in self._watched_threads:
            for lit in self._watch_lits:
                control.add_watch(lit)
            self._watched_threads.add(thread_id)

    def propagate(self, control, changes):
        if self._maybe_activate(control) and self._trace_backjumps:
            self._report_post_backjump(control.thread_id, control.assignment)
            self._capture_decisions(control.thread_id, control.assignment)

    def decide(self, thread_id, assignment, fallback):
        # Return zero so profiling never chooses a literal. Depending on an
        # earlier propagator's decision this callback may be skipped; the next
        # propagate/undo/check callback still captures the resulting state.
        if self._active and self._trace_backjumps:
            self._report_post_backjump(thread_id, assignment, final=True)
        return 0

    def _capture_decisions(self, thread_id, assignment):
        history = self._decisions[thread_id]
        for level in range(1, assignment.decision_level + 1):
            if level not in history:
                try:
                    history[level] = assignment.decision(level)
                except RuntimeError:
                    break

    def undo(self, thread_id, assignment, changes):
        if not self._maybe_activate():
            return
        if self._trace_backjumps:
            self._report_post_backjump(thread_id, assignment, final=True)
            self._capture_decisions(thread_id, assignment)
        level = assignment.decision_level
        # Depending on clingo's callback timing, assignment can still expose
        # the pre-undo levels of `changes`. Their minimum level is target+1.
        change_levels = []
        if self._trace_backjumps:
            for lit in changes:
                try:
                    change_levels.append(assignment.level(lit))
                except RuntimeError:
                    pass
        if change_levels:
            level = min(level, min(change_levels) - 1)
        if self._trace_backjumps:
            self._trace_backjump(thread_id, level)
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

    def _describe_decision(self, lit):
        infos = self._decision_info.get(abs(lit))
        if not infos:
            return "?", "true" if lit > 0 else "false", f"lit({lit})"
        choice_priority = {
            "mergeClasses": 0,
            "method": 1,
            "constructor": 2,
            "vfTable": 3,
            "vfTableSize": 4,
            "embeddedObject": 5,
            "derivedClass": 6,
            "guessEnabled": 7,
        }
        positive_lit, pred, text = min(
            infos,
            key=lambda info: (
                choice_priority.get(info[1], 100),
                info[2].startswith("-"),
                info[2],
            ),
        )
        atom_is_true = lit == positive_lit
        # Classical negation is a separate symbolic atom in clingo. Report
        # `-method(M)=true` as the semantic decision `method(M)=false`, so
        # repetitions and phase flips compare the underlying choice.
        classically_negative = text.startswith("-")
        semantic_true = atom_is_true != classically_negative
        if classically_negative:
            text = text[1:]
        phase = "true" if semantic_true else "false"
        aliases = []
        for _, _, alias in infos:
            if alias != text and alias not in aliases:
                aliases.append(alias)
        if aliases:
            text += "  aliases=[" + ", ".join(aliases[:4]) + (", ..." if len(aliases) > 4 else "") + "]"
        return pred, phase, text

    def _decision_identity(self, lit):
        pred, phase, text = self._describe_decision(lit)
        # Aliases are diagnostic decoration, not part of decision identity.
        canonical = text.split("  aliases=[", 1)[0]
        return pred, phase, canonical

    def _report_post_backjump(self, thread_id, assignment, final=False):
        pending = self._pending_backjump.get(thread_id)
        if pending is None:
            return
        target, abandoned = pending
        assigned_same = []
        assigned_opposite = []
        for level, lit in abandoned:
            if assignment.is_true(lit):
                assigned_same.append((level, lit))
            elif assignment.is_false(lit):
                assigned_opposite.append((level, lit))
        if not assigned_opposite and not final:
            return
        self._pending_backjump.pop(thread_id, None)
        print("  Post-backjump state after propagation:")
        print(f"    abandoned decisions still assigned same phase: {len(assigned_same):,}")
        print(f"    abandoned decisions assigned opposite phase:   {len(assigned_opposite):,}")
        for _, old_lit in assigned_opposite[:10]:
            new_lit = -old_lit
            pred, phase, text = self._describe_decision(new_lit)
            try:
                level = assignment.level(new_lit)
                decision = assignment.decision(level) if level > 0 else None
                origin = "decision" if decision is not None and abs(decision) == abs(new_lit) else "propagated"
                detail = f"at L{level} ({origin})"
            except RuntimeError:
                detail = "(assignment level unavailable)"
            print(f"    {phase:<5} {pred:<28} {text} {detail}")
        if not assigned_opposite:
            print(f"    no abandoned decision had yet been forced opposite at target L{target}")
        sys.stdout.flush()

    def _trace_backjump(self, thread_id, target):
        history = self._decisions[thread_id]
        if not history:
            return
        source = max(history)
        span = source - target
        if span >= self._trace_backjumps:
            self._large_jump_count += 1
            abandoned = [(level, history[level]) for level in sorted(history)
                         if target < level <= source]
            current = {self._decision_identity(lit) for _, lit in abandoned}
            previous = self._last_abandoned[thread_id]
            counts = self._abandoned_counts[thread_id]
            repeated_previous = sum(key in previous for key in current)
            repeated_ever = sum(counts[key] > 0 for key in current)
            flipped_ever = sum(
                counts[(pred, "false" if phase == "true" else "true", text)] > 0
                for pred, phase, text in current
            )
            for key in current:
                counts[key] += 1
            self._last_abandoned[thread_id] = current

            elapsed = time.monotonic() - (self._trace_start_time or self._start_time)
            should_print = self._trace_count < self._trace_backjump_limit
            if not should_print:
                for old_level in [level for level in history if level > target]:
                    del history[old_level]
                return

            self._trace_count += 1
            kinds = Counter()
            for _, lit in abandoned:
                pred, phase, _ = self._describe_decision(lit)
                kinds[(pred, phase)] += 1

            print(f"\n=== BACKJUMP TRACE {self._trace_count} "
                  f"(large jump #{self._large_jump_count}, {elapsed:.1f}s): "
                  f"L{source} -> L{target} "
                  f"({span:,} levels; {len(abandoned):,} recorded decisions) ===")
            if previous or counts:
                total = max(1, len(current))
                print("  Repeated abandoned decisions:")
                print(f"    from previous large jump: {repeated_previous:>7,}/{len(current):,} "
                      f"({100.0 * repeated_previous / total:5.1f}%)")
                print(f"    from any earlier jump:    {repeated_ever:>7,}/{len(current):,} "
                      f"({100.0 * repeated_ever / total:5.1f}%)")
                print(f"    seen earlier opposite phase: {flipped_ever:>5,}")
            print("  Abandoned decision kinds:")
            for (pred, phase), count in kinds.most_common(15):
                print(f"    {pred:<32} {phase:<5} {count:>7,}")

            print("  Decisions around jump target:")
            for level in range(max(1, target - 2), min(source, target + 12) + 1):
                lit = history.get(level)
                if lit is None:
                    continue
                pred, phase, text = self._describe_decision(lit)
                marker = " <target" if level == target else ""
                print(f"    L{level:<6} {phase:<5} {pred:<28} {text}{marker}")

            print("  Last decisions before conflict:")
            for level, lit in abandoned[-12:]:
                pred, phase, text = self._describe_decision(lit)
                print(f"    L{level:<6} {phase:<5} {pred:<28} {text}")
            repeated = [(count, key) for key, count in counts.items() if count > 1]
            if repeated:
                print("  Most repeated abandoned decisions:")
                for count, (pred, phase, text) in sorted(repeated, reverse=True)[:10]:
                    print(f"    {count:>3} jumps  {phase:<5} {pred:<28} {text}")
            self._pending_backjump[thread_id] = (target, abandoned)
            sys.stdout.flush()

        for old_level in [level for level in history if level > target]:
            del history[old_level]

    def check(self, control):
        if self._after_first_model and not self._model_gate_open:
            self._model_gate_open = True
        if not self._maybe_activate(control):
            return
        if self._trace_backjumps:
            self._report_post_backjump(control.thread_id, control.assignment, final=True)
            self._capture_decisions(control.thread_id, control.assignment)

    # ------------------------------------------------------------------
    def reset_counts(self, label=None):
        self._undo_by_pred.clear()
        self._undo_by_atom.clear()
        self._level_by_pred.clear()
        self._total_undos = 0
        self._start_time = time.monotonic()
        self._last_report_time = self._start_time
        self._window_label = label or "reset"

    def _periodic_report(self, top_preds=15):
        T = max(self._total_undos, 1)
        elapsed = time.monotonic() - self._start_time
        print(f"\n--- Conflict Profile [{self._window_label}] @ {elapsed:.0f}s  "
              f"({self._total_undos:,} backtracks) ---")
        print(f"{'Predicate':<42} {'Backtracks':>12} {'%':>6}")
        for pred, cnt in self._undo_by_pred.most_common(top_preds):
            pct = 100.0 * cnt / T
            print(f"  {pred:<40} {cnt:>12,} {pct:>5.1f}%")
        sys.stdout.flush()

    def report(self, top_preds=25, top_atoms=15, title=None):
        if not self._active:
            waits = []
            if self._after_first_model and not self._model_gate_open:
                waits.append("first model")
            elapsed = time.monotonic() - self._start_time
            if elapsed < self._profile_after:
                waits.append(f"{self._profile_after:g}s delay")
            waiting_for = " and ".join(waits) or "activation callback"
            print(f"\n=== Conflict Profile not started (waiting for {waiting_for}) ===")
            return
        T = max(self._total_undos, 1)
        elapsed = time.monotonic() - self._start_time
        heading = title or f"Conflict Profile [{self._window_label}]"
        print(f"\n=== {heading}  ({self._total_undos:,} total backtracks; "
              f"{elapsed:.1f}s window; "
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
