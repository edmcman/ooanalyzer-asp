#!/usr/bin/env python3
"""Focused tests for delayed conflict-profiler activation."""

import unittest
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from propagator import conflict_profiler
from propagator.conflict_profiler import ConflictProfiler


class FakeInit:
    def __init__(self):
        symbol = SimpleNamespace(name="mergeClasses")
        atom = SimpleNamespace(symbol=symbol, literal=7)
        self.symbolic_atoms = [atom]
        self.theory_atoms = []
        self.watches = []
        self.check_mode = None

    @staticmethod
    def solver_literal(literal):
        return literal

    def add_watch(self, literal):
        self.watches.append(literal)


class FakeControl:
    thread_id = 0

    def __init__(self):
        self.watches = []
        self.assignment = SimpleNamespace(decision_level=0)

    def add_watch(self, literal):
        self.watches.append(literal)

    def remove_watch(self, literal):
        self.watches.remove(literal)


class ConflictProfilerTests(unittest.TestCase):
    def test_first_model_gate_defers_counting_and_omits_decide_callback(self):
        profiler = ConflictProfiler(after_first_model=True)
        callbacks = profiler.callbacks()
        init = FakeInit()

        callbacks.init(init)
        self.assertCountEqual(init.watches, [7, -7])
        self.assertFalse(hasattr(callbacks, "decide"))
        self.assertFalse(profiler._active)

        control = FakeControl()
        callbacks.check(control)
        self.assertFalse(profiler._active)
        profiler.model_found()
        self.assertTrue(profiler._active)

    def test_trace_callbacks_keep_decide_hook(self):
        profiler = ConflictProfiler(trace_backjumps=10, after_first_model=True)
        self.assertIs(profiler.callbacks(), profiler)
        self.assertTrue(hasattr(profiler, "decide"))
        init = FakeInit()
        profiler.init(init)
        self.assertCountEqual(init.watches, [7, -7])
        self.assertFalse(profiler._active)
        profiler.model_found()
        self.assertTrue(profiler._active)

    def test_duty_cycle_toggles_watches_on_the_clock(self):
        clock = [0.0]
        with mock.patch.object(conflict_profiler.time, "monotonic", lambda: clock[0]):
            profiler = ConflictProfiler(profile_window=2, profile_period=10)
            self.assertTrue(profiler._duty_cycle)
            callbacks = profiler.callbacks()
            self.assertFalse(hasattr(callbacks, "decide"))

            init = FakeInit()
            callbacks.init(init)
            # Deferred: no watches at init, but the lit set is recorded.
            self.assertEqual(init.watches, [])
            self.assertEqual(init.check_mode, conflict_profiler.clingo.PropagatorCheckMode.Fixpoint)

            control = FakeControl()
            # t=0 inside the first window -> ON, watches installed.
            callbacks.check(control)
            self.assertCountEqual(control.watches, [7, -7])

            # t=5 outside the window -> OFF, watches removed.
            clock[0] = 5.0
            callbacks.check(control)
            self.assertEqual(control.watches, [])

            # t=10 back inside the window -> ON again.
            clock[0] = 10.0
            callbacks.check(control)
            self.assertCountEqual(control.watches, [7, -7])


if __name__ == "__main__":
    unittest.main()
