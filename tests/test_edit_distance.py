#!/usr/bin/env python3
"""Regression tests for the cross-repository edit-distance aggregator."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import edit_distance


METRICS = "398,35,24,56,10,20,29,3,118,0.29648,36,36"


def _write_specimen(
    results_root: Path,
    testcases: Path,
    name: str,
    *,
    asp: str | None = METRICS,
    ooanalyzer: str | None = METRICS,
) -> None:
    """Lay down a local .results plus optional ASP and baseline .editdist files."""
    results = results_root / f"{name}.results"
    results.parent.mkdir(parents=True, exist_ok=True)
    results.touch()

    testcase = testcases / name
    testcase.parent.mkdir(parents=True, exist_ok=True)
    Path(f"{testcase}.ground").touch()
    Path(f"{testcase}.idaxrefs").touch()
    if asp is not None:
        results.with_suffix(".editdist").write_text(f"Action Move: 0x401000\n{asp}\n")
    if ooanalyzer is not None:
        Path(f"{testcase}.editdist").write_text(f"Action Move: 0x401000\n{ooanalyzer}\n")


class EditDistanceAggregatorTests(unittest.TestCase):
    def test_discovery_is_sorted_and_classifies_missing_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            results_root = root / "results"
            tests_root = root / "tests"
            testcases = tests_root / "code" / "testcases"

            _write_specimen(results_root, testcases, "z/last.exe")
            _write_specimen(results_root, testcases, "a/first.exe")
            # Synthetic specimen: solved locally but no ground truth.
            ungrounded = results_root / "m/ungrounded.exe.results"
            ungrounded.parent.mkdir(parents=True, exist_ok=True)
            ungrounded.touch()
            # Grounded but ASP side not yet scored by `make editdist`.
            _write_specimen(results_root, testcases, "u/unscored.exe", asp=None)

            specimens, skipped = edit_distance.discover_specimens(
                results_root, tests_root
            )

            self.assertEqual([s.name for s in specimens], ["a/first.exe", "z/last.exe"])
            by_name = {s.name: s.missing for s in skipped}
            self.assertEqual(by_name["m/ungrounded.exe"], ("ground", "idaxrefs"))
            self.assertEqual(
                by_name["u/unscored.exe"], ("asp editdist (run make editdist)",)
            )

    def test_parse_metrics_drops_relationship_fields(self) -> None:
        output = f"Action Move: 0x401000\n{METRICS}\n"
        self.assertEqual(
            edit_distance.parse_metrics(output),
            tuple(METRICS.split(",")[:10]),
        )

        with self.assertRaises(edit_distance.EditDistanceError):
            edit_distance.parse_metrics("not,a,valid,row\n")

    def test_read_metrics_parses_final_line_and_reports_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            good = Path(temp) / "good.editdist"
            good.write_text(f"noise\n{METRICS}\n")
            self.assertEqual(
                edit_distance.read_metrics(good), tuple(METRICS.split(",")[:10])
            )

            bad = Path(temp) / "bad.editdist"
            bad.write_text("not,a,valid,row\n")
            with self.assertRaisesRegex(
                edit_distance.EditDistanceError, r"bad\.editdist:"
            ):
                edit_distance.read_metrics(bad)

            with self.assertRaisesRegex(edit_distance.EditDistanceError, "cannot read"):
                edit_distance.read_metrics(Path(temp) / "missing.editdist")

    def test_main_emits_csv_and_skip_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            results_root = root / "results"
            tests_root = root / "tests"
            testcases = tests_root / "code" / "testcases"

            asp = "398,35,24,56,10,20,29,3,118,0.29648,36,36"
            ooa = "398,35,24,50,10,20,29,3,112,0.28141,36,36"
            _write_specimen(results_root, testcases, "b/two.exe", asp=asp, ooanalyzer=ooa)
            _write_specimen(results_root, testcases, "a/one.exe", asp=ooa, ooanalyzer=ooa)
            # Ungrounded synthetic specimen → skipped.
            skipped_results = results_root / "c/skipped.exe.results"
            skipped_results.parent.mkdir(parents=True, exist_ok=True)
            skipped_results.touch()

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
            # a/one matches the baseline exactly → zero delta.
            self.assertTrue(rows[1].endswith(",0,0.00000"))
            # b/two is 118 vs 112 total, 0.29648 vs 0.28141 average.
            self.assertTrue(rows[2].endswith(",6,0.01507"))
            self.assertIn("SKIP: c/skipped.exe", stderr.getvalue())
            self.assertIn("INFO: scored=2", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
