# OOAnalyzer Clingo Prototype -- Rule Coverage TODO

This file tracks the bidirectional mapping between the OOAnalyzer Prolog reference implementation (`pharos/`) and the Clingo ASP prototype (`src/`).

- **Section 1:** OOAnalyzer rules that are **not yet implemented** in the Clingo prototype.
- **Section 2:** Clingo prototype constructs that have **no direct OOAnalyzer counterpart** (ASP-specific encoding helpers).

When a rule is ported, remove it from Section 1. When a new Clingo-specific helper is added, document it in Section 2.

---

## 1. OOAnalyzer rules NOT in Clingo prototype

### 1.1 Destructor & constructor negation
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `reasonNOTRealDestructor_A..J` | `rules.pl` | Full 10-variant negation heuristics. Basic versions (`factNOTRealDestructor`) implemented: constructors and deleting destructors cannot be real destructors; non-`possibleDestructor` methods excluded. | Medium |
| `reasonNOTDeletingDestructor_A..I` | `rules.pl` | Full 9-variant negation heuristics. Basic versions (`factNOTDeletingDestructor`) implemented: constructors and real destructors cannot be deleting destructors. | Medium |
| `reasonNOTConstructor_A/H/I/J` | `rules.pl` | Additional negation heuristics for constructors | Medium |
| `guessConstructor4` / `factConstructor4` | `guess.pl` | Additional constructor guessing variants | Low |
| `reasonDestructorParams` | `rules.pl` | Parameter-based destructor identification | Low |

### 1.2 Method identification
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `reasonMethod_Q` | `rules.pl` | Thunk to proven method -> method. Disabled in prototype because it causes UNSAT on real binaries; Prolog reference also has this rule commented out. | Medium |

### 1.3 Class size reasoning
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factClassSizeGTE` / `reasonClassSizeGTE_A..G` | `rules.pl` | Lower bounds from members, allocations, inherited objects | Medium |
| `factClassSizeLTE` / `reasonClassSizeLTE_A..D` | `rules.pl` | Upper bounds (heap alloc size, derived-class constraint) | Medium |
| `reasonMaximumPossibleClassSize` / `reasonMinimumPossibleClassSize` | `rules.pl` | Aggregated size bounds | Medium |
| `insanityClassSizeInvalid` | `insanity.pl` | `LTE < GTE` sanity check | Medium |
| `insanityMemberPastEndOfObject` | `insanity.pl` | Member access beyond class size | Medium |
| `insanityEmbeddedObjectLarger` | `insanity.pl` | Embedded object exceeds outer size | Medium |

### 1.4 Member access reasoning
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `methodMemberAccess` | `facts.pl` | Raw input: instruction-level member access | Medium |
| `validMethodMemberAccess` / `invalidMethodMemberAccess` | `rules.pl` | Validate / invalidate member accesses | Medium |
| `certainMemberOnClass` / `certainMemberOnExactClass` / `certainMemberNOTOnExactClass` | `rules.pl` | Confident member-to-class assignment | Low |

### 1.5 Virtual function call detection
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factVirtualFunctionCall` / `factNOTVirtualFunctionCall` | `setup.pl`, `rules.pl` | Resolve a concrete virtual call via vftable | Medium |
| `guessVirtualFunctionCall` | `guess.pl` | Guess a possible virtual call is real | Medium |
| `reasonVirtualFunctionCall` | `rules.pl` | Forward-reasoning virtual call resolution | Medium |

### 1.6 Advanced thunk reasoning
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `uniqueThunk` / `conflictedThunk` | `rules.pl` | Distinguish unambiguous vs ambiguous thunk chains | Low |
| `eventualThunk` | `rules.pl` | Forward-reasoning variant of thunk resolution | Low |

