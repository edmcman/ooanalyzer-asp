# Autoresearch TinyXml-NewDebug BB/domain heuristic sweep

Goal: improve 5m TinyXml-NewDebug anytime performance to at least `[-704,-42000]`,
focused on domain heuristics and input-vs-output ordering.

Best TinyXml-specific heuristic-only command:

```sh
env UV_CACHE_DIR=/tmp/uv-cache uv run --offline --no-sync \
  python ooanalyzer.py examples/ooa/TinyXml/tinyXmlTest-NewDebug.exe.lp \
  -n -1 --opt-strategy=bb,lin --heuristic=domain \
  --opt-heuristic=sign,model --restart-on-model --decide-inputs \
  --const weak_merge_input_phase=1 \
  --const weak_merge_after_vftable_complete=1 \
  --time-limit=300 --stats --show-guesses
```

Result: `[-704,-46828]` at 276.86s, 13 models, target met on TinyXml.
This should not be a general default because the vftable-complete condition can
stay false forever on programs that correctly reject some possible vftables.

Key probes:

| Log | Config | Result |
|---|---|---|
| `probe01_input_only.log` | USC/domain/input-first | `[-704,-36655]` at 60s |
| `probe02_input_reward_p0.log` | USC/domain/input + reward outputs p0 | no model at 60s |
| `bb_probe02_input_only_180.log` | BB/domain/input-first | `[-704,-37442]` at 180s |
| `bb_probe03_input_reward_p4_180.log` | BB/domain/reward-output first | no model at 180s |
| `bb_probe04_input_opt_sign_model_180.log` | BB/domain/input-first + `sign,model` | `[-704,-38197]` at 180s |
| `bb_probe05_weak_true_180.log` | BB/domain/weak merge true-first, no vftable floor | `[-644,-45683]` at 180s |
| `bb_probe06_weak_true_min704_180.log` | BB/domain/weak merge true-first + vftable floor | `[-704,-45378]` at 180s; diagnostic only |
| `bb_verify02_weak_true_min704_300.log` | staged 300s verify | `[-704,-46520]`; diagnostic only |
| `bb_probe07_weak_after_vftable_complete_180.log` | weak true only after vftable layer complete | `[-704,-45740]` at 180s |
| `bb_verify04_weak_after_vftable_complete_300.log` | final heuristic-only 300s verify | `[-704,-46828]` |
| interactive method-priority probe | BB/domain + `--const method_heuristic_priority=3` | first `-704` at ~73s, `[-704,-38257]` at 180s |

Interpretation:

- Branching directly on reward/output atoms delayed or prevented first
  incumbents in the measured windows. Treat these as "no incumbent by N
  seconds", not a proof they are globally dominated.
- Input-first remains the useful ordering for BB, but the weak merge input
  phase should be optimistic (`true`) once the high-priority vftable layer is
  staged.
- Without ordering, weak-true quickly finds strong priority-0 reward
  (`-45683`) but sacrifices comp1 (`-644`) in the 180s probe.
- The non-cheating TinyXml ordering is: vftable layer first, then weak merge
  inputs true-first. `weak_merge_after_vftable_complete=1` encodes that ordering
  without a numeric floor, but it is not safe as a global default.
- Raising broad `method/1` input priority to the vftable layer (`@3`) helps
  expose TinyXml vftable candidates earlier, but is much weaker than the
  vftable-complete weak-merge phase. A safer next experiment is a targeted high
  priority for methods that directly unlock vftables (writers/entries), not all
  `possibleMethod/1`.
- Final selected reward counts: methods `3164/3164`, strong merges `316/513`,
  weak merges `553/714`, late F2 `89/164`, weak G1 `519/714`,
  derived-class reward `60/66`.
