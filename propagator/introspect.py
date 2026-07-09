"""Time-resolved solver introspection.

Records how the solver's internal behavior evolves over wall-clock time so we
can *see* the merge-reward plateau (`.state/merge-optimization-blocker.md`)
instead of inferring it from a final `--stats` snapshot.

Two capture channels write one JSONL trace:

  * Incumbent channel (driver `on_model`, in ooanalyzer.py): exact comp2
    reward decomposition by family at each improving model, via
    `decompose_reward`. A `final` record written after solve carries the
    post-solve `ctl.statistics` snapshot (exact choices / conflicts / restarts
    and the USC lower bound `summary.lower`).

    NOTE: clingo exposes `ctl.statistics` only *after* `solve()` returns -- it
    is unavailable inside `on_model` and during an in-progress (even async)
    solve. So coarse counters (choices/conflicts/restarts) and the lower bound
    are single end-of-run scalars, not trajectories. Restarts in particular
    have no per-time series: a propagator cannot see them either, since under
    USC the search never returns to decision level 0.

  * Sample channel (`IntrospectPropagator`, here): a duty-cycled sampler that
    is near-zero cost when idle -- it holds NO persistent watches, so clingo
    never calls its propagate/undo between windows; only `check()` fires (in
    Fixpoint mode) and merely decrements a heartbeat countdown. Every `period`
    seconds it opens a `window`-second burst: it installs watches on the choice
    atoms and, every `sample_interval` seconds within the burst, emits a fine
    `sample` record of the assignments / flips / backtracks / restarts by family
    that occurred *in that slice* -- so backtracks are plotted at the times they
    happen, not aggregated over the whole burst -- plus decision depth and
    currently-true reward atoms. It removes the watches at burst end.

The duty-cycled deferred-watch machinery mirrors ConflictProfiler, which is the
battle-tested reference for mid-solve add_watch/remove_watch in this codebase.

Overhead note (TinyXml, domain/usc champion, 40s A/B): idle heartbeat alone
(`check_mode=Fixpoint`, no watches, no windows) measured ~18% fewer choices than
an uninstrumented run, and the 0.5s/10s sampling windows add ~6% more. The
dominant cost is the per-fixpoint C->Python `check()` transition, NOT the window
watches -- so "near-zero idle" is bounded by Python callback overhead. Making it
truly free would require moving the heartbeat into the Rust `&sameClass`
propagator (native `check`, no GIL). Until then the tool is opt-in (`--introspect`
off by default) and the introspection is qualitatively faithful (the plateau,
method saturation, and merge-dominated backtracks all reproduce); only absolute
rates are scaled by the overhead.
"""

import json
import threading
import time
from collections import Counter, defaultdict

import clingo

# Choice-atom predicate -> decision-anatomy family (what the solver branches on).
CHOICE_FAMILY = {
    "mergeClasses": "merge",
    "method": "method",
    "constructor": "ctor",
    "vfTable": "vftable",
    "vfTableSize": "vftable",
}

# Reward-atom predicate -> (family, weight). comp2 (priority @0) only; verified
# against src/modules/{methods,merges,composition,ctorsdtors}.lp.
REWARD_FAMILY = {
    "guessMethodReward": ("method", 10),
    "guessConstructor1Reward": ("ctor", 10),
    "guessConstructor2Reward": ("ctor", 9),
    "guessConstructor3Reward": ("ctor", 8),
    "guessConstructor4Reward": ("ctor", 7),
    "strongMergeReward": ("strong_merge", 10),
    "weakMergeReward": ("weak_merge", 8),
    "weakG1Bonus": ("weak_g1", 9),
    "lateF2Reward": ("late_f2", 8),
    "guessDerivedClassReward": ("composition", 10),
    "purecallNotMostDerivedReward": ("composition", 40),
    "embedsKnownBasePenalty": ("composition", -20),
}


def decompose_reward(symbols):
    """Exact comp2 reward by family from a model's true atoms.

    Returns (reward_by_family, count_by_family). Summed reward across families
    equals the comp2 cost component (a built-in cross-check in the viz)."""
    reward = defaultdict(int)
    counts = defaultdict(int)
    for sym in symbols:
        fw = REWARD_FAMILY.get(sym.name)
        if fw is None:
            continue
        family, weight = fw
        reward[family] += weight
        counts[family] += 1
    return dict(reward), dict(counts)