### 1.7 Reused / trivial implementation detection
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factReusedImplementation` / `reasonReusedImplementation_A/B` | `rules.pl` | Detect shared implementations (blocks incorrect merges) | Medium |
| `factPossiblyReused` / `possiblyReused` | `rules.pl` | Tentative reused-implementation detection | Low |
| `factTrivial` / `trivial` | `rules.pl` | Trivial method detection | Low |
| `reasonSharedImplementation` | `rules.pl` | Shared deleting destructors across classes | Low |

### 1.8 Additional merge / NOT-merge variants
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `reasonMergeClasses_B/H/J/K` | `rules.pl` | Extra merge heuristics | Medium |
| `reasonMergeVFTables` | `rules.pl` | Early merge of a vftable into a class | Low |
| `factLateMergeClasses_F1/F2/G1/G2` | `guess.pl` | Late-stage merge guesses (singletons, related methods) | Low |
| `factNOTMergeClasses` / `reasonNOTMergeClassesSet` | `rules.pl`, `guess.pl` | Hard "must not merge" facts | Medium |
| `reasonNOTMergeClasses_A/J/K/L/M/O/P/Q/R/new` | `rules.pl` | Many additional NOT-merge heuristics | Medium |
| `reasonNOTMergeClasses_Qhelper` | `rules.pl` | Helper for NOT-merge at offset 0 | Low |

### 1.9 Embedding / derived negation
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factNOTEmbeddedObject` / `reasonNOTEmbeddedObject_*` | `rules.pl` | Explicitly conclude NOT an embedded object | Medium |
| `factNOTDerivedClass` / `reasonNOTDerivedClass_*` | `rules.pl` | Explicitly conclude NOT inheritance | Medium |
| `reasonEmbeddedObject_A/B/C/D` | `rules.pl` | Detailed embedding heuristics | Low |

### 1.10 Object-in-object variants
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `reasonObjectInObject_A..F` | `rules.pl` | Detailed variants of object-in-object detection | Low |

### 1.11 Unknown base / derived existence
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factClassHasUnknownBase` / `reasonClassHasUnknownBase_A..E` | `rules.pl` | "There is a base, but we don't know which one" | Medium |
| `factClassHasNoDerived` / `guessClassHasNoDerived` / `factClassHasUnknownDerived` | `rules.pl`, `guess.pl` | Derived-class existence variants | Low |

### 1.12 VFTable / VBTable negation
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factNOTVFTable` / `reasonNOTVFTable_A..H` | `rules.pl` | Conclude a candidate is NOT a vftable | Medium |
| `factNOTVFTableEntry` / `reasonNOTVFTableEntry_A..E` | `rules.pl` | Conclude an entry is NOT in a vftable | Low |
| `factNOTVBTable` / `factNOTVBTableEntry` / `factNOTVBTableWrite` | `rules.pl` | VBTable negation | Low |

### 1.13 Class relationship / offset reasoning
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `reasonClassAtOffset` / `isOffsetPrecise` | `rules.pl` | Resolve which inner class lives at a nested offset | Medium |
| `reasonClassRelationship` / `reasonClassRelationship_internal` | `rules.pl` | Transitive object-in-object (inheritance or embedding) | Low |
| `reasonClassRelatedMethod_A/B/C` | `rules.pl` | Undirected class-method relationship | Low |
| `reasonClassCallsMethod_B/C` | `rules.pl` | Additional directional call variants | Low |

### 1.14 This-pointer usage analysis
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `thisPtrUsage` / `thisPtrAssociatedWithConstructor` / `thisPtrConstructorCommon` | `rules.pl` | This-pointer usage heuristics | Low |
| `thisPtrAllocation` | `facts.pl` | Heap/stack/global/param allocation | Low |
| `thisPtrOffset` / `thisPtrDefinition` | `facts.pl` | Generalized this-pointer relationships | Low |

### 1.15 Additional sanity checks
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `insanityEmbeddedAndNot` | `insanity.pl` | `factEmbeddedObject` vs `factNOTEmbeddedObject` | Medium |
| `insanityInheritanceAfterNonInheritance` | `insanity.pl` | Inheritance appearing after non-inheritance pattern | Low |
| `insanityInheritanceTwice` | `insanity.pl` | Same class inherited twice at different offsets | Medium |
| `insanityVFTableSizeInvalid` | `insanity.pl` | `LTE < GTE` for vftable | Low |
| `insanityContradictoryNOTConstructor` | `insanity.pl` | `reasonNOTConstructor` vs `factConstructor` | Medium |
| `insanityDestructorDoubleDuty` | `insanity.pl` | Method cannot be both real and deleting destructor | Medium |
| `insanityContradictoryNOTRealDestructor` | `insanity.pl` | `factNOTRealDestructor` vs `factRealDestructor` | Low |
| `insanityContradictoryNOTDeletingDestructor` | `insanity.pl` | `factNOTDeletingDestructor` vs `factDeletingDestructor` | Low |

