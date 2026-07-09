#!/usr/bin/env python3
"""Convert a --introspect JSONL trace into a speedscope profile.

    uv run python scripts/introspect2speedscope.py TRACE.jsonl [-o OUT.json]

speedscope (https://www.speedscope.app/) is a flamegraph viewer built for
drill-down/ranking questions that scripts/viz_introspect.py's time-aligned
line charts don't answer well: "which predicate/decision path dominated?"

Emits one speedscope file with several profiles:

  - One real per-thread decision-stack flamegraph per solver thread, built
    from `stack` records (level 1..current, one predicate per level,
    snapshotted once per duty-cycle window directly from clingo's
    assignment via ffi.decision() -- see rust/src/inspector.rs). Each sample
    is the full ordered stack for that window; sample weight is the
    wall-clock gap since the thread's previous stack snapshot. This is a
    genuine nested profile, not a synthetic one.
  - Four flat, count-ranked "sampled" profiles (single-frame stacks) built
    from the existing `backtracks`/`decided`/`implied`/`true_now` per-window
    counter dicts on `sample` records: useful as a totals leaderboard, a
    different question than the decision-stack profiles answer.

Decision depth bands and anytime cost/lower-bound (`model`/`lb`/`final`) are
gauge/line-series data, not count- or stack-shaped, and stay out of scope
here -- see scripts/viz_introspect.py panels 1 and 4 for those.

speedscope's hosted app can't fetch a local file:// path (CORS), so this
script does not try to open a browser -- drag the output file onto
https://www.speedscope.app/, or use a local `npx speedscope` install.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import viz_introspect  # noqa: E402


class FrameTable:
    def __init__(self):
        self._index = {}
        self.names = []

    def get(self, name):
        i = self._index.get(name)
        if i is None:
            i = len(self.names)
            self._index[name] = i
            self.names.append(name)
        return i


def stack_profiles(stacks, frames):
    by_tid = {}
    for r in stacks:
        by_tid.setdefault(r["tid"], []).append(r)
    profiles = []
    for tid in sorted(by_tid):
        recs = sorted(by_tid[tid], key=lambda r: r["t"])
        samples = [[frames.get(p) for p in r["stack"]] for r in recs]
        weights = [0.0] + [round(recs[i]["t"] - recs[i - 1]["t"], 4) for i in range(1, len(recs))]
        profiles.append({
            "type": "sampled",
            "name": f"thread {tid} decision stack",
            "unit": "seconds",
            "startValue": 0,
            "endValue": round(sum(weights), 4),
            "samples": samples,
            "weights": weights,
        })
    return profiles


def counter_profile(name, samples, field, frames):
    stacks, weights = [], []
    for r in samples:
        counts = viz_introspect.by_predicate(r[field])
        for pred in sorted(counts):
            count = counts[pred]
            if count > 0:
                stacks.append([frames.get(pred)])
                weights.append(count)
    return {
        "type": "sampled",
        "name": name,
        "unit": "none",
        "startValue": 0,
        "endValue": sum(weights),
        "samples": stacks,
        "weights": weights,
    }


def build(recs, title):
    frames = FrameTable()
    profiles = stack_profiles(recs["stack"], frames)
    active = max(range(len(profiles)), key=lambda i: len(profiles[i]["samples"]), default=None)
    for name, field in (
        ("backtracks", "backtracks"), ("decided", "decided"),
        ("implied", "implied"), ("true_now (reward family levels)", "true_now"),
    ):
        profiles.append(counter_profile(name, recs["sample"], field, frames))
    return {
        "$schema": "https://www.speedscope.app/file-format-schema.json",
        "name": title,
        "activeProfileIndex": active if active is not None else 0,
        "exporter": "ooanalyzer-asp scripts/introspect2speedscope.py",
        "shared": {"frames": [{"name": n} for n in frames.names]},
        "profiles": profiles,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", help="JSONL trace from --introspect")
    ap.add_argument("-o", "--out", help="output speedscope JSON path (default: <trace>.speedscope.json)")
    ap.add_argument("--title", help="profile file title")
    args = ap.parse_args(argv)

    recs = viz_introspect.load(args.trace)
    if not recs["stack"] and not recs["sample"]:
        print(f"error: no stack/sample records in {args.trace}", file=sys.stderr)
        return 1
    out = args.out or str(Path(args.trace).with_suffix(".speedscope.json"))
    title = args.title or Path(args.trace).name
    doc = build(recs, title)
    with open(out, "w") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    n_stack, n_sample = len(recs["stack"]), len(recs["sample"])
    print(f"wrote {out}  ({len(doc['profiles'])} profiles, {n_stack} stack snapshots, {n_sample} sample windows)")
    print("open https://www.speedscope.app/ and drag in the file (or use a local `npx speedscope` install)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
