#!/usr/bin/env python3
"""Render a --introspect JSONL trace into an interactive HTML dashboard.

    uv run python scripts/viz_introspect.py TRACE.jsonl [-o OUT.html] [--no-open]

Four stacked, time-aligned panels tell the plateau story
(`.state/merge-optimization-blocker.md`):

  1. Anytime cost gap (comp2): incumbent upper bound vs USC lower bound.
  2. Reward-family selection over time: currently-true reward atoms per family
     (which pools fill early vs which stall / get abandoned).
  3. Backtracks by family, as a rate at the times they occur (decision anatomy;
     is the churn on `merge` or elsewhere?).
  4. Decision depth (min-mean-max band) with restart events.

Records consumed: meta, model, lb, sample, final (see propagator/introspect.py).
"""

import argparse
import json
import sys
import webbrowser
from pathlib import Path

import plotly.graph_objects as go
from plotly.subplots import make_subplots

# Validated categorical palette (dataviz skill, light surface #fcfcfb), assigned
# in fixed order per family. merge -> red: it is the churn villain.
FAMILY_COLOR = {
    "method": "#2a78d6",       # blue
    "ctor": "#1baf7a",         # aqua
    "strong_merge": "#008300", # green
    "weak_merge": "#4a3aa7",   # violet
    "weak_g1": "#e87ba4",      # magenta
    "late_f2": "#eb6834",      # orange
    "composition": "#e34948",  # red
    "merge": "#e34948",        # red (decision family)
    "vftable": "#eda100",      # yellow
}
REWARD_FAMILIES = ["method", "ctor", "strong_merge", "weak_merge",
                   "weak_g1", "late_f2", "composition"]
DECISION_FAMILIES = ["merge", "method", "ctor", "vftable"]
SURFACE = "#fcfcfb"
GRID = "#e7e7e3"
INK = "#0b0b0b"


def load(path):
    recs = {"meta": None, "final": None, "model": [], "lb": [], "sample": []}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            k = r["kind"]
            if k in ("meta", "final"):
                recs[k] = r
            elif k in recs:
                recs[k].append(r)
    return recs


def bursts(samples, gap):
    """Group consecutive samples into duty-cycle bursts (split on idle gaps)."""
    group, prev_t = [], None
    for s in samples:
        if prev_t is not None and s["t"] - prev_t > gap and group:
            yield group
            group = []
        group.append(s)
        prev_t = s["t"]
    if group:
        yield group


def sum_fam(records, field):
    total = {}
    for r in records:
        for k, v in r[field].items():
            total[k] = total.get(k, 0) + v
    return total


def aggregate(samples, gap):
    """Collapse each 0.5s burst of 50ms samples into ONE point so the timeline
    reads as a clean line instead of a comb of vertical spikes. Backtracks/
    assignments become a per-burst rate (still 'over time', at burst cadence);
    true_now is the burst mean; depth keeps min/mean/max envelope."""
    out = []
    for b in bursts(samples, gap):
        t0, t1 = b[0]["t"], b[-1]["t"]
        dur = sum(s["dt"] for s in b) or 1e-6
        bt = sum_fam(b, "backtracks")
        asg = sum_fam(b, "assigned")
        tn = {}
        for s in b:
            for k, v in s["true_now"].items():
                tn.setdefault(k, []).append(v)
        out.append({
            "t": round((t0 + t1) / 2, 3),
            "bt_rate": {k: round(v / dur) for k, v in bt.items()},
            "asg_rate": {k: round(v / dur) for k, v in asg.items()},
            "true_now": {k: round(sum(vs) / len(vs)) for k, vs in tn.items()},
            "depth_min": min(s["depth"]["min"] for s in b),
            "depth_mean": round(sum(s["depth"]["mean"] for s in b) / len(b)),
            "depth_max": max(s["depth"]["max"] for s in b),
        })
    return out


