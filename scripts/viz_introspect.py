#!/usr/bin/env python3
"""Render a --introspect JSONL trace into an interactive HTML dashboard.

    uv run python scripts/viz_introspect.py TRACE.jsonl [-o OUT.html] [--no-open]

Six stacked, time-aligned panels tell the plateau story
(`.state/merge-optimization-blocker.md`):

  1. Anytime cost gap (comp2): incumbent upper bound vs USC lower bound.
  2. Reward-family selection over time: currently-true reward atoms per family
     (which pools fill early vs which stall / get abandoned).
  3. Backtracks by family, as a rate at the times they occur (decision anatomy;
     is the churn on `merge` or elsewhere?).
  4. Decision depth (min-mean-max band) with restart events.
  5. The percentage distribution of direct symbolic decisions by predicate.
  6. The corresponding distribution of propagation-implied assignments.

Records consumed: meta, model, lb, sample, final (emitted by the native Rust
inspector in `rust/src/inspector.rs`). `load()` also collects `stack` records
(one real decision-stack snapshot per duty-cycle window per thread) for
`scripts/introspect2speedscope.py`; this dashboard does not plot them.
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
    "other": "#9a9a94",        # muted gray (all non-choice literals)
}
# Categorical hues assigned by backtrack rank (stable within a trace); the tail
# beyond the top-N folds into a muted-gray "other".
PALETTE = ["#2a78d6", "#1baf7a", "#eda100", "#008300", "#4a3aa7", "#e34948",
           "#e87ba4", "#eb6834", "#6da7ec", "#0d366b", "#199e70", "#c98500"]
OTHER_GRAY = "#9a9a94"
TOP_N_PREDS = 12
PREDICATE_COLOR = {
    "mergeClasses": "#e34948",
    "method": "#2a78d6",
    "constructor": "#1baf7a",
    "vfTable": "#eda100",
    "vfTableSize": "#eb6834",
}
SURFACE = "#fcfcfb"
GRID = "#e7e7e3"
INK = "#0b0b0b"


def load(path):
    recs = {"meta": None, "final": None, "model": [], "lb": [], "sample": [], "stack": []}
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


def predicate_name(atom):
    """Return a signed or unsigned ground atom's predicate name.

    Older trace keys preserve the full literal, while new traces emit the
    predicate directly. The dashboard supports both forms: both
    `mergeClasses(1,2)` and `-mergeClasses(3,4)` contribute to
    `mergeClasses`.
    """
    return atom.lstrip("-").split("(", 1)[0]


def by_predicate(events):
    counts = {}
    for atom, value in events.items():
        name = predicate_name(atom)
        counts[name] = counts.get(name, 0) + value
    return counts


# Plotly's built-in unified hover has no per-point entry limit. This post-script
# leaves every bar in the chart untouched and replaces its tooltip only for the
# two predicate-distribution panels with the ten largest entries at that time.
HOVER_FILTER_JS = r"""
const gd = document.getElementById('{plot_id}');
const tooltip = document.createElement('div');
tooltip.style.cssText = [
  'display:none', 'position:fixed', 'z-index:10000', 'max-width:360px',
  'padding:8px 10px', 'border:1px solid #b9b9b3', 'border-radius:4px',
  'background:rgba(252,252,251,0.96)', 'box-shadow:0 2px 8px rgba(0,0,0,0.15)',
  'font:12px Arial,sans-serif', 'color:#0b0b0b', 'pointer-events:none'
].join(';');
document.body.appendChild(tooltip);

