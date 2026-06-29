#!/usr/bin/env python3
"""Score local OOAnalyzer results against a separate ooanalyzer-tests checkout."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import sys
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS_ROOT = ROOT / "examples" / "ooa"
DEFAULT_TESTS_ROOT = Path(
    os.environ.get("OOANALYZER_TESTS", "~/ooanalyzer-tests")
).expanduser()

OUTPUT_FIELDS = (
    "num_methods",
    "num_classes",
    "virtual_classes",
    "move",
    "split",
    "join",
    "add",
    "remove",
    "total_edit_distance",
    "average_edit_distance",
)


class EditDistanceError(RuntimeError):
    """Raised when the legacy edit-distance tool cannot score a specimen."""


@dataclass(frozen=True)
class Specimen:
    name: str
    results: Path
    ooanalyzer_results: Path
    ground: Path
    xrefs: Path


@dataclass(frozen=True)
class SkippedSpecimen:
    name: str
    missing: tuple[str, ...]


def discover_specimens(
    results_root: Path, tests_root: Path
) -> tuple[list[Specimen], list[SkippedSpecimen]]:
    """Return scoreable and skipped result files in deterministic name order."""
    testcases_root = tests_root / "code" / "testcases"
    specimens: list[Specimen] = []
    skipped: list[SkippedSpecimen] = []

    for results in sorted(results_root.rglob("*.results")):
        relative = results.relative_to(results_root)
        name = relative.as_posix()[: -len(".results")]
        testcase = testcases_root / name
        ground = Path(f"{testcase}.ground")
        xrefs = Path(f"{testcase}.idaxrefs")
        ooanalyzer_results = Path(f"{testcase}.results")
        missing = tuple(
            label
            for label, path in (("ground", ground), ("idaxrefs", xrefs))
            if not path.is_file()
        )
        if missing:
            skipped.append(SkippedSpecimen(name, missing))
        elif not ooanalyzer_results.is_file():
            skipped.append(SkippedSpecimen(name, ("ooanalyzer results",)))
        else:
            specimens.append(
                Specimen(name, results, ooanalyzer_results, ground, xrefs)
            )

    return specimens, skipped


def parse_metrics(output: str) -> tuple[str, ...]:
    """Parse the legacy tool's final CSV line and retain class metrics only."""
    lines = [line for line in output.splitlines() if line.strip()]
    if not lines:
        raise EditDistanceError("edit-distance tool produced no output")

    row = next(csv.reader([lines[-1]]))
    if len(row) != 12:
        raise EditDistanceError(
            f"expected 12 values in final CSV line, received {len(row)}"
        )

    try:
        for value in row[:9]:
            int(value)
        float(row[9])
    except ValueError as exc:
        raise EditDistanceError(f"invalid final CSV line: {lines[-1]!r}") from exc

    # The final two relation fields are intentionally excluded. The legacy parser
    # does not recognize the current five-field finalInheritance output shape.
    return tuple(row[:10])


def run_specimen(
    specimen: Specimen,
    analysis_script: Path,
    *,
    results: Path | None = None,
    python: str = sys.executable,
) -> tuple[str, ...]:
    results = specimen.results if results is None else results
    command = [
        python,
        str(analysis_script),
        "--ignore-exceptions-pl",
        "--ignore-cdecl-exceptions",
        "--xrefs",
        str(specimen.xrefs),
        str(specimen.ground),
        str(results),
    ]
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "no details"
        raise EditDistanceError(
            f"edit-distance tool exited {completed.returncode}: {detail}"
        )
    return parse_metrics(completed.stdout)


def git_state(tests_root: Path) -> tuple[str, bool] | None:
    """Return the external repository's commit and worktree dirty state."""
    revision = subprocess.run(
        ["git", "-C", str(tests_root), "rev-parse", "--short=12", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if revision.returncode != 0:
        return None

    status = subprocess.run(
        [
            "git",
            "-C",
            str(tests_root),
            "status",
            "--porcelain",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    dirty = status.returncode != 0 or bool(status.stdout.strip())
    return revision.stdout.strip(), dirty


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Score local .results files with analysis/edit-distance.py from an "
            "ooanalyzer-tests checkout."
        )
    )
    parser.add_argument(
        "--tests-root",
        type=Path,
        default=DEFAULT_TESTS_ROOT,
        help="ooanalyzer-tests checkout (default: %(default)s)",
    )
    parser.add_argument(
        "--results-root",
        type=Path,
        default=DEFAULT_RESULTS_ROOT,
        help="root containing local .results files (default: %(default)s)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    tests_root = args.tests_root.expanduser().resolve()
    results_root = args.results_root.expanduser().resolve()
    analysis_script = tests_root / "analysis" / "edit-distance.py"

    if not results_root.is_dir():
        print(f"ERROR: results root does not exist: {results_root}", file=sys.stderr)
        return 2
    if not analysis_script.is_file():
        print(
            f"ERROR: edit-distance tool does not exist: {analysis_script}",
            file=sys.stderr,
        )
        return 2

    state = git_state(tests_root)
    if state is None:
        print("INFO: ooanalyzer-tests revision=unknown", file=sys.stderr)
    else:
        revision, dirty = state
        print(
            f"INFO: ooanalyzer-tests revision={revision} dirty={'yes' if dirty else 'no'}",
            file=sys.stderr,
        )

    specimens, skipped = discover_specimens(results_root, tests_root)
    total = len(specimens) + len(skipped)
    print(
        f"INFO: discovered={total} scoreable={len(specimens)} skipped={len(skipped)}",
        file=sys.stderr,
    )
    for item in skipped:
        print(
            f"SKIP: {item.name} (missing {', '.join(item.missing)})",
            file=sys.stderr,
        )
    print(
        "INFO: relationship metrics omitted (legacy parser/current "
        "finalInheritance format mismatch)",
        file=sys.stderr,
    )

    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(
        (
            "specimen",
            *(f"asp_{field}" for field in OUTPUT_FIELDS),
            *(f"ooanalyzer_{field}" for field in OUTPUT_FIELDS),
            "asp_minus_ooanalyzer_total_edit_distance",
            "asp_minus_ooanalyzer_average_edit_distance",
        )
    )

    failures = 0
    for specimen in specimens:
        try:
            asp_metrics = run_specimen(specimen, analysis_script)
            ooanalyzer_metrics = run_specimen(
                specimen,
                analysis_script,
                results=specimen.ooanalyzer_results,
            )
        except EditDistanceError as exc:
            failures += 1
            print(f"ERROR: {specimen.name}: {exc}", file=sys.stderr)
            continue
        total_delta = int(asp_metrics[8]) - int(ooanalyzer_metrics[8])
        average_delta = float(asp_metrics[9]) - float(ooanalyzer_metrics[9])
        writer.writerow(
            (
                specimen.name,
                *asp_metrics,
                *ooanalyzer_metrics,
                total_delta,
                f"{average_delta:.5f}",
            )
        )

    if not specimens:
        print("ERROR: no scoreable specimens found", file=sys.stderr)
        return 1
    if failures:
        print(f"ERROR: failed={failures}", file=sys.stderr)
        return 1

    print(f"INFO: scored={len(specimens)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
