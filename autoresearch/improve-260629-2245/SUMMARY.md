# Autoresearch Session: 5m Lexicographic Improvement on TinyXml-NewDebug
**Date**: 2026-06-29 to 2026-06-30  
**Guard**: Never modify ASP (.lp) files — solver flags, ooanalyzer.py, and Rust propagator only  
**Tests**: 45/45 throughout

## Problem Setup

After adding `reasonMergeClasses_B` + `reasonReusedImplementation_B`, the previous
champion config (`crafty+F,736+opt-heuristic=sign`) stopped settling `comp1=-704`:
it now gets comp1=-656, which is lexicographically worse. The user noted that plain
`--heuristic=domain` outperformed the old champion.

**Baseline**: `-n -1 --heuristic=domain --time-limit=300` → `[-704, -33011]` (6 models)

## Key Discovery

**4 competing threads + geometric fixed restarts** is dramatically better than either alone.

| Config | comp2 | vs baseline |
|---|---:|---:|
| domain (1t, baseline) | -33011 | — |
| crafty+F,736 | -34443 | BROKEN (comp1=-656) |
| domain+t4 (no restarts) | -35977 | +2966 |
| domain+t4+F,256 (best run) | **-39582** | **+6571** |
| domain+t4+F,512 (avg) | **-39112** | **+6101** |

## Mechanism

Geometric F-restarts (F,512 → 1024 → 2048...) produce a **burst improvement pattern**:
- First burst: 5-20s (initial fast convergence)
- Second burst: 200-225s (when schedule reaches 5th-6th cycle, ~16k conflict threshold)

4 threads provide seed diversity: all 4 threads find different local optima on the
first burst, and one usually finds a significantly better starting point that enables
the second burst.

## Thread Count Analysis

- **t2**: terrible (1-2 models found total, -32977 with F,512)
- **t4**: sweet spot; enough diversity, manageable clause-sharing
- **t8**: mediocre without F (-36213); terrible with F,512 (-32943, only 2 models)
- **t16+**: FAILS — `--heuristic=domain` requires lookback strategy; clasp auto-assigns
  a no-lookback thread at position ≥14 → `RuntimeError`

## F-Value Analysis (t4,compete, 300s)

| F | comp2 | notes |
|--:|--:|---|
| F,128 | -38999 | good |
| F,192 | -37777 | mediocre |
| F,256 | -39582 / -38266 | best peak, variance ±656 |
| F,320 | -35482 | poor |
| F,448 | -37494 | mediocre |
| **F,512** | **-39253 / -38971** | **best avg -39112, variance ±141** |
| F,736 | -35771 | too long |

F,512 is recommended for production: 4.6× tighter variance than F,256 with
slightly lower average but more reliable behavior.

## Negative Results (Ruled Out)

- `--save-progress=20` with t4: -35482 (hurts thread diversity)
- Luby restarts: -35798 (geometric beats Luby with threads)
- `--opt-usc-shrink=*`: hurts both UB and LB
- `--opt-heuristic=sign`: harms UB with t4
- t8+F,512: terrible (only 2 models, -32943)
- `--no-inter-learn`: not a valid clingo option in this version

## Conflict Profile (unchanged)

`notMergeUnsorted`: 29.4% of backtracks at avg level 4540. Method 4948404 is a hub
appearing in 8207 backtracking pairs. The conditional merge mutex structure (the
fundamental LB-proof bottleneck) is unchanged by these experiments — the improvement
is entirely in UB search, not LB proof.

**Gap**: LB = -49774, best model = -39582; gap = 10192. Larger than old gap (7564)
because the new rules raised the problem's achievable optimum.

## Output Changes

- **`Makefile`** PROP_FLAGS updated to: `-n -1 --heuristic=domain -t4,compete --restarts=F,512 --time-limit=300 --stats --show-guesses`
- **`.state/merge-optimization-blocker.md`**: new champion section appended
- **`memory/opt_heuristic_sign_champion.md`**: updated with new champion history

## Full Results

See `results.tsv` for all 31 iterations.
