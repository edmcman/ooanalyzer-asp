#!/usr/bin/env python3
"""Aggregate precomputed .editdist scores into an ASP-vs-OOAnalyzer comparison CSV.

The metrics themselves are produced by analysis/edit-distance.py and cached as
`.editdist` files (whose final line is the metrics CSV):

* ASP side — local ``<results-root>/<name>.editdist`` written by ``make editdist``
* OOAnalyzer side — ``<tests-root>/code/testcases/<name>.editdist`` shipped in the
  ooanalyzer-tests checkout

This script no longer runs the legacy tool; it only parses those files. Run
``make editdist`` (or ``make edit-distance``, which depends on it) first.
"""

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
    """Raised when an .editdist file cannot be parsed."""


@dataclass(frozen=True)
class Specimen:
    name: str
    asp_editdist: Path
    ooanalyzer_editdist: Path


@dataclass(frozen=True)
class SkippedSpecimen:
    name: str
    missing: tuple[str, ...]


def discover_specimens(
    results_root: Path, tests_root: Path
) -> tuple[list[Specimen], list[SkippedSpecimen]]:
    """Return scoreable and skipped specimens in deterministic name order.

    A specimen is scoreable when ground truth exists in the tests checkout AND
    both the ASP and OOAnalyzer ``.editdist`` files are present.
    """
    testcases_root = tests_root / "code" / "testcases"
    specimens: list[Specimen] = []
    skipped: list[SkippedSpecimen] = []

    for results in sorted(results_root.rglob("*.results")):
        relative = results.relative_to(results_root)
        name = relative.as_posix()[: -len(".results")]
        testcase = testcases_root / name
        asp_editdist = results.with_suffix(".editdist")
        ooanalyzer_editdist = Path(f"{testcase}.editdist")

        # Ground truth gates scoreability at all; report it before the derived
        # .editdist outputs so synthetic specimens read as "missing ground".
        ungrounded = tuple(
            label
            for label, path in (
                ("ground", Path(f"{testcase}.ground")),
                ("idaxrefs", Path(f"{testcase}.idaxrefs")),
            )
            if not path.is_file()
        )
        if ungrounded:
            skipped.append(SkippedSpecimen(name, ungrounded))
            continue

        unscored = tuple(
            label
            for label, path in (
                ("ooanalyzer editdist", ooanalyzer_editdist),
                ("asp editdist (run make editdist)", asp_editdist),
            )
            if not path.is_file()
        )
        if unscored:
            skipped.append(SkippedSpecimen(name, unscored))
        else:
            specimens.append(Specimen(name, asp_editdist, ooanalyzer_editdist))

    return specimens, skipped


def parse_metrics(output: str) -> tuple[str, ...]:
    """Parse an .editdist file's final CSV line and retain class metrics only."""
    lines = [line for line in output.splitlines() if line.strip()]
    if not lines:
        raise EditDistanceError("editdist file is empty")

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


def read_metrics(editdist: Path) -> tuple[str, ...]:
    """Parse the cached metrics from a single .editdist file."""
    try:
        text = editdist.read_text()
    except OSError as exc:
        raise EditDistanceError(f"cannot read {editdist}: {exc}") from exc
    try:
        return parse_metrics(text)
    except EditDistanceError as exc:
        raise EditDistanceError(f"{editdist}: {exc}") from exc


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
            "Aggregate cached .editdist scores (from make editdist and the "
            "ooanalyzer-tests checkout) into an ASP-vs-OOAnalyzer comparison CSV."
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
        help="root containing local .results/.editdist files (default: %(default)s)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    tests_root = args.tests_root.expanduser().resolve()
    results_root = args.results_root.expanduser().resolve()

    if not results_root.is_dir():
        print(f"ERROR: results root does not exist: {results_root}", file=sys.stderr)
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
            asp_metrics = read_metrics(specimen.asp_editdist)
            ooanalyzer_metrics = read_metrics(specimen.ooanalyzer_editdist)
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
