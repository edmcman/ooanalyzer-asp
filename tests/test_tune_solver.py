#!/usr/bin/env python3
"""Focused tests for the OOAnalyzer hyperparameter tuner."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import tune_solver as tune


class SolverTunerTests(unittest.TestCase):
    def test_duration_and_list_parsers(self) -> None:
        self.assertEqual(tune.parse_duration("24h"), 86400)
        self.assertEqual(tune.parse_duration("30m"), 1800)
        self.assertEqual(tune.parse_int_list("1, 2,3"), (1, 2, 3))
        self.assertEqual(tune.parse_float_list("1,3,5"), (1.0, 3.0, 5.0))
        with self.assertRaises(Exception):
            tune.parse_float_list("3,1")

    def test_default_checkpoints_scale_with_trial_time_limit(self) -> None:
        self.assertEqual(
            tune.default_checkpoints(1800),
            (300.0, 600.0, 1200.0, 1800.0),
        )
        self.assertEqual(
            tune.default_checkpoints(90),
            (15.0, 30.0, 60.0, 90.0),
        )
        args = tune.build_parser().parse_args(
            [
                "study",
                "--input",
                str(tune.ROOT / "examples/manual/example.lp"),
                "--trial-time-limit",
                "90",
            ]
        )
        tune.validate_args(args)
        self.assertEqual(args.checkpoints, (15.0, 30.0, 60.0, 90.0))

    def test_explicit_checkpoints_override_scaled_defaults(self) -> None:
        parser = tune.build_parser()
        args = parser.parse_args(
            [
                "study",
                "--input",
                str(tune.ROOT / "examples/manual/example.lp"),
                "--trial-time-limit",
                "90",
                "--checkpoints",
                "10,90",
            ]
        )
        tune.validate_args(args)
        self.assertEqual(args.checkpoints, (10.0, 90.0))

    def test_model_line_parser_accepts_first_and_later_models(self) -> None:
        self.assertEqual(
            tune.parse_model_line("12:00:00 Model found (98.60s): [-704, -44778]"),
            (98.6, (-704, -44778)),
        )
        self.assertEqual(
            tune.parse_model_line("12:00:02 Model found (100.25s, +1.65s): [-704, -44800]"),
            (100.25, (-704, -44800)),
        )
        self.assertIsNone(tune.parse_model_line("Grounding done (8.19s)"))

    def test_scalarization_preserves_lexicographic_order(self) -> None:
        costs = [(-703, -999999), (-704, -44000), (-704, -45000)]
        self.assertEqual(sorted(costs), sorted(costs, key=tune.scalarize_cost))
        self.assertLess(tune.scalarize_cost((-704, -44000)), tune.scalarize_cost((-703, -999999)))
        self.assertEqual(tune.scalarize_cost(None), tune.NO_MODEL_SCORE)
        with self.assertRaisesRegex(ValueError, "two OOAnalyzer objective levels"):
            tune.scalarize_cost((-704,))

    def test_checkpoint_and_seed_aggregation(self) -> None:
        results = [
            tune.SeedResult(1, [], "", [tune.ModelEvent(10, (-704, -44000))]),
            tune.SeedResult(2, [], "", [tune.ModelEvent(20, (-704, -45000))]),
            tune.SeedResult(3, [], "", []),
        ]
        costs_at_15 = [tune.incumbent_at(result.events, 15) for result in results]
        self.assertEqual(costs_at_15, [(-704, -44000), None, None])
        costs_at_30 = [tune.incumbent_at(result.events, 30) for result in results]
        self.assertEqual(tune.median_cost(costs_at_30), (-704, -44000))
        self.assertEqual(
            tune.aggregate_score(costs_at_30), tune.scalarize_cost((-704, -44000))
        )

    def test_baseline_keeps_single_thread_and_objective_weights_fixed(self) -> None:
        args = tune.baseline_args()
        joined = " ".join(args)
        self.assertIn("--opt-strategy=bb,lin", args)
        self.assertIn("--parallel-mode=1", args)
        self.assertIn("--decide-inputs", args)
        self.assertNotIn("reward_weight", joined)
        self.assertEqual(tune.solver_threads_from_args(args), 1)

    def test_conditional_arguments_are_rendered(self) -> None:
        params = dict(tune.BASELINE_PARAMS)
        params.pop("bb_tactic")
        params.update(
            {
                "parallel_threads": 4,
                "parallel_mode": "split",
                "opt_strategy": "usc",
                "usc_relax": "oll",
                "usc_disjoint": 0,
                "usc_succinct": 0,
                "usc_stratify": 1,
                "usc_shrink": "min",
                "usc_shrink_limit": 12,
                "rand_enabled": 1,
                "rand_freq": 0.001,
                "weak_merge_input_phase": 1,
                "weak_merge_after_vftable_complete": 1,
            }
        )
        args = tune.parameters_to_args(params)
        self.assertIn("--parallel-mode=4,split", args)
        self.assertEqual(tune.solver_threads_from_args(args), 4)
        self.assertIn("--opt-strategy=usc,oll,stratify", args)
        self.assertIn("--opt-usc-shrink=min,12", args)
        self.assertIn("--rand-freq=0.001", args)
        self.assertIn("weak_merge_after_vftable_complete=1", args)

    def test_search_space_never_emits_known_invalid_save_progress_flag(self) -> None:
        params = dict(tune.BASELINE_PARAMS)
        params["save_progress"] = 20
        args = tune.parameters_to_args(params)
        self.assertIn("--save-progress=20", args)
        self.assertNotIn("--no-save-progress", args)

    def test_numeric_restart_and_heuristic_parameters_are_rendered(self) -> None:
        params = dict(tune.BASELINE_PARAMS)
        params.update(
            {
                "heuristic": "Vsids",
                "vsids_decay": 93,
                "restart_policy": "x",
                "restart_base": 256,
                "restart_factor": 1.25,
            }
        )
        args = tune.parameters_to_args(params)
        self.assertIn("--heuristic=Vsids,93", args)
        self.assertIn("--restarts=x,256,1.25", args)

    def test_cpu_budget_serializes_oversubscribed_reservations(self) -> None:
        budget = tune.CpuBudget(4)
        with budget.reserve(3) as reserved:
            self.assertEqual(reserved, 3)
            self.assertEqual(budget.available, 1)
        self.assertEqual(budget.available, 4)

    def test_study_uses_median_percentile_pruner(self) -> None:
        pruner = tune.create_pruner()
        self.assertIsInstance(pruner, tune.optuna.pruners.PercentilePruner)
        self.assertNotIsInstance(pruner, tune.optuna.pruners.PatientPruner)

    def test_pruner_skips_first_checkpoint_and_prunes_no_model_at_median(self) -> None:
        study = tune.optuna.create_study(direction="minimize", pruner=tune.create_pruner())
        for index in range(24):
            final = tune.scalarize_cost((-704, -44000 - index))
            at_200 = final if index < 8 else tune.NO_MODEL_SCORE
            at_400 = final if index < 13 else tune.NO_MODEL_SCORE
            study.add_trial(
                tune.optuna.trial.create_trial(
                    value=float(final),
                    intermediate_values={
                        0: float(tune.NO_MODEL_SCORE),
                        1: float(at_200),
                        2: float(at_400),
                    },
                )
            )

        trial = study.ask()
        trial.report(float(tune.NO_MODEL_SCORE), 0)
        self.assertFalse(trial.should_prune())
        trial.report(float(tune.NO_MODEL_SCORE), 1)
        self.assertFalse(trial.should_prune())
        trial.report(float(tune.NO_MODEL_SCORE), 2)
        self.assertTrue(trial.should_prune())

    def test_finalists_exclude_duplicate_baseline_arguments(self) -> None:
        class Trial:
            def __init__(self, number, value, args):
                self.number = number
                self.value = value
                self.state = tune.optuna.trial.TrialState.COMPLETE
                self.params = {}
                self.user_attrs = {
                    "solver_args": args,
                    "anytime_score": value,
                    "worst_score": value,
                }

        class Study:
            trials = [
                Trial(0, 0, tune.baseline_args()),
                Trial(1, 1, ["--heuristic=Vsids"]),
            ]

        finalists = tune.unique_finalists(
            Study(), 1, excluded_args=(tune.baseline_args(),)
        )
        self.assertEqual(finalists[0]["trial"], 1)

    def test_default_output_uses_input_name_and_not_autoresearch(self) -> None:
        output = tune.default_output_dir(Path("some program.exe.lp"))
        self.assertEqual(output.parent, tune.ROOT / ".state" / "hyperopt")
        self.assertTrue(output.name.startswith("some-program.exe-"))


if __name__ == "__main__":
    unittest.main()