class IntrospectPropagator:
    """Duty-cycled, near-zero-idle sampler of search internals over time."""

    # Idle check() reads the clock only every _HB fixpoints; small enough that a
    # 0.5s window is never missed even at low fixpoint rates, large enough that
    # the idle path is effectively free.
    _HB = 512

    def __init__(self, sink, period, window, after=0.0, sample_interval=0.05):
        # sink: callable(dict) -> None, appends one JSONL record.
        self._sink = sink
        self._period = period
        self._window = window
        self._after = after
        self._sample_interval = sample_interval

        # Classified solver literals, filled in init().
        self._choice_fam = {}          # abs(lit) -> family (watched during windows)
        self._choice_lits = []         # signed lits to add/remove as watches
        self._reward_lits = []         # (lit, family) queried for true_now

        # Sampling state.
        self._solve_start = None
        self._active = False
        self._watched_threads = set()
        self._hb = self._HB
        self._phase = {}               # abs(lit) -> last phase, carried across burst
        self._last_sample_t = 0.0
        self._reset_sample()

    # ------------------------------------------------------------------
    def init(self, init):
        self._solve_start = time.monotonic()
        # Fixpoint mode: check() is our heartbeat and fires with no watches.
        init.check_mode = clingo.PropagatorCheckMode.Fixpoint
        for sym_atom in init.symbolic_atoms:
            name = sym_atom.symbol.name
            lit = init.solver_literal(sym_atom.literal)
            fam = CHOICE_FAMILY.get(name)
            if fam is not None:
                self._choice_fam[abs(lit)] = fam
                self._choice_lits.append(lit)
                self._choice_lits.append(-lit)
            rw = REWARD_FAMILY.get(name)
            if rw is not None:
                self._reward_lits.append((lit, rw[0]))

    # ------------------------------------------------------------------
    def _reset_sample(self):
        # Per-slice delta accumulators (reset after every emitted sample).
        self._assigned = Counter()
        self._backtracks = Counter()
        self._flips = Counter()
        self._depth_n = 0
        self._depth_sum = 0
        self._depth_min = None
        self._depth_max = None

    def _now(self):
        return time.monotonic() - self._solve_start

    def _in_window(self, t):
        e = t - self._after
        return e >= 0 and (e % self._period) < self._window

    def _add_watches(self, control):
        if control.thread_id not in self._watched_threads:
            for lit in self._choice_lits:
                control.add_watch(lit)
            self._watched_threads.add(control.thread_id)

    def _remove_watches(self, control):
        if control.thread_id in self._watched_threads:
            for lit in self._choice_lits:
                control.remove_watch(lit)
            self._watched_threads.discard(control.thread_id)

    # ------------------------------------------------------------------
    def check(self, control):
        # Restarts are captured by the driver's non-perturbing statistics poller
        # (poll records), not here: under USC the solver never returns to
        # decision level 0 (it works beneath an assumption frame), so a
        # propagator-side level-0 test never fires.
        if self._active:
            self._sample_depth_lvl(control.assignment.decision_level)
            now = self._now()
            if not self._in_window(now):
                self._flush(control, now)          # final slice of the burst
                self._remove_watches(control)
                self._active = False
                self._hb = self._HB
            elif now - self._last_sample_t >= self._sample_interval:
                self._flush(control, now)
            return
        # Idle heartbeat: no watches installed, so this is the only callback.
        self._hb -= 1
        if self._hb > 0:
            return
        self._hb = self._HB
        now = self._now()
        if self._in_window(now):
            self._open_window(control, now)

    def _open_window(self, control, now):
        self._add_watches(control)
        self._reset_sample()
        self._last_sample_t = now
        self._active = True

    def _flush(self, control, now):
        """Emit one fine time-slice sample of what happened since the last flush."""
        dt = max(now - self._last_sample_t, 1e-6)
        self._sink({
            "kind": "sample",
            "t": round(now, 3),
            "dt": round(dt, 4),
            "depth": {
                "min": self._depth_min or 0,
                "mean": round(self._depth_sum / self._depth_n, 1) if self._depth_n else 0,
                "max": self._depth_max or 0,
            },
            "assigned": dict(self._assigned),
            "backtracks": dict(self._backtracks),
            "flips": dict(self._flips),
            "true_now": self._sample_true_now(control.assignment),
        })
        self._reset_sample()
        self._last_sample_t = now

    def _sample_depth_lvl(self, lvl):
        self._depth_n += 1
        self._depth_sum += lvl
        if self._depth_min is None or lvl < self._depth_min:
            self._depth_min = lvl
        if self._depth_max is None or lvl > self._depth_max:
            self._depth_max = lvl

    def _sample_true_now(self, assignment):
        counts = Counter()
        for lit, fam in self._reward_lits:
            if assignment.is_true(lit):
                counts[fam] += 1
        return dict(counts)

    # -- watched-literal callbacks: only fire while a window is open ----
    def propagate(self, control, changes):
        for lit in changes:
            fam = self._choice_fam.get(abs(lit))
            if fam is None:
                continue
            self._assigned[fam] += 1
            phase = lit > 0
            prev = self._phase.get(abs(lit))
            if prev is not None and prev != phase:
                self._flips[fam] += 1
            self._phase[abs(lit)] = phase

    def undo(self, thread_id, assignment, changes):
        for lit in changes:
            fam = self._choice_fam.get(abs(lit))
            if fam is not None:
                self._backtracks[fam] += 1

    def finalize(self, control=None):
        """Flush an in-progress burst at solve end (best effort)."""
        if self._active and control is not None:
            self._flush(control, self._now())
            self._remove_watches(control)
            self._active = False


class TraceWriter:
    """Owns the JSONL file. Thread-safe: the propagator and on_model write from
    the solve thread while the driver's stats poller writes from the main
    thread, so a lock keeps JSON lines from interleaving."""

    def __init__(self, path):
        self._fh = open(path, "w")
        self._lock = threading.Lock()

    def write(self, record):
        line = json.dumps(record) + "\n"
        with self._lock:
            self._fh.write(line)
            self._fh.flush()

    def close(self):
        with self._lock:
            self._fh.close()
