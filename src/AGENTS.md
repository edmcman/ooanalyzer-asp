# src/ — ASP Module Conventions

Seven focused modules; `ooanalyzer.lp` includes them in this fixed order:
`facts.lp` → `initial.lp` → `guess.lp` → `rules.lp` → `insanity.lp` → `optimize.lp` → `output.lp`

## Module responsibilities

| File | Role | Rule: touch only for… |
|---|---|---|
| `facts.lp` | Schema: `#defined` declarations for every predicate | Adding a new input predicate |
| `initial.lp` | Projection of full-arity `.facts` into simplified predicates | Adapting new OOAnalyzer fact arities |
| `guess.lp` | All choice rules `{ }` and `mergeCandidate/2` domain restriction | New guesses or pruning mergeCandidate |
| `rules.lp` | All deterministic derivations; helper predicates | Core logic changes |
| `insanity.lp` | All integrity constraints via `insanity(Tag, Witness)` pattern | New sanity checks or moving inline `:-` here |
| `optimize.lp` | Lexicographic `#maximize` only | Preference priority changes |
| `output.lp` | `#show` directives only | Changing visible output |

## Hard rules

- **No hard constraints outside `insanity.lp`**: inline `:-` bypass `--const diagnose=1`. Move them.
- **Never use `find/2` in rule bodies**: it is display-only. Use raw method IDs or `sameClass/2`.
- **`sortPair/4` for canonical ordering**: use it instead of duplicating `A < B` / `B < A` rule pairs.
- **Merge heads use raw IDs, not `find`**: avoids self-defeating loop when reps merge.
- **Keep `mergeCandidate/2` sparse**: it's the grounding-scale control knob; don't widen without benchmarking.

## Disabled rules — do not re-enable without benchmark + UNSAT check

- `reasonMethod_Q`: causes UNSAT on `ooex4/5/6/9`; commented out in Prolog reference too.
- `inheritedVftableEntry`: caused interaction problems on real binaries; `guessMergeClassesB` is already soft.

## Known bugs (see TODO.md §3)

- `factClassHasNoBase` inline constraint bypasses diagnostic mode (line 373 of `rules.lp`).
- `insanity(cycle)` only catches 2-cycles.
- `insanity(nomethod)` is redundant (can never fire).

## Diagnostic workflow

```sh
clingo --const diagnose=1 ooanalyzer.lp <input>.lp
# emits violate(Tag, Witness) instead of hard UNSAT; shows which constraint fires
# direct signed p/-p clashes can still be UNSAT before violate/2 is emitted
```