### 1.16 Final reporting layer
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `finalClass` | `final.pl` | Class summary output | Low |
| `finalVFTable` / `finalVFTableEntry` | `final.pl` | Final vftable report | Low |
| `finalVBTable` / `finalVBTableEntry` | `final.pl` | Final vbtable report | Low |
| `finalEmbeddedObject` | `final.pl` | Embedded object report | Low |
| `finalInheritance` | `final.pl` | Inheritance report | Low |
| `finalMember` / `finalMemberAccess` | `final.pl` | Member definition / evidence | Low |
| `finalResolvedVirtualCall` | `final.pl` | Resolved virtual call report | Low |
| `finalThunk` / `finalDemangledName` | `final.pl` | Thunk / demangling output | Low |

### 1.17 Prolog infrastructure (noted as architecture differences)
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `tryBinarySearch` / `doNotGuess` / `guessed*` | `guess.pl` | Explicit procedural guessing with backtracking | N/A |
| `trigger_fact` / `dispatchTrigger` / `concludeTrigger` | `trigger.pl` | Incremental recomputation triggers | N/A |
| `findint` / `union` / `makeIfNecessary` | `class.pl` | Union-find implementation | N/A |

---

## 2. Clingo prototype constructs with NO OOAnalyzer counterpart

These are encoding artifacts required by ASP grounding / solving and do not correspond to concepts in the OOAnalyzer Prolog implementation.

| Predicate / Construct | Source | Why it is Clingo-specific |
|---|---|---|
| `mergeCandidate/2` | `src/guess.lp` | Domain restriction to prevent O(n²) grounding of the `mergeClasses` guess. Prolog uses incremental tabling and lazy evaluation, so it does not need an explicit candidate set. |
| `hasLesser/1` | `src/rules.lp` | Helper for computing `classRep` as the minimum-address method via negation. Prolog computes `classRep` through the union-find in `class.pl`. |
| `sameClass/2` | `src/rules.lp` | Explicit transitive closure materialized as ASP facts. Prolog maintains equivalence via union-find (`find/2`, `union/2`) rather than grounding all pairs. Compacted with `merged/2` edge predicate to reduce symmetry-rule grounding (~18x reduction on `oo.lp`). |
| `inheritedVftableEntry/3` | `src/rules.lp` | **DISABLED.** Idea: detect base-class slots reused in a derived vftable so the merge rule can skip them. Prolog avoids the problem implicitly because `guessMergeClassesB` is a *soft guess*, not a hard `reasonMergeClasses` rule — so the solver is free to not merge inherited entries. In the Clingo prototype, `guessMergeClassesB` is also a soft guess (via `mergeCandidate`), so the predicate should not be needed here either. **Potential OOAnalyzer improvement:** consider adding an explicit `inheritedVftableEntry` concept to the Prolog side to suppress spurious `reasonMergeClasses_B`-like merges in cases where the sibling-class problem (two classes inheriting from the same base sharing entries) causes incorrect same-class conclusions. |
| Choice rules `{ }` + integrity constraints `:-` | `src/guess.lp`, `src/insanity.lp` | The "guess/constraint/optimize" skeleton is the ASP equivalent of OOAnalyzer's forward reasoning + chronological backtracking. |
| `#maximize` lexicographic optimization | `src/optimize.lp` | OOAnalyzer uses a binary-search guessing loop (`tryBinarySearch`). Clingo delegates search to the solver with `@2/@1/@0` priority levels. |
| No transitive `sameClass` constraint for `insanityContradictoryMerges` | `src/insanity.lp` | Prolog's `insanityContradictoryMerges` only checks direct `reasonMergeClasses` + `reasonNOTMergeClasses` conflicts. A transitive `sameClass` constraint (`:- objectInObject(M1, M2, _), sameClass(M1, M2).`) is strictly stronger and caused UNSAT on real `.facts` files. |
| `factRealDestructor` as ASP choice rule | `src/rules.lp` | Prolog's `guessRealDestructor` only considers methods called by a confirmed deleting destructor. The Clingo prototype encodes this directly as `{ factRealDestructor(M) } :- callTarget(D, M), factDeletingDestructor(D), ...` rather than guessing all `noCallsAfter` methods. |
| `insanity/2` + `diagnosing` | `src/insanity.lp` | All sanity conditions are expressed as `insanity(Tag, Witness) :- condition.` facts; a single dispatch pair converts them to either hard constraints (`:- not diagnosing, insanity(_, _).`) or soft `violate(Tag, Witness)` atoms (`violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).`) depending on `--const diagnose=1`. Run with `--const diagnose=1` to see which constraints fire instead of getting hard UNSAT. This pattern has no OOAnalyzer counterpart. |

