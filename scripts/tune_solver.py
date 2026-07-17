#!/usr/bin/env python3
"""Resumable Optuna tuning for OOAnalyzer anytime performance.

The tuner changes solver search behaviour, including Clasp's internal thread
count, while fixing the ASP program, objective weights, offset bounds, and
semantic guess-family enablement. It compares the lexicographic incumbent
reached at a fixed wall-clock cutoff across several solver seeds.
"""

from __future__ import annotations

import argparse
import atexit
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import queue
import re
import shlex
import signal
import statistics
import subprocess
import sys
import threading
import time
from typing import Any, Iterable, Sequence

import optuna
from optuna.storages import JournalStorage
from optuna.storages.journal import JournalFileBackend


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TUNING_SEEDS = (1, 2, 3)
DEFAULT_VALIDATION_SEEDS = (11, 17, 23, 29, 31)
DEFAULT_CHECKPOINT_RATIOS = (1 / 6, 1 / 3, 2 / 3, 1.0)
LEX_SCALE = 1_000_000_000
NO_MODEL_SCORE = 1_000_000_000_000_000_000
MODEL_RE = re.compile(r"Model found \((?P<t>[0-9.]+)s(?:,[^)]*)?\): (?P<cost>\[[^]]+\]|0)")


def parse_duration(value: str) -> float:
    """Parse a positive duration such as 1800, 30m, or 24h."""
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([smhd]?)\s*", value)
    if not match:
        raise argparse.ArgumentTypeError(f"invalid duration: {value!r}")
    number = float(match.group(1))
    multiplier = {"": 1.0, "s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0}[match.group(2)]
    seconds = number * multiplier
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be positive")
    return seconds


def parse_int_list(value: str) -> tuple[int, ...]:
    try:
        result = tuple(int(item.strip()) for item in value.split(",") if item.strip())
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer list: {value!r}") from exc
    if not result:
        raise argparse.ArgumentTypeError("list must not be empty")
    return result


def parse_float_list(value: str) -> tuple[float, ...]:
    try:
        result = tuple(float(item.strip()) for item in value.split(",") if item.strip())
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid number list: {value!r}") from exc
    if not result or any(item <= 0 for item in result) or tuple(sorted(set(result))) != result:
        raise argparse.ArgumentTypeError("checkpoints must be unique, positive, and increasing")
    return result


def default_checkpoints(trial_time_limit: float) -> tuple[float, ...]:
    """Scale the standard anytime checkpoints to a trial's time limit."""
    return tuple(trial_time_limit * ratio for ratio in DEFAULT_CHECKPOINT_RATIOS)


def parse_cost(text: str) -> tuple[int, ...]:
    text = text.strip()
    if text == "0":
        return ()
    if not (text.startswith("[") and text.endswith("]")):
        raise ValueError(f"invalid cost: {text!r}")
    try:
        return tuple(int(item.strip()) for item in text[1:-1].split(","))
    except ValueError as exc:
        raise ValueError(f"invalid cost: {text!r}") from exc


def parse_model_line(line: str) -> tuple[float, tuple[int, ...]] | None:
    match = MODEL_RE.search(line)
    if not match:
        return None
    return float(match.group("t")), parse_cost(match.group("cost"))


def scalarize_cost(cost: Sequence[int] | None) -> int:
    """Encode OOAnalyzer's fixed two-level objective without losing order."""
    if cost is None:
        return NO_MODEL_SCORE
    if len(cost) != 2:
        raise ValueError(f"expected two OOAnalyzer objective levels, got {list(cost)}")
    if abs(cost[1]) >= LEX_SCALE // 2:
        raise ValueError(f"secondary objective {cost[1]} exceeds scalarization bound")
    return int(cost[0]) * LEX_SCALE + int(cost[1])


def incumbent_at(events: Sequence["ModelEvent"], checkpoint: float) -> tuple[int, ...] | None:
    available = [event.cost for event in events if event.elapsed <= checkpoint]
    return min(available) if available else None


def median_cost(costs: Sequence[tuple[int, ...] | None]) -> tuple[int, ...] | None:
    ranked = sorted((scalarize_cost(cost), cost) for cost in costs)
    if not ranked:
        return None
    return ranked[len(ranked) // 2][1]


def aggregate_score(costs: Sequence[tuple[int, ...] | None]) -> int:
    if not costs:
        return NO_MODEL_SCORE
    return int(statistics.median(scalarize_cost(cost) for cost in costs))


def anytime_score(
    results: Sequence["SeedResult"], checkpoints: Sequence[float]
) -> float:
    values = []
    for checkpoint in checkpoints:
        values.append(
            aggregate_score([incumbent_at(result.events, checkpoint) for result in results])
        )
    return statistics.fmean(values) if values else float(NO_MODEL_SCORE)


@dataclass(frozen=True)
class ModelEvent:
    elapsed: float
    cost: tuple[int, ...]


@dataclass
class SeedResult:
    seed: int
    command: list[str]
    log: str
    events: list[ModelEvent] = field(default_factory=list)
    returncode: int | None = None
    duration: float = 0.0
    status: str = "running"

    @property
    def final_cost(self) -> tuple[int, ...] | None:
        return min((event.cost for event in self.events), default=None)

    def to_json(self) -> dict[str, Any]:
        data = asdict(self)
        data["events"] = [
            {"elapsed": event.elapsed, "cost": list(event.cost)} for event in self.events
        ]
        data["final_cost"] = list(self.final_cost) if self.final_cost is not None else None
        return data


@dataclass
class RunningSeed:
    result: SeedResult
    process: subprocess.Popen[str]
    started: float
    reader: threading.Thread


_ACTIVE: set[subprocess.Popen[str]] = set()
_ACTIVE_LOCK = threading.Lock()
_CONSOLE_LOCK = threading.Lock()


def console(message: str) -> None:
    with _CONSOLE_LOCK:
        print(message, flush=True)


class CpuBudget:
    """Coordinate independent trials by their requested Clasp thread count."""

    def __init__(self, total: int):
        self.total = total
        self.available = total
        self.condition = threading.Condition()

    @contextmanager
    def reserve(self, requested: int):
        units = min(requested, self.total)
        with self.condition:
            self.condition.wait_for(lambda: self.available >= units)
            self.available -= units
        try:
            yield units
        finally:
            with self.condition:
                self.available += units
                self.condition.notify_all()


def _remember_process(process: subprocess.Popen[str]) -> None:
    with _ACTIVE_LOCK:
        _ACTIVE.add(process)


def _forget_process(process: subprocess.Popen[str]) -> None:
    with _ACTIVE_LOCK:
        _ACTIVE.discard(process)


def _terminate_process(process: subprocess.Popen[str], grace: float = 5.0) -> None:
    if process.poll() is not None:
        _forget_process(process)
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        _forget_process(process)
        return
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    finally:
        _forget_process(process)


def _cleanup_processes() -> None:
    with _ACTIVE_LOCK:
        processes = list(_ACTIVE)
    for process in processes:
        _terminate_process(process, grace=1.0)


atexit.register(_cleanup_processes)


def _reader(
    running_result: SeedResult,
    process: subprocess.Popen[str],
    output_queue: queue.Queue[tuple[int, ModelEvent]],
    log_path: Path,
) -> None:
    with log_path.open("w", encoding="utf-8") as stream:
        assert process.stdout is not None
        for line in process.stdout:
            stream.write(line)
            stream.flush()
            parsed = parse_model_line(line)
            if parsed is not None:
                elapsed, cost = parsed
                event = ModelEvent(elapsed, cost)
                output_queue.put((running_result.seed, event))


def start_seed(
    seed: int,
    command: list[str],
    log_path: Path,
    output_queue: queue.Queue[tuple[int, ModelEvent]],
) -> RunningSeed:
    full_command = [*command, f"--seed={seed}"]
    env = os.environ.copy()
    env.setdefault("UV_CACHE_DIR", "/tmp/uv-cache")
    process = subprocess.Popen(
        full_command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
        env=env,
    )
    _remember_process(process)
    result = SeedResult(seed=seed, command=full_command, log=str(log_path))
    thread = threading.Thread(
        target=_reader,
        args=(result, process, output_queue, log_path),
        name=f"ooanalyzer-seed-{seed}",
        daemon=True,
    )
    thread.start()
    return RunningSeed(result=result, process=process, started=time.monotonic(), reader=thread)


def run_seed_group(
    command: list[str],
    seeds: Sequence[int],
    output_dir: Path,
    checkpoints: Sequence[float],
    time_limit: float,
    trial: optuna.Trial | None = None,
    label: str | None = None,
) -> tuple[list[SeedResult], list[dict[str, Any]]]:
    """Run one configuration across seeds and optionally report/prune it."""
    output_dir.mkdir(parents=True, exist_ok=True)
    messages: queue.Queue[tuple[int, ModelEvent]] = queue.Queue()
    running: list[RunningSeed] = []
    try:
        for seed in seeds:
            running.append(
                start_seed(seed, command, output_dir / f"seed-{seed}.log", messages)
            )
    except BaseException:
        for item in running:
            _terminate_process(item.process)
        raise
    by_seed = {item.result.seed: item.result for item in running}
    started = time.monotonic()
    checkpoint_index = 0
    summaries: list[dict[str, Any]] = []
    pruned = False
    try:
        while True:
            while True:
                try:
                    seed, event = messages.get_nowait()
                except queue.Empty:
                    break
                by_seed[seed].events.append(event)

            elapsed = time.monotonic() - started
            all_done = all(item.process.poll() is not None for item in running)
            if all_done:
                for item in running:
                    item.reader.join(timeout=2.0)
                while True:
                    try:
                        seed, event = messages.get_nowait()
                    except queue.Empty:
                        break
                    by_seed[seed].events.append(event)
            while checkpoint_index < len(checkpoints) and (
                elapsed >= checkpoints[checkpoint_index] or all_done
            ):
                checkpoint = checkpoints[checkpoint_index]
                costs = [incumbent_at(item.result.events, checkpoint) for item in running]
                score = aggregate_score(costs)
                summaries.append(
                    {
                        "checkpoint": checkpoint,
                        "costs": [list(cost) if cost is not None else None for cost in costs],
                        "median_cost": (
                            list(median_cost(costs)) if median_cost(costs) is not None else None
                        ),
                        "score": score,
                    }
                )
                if label is not None:
                    console(
                        f"[{label}] {checkpoint:g}s median={_cost_text(median_cost(costs))} "
                        f"seeds={[list(cost) if cost is not None else None for cost in costs]}"
                    )
                if trial is not None:
                    trial.report(float(score), checkpoint_index)
                    # Pruning only saves work before the final checkpoint. Once
                    # the full budget has been spent, retain the trial as a
                    # completed observation for the sampler and percentile.
                    if checkpoint_index < len(checkpoints) - 1 and trial.should_prune():
                        pruned = True
                        raise optuna.TrialPruned(
                            f"underperforming through {checkpoint:g}s"
                        )
                checkpoint_index += 1

            if all_done:
                break
            if elapsed > time_limit + 60.0:
                break
            next_wait = 0.2
            if checkpoint_index < len(checkpoints):
                next_wait = min(next_wait, max(0.01, checkpoints[checkpoint_index] - elapsed))
            try:
                seed, event = messages.get(timeout=next_wait)
                by_seed[seed].events.append(event)
            except queue.Empty:
                pass
    finally:
        for item in running:
            if item.process.poll() is None:
                _terminate_process(item.process)
            else:
                _forget_process(item.process)
            item.reader.join(timeout=2.0)
            item.result.returncode = item.process.returncode
            item.result.duration = time.monotonic() - item.started
            if pruned:
                item.result.status = "pruned"
            elif item.process.returncode in (0, 10, 20, 30) and item.result.final_cost is not None:
                item.result.status = "complete"
            elif item.result.final_cost is not None:
                item.result.status = "interrupted"
            else:
                item.result.status = "failed"
        while True:
            try:
                seed, event = messages.get_nowait()
            except queue.Empty:
                break
            by_seed[seed].events.append(event)
        payload = {
            "command": command,
            "checkpoints": summaries,
            "seeds": [item.result.to_json() for item in running],
        }
        (output_dir / "result.json").write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    return [item.result for item in running], summaries


HEURISTICS = ("Domain", "Vsids", "Berkmin", "Vmtf", "Unit", "None")


BASELINE_PARAMS: dict[str, Any] = {
    "configuration": "auto",
    "parallel_threads": 1,
    "opt_strategy": "bb",
    "bb_tactic": "lin",
    "heuristic": "Domain",
    "opt_heuristic": "none",
    "restart_on_model": 1,
    "restart_policy": "default",
    "save_progress": 0,
    "sign_def": "default",
    "init_moms": "default",
    "rand_enabled": 0,
    "decide_inputs": 1,
    "enable_input_heuristics": 1,
    "enable_reward_heuristics": 0,
    "method_heuristic_priority": 0,
    "vftable_base_heuristic_priority": 2,
    "vftable_heuristic_priority": 3,
    "vftable_size_heuristic_priority": 3,
    "all_input_priority": 0,
    "prolog_order_priority": 10,
    "weak_merge_input_phase": 0,
    "late_merge_input_phase": 0,
    "enable_dynamic_guess_gates": 1,
}


def suggest_parameters(
    trial: optuna.Trial, max_solver_threads: int = 8
) -> dict[str, Any]:
    params: dict[str, Any] = {}
    params["configuration"] = trial.suggest_categorical(
        "configuration", ["auto", "tweety", "frumpy", "jumpy", "handy", "crafty", "trendy"]
    )
    params["parallel_threads"] = trial.suggest_int(
        "parallel_threads", 1, max_solver_threads
    )
    if params["parallel_threads"] > 1:
        params["parallel_mode"] = trial.suggest_categorical(
            "parallel_mode", ["compete", "split"]
        )
    params["opt_strategy"] = trial.suggest_categorical("opt_strategy", ["bb", "usc"])
    if params["opt_strategy"] == "bb":
        params["bb_tactic"] = trial.suggest_categorical(
            "bb_tactic", ["lin", "hier", "inc", "dec"]
        )
    else:
        params["usc_relax"] = trial.suggest_categorical(
            "usc_relax", ["oll", "one", "k", "pmres"]
        )
        if params["usc_relax"] == "oll":
            params["usc_disjoint"] = trial.suggest_int("usc_disjoint", 0, 1)
            params["usc_succinct"] = trial.suggest_int("usc_succinct", 0, 1)
            params["usc_stratify"] = trial.suggest_int("usc_stratify", 0, 1)
        elif params["usc_relax"] == "k":
            params["usc_k_limit"] = trial.suggest_int("usc_k_limit", 0, 64)
    params["heuristic"] = trial.suggest_categorical("heuristic", HEURISTICS)
    if params["heuristic"] == "Vsids":
        params["vsids_decay"] = trial.suggest_int("vsids_decay", 80, 99)
    elif params["heuristic"] == "Berkmin":
        params["berkmin_history"] = trial.suggest_int("berkmin_history", 0, 1024)
    elif params["heuristic"] == "Vmtf":
        params["vmtf_move"] = trial.suggest_int("vmtf_move", 1, 64, log=True)
    params["opt_heuristic"] = trial.suggest_categorical(
        "opt_heuristic", ["none", "sign", "model", "sign,model"]
    )
    params["restart_on_model"] = trial.suggest_int("restart_on_model", 0, 1)
    params["restart_policy"] = trial.suggest_categorical(
        "restart_policy", ["default", "no", "F", "L", "x", "+", "D"]
    )
    if params["restart_policy"] in ("F", "L", "x", "+"):
        params["restart_base"] = trial.suggest_int(
            "restart_base", 16, 2048, log=True
        )
    if params["restart_policy"] == "x":
        params["restart_factor"] = trial.suggest_float(
            "restart_factor", 1.05, 2.0
        )
    elif params["restart_policy"] == "+":
        params["restart_increment"] = trial.suggest_int(
            "restart_increment", 1, 512, log=True
        )
    elif params["restart_policy"] == "D":
        params["restart_window"] = trial.suggest_int(
            "restart_window", 20, 500, log=True
        )
        params["restart_margin"] = trial.suggest_float(
            "restart_margin", 0.5, 1.0
        )
    params["save_progress"] = trial.suggest_int("save_progress", 0, 256)
    params["sign_def"] = trial.suggest_categorical(
        "sign_def", ["default", "asp", "pos", "neg", "rnd"]
    )
    params["init_moms"] = trial.suggest_categorical("init_moms", ["default", "on", "off"])
    params["rand_enabled"] = trial.suggest_int("rand_enabled", 0, 1)
    if params["rand_enabled"]:
        params["rand_freq"] = trial.suggest_float("rand_freq", 1e-5, 5e-2, log=True)
    params["decide_inputs"] = trial.suggest_int("decide_inputs", 0, 1)
    if params["opt_strategy"] == "usc":
        params["usc_shrink"] = trial.suggest_categorical(
            "usc_shrink", ["default", "lin", "inv", "bin", "rgs", "exp", "min"]
        )
        if params["usc_shrink"] != "default":
            params["usc_shrink_limit"] = trial.suggest_int(
                "usc_shrink_limit", 1, 20
            )

    params["enable_input_heuristics"] = trial.suggest_int("enable_input_heuristics", 0, 1)
    params["enable_reward_heuristics"] = trial.suggest_int("enable_reward_heuristics", 0, 1)
    if params["enable_reward_heuristics"]:
        params["reward_heuristic_priority"] = trial.suggest_int(
            "reward_heuristic_priority", 1, 20
        )
    if params["heuristic"] == "Domain":
        params["method_heuristic_priority"] = trial.suggest_int(
            "method_heuristic_priority", 0, 20
        )
        params["vftable_base_heuristic_priority"] = trial.suggest_int(
            "vftable_base_heuristic_priority", 0, 20
        )
        params["vftable_heuristic_priority"] = trial.suggest_int(
            "vftable_heuristic_priority", 0, 20
        )
        params["vftable_size_heuristic_priority"] = trial.suggest_int(
            "vftable_size_heuristic_priority", 0, 20
        )
        params["all_input_priority"] = trial.suggest_int(
            "all_input_priority", 0, 20
        )
        params["prolog_order_priority"] = trial.suggest_int(
            "prolog_order_priority", 0, 20
        )
        params["weak_merge_input_phase"] = trial.suggest_int("weak_merge_input_phase", 0, 2)
        params["late_merge_input_phase"] = trial.suggest_int("late_merge_input_phase", 0, 2)
        if params["weak_merge_input_phase"] == 1:
            params["weak_merge_after_vftable_complete"] = trial.suggest_int(
                "weak_merge_after_vftable_complete", 0, 1
            )
    params["enable_dynamic_guess_gates"] = trial.suggest_int(
        "enable_dynamic_guess_gates", 0, 1
    )
    return params


def parameters_to_args(params: dict[str, Any]) -> list[str]:
    threads = int(params.get("parallel_threads", 1))
    parallel = str(threads)
    if threads > 1:
        parallel += f",{params.get('parallel_mode', 'compete')}"
    strategy = params["opt_strategy"]
    if strategy == "bb":
        strategy = f"bb,{params.get('bb_tactic', 'lin')}"
    else:
        relax = params.get("usc_relax", "oll")
        if relax == "k" and int(params.get("usc_k_limit", 0)) > 0:
            relax = f"k,{params['usc_k_limit']}"
        tactics = []
        if params.get("usc_relax", "oll") == "oll":
            tactics = [
                name
                for name in ("disjoint", "succinct", "stratify")
                if params.get(f"usc_{name}")
            ]
        strategy = ",".join(("usc", relax, *tactics))
    heuristic = params["heuristic"]
    if heuristic == "Vsids":
        heuristic += f",{params.get('vsids_decay', 95)}"
    elif heuristic == "Berkmin" and int(params.get("berkmin_history", 0)) > 0:
        heuristic += f",{params['berkmin_history']}"
    elif heuristic == "Vmtf":
        heuristic += f",{params.get('vmtf_move', 8)}"
    args = [
        f"--configuration={params['configuration']}",
        f"--parallel-mode={parallel}",
        f"--opt-strategy={strategy}",
        f"--heuristic={heuristic}",
    ]
    opt_heuristic = params.get("opt_heuristic", "none")
    if opt_heuristic != "none":
        args.append(f"--opt-heuristic={opt_heuristic}")
    args.append("--restart-on-model" if params.get("restart_on_model") else "--no-restart-on-model")
    restart_policy = params.get("restart_policy", "default")
    if restart_policy == "no":
        args.append("--restarts=no")
    elif restart_policy in ("F", "L"):
        args.append(f"--restarts={restart_policy},{params['restart_base']}")
    elif restart_policy == "x":
        args.append(
            f"--restarts=x,{params['restart_base']},{float(params['restart_factor']):.6g}"
        )
    elif restart_policy == "+":
        args.append(
            f"--restarts=+,{params['restart_base']},{params['restart_increment']}"
        )
    elif restart_policy == "D":
        args.append(
            f"--restarts=D,{params['restart_window']},{float(params['restart_margin']):.6g}"
        )
    save_progress = int(params.get("save_progress", 0))
    if save_progress > 0:
        args.append(f"--save-progress={save_progress}")
    if params.get("sign_def", "default") != "default":
        args.append(f"--sign-def={params['sign_def']}")
    if params.get("init_moms") == "on":
        args.append("--init-moms")
    elif params.get("init_moms") == "off":
        args.append("--no-init-moms")
    if params.get("rand_enabled"):
        args.append(f"--rand-freq={float(params['rand_freq']):.8g}")
    if params.get("decide_inputs"):
        args.append("--decide-inputs")
    if params.get("usc_shrink", "default") != "default":
        args.append(
            f"--opt-usc-shrink={params['usc_shrink']},{params['usc_shrink_limit']}"
        )

    constant_names = (
        "enable_input_heuristics",
        "enable_reward_heuristics",
        "reward_heuristic_priority",
        "method_heuristic_priority",
        "vftable_base_heuristic_priority",
        "vftable_heuristic_priority",
        "vftable_size_heuristic_priority",
        "all_input_priority",
        "prolog_order_priority",
        "weak_merge_input_phase",
        "late_merge_input_phase",
        "weak_merge_after_vftable_complete",
        "enable_dynamic_guess_gates",
    )
    for name in constant_names:
        if name in params:
            args.extend(("--const", f"{name}={params[name]}"))
    return args


def baseline_args() -> list[str]:
    return parameters_to_args(BASELINE_PARAMS)


def solver_threads_from_args(args: Sequence[str]) -> int:
    for arg in args:
        if arg.startswith("--parallel-mode="):
            return int(arg.split("=", 1)[1].split(",", 1)[0])
    return 1


def solver_command(input_path: Path, solver_args: Sequence[str], time_limit: float) -> list[str]:
    return [
        sys.executable,
        str(ROOT / "ooanalyzer.py"),
        str(input_path),
        "-n",
        "-1",
        "--benchmark",
        f"--time-limit={math.ceil(time_limit)}",
        *solver_args,
    ]


def _hash_files(paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(set(path.resolve() for path in paths)):
        digest.update(str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def solver_fingerprint(input_path: Path) -> dict[str, Any]:
    paths = [ROOT / "ooanalyzer.py", ROOT / "ooanalyzer.lp", input_path]
    paths.extend((ROOT / "src").rglob("*.lp"))
    paths.extend((ROOT / "propagator").rglob("*.py"))
    paths.extend((ROOT / "rust/src").rglob("*.rs"))
    paths.append(ROOT / "rust/Cargo.toml")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True, check=True
    ).stdout.strip()
    diff = subprocess.run(
        ["git", "diff", "--", "ooanalyzer.py", "ooanalyzer.lp", "src", "propagator", "rust/src", "rust/Cargo.toml"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    ).stdout
    return {
        "revision": revision,
        "dirty_diff_sha256": hashlib.sha256(diff.encode()).hexdigest(),
        "solver_input_sha256": _hash_files(paths),
        "input": str(input_path.resolve()),
        "python": sys.version,
        "platform": platform.platform(),
        "cpu_count": os.cpu_count(),
        "optuna": optuna.__version__,
    }


def ensure_manifest(output_dir: Path, input_path: Path, settings: dict[str, Any]) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / "manifest.json"
    current = {"fingerprint": solver_fingerprint(input_path), "settings": settings}
    if manifest_path.exists():
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        if existing["fingerprint"] != current["fingerprint"]:
            raise RuntimeError(
                "solver or input changed since this study was created; use a new output directory"
            )
        if settings and existing.get("settings") != settings:
            raise RuntimeError(
                "study settings changed since this study was created; use a new output directory"
            )
        return existing
    manifest_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return current


def create_pruner() -> optuna.pruners.PercentilePruner:
    return optuna.pruners.PercentilePruner(
        50.0,
        n_startup_trials=24,
        n_warmup_steps=1,
        interval_steps=1,
        n_min_trials=6,
    )


def create_study(output_dir: Path) -> optuna.Study:
    storage = JournalStorage(JournalFileBackend(str(output_dir / "optuna.journal")))
    sampler = optuna.samplers.TPESampler(
        seed=20260717,
        n_startup_trials=24,
        multivariate=True,
        group=True,
        constant_liar=True,
    )
    study = optuna.create_study(
        study_name="ooanalyzer-anytime-v3",
        storage=storage,
        sampler=sampler,
        pruner=create_pruner(),
        direction="minimize",
        load_if_exists=True,
    )
    if not study.trials:
        study.enqueue_trial(BASELINE_PARAMS, user_attrs={"label": "makefile-baseline"})
        usc = dict(BASELINE_PARAMS)
        usc.pop("bb_tactic")
        usc["opt_strategy"] = "usc"
        usc["usc_relax"] = "oll"
        usc["usc_disjoint"] = 1
        usc["usc_succinct"] = 1
        usc["usc_stratify"] = 1
        usc["usc_shrink"] = "default"
        study.enqueue_trial(usc, user_attrs={"label": "documented-usc"})
        weak_after = dict(BASELINE_PARAMS)
        weak_after["weak_merge_input_phase"] = 1
        weak_after["weak_merge_after_vftable_complete"] = 1
        study.enqueue_trial(weak_after, user_attrs={"label": "weak-after-vftable"})
    return study


def objective_factory(
    input_path: Path,
    output_dir: Path,
    seeds: Sequence[int],
    checkpoints: Sequence[float],
    time_limit: float,
    max_solver_threads: int,
    cpu_budget: CpuBudget,
):
    def objective(trial: optuna.Trial) -> float:
        params = suggest_parameters(trial, max_solver_threads=max_solver_threads)
        args = parameters_to_args(params)
        solver_threads = int(params["parallel_threads"])
        cpu_units = len(seeds) * solver_threads
        trial.set_user_attr("solver_args", args)
        trial.set_user_attr("seeds", list(seeds))
        trial.set_user_attr("solver_threads", solver_threads)
        trial.set_user_attr("cpu_units", cpu_units)
        trial_dir = output_dir / "trials" / f"trial-{trial.number:05d}"
        command = solver_command(input_path, args, time_limit)
        try:
            console(
                f"[trial {trial.number}] waiting for {cpu_units} CPU tokens "
                f"({solver_threads} threads x {len(seeds)} seeds)"
            )
            with cpu_budget.reserve(cpu_units) as reserved:
                console(f"[trial {trial.number}] running with {reserved} CPU tokens")
                results, summaries = run_seed_group(
                    command,
                    seeds,
                    trial_dir,
                    checkpoints,
                    time_limit,
                    trial=trial,
                    label=f"trial {trial.number}",
                )
        except optuna.TrialPruned:
            trial.set_user_attr("artifact", str(trial_dir.relative_to(output_dir)))
            raise
        costs = [result.final_cost for result in results]
        score = aggregate_score(costs)
        trial.set_user_attr("artifact", str(trial_dir.relative_to(output_dir)))
        trial.set_user_attr(
            "final_costs", [list(cost) if cost is not None else None for cost in costs]
        )
        trial.set_user_attr(
            "median_cost", list(median_cost(costs)) if median_cost(costs) is not None else None
        )
        trial.set_user_attr("worst_score", max(scalarize_cost(cost) for cost in costs))
        trial.set_user_attr("anytime_score", anytime_score(results, checkpoints))
        trial.set_user_attr("checkpoints", summaries)
        return float(score)

    return objective


def study_trials_ranked(study: optuna.Study) -> list[optuna.trial.FrozenTrial]:
    complete = [
        trial
        for trial in study.trials
        if trial.state == optuna.trial.TrialState.COMPLETE and trial.value is not None
    ]
    return sorted(
        complete,
        key=lambda trial: (
            trial.value,
            float(trial.user_attrs.get("anytime_score", NO_MODEL_SCORE)),
            int(trial.user_attrs.get("worst_score", NO_MODEL_SCORE)),
            trial.number,
        ),
    )


def run_study(args: argparse.Namespace, output_dir: Path, study_seconds: float) -> optuna.Study:
    settings = {
        "mode": "study",
        "trial_time_limit": args.trial_time_limit,
        "checkpoints": list(args.checkpoints),
        "tuning_seeds": list(args.tuning_seeds),
        "jobs": args.jobs,
        "max_solver_threads": args.max_solver_threads,
        "cpu_budget": args.cpu_budget,
        "search_space_version": 2,
    }
    ensure_manifest(output_dir, args.input, settings)
    study = create_study(output_dir)
    cpu_budget = CpuBudget(args.cpu_budget)
    objective = objective_factory(
        args.input,
        output_dir,
        args.tuning_seeds,
        args.checkpoints,
        args.trial_time_limit,
        args.max_solver_threads,
        cpu_budget,
    )
    console(
        f"study: budget={study_seconds:g}s jobs={args.jobs} "
        f"seeds={list(args.tuning_seeds)} cutoff={args.trial_time_limit:g}s "
        f"solver_threads=1..{args.max_solver_threads} cpu_budget={args.cpu_budget}"
    )
    old_pruner = study.pruner
    if args.no_prune:
        study.pruner = optuna.pruners.NopPruner()
    try:
        study.optimize(
            objective,
            n_trials=args.trials,
            timeout=study_seconds,
            n_jobs=args.jobs,
            gc_after_trial=True,
            show_progress_bar=False,
        )
    finally:
        study.pruner = old_pruner
        write_study_report(study, output_dir)
    return study


def unique_finalists(
    study: optuna.Study,
    count: int,
    excluded_args: Iterable[Sequence[str]] = (),
) -> list[dict[str, Any]]:
    finalists: list[dict[str, Any]] = []
    seen = {tuple(args) for args in excluded_args}
    for trial in study_trials_ranked(study):
        stored_args = trial.user_attrs.get("solver_args")
        args = tuple(stored_args if stored_args is not None else parameters_to_args(trial.params))
        if args in seen:
            continue
        seen.add(args)
        finalists.append(
            {"label": f"trial-{trial.number:05d}", "trial": trial.number, "solver_args": list(args)}
        )
        if len(finalists) >= count:
            break
    return finalists


def validate_study(args: argparse.Namespace, output_dir: Path) -> list[dict[str, Any]]:
    ensure_manifest(output_dir, args.input, {})
    study = create_study(output_dir)
    baseline_solver_args = baseline_args()
    candidates = [
        {"label": "makefile-baseline", "trial": None, "solver_args": baseline_solver_args}
    ]
    candidates.extend(
        unique_finalists(study, args.top, excluded_args=(baseline_solver_args,))
    )
    validation: list[dict[str, Any]] = []
    validation_root = output_dir / "validation"
    for index, candidate in enumerate(candidates):
        candidate_dir = validation_root / f"{index:02d}-{candidate['label']}"
        solver_threads = solver_threads_from_args(candidate["solver_args"])
        cpu_units = solver_threads * len(args.validation_seeds)
        if cpu_units > args.cpu_budget:
            raise RuntimeError(
                f"validation candidate {candidate['label']} needs {cpu_units} CPU tokens; "
                f"increase --cpu-budget or use fewer validation seeds"
            )
        command = solver_command(args.input, candidate["solver_args"], args.trial_time_limit)
        console(
            f"validation: {candidate['label']} seeds={list(args.validation_seeds)} "
            f"solver_threads={solver_threads} cpu_tokens={cpu_units}"
        )
        results, _ = run_seed_group(
            command,
            args.validation_seeds,
            candidate_dir,
            args.checkpoints,
            args.trial_time_limit,
            label=f"validation {candidate['label']}",
        )
        costs = [result.final_cost for result in results]
        worst_cost = max(costs, key=scalarize_cost)
        validation.append(
            {
                **candidate,
                "costs": [list(cost) if cost is not None else None for cost in costs],
                "median_cost": list(median_cost(costs)) if median_cost(costs) is not None else None,
                "worst_cost": list(worst_cost) if worst_cost is not None else None,
                "score": aggregate_score(costs),
                "worst_score": max(scalarize_cost(cost) for cost in costs),
                "anytime_score": anytime_score(results, args.checkpoints),
                "artifact": str(candidate_dir.relative_to(output_dir)),
            }
        )
    validation.sort(
        key=lambda row: (row["score"], row["anytime_score"], row["worst_score"], row["label"])
    )
    (output_dir / "validation.json").write_text(
        json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_study_report(study, output_dir, validation)
    return validation


def _cost_text(cost: Sequence[int] | None) -> str:
    return "none" if cost is None else "[" + ", ".join(str(item) for item in cost) + "]"


def write_study_report(
    study: optuna.Study,
    output_dir: Path,
    validation: list[dict[str, Any]] | None = None,
) -> None:
    manifest_path = output_dir / "manifest.json"
    manifest = (
        json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest_path.exists()
        else {}
    )
    input_name = Path(
        manifest.get("fingerprint", {}).get("input", "OOAnalyzer input")
    ).name
    rows = study_trials_ranked(study)
    tsv = ["rank\ttrial\tvalue\tmedian_cost\tworst_score\tanytime_score\tlabel\targs"]
    for rank, trial in enumerate(rows, 1):
        tsv.append(
            "\t".join(
                (
                    str(rank),
                    str(trial.number),
                    str(trial.value),
                    json.dumps(trial.user_attrs.get("median_cost")),
                    str(trial.user_attrs.get("worst_score", "")),
                    str(trial.user_attrs.get("anytime_score", "")),
                    str(trial.user_attrs.get("label", "")),
                    shlex.join(trial.user_attrs.get("solver_args", [])),
                )
            )
        )
    (output_dir / "trials-results.tsv").write_text("\n".join(tsv) + "\n", encoding="utf-8")

    if validation is None and (output_dir / "validation.json").exists():
        validation = json.loads((output_dir / "validation.json").read_text(encoding="utf-8"))

    accepted = False
    recommendation: dict[str, Any] | None = None
    baseline: dict[str, Any] | None = None
    if validation:
        baseline = next((row for row in validation if row["label"] == "makefile-baseline"), None)
        recommendation = validation[0]
        accepted = bool(baseline and recommendation["score"] < baseline["score"])
        if not accepted:
            recommendation = baseline
    elif rows:
        recommendation = {
            "label": f"trial-{rows[0].number:05d}",
            "trial": rows[0].number,
            "solver_args": rows[0].user_attrs.get("solver_args", []),
            "median_cost": rows[0].user_attrs.get("median_cost"),
            "score": rows[0].value,
        }

    best_payload = {
        "accepted_over_baseline": accepted,
        "recommendation": recommendation,
        "baseline": baseline,
    }
    (output_dir / "best.json").write_text(
        json.dumps(best_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if recommendation is not None:
        best_args = recommendation.get("solver_args", [])
        (output_dir / "best.args").write_text(shlex.join(best_args) + "\n", encoding="utf-8")

    lines = [
        f"# OOAnalyzer hyperparameter tuning: {input_name}",
        "",
        f"- Completed trials: {len(rows)}",
        f"- Pruned trials: {sum(t.state == optuna.trial.TrialState.PRUNED for t in study.trials)}",
    ]
    if validation:
        lines.extend(("", "## Held-out validation", "", "| Rank | Candidate | Median cost | Worst cost |", "|---:|---|---:|---:|"))
        for rank, row in enumerate(validation, 1):
            if "worst_cost" in row:
                worst_cost = row["worst_cost"]
            else:
                legacy_costs = [tuple(cost) if cost is not None else None for cost in row["costs"]]
                worst_cost = max(legacy_costs, key=scalarize_cost)
            lines.append(
                f"| {rank} | {row['label']} | {_cost_text(row['median_cost'])} | {_cost_text(worst_cost)} |"
            )
        lines.extend(
            (
                "",
                "Result: " + ("validated improvement over baseline" if accepted else "no validated improvement over baseline"),
            )
        )
    if recommendation is not None:
        lines.extend(
            (
                "",
                "## Recommended arguments",
                "",
                "```sh",
                shlex.join(recommendation.get("solver_args", [])),
                "```",
            )
        )
    (output_dir / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    console(f"report: {output_dir / 'REPORT.md'}")


def input_slug(input_path: Path) -> str:
    name = input_path.name.removesuffix(".lp")
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")
    return slug or "input"


def default_output_dir(input_path: Path) -> Path:
    stamp = datetime.now().astimezone().strftime("%y%m%d-%H%M")
    return ROOT / ".state" / "hyperopt" / f"{input_slug(input_path)}-{stamp}"


def default_cpu_budget() -> int:
    try:
        logical_cpus = len(os.sched_getaffinity(0))
    except AttributeError:
        logical_cpus = os.cpu_count() or 1
    return max(1, logical_cpus // 2)


def add_common_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--trial-time-limit", type=parse_duration, default=1800.0)
    parser.add_argument(
        "--checkpoints",
        type=parse_float_list,
        help="comma-separated checkpoint seconds (default: 1/6, 1/3, 2/3, and all of the trial limit)",
    )
    parser.add_argument("--tuning-seeds", type=parse_int_list, default=DEFAULT_TUNING_SEEDS)
    parser.add_argument("--validation-seeds", type=parse_int_list, default=DEFAULT_VALIDATION_SEEDS)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--max-solver-threads", type=int, default=8)
    parser.add_argument("--cpu-budget", type=int, default=default_cpu_budget())
    parser.add_argument("--top", type=int, default=5)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run", help="run search, held-out validation, and report")
    add_common_options(run)
    run.add_argument("--wall-time", type=parse_duration, default=24 * 3600.0)
    run.add_argument("--trials", type=int)
    run.add_argument("--no-prune", action="store_true")

    study = subparsers.add_parser("study", help="create or resume the optimization study")
    add_common_options(study)
    study.add_argument("--study-time", type=parse_duration, default=20 * 3600.0)
    study.add_argument("--trials", type=int)
    study.add_argument("--no-prune", action="store_true")

    validate = subparsers.add_parser("validate", help="validate the baseline and top trials")
    add_common_options(validate)

    report = subparsers.add_parser("report", help="regenerate reports from a study directory")
    report.add_argument("--output", type=Path, required=True)
    return parser


def validate_args(args: argparse.Namespace) -> None:
    if args.command == "report":
        return
    args.input = args.input.resolve()
    if args.checkpoints is None:
        args.checkpoints = default_checkpoints(args.trial_time_limit)
    if not args.input.is_file():
        raise SystemExit(f"input does not exist: {args.input}")
    if args.jobs < 1 or args.top < 1 or args.cpu_budget < 1:
        raise SystemExit("--jobs, --top, and --cpu-budget must be positive")
    if not 1 <= args.max_solver_threads <= 64:
        raise SystemExit("--max-solver-threads must be between 1 and 64")
    if args.command == "study":
        largest_seed_group = len(args.tuning_seeds)
    elif args.command == "validate":
        largest_seed_group = len(args.validation_seeds)
    else:
        largest_seed_group = max(len(args.tuning_seeds), len(args.validation_seeds))
    if args.max_solver_threads * largest_seed_group > args.cpu_budget:
        raise SystemExit(
            "--cpu-budget must cover --max-solver-threads times the largest seed group"
        )
    if args.checkpoints[-1] != args.trial_time_limit:
        raise SystemExit("the final --checkpoints value must equal --trial-time-limit")


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    validate_args(args)
    output_dir = (
        args.output
        if args.output is not None
        else default_output_dir(args.input)
    ).resolve()
    console("OOAnalyzer hyperparameter optimization")
    console(f"artifacts: {output_dir}")

    if args.command == "report":
        study = create_study(output_dir)
        write_study_report(study, output_dir)
        return 0
    if args.command == "study":
        run_study(args, output_dir, args.study_time)
        return 0
    if args.command == "validate":
        validate_study(args, output_dir)
        return 0

    validation_budget = (args.top + 1) * args.trial_time_limit
    reserve = 3600.0
    study_seconds = args.wall_time - validation_budget - reserve
    if study_seconds <= 0:
        raise SystemExit(
            "wall-time is too short for validation; increase --wall-time or reduce --top/--trial-time-limit"
        )
    run_study(args, output_dir, study_seconds)
    validate_study(args, output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
