#!/usr/bin/env python3
"""Focused tests for delayed conflict-profiler activation."""

import unittest
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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


class ConflictProfilerTests(unittest.TestCase):
    def test_first_model_gate_defers_watches_and_omits_decide_callback(self):
        profiler = ConflictProfiler(after_first_model=True)
        callbacks = profiler.callbacks()
        init = FakeInit()

        callbacks.init(init)
        self.assertEqual(init.watches, [])
        self.assertFalse(hasattr(callbacks, "decide"))

        control = FakeControl()
        callbacks.check(control)
        self.assertCountEqual(control.watches, [7, -7])

    def test_trace_callbacks_keep_decide_hook(self):
        profiler = ConflictProfiler(trace_backjumps=10, after_first_model=True)
        self.assertIs(profiler.callbacks(), profiler)
        self.assertTrue(hasattr(profiler, "decide"))
        init = FakeInit()
        profiler.init(init)
        self.assertEqual(init.watches, [])
        control = FakeControl()
        profiler.check(control)
        self.assertCountEqual(control.watches, [7, -7])


if __name__ == "__main__":
    unittest.main()
