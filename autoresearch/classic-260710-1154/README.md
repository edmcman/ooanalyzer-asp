# All-input Domain priority experiment

Date: 2026-07-10

## Hypothesis

Putting every genuine choice/input atom in one high Domain-heuristic priority
tier will make clasp branch on causal inputs before derived size/reward/theory
outputs.  If the plateau is partly an output-first artifact, this should reduce
the derived/reward share of direct decisions, shorten conflicts, and improve
TinyXml's 300-second anytime objective.

The measured prototype used an enable flag plus priority 10.  The retained,
equivalent interface is default-off and enabled directly with:

```sh
--const all_input_priority=10
```

It covers the dynamic merge gate, method, constructor/destructor kind,
constructor guesses, vftable, exact vftable size, embedded-vs-derived
classification, and strong/weak/late merge inputs.  Existing phase directives
remain unchanged.

## Baseline

Current HEAD before the experiment: `4764b6f` plus pre-existing user changes.
Exact 300-second BB/domain baseline: `[-704,-37521]`, 27.0M choices, 346k
conflicts, 858 restarts, average conflict clause length 1347, average backjump
68.  Native trace: `/tmp/fun.jsonl`.

## Original acceptance signal

1. Verification remains green.
2. A traced probe shifts direct decisions materially toward genuine inputs.
3. The matched 300-second run improves the incumbent basin or meaningfully
   improves conflict leverage without a severe time-to-first-model regression.

If these signals fail, remove the overlay and keep this directory as the
negative experiment record.

The user subsequently clarified that model cadence and avoiding long stalls
matter more than the best objective reached in 300 seconds.  Under the revised
metric, acceptance is: preserve correctness, increase the number of improving
models, and reduce the longest no-improvement interval; final cost is reported
as a tradeoff rather than used as the gate.

## Results

Verification passed: 63/63 propagator tests, `example.lp` remained optimal at
`[-24,-330]`, and `invalid_example.lp` remained UNSAT.

The first overlay placed all inputs at one common heuristic priority. Its
120-second native trace changed the symbolic predicate mix: explicit
merge/embedded/derived labels in the last 100 decision-stack entries rose from
about 4% to about 15%, while reward labels fell from about 90% to about 62%.
The inspector alias limitation documented below means this locates a different
logical region, not necessarily distinct input-vs-output decisions. Its
incumbent was only `[-704,-36944]` at 120 s, versus the baseline's
`[-704,-37357]`.

The clean 300-second candidate finished at `[-704,-37129]` with 19 models,
42.57M choices, 551,489 conflicts, 1,326 restarts, average conflict-clause
length 1369.8, and average backjump 67.89.  The clean baseline finished at
`[-704,-37521]` with 8 models, 26.99M choices, 345,954 conflicts, 858 restarts,
average conflict-clause length 1347.2, and average backjump 68.26.  Global
input priority therefore caused 58% more choices and 59% more conflicts while
finding a secondary objective 392 points worse.  It also produced 19 improving
models instead of 8 and reduced the longest between-model stall from about
151 seconds to about 70 seconds.  The extra models are local motion within a
worse partition basin, which is nevertheless the desired behavior under the
revised cadence metric.

A second overlay preserved the original relative heuristic priorities by
adding a common offset (vftable `@13`, strong merge `@12`, weak/late `@11`,
base inputs `@10`).  Its 120-second trace reproduced the exact same 12-model
cost sequence and `[-704,-36944]` endpoint, so flattening the family priorities
was not the cause.

The requested 1,800-second follow-up invalidated the apparent cadence result.
It finished at `[-704,-37267]` after 27 models, 103.11M choices, 4.53M
conflicts, and 8,190 restarts.  After model 19 at 230.14 s, the next incumbent
did not arrive until 954.00 s: a **723.85-second plateau** for an 8-point gain.
A later 446-second plateau ended in a short burst, and the final 4-point gain
required another 197.68 seconds.  Average learned conflict clauses remained
huge (1,374 literals); average backjump fell to only 15.98 levels.  The solver
was continuously active, but learned facts were too local to redirect the
global class partition.

## Verdict

**NEGATIVE FOR AVOIDING PLATEAUS; RETAINED ONLY AS A DIAGNOSTIC OPT-IN.**  The
300-second cadence gain was front-loaded and a cutoff artifact.  The 30-minute
run produced a much longer plateau than the baseline window and remained 254
secondary-objective points worse than the baseline reached in 300 seconds.
The overlay remains available behind `--const all_input_priority=10`, with the
default still `0`, because it is useful for reproducing the decision-region
experiment; it should not be described as an anti-stall setting.  A semantic
family order or coordinated class-component moves are required to change the
partition basin.

## Prolog-family-order follow-up

The follow-up question exposed a more important distinction: prioritizing all
inputs equally is not equivalent to Prolog's procedural guess order.  The
reference driver (`setup.pl:506-582`) repeatedly tries vftable and
derived-vs-embedded guesses, then methods and vftable entries, then
destructor/constructor classification, then normal merges, and only finally
late merges.  After each guess it saturates forward reasoning and starts the
family scan again at the top.

A now-default `prolog_order_priority=10` approximation assigns strict
Domain levels and positive-first phases to the corresponding choice families
available in v2.  With `--decide-inputs` and the otherwise requested BB/domain
flags, TinyXml reached `[-704,-41358]` in 48.92 s, `[-704,-41374]` in 50.74 s,
and `[-704,-41382]` in 108.99 s.  It then plateaued through the 300 s cutoff.
Compared with the blanket-input 300 s run, average conflict clauses shrank
from 1369.8 to 536.1 literals, average backjump grew from 67.89 to 256.65
levels, and conflicts fell from 551,489 to 173,765.  Semantic order therefore
finds a substantially better initial partition and produces more useful
conflicts, though literal ordering alone does not eliminate later plateaus.

This is an approximation, not a literal port: v2 does not expose every Prolog
guess family as a choice atom, and `#heuristic` cannot reproduce Prolog's
sorted/batched `tryBinarySearch` or its procedural cut behavior. Set
`--const prolog_order_priority=0` to restore the previous Domain ordering.
After promotion, a 60-second run with the constant omitted reproduced
`[-704,-41358]` at 48.64 s and `[-704,-41374]` at 50.50 s. The regression
suite remained 63/63 passing.

## Inspector alias correction

The native inspector currently records one predicate name per absolute solver
literal (`preds.insert(lit.abs(), name)`).  Preprocessing can map an input such
as `mergeClasses(A,B)` and a derived reward such as `weakMergeReward(A,B)` to
the same solver literal; the last symbolic atom visited overwrites the earlier
label.  Consequently, stack percentages labelled as reward/output predicates
do **not** prove that clasp chose an output instead of the prioritized input.
Some genuine output fallbacks can occur after applicable inputs are exhausted,
but the current trace cannot distinguish those from aliases.  Future causal
analysis should retain all symbolic aliases or prefer genuine choice-input
labels.
