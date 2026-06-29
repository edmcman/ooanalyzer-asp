#!/usr/bin/env python3
"""Regression tests for the cross-repository edit-distance runner."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import edit_distance


METRICS = "398,35,24,56,10,20,29,3,118,0.29648,36,36"


class EditDistanceRunnerTests(unittest.TestCase):
    def test_discovery_is_sorted_and_reports_missing_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            results_root = root / "results"
            tests_root = root / "tests"
            testcases = tests_root / "code" / "testcases"

            for name in ("z/last.exe", "a/first.exe", "m/missing.exe"):
                path = results_root / f"{name}.results"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            for name in ("z/last.exe", "a/first.exe"):
                path = testcases / name
                path.parent.mkdir(parents=True, exist_ok=True)
                Path(f"{path}.ground").touch()
                Path(f"{path}.idaxrefs").touch()
                Path(f"{path}.results").touch()

            specimens, skipped = edit_distance.discover_specimens(
                results_root, tests_root
            )

            self.assertEqual([s.name for s in specimens], ["a/first.exe", "z/last.exe"])
            self.assertEqual([s.name for s in skipped], ["m/missing.exe"])
            self.assertEqual(skipped[0].missing, ("ground", "idaxrefs"))

    def test_parse_metrics_drops_relationship_fields(self) -> None:
        output = f"Action Move: 0x401000\n{METRICS}\n"
        self.assertEqual(
            edit_distance.parse_metrics(output),
            tuple(METRICS.split(",")[:10]),
        )

        with self.assertRaises(edit_distance.EditDistanceError):
            edit_distance.parse_metrics("not,a,valid,row\n")

    def test_run_specimen_uses_canonical_flags(self) -> None:
        specimen = edit_distance.Specimen(
            "sample.exe",
            Path("local.results"),
            Path("ooanalyzer.results"),
            Path("external.ground"),
            Path("external.idaxrefs"),
        )
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=f"{METRICS}\n", stderr="noisy diagnostics"
        )
        with patch.object(edit_distance.subprocess, "run", return_value=completed) as run:
            metrics = edit_distance.run_specimen(
                specimen, Path("analysis/edit-distance.py"), python="python-test"
            )

        self.assertEqual(metrics, tuple(METRICS.split(",")[:10]))
        self.assertEqual(
            run.call_args.args[0],
            [
                "python-test",
                "analysis/edit-distance.py",
                "--ignore-exceptions-pl",
                "--ignore-cdecl-exceptions",
                "--xrefs",
                "external.idaxrefs",
                "external.ground",
                "local.results",
            ],
        )

        with patch.object(
            edit_distance.subprocess, "run", return_value=completed
        ) as baseline_run:
            edit_distance.run_specimen(
                specimen,
                Path("analysis/edit-distance.py"),
                results=specimen.ooanalyzer_results,
                python="python-test",
            )
        self.assertEqual(baseline_run.call_args.args[0][-1], "ooanalyzer.results")

    def test_run_specimen_reports_subprocess_failure(self) -> None:
        specimen = edit_distance.Specimen(
            "sample.exe", Path("r"), Path("or"), Path("g"), Path("x")
        )
        completed = subprocess.CompletedProcess(
            args=[], returncode=7, stdout="", stderr="analysis failed"
        )
        with patch.object(edit_distance.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(
                edit_distance.EditDistanceError, "exited 7: analysis failed"
            ):
                edit_distance.run_specimen(specimen, Path("edit-distance.py"))

    def test_main_emits_csv_and_skip_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            results_root = root / "results"
            tests_root = root / "tests"
            analysis = tests_root / "analysis" / "edit-distance.py"
            testcases = tests_root / "code" / "testcases"
            analysis.parent.mkdir(parents=True)
            analysis.write_text(f"print({METRICS!r})\n")

            for name in ("b/two.exe", "a/one.exe", "c/skipped.exe"):
                results = results_root / f"{name}.results"
                results.parent.mkdir(parents=True, exist_ok=True)
                results.touch()
            for name in ("b/two.exe", "a/one.exe"):
                testcase = testcases / name
                testcase.parent.mkdir(parents=True, exist_ok=True)
                Path(f"{testcase}.ground").touch()
                Path(f"{testcase}.idaxrefs").touch()
                Path(f"{testcase}.results").touch()

            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = edit_distance.main(
                    [
                        "--tests-root",
                        str(tests_root),
                        "--results-root",
                        str(results_root),
                    ]
                )

            self.assertEqual(result, 0)
            rows = stdout.getvalue().splitlines()
            self.assertEqual(len(rows), 3)
            self.assertIn("asp_total_edit_distance", rows[0])
            self.assertIn("ooanalyzer_total_edit_distance", rows[0])
            self.assertIn("asp_minus_ooanalyzer_total_edit_distance", rows[0])
            self.assertTrue(rows[1].startswith("a/one.exe,"))
            self.assertTrue(rows[2].startswith("b/two.exe,"))
            self.assertTrue(rows[1].endswith(",0,0.00000"))
            self.assertIn("SKIP: c/skipped.exe", stderr.getvalue())
            self.assertIn("INFO: scored=2", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
