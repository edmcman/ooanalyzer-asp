# Propagator Bug: Circular `&sameClass` Bootstrap

## Problem

The `SameClassPropagator` can incorrectly merge unrelated classes by enabling a
self-justifying cycle between `mergeClasses/2` and `&sameClass/2`.

### How it happens

1. **K-rule grounding.** Rules like `reasonMergeClasses_K` have `&sameClass` in
   their body and `mergeClasses` in their head. The grounder produces ground
   instances such as:

   ```
   mergeClasses(CM, TI) :- &sameClass(CM, TI), &sameClass(M, TI), ...
   ```

   even for class pairs (CM, TI) with no independent merge evidence.

2. **`_potential_uf` includes K-rule heads.** `init()` builds `_potential_uf`
   from *all* grounded `mergeClasses/2` atoms, including those from K-rule heads.
   This makes `_potential_uf.same(CM, TI) = True`, so `&sameClass(CM, TI)` is
   not forced permanently false and the solver is allowed to guess it true.

3. **`_assert_not_same` creates a circular cut clause.** When the solver guesses
   `&sameClass(CM, TI) = true` but the union-find has no path yet, `check()` calls
   `_assert_not_same`. The cut around CM's singleton component contains exactly the
   K-rule-derived `mergeClasses(CM, TI)` edge. The added clause is:

   ```
   mergeClasses(CM, TI)  ∨  ¬&sameClass(CM, TI)
   ```

4. **Unit propagation closes the loop.** Since `&sameClass(CM, TI)` is true
   (by assumption), unit propagation forces `mergeClasses(CM, TI) = true`. The
   propagator's `propagate()` then joins CM into TI's union-find component,
   which confirms `&sameClass(CM, TI)`. The model is self-consistent.

Clingo's unfounded-set checker would catch this cycle if `sameClass` were a
normal ASP predicate, but the theory-atom boundary makes the cycle invisible to
it.

## Observed symptom

`CPluginManager` methods are merged into the `type_info` class even though no
seed merge connects them. `classHasNoBase` has only `type_info::vftable` as a
witness (RTTI-derived); the K-rule therefore grounds `mergeClasses(CM, type_info)`
for every method CM that is `classRelatedMethod` with any type_info method,
providing the circular edge.

## Fix (implemented — no .lp changes needed)

**Potential-UF least fixpoint** replaces the old union-all seeding in `init()`.

`SameClassPropagator` now also implements the clingo observer interface.
`ooanalyzer.py` registers it before grounding:

```python
ctl.register_observer(prop)   # must come before register_propagator
ctl.register_propagator(prop)
```

During grounding the observer collects every ground rule as
`(choice, heads_tuple, pos_body_tuple)`.  In `init()`, `_build_potential_uf()`
runs a least fixpoint:

- **Seed**: facts (rules with no positive body) and choice-rule heads are
  immediately derivable. `weight_rule` heads and externals are conservative.
- **Non-tracked atoms** (anything that is not a `mergeClasses` or `&sameClass`
  program literal) are treated as unconditionally derivable — they are structural
  ground facts that do not participate in the circular bootstrap.
- **mergeClasses(a,b)** becomes derivable when some supporting rule has all
  positive body atoms derivable, where `&sameClass(x,y)` body literals require
  `potential_uf.same(x,y)`.  When a merge atom becomes derivable it is unioned
  into `_potential_uf`, which may enable further sc atoms.
- The fixpoint iterates until no new merge atoms are added.

Effect: `mergeClasses(CM, TI)` that is supported only by a K-rule requiring
`&sameClass(CM, TI)` never enters `_potential_uf` because that sc atom is
cross-component until the edge exists.  `&sameClass(CM, TI)` is therefore forced
permanently false at level 0, and the cut clause in `_assert_not_same` can never
unit-propagate the K-edge true.

**Why this supersedes the `seedMergeClasses` proposal.** The observer-based
fixpoint is both correct and more precise:
- No .lp changes required.
- It handles intermediates like `reasonMergeClassesKUnsorted` automatically.
- It admits K-rule heads that are *legitimately* derivable — i.e., their `&sameClass`
  preconditions are satisfiable via seed-founded edges — without pre-blocking them.
  A pure seed-only filter would incorrectly force those permanently false.

Falls back to union-all (original behaviour) if the observer was not registered.

## Residual: within-component circular case

After the fixpoint fix, a second circular path remains: if a and c are in the
same potential-UF component via seed choice edges (say a-b, b-c), a K-rule
`mergeClasses(a,c) :- &sameClass(a,c)` is admitted into `_potential_uf`.  If the
solver guesses both seed merges false but then guesses `&sameClass(a,c)=true`,
the cut clause unit-propagates `mergeClasses(a,c)=true`, which joins a and c in
the live UF, confirming `&sameClass(a,c)`.

**Foundedness check** (flag `--foundedness-check`): at every total assignment,
`_check_foundedness()` in `check()` builds a *founded union-find* from true merge
atoms that have a non-circular support:
- Seed: merge atoms in `_obs_unconditional` (choice facts) that are true.
- Fixpoint: admit a true merge atom when some supporting rule's sc body atoms are
  *founded-same* in the founded UF and all non-sc atoms are true.
- Any true merge atom absent from the founded set is unfounded → rejected with
  `add_clause([-slit])`.

Enable with `python ooanalyzer.py --foundedness-check examples/...` to close the
residual case.  The extra cost is one fixpoint pass per total assignment over the
(typically small) set of K/E-derived true merge atoms.