---

---

## 3. Known bugs / deviations in current Clingo prototype

These are rules that ARE implemented but have correctness or completeness issues discovered during review.

| Bug | Source | Description | Severity |
|---|---|---|---|
| `reasonMergeClasses_E` missing same-derived check | `src/rules.lp` | Line 235 uses `factDerivedClass(_, B1, Off), factDerivedClass(_, B2, Off)` with anonymous variables, so two **unrelated** derived classes at the same offset spuriously force their bases to merge. Should bind to the same `Derived`. | High |
| `reasonNOTMergeClasses_L/P/R` indexed by reps | `src/rules.lp` | Lines 296-338 derive `reasonNOTMergeClasses(R1, R2)` where `R1,R2` are class reps, but `insanity(not_merge)` checks `reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2)` for methods. If reps aren't in `mergeCandidate`, the constraint never fires for actual violating pairs. | High |
| `possibleVFTableOverwrite` missing `V1 != V2` | `src/initial.lp` | Lines 72-75 derive overwrite even when two instructions write the **same** vftable at the same offset. Downstream `reasonDerivedClass_B` then treats it as a base-to-derived overwrite. | High |
| `mergeCandidate` gap for `reasonMergeClasses_C` | `src/guess.lp` | Lines 42-43 cover direct `callAtOffset(Caller, Callee, 0)` pairs, but `reasonMergeClasses_C` (rules.lp:385-388) operates on class reps. If the caller is not its own rep, `(R1, R2)` is not in `mergeCandidate`, causing unavoidable UNSAT when two no-base classes call each other at offset 0. | High |
| `factClassHasNoBase` hard constraint bypasses diagnostic mode | `src/rules.lp` | Line 373 is an inline `:-` constraint, not an `insanity/2` fact, so it remains hard even when `--const diagnose=1` is passed. Should be moved to `insanity.lp`. | Medium |
| `insanity(vft_diff)` incorrect and redundant | `src/insanity.lp` | Lines 38-39 check `factVFTableWrite` without requiring `factConstructor`, apply to any offset, and lack guards that Prolog `reasonNOTMergeClasses_E` uses. Also redundant since `rules.lp:277-281` already covers it via `insanity(not_merge)`. | Medium |
| `insanity(cycle)` only catches 2-cycles | `src/insanity.lp` | Line 45 only detects `A→B→A`. Longer cycles (e.g. `A→B→C→A`) escape detection. | Medium |
| `possibleMethod` misses callees | `src/initial.lp` | Line 133 only includes `Address` as a caller (`callTarget(_, Address, _)`). Methods that are only ever called and lack other indicators are excluded from `possibleMethod`, blocking them from becoming `factMethod`. | Medium |
| Missing offset-0 preference in optimization | `src/optimize.lp` | `factDerivedClass(Outer, Inner, _)` weights all offsets equally, but offset-0 inheritance is the dominant case and should be preferred. | Medium |
| `insanity(nomethod)` is redundant | `src/insanity.lp` | Line 42 can never fire because `rules.lp:65` already hard-derives `factMethod` from `factVFTableEntry`. | Low |

## Maintenance notes

- When adding a new Clingo rule, check if it maps to an OOAnalyzer predicate and update **Section 1** accordingly.
- When porting an OOAnalyzer rule to Clingo, move it from **Section 1** to the AGENTS.md correspondence table and add any new Clingo-specific helpers to **Section 2**.
- Prefer predicate names over line numbers when referencing source files — line numbers drift as code evolves.
- Verify counts with: `grep -c "^reasonFoo_" pharos/share/prolog/oorules/rules.pl`