function html(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

gd.on('plotly_hover', function(evt) {
  const bars = evt.points.filter(p => p.data.type === 'bar');
  const hoverlayer = gd.querySelector('.hoverlayer');
  if (!bars.length) {
    if (hoverlayer) hoverlayer.style.opacity = 1;
    tooltip.style.display = 'none';
    return;
  }
  const top = bars.slice().sort((a, b) => b.y - a.y).slice(0, 10);
  const lines = top.map(p => {
    const count = Number(p.customdata || 0).toLocaleString();
    return `${html(p.data.name)}: <b>${p.y.toFixed(1)}%</b> (${count} events)`;
  });
  tooltip.innerHTML = `<b>${html(top[0].x)} s</b><br>${lines.join('<br>')}`;
  tooltip.style.left = `${Math.min(evt.event.clientX + 14, window.innerWidth - 380)}px`;
  tooltip.style.top = `${Math.min(evt.event.clientY + 14, window.innerHeight - 250)}px`;
  tooltip.style.display = 'block';
  if (hoverlayer) hoverlayer.style.opacity = 0;
});
gd.on('plotly_unhover', function() {
  const hoverlayer = gd.querySelector('.hoverlayer');
  if (hoverlayer) hoverlayer.style.opacity = 1;
  tooltip.style.display = 'none';
});
"""


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
        tn = {}
        decided, implied = {}, {}
        for s in b:
            for k, v in s["true_now"].items():
                tn.setdefault(k, []).append(v)
            for k, v in s.get("decided", {}).items():
                decided[k] = decided.get(k, 0) + v
            for k, v in s.get("implied", {}).items():
                implied[k] = implied.get(k, 0) + v
        out.append({
            "t": round((t0 + t1) / 2, 3),
            "bt_rate": {k: round(v / dur) for k, v in bt.items()},
            "root_returns_rate": round(sum(s.get("root_returns", 0) for s in b) / dur),
            "true_now": {k: round(sum(vs) / len(vs)) for k, vs in tn.items()},
            # Both are symbolic assignment events binned by burst and then
            # coalesced by predicate. `decided` contains direct branch
            # literals; `implied` contains literals forced by propagation.
            "decided": by_predicate(decided),
            "implied": by_predicate(implied),
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
    # burst-gap threshold: a couple of active-window intervals
    dts = [s["dt"] for s in samples if s.get("dt")]
    gap = 4 * (sorted(dts)[len(dts) // 2] if dts else 0.05)

    agg = aggregate(samples, gap)
    at = [a["t"] for a in agg]
    families = sorted({family for point in agg for family in point["true_now"]})
    def assignment_predicates(field):
        totals = {}
        for point in agg:
            for predicate, count in point[field].items():
                totals[predicate] = totals.get(predicate, 0) + count
        return [predicate for predicate, _ in sorted(
            totals.items(), key=lambda item: (-item[1], item[0])
        )]

    decided_predicates = assignment_predicates("decided")
    implied_predicates = assignment_predicates("implied")
    all_assignment_predicates = sorted(set(decided_predicates) | set(implied_predicates))
    predicate_totals = {}
    for point in agg:
        for field in ("decided", "implied"):
            for predicate, count in point[field].items():
                predicate_totals[predicate] = predicate_totals.get(predicate, 0) + count
    legend_predicates = {
        predicate for predicate, _ in sorted(
            predicate_totals.items(), key=lambda item: (-item[1], item[0])
        )[:10]
    }
    assignment_colors = dict(PREDICATE_COLOR)
    for i, predicate in enumerate(
        p for p in all_assignment_predicates if p not in assignment_colors
    ):
        assignment_colors[predicate] = PALETTE[i % len(PALETTE)]

    fig = make_subplots(
        rows=6, cols=1, shared_xaxes=True, vertical_spacing=0.035,
        subplot_titles=(
            "Anytime cost: incumbent vs lower bound (comp1 = vftable size, comp2 = merge/reward)",
            "Reward-family selection over time (currently-true reward atoms, per burst)",
            "Backtracks by family — rate per burst over time",
            "Decision depth (min / mean / max)",
            "Direct symbolic decisions by predicate — percentage per burst",
            "Implied symbolic assignments by predicate — percentage per burst",
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
    for index, fam in enumerate(families):
        ys = [a["true_now"].get(fam, 0) for a in agg]
        if any(ys):
            fig.add_trace(go.Scatter(
                x=at, y=ys, name=fam, legendgroup="reward",
                mode="lines+markers", marker=dict(size=4),
                line=dict(color=FAMILY_COLOR.get(fam, PALETTE[index % len(PALETTE)]), width=2)), row=2, col=1)

    # -- Panel 3: backtracks broken down by predicate name -----------
    # Rank predicates by total backtracks; top-N get their own colored line,
    # the long tail folds into a single gray "other".
    totals = {}
    for a in agg:
        for k, v in a["bt_rate"].items():
            totals[k] = totals.get(k, 0) + v
    top = [k for k, _ in sorted(totals.items(), key=lambda kv: -kv[1])[:TOP_N_PREDS]]
    topset = set(top)
    for i, pred in enumerate(top):
        fig.add_trace(go.Scatter(
            x=at, y=[a["bt_rate"].get(pred, 0) for a in agg],
            name=pred, legendgroup="bt", mode="lines+markers", marker=dict(size=4),
            line=dict(color=PALETTE[i % len(PALETTE)], width=2)), row=3, col=1)
    other = [sum(v for k, v in a["bt_rate"].items() if k not in topset) for a in agg]
    if any(other):
        fig.add_trace(go.Scatter(
            x=at, y=other, name=f"other ({len(totals) - len(top)} preds)",
            legendgroup="bt", mode="lines+markers", marker=dict(size=4),
            line=dict(color=OTHER_GRAY, width=2, dash="dot")), row=3, col=1)

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

    # -- Panels 5–6: symbolic-assignment predicate distributions -------
    # The propagator classifies every watched symbolic literal at assignment time:
    # it is a direct decision iff it is the decision literal at its own level;
    # otherwise it was forced by propagation. The full atom remains in JSONL,
    # while these panels deliberately answer the high-level mix question.
    def add_distribution(field, predicates, row):
        totals = [sum(point[field].values()) for point in agg]
        for predicate in predicates:
            counts = [point[field].get(predicate, 0) for point in agg]
            percentages = [100 * count / total if total else None
                           for count, total in zip(counts, totals)]
            fig.add_trace(go.Bar(
                x=at, y=percentages, customdata=counts, name=predicate,
                # Both distributions use the same categorical colors; only
                # Show just the ten most frequent predicates once rather than
                # duplicating a potentially long legend across both panels.
                legendgroup=predicate,
                showlegend=(predicate in legend_predicates and
                            (row == 5 or predicate not in decided_predicates)),
                marker_color=assignment_colors[predicate],
                hovertemplate=("time %{x:.3f}s<br>" + predicate +
                               ": %{y:.1f}% (%{customdata:,} events)<extra></extra>"),
            ), row=row, col=1)

    add_distribution("decided", decided_predicates, 5)
    add_distribution("implied", implied_predicates, 6)

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
        height=1450, hovermode="x unified", barmode="stack",
        legend=dict(groupclick="toggleitem", tracegroupgap=16,
                    yanchor="top", y=1, xanchor="left", x=1.005),
        margin=dict(t=90, l=70, r=200, b=50),
    )
    fig.update_xaxes(gridcolor=GRID, zeroline=False)
    fig.update_yaxes(gridcolor=GRID, zeroline=False)
    fig.update_xaxes(title_text="solve time (s)", row=6, col=1)
    fig.update_yaxes(title_text="cost", row=1, col=1)
    fig.update_yaxes(title_text="# atoms true", row=2, col=1)
    fig.update_yaxes(title_text="backtracks / s", row=3, col=1)
    fig.update_yaxes(title_text="decision level", row=4, col=1)
    fig.update_yaxes(title_text="share of events (%)", range=[0, 100], row=5, col=1)
    fig.update_yaxes(title_text="share of events (%)", range=[0, 100], row=6, col=1)
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
    fig.write_html(out, include_plotlyjs=True, full_html=True,
                   post_script=HOVER_FILTER_JS)
    n_s, n_m = len(recs["sample"]), len(recs["model"])
    print(f"wrote {out}  ({n_s} samples, {n_m} incumbents)")
    if not args.no_open:
        webbrowser.open(f"file://{Path(out).resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