def build(recs, title):
    samples = recs["sample"]
    models = recs["model"]
    final = recs["final"]
    ground_t = recs["meta"]["ground_time"] if recs["meta"] else None
    # burst-gap threshold: a couple of sample intervals
    dts = [s["dt"] for s in samples if s.get("dt")]
    gap = 4 * (sorted(dts)[len(dts) // 2] if dts else 0.05)

    agg = aggregate(samples, gap)
    at = [a["t"] for a in agg]

    fig = make_subplots(
        rows=4, cols=1, shared_xaxes=True, vertical_spacing=0.055,
        subplot_titles=(
            "Anytime cost: incumbent vs lower bound (comp1 = vftable size, comp2 = merge/reward)",
            "Reward-family selection over time (currently-true reward atoms, per burst)",
            "Backtracks by family — rate per burst over time",
            "Decision depth (min / mean / max)",
        ),
    )

    # -- Panel 1: anytime cost, both components -----------------------
    def cost_series(idx):
        mt = [m["t"] for m in models]
        my = [m["cost"][idx] if len(m["cost"]) > idx else None for m in models]
        if final and final.get("cost") and len(final["cost"]) > idx:
            mt, my = mt + [final["t"]], my + [final["cost"][idx]]
        return mt, my

    fcost = (final or {}).get("cost")
    ncomp = len(models[0]["cost"]) if models else (len(fcost) if fcost else 0)
    if ncomp >= 2:
        comp_defs = [(0, "comp1 (UB)", "#1baf7a"), (1, "comp2 (UB)", "#2a78d6")]
    elif ncomp == 1:
        comp_defs = [(0, "cost (UB)", "#2a78d6")]
    else:
        comp_defs = []
    for idx, name, color in comp_defs:
        mt, my = cost_series(idx)
        if any(v is not None for v in my):
            fig.add_trace(go.Scatter(x=mt, y=my, name=name, legendgroup="gap",
                                     mode="lines+markers", marker=dict(size=7),
                                     line=dict(color=color, width=2, shape="hv")),
                          row=1, col=1)
    # Lower bound: clingo exposes statistics only post-solve, so summary.lower is
    # a single end-of-run scalar -> draw it as a reference line = the unclosed gap.
    lower = (final or {}).get("stats", {}).get("lower")
    for idx, name, color in comp_defs:
        if lower and len(lower) > idx:
            fig.add_trace(go.Scatter(
                x=[0, final["t"]], y=[lower[idx]] * 2, name=name.replace("UB", "LB"),
                legendgroup="gap", mode="lines",
                line=dict(color=color, width=1.5, dash="dash")), row=1, col=1)

    # -- Panel 2: reward-family selection (burst-mean true_now) -------
    for fam in REWARD_FAMILIES:
        ys = [a["true_now"].get(fam, 0) for a in agg]
        if any(ys):
            fig.add_trace(go.Scatter(
                x=at, y=ys, name=fam, legendgroup="reward",
                mode="lines+markers", marker=dict(size=4),
                line=dict(color=FAMILY_COLOR[fam], width=2)), row=2, col=1)

    # -- Panel 3: backtracks by family (per-burst rate) --------------
    for fam in DECISION_FAMILIES:
        ys = [a["bt_rate"].get(fam, 0) for a in agg]
        if any(ys):
            fig.add_trace(go.Scatter(
                x=at, y=ys, name=f"{fam} bt/s", legendgroup="bt",
                mode="lines+markers", marker=dict(size=4),
                line=dict(color=FAMILY_COLOR[fam], width=2)), row=3, col=1)

    # -- Panel 4: decision depth band + restarts ---------------------
    fig.add_trace(go.Scatter(x=at, y=[a["depth_max"] for a in agg],
                             mode="lines", line=dict(width=0, color="#6da7ec"),
                             hoverinfo="skip", showlegend=False), row=4, col=1)
    fig.add_trace(go.Scatter(x=at, y=[a["depth_min"] for a in agg],
                             name="depth min–max", legendgroup="depth",
                             mode="lines", line=dict(width=0, color="#6da7ec"),
                             fill="tonexty", fillcolor="rgba(109,167,236,0.30)"),
                  row=4, col=1)
    fig.add_trace(go.Scatter(x=at, y=[a["depth_mean"] for a in agg],
                             name="depth mean", legendgroup="depth", mode="lines",
                             line=dict(color="#184f95", width=2)), row=4, col=1)

    # Final post-solve scalars (the only exact statistics clingo exposes).
    st = (final or {}).get("stats", {})
    bits = []
    if models and st.get("lower") and len(st["lower"]) >= ncomp >= 1:
        ub, lb = models[-1]["cost"][-1], st["lower"][-1]
        bits.append(f"comp2 gap {ub}→{lb} ({abs(ub - lb):,})")
    for k in ("restarts", "conflicts", "choices"):
        if k in st:
            bits.append(f"{k} {st[k]:,}")
    if bits:
        fig.add_annotation(text="final:  " + "   ".join(bits), xref="paper",
                           yref="paper", x=0, y=1.045, showarrow=False,
                           font=dict(size=12, color="#52514e"), align="left")

    # -- shared annotations: grounding + incumbent markers -----------
    for m in models:
        fig.add_vline(x=m["t"], line=dict(color="#b0b0aa", width=1, dash="dot"))
    if ground_t is not None:
        fig.add_vline(x=ground_t, line=dict(color="#1baf7a", width=1, dash="dash"),
                      annotation_text="ground", annotation_position="top")

    fig.update_layout(
        title=title, template="plotly_white",
        paper_bgcolor=SURFACE, plot_bgcolor=SURFACE, font=dict(color=INK),
        height=1150, hovermode="x unified",
        legend=dict(groupclick="toggleitem", tracegroupgap=16,
                    yanchor="top", y=1, xanchor="left", x=1.005),
        margin=dict(t=90, l=70, r=200, b=50),
    )
    fig.update_xaxes(gridcolor=GRID, zeroline=False)
    fig.update_yaxes(gridcolor=GRID, zeroline=False)
    fig.update_xaxes(title_text="solve time (s)", row=4, col=1)
    fig.update_yaxes(title_text="cost", row=1, col=1)
    fig.update_yaxes(title_text="# atoms true", row=2, col=1)
    fig.update_yaxes(title_text="backtracks / s", row=3, col=1)
    fig.update_yaxes(title_text="decision level", row=4, col=1)
    return fig


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", help="JSONL trace from --introspect")
    ap.add_argument("-o", "--out", help="output HTML path (default: <trace>.html)")
    ap.add_argument("--title", help="dashboard title")
    ap.add_argument("--no-open", action="store_true", help="do not open a browser")
    args = ap.parse_args(argv)

    recs = load(args.trace)
    if not recs["sample"] and not recs["model"]:
        print(f"error: no sample/model records in {args.trace}", file=sys.stderr)
        return 1
    out = args.out or str(Path(args.trace).with_suffix(".html"))
    title = args.title or f"Solver introspection — {Path(args.trace).name}"
    fig = build(recs, title)
    fig.write_html(out, include_plotlyjs=True, full_html=True)
    n_s, n_m = len(recs["sample"]), len(recs["model"])
    print(f"wrote {out}  ({n_s} samples, {n_m} incumbents)")
    if not args.no_open:
        webbrowser.open(f"file://{Path(out).resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
