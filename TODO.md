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

### 1.2 Method classification layer
| Predicate(s) | Source | Description | Priority |
|---|---|---|---|
| `factMethod` | `setup.pl`, `rules.pl` | Derives `factMethod(M)` from vftable entries/writers, constructors/destructors, symbols, and call targets (guarded by `possibleMethod`). Implemented; `factNOTMethod` is not. | **High** |
| `reasonMethod` / `reasonMethod_A..P` | `rules.pl` | ~16 heuristics for identifying methods (calling convention, clusters, etc.). `possibleMethod` covers the basic candidates. | **High** |

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
| `sameClass/2` | `src/rules.lp` | Explicit transitive closure materialized as ASP facts. Prolog maintains equivalence via union-find (`find/2`, `union/2`) rather than grounding all pairs. |
| `inheritedVftableEntry/3` | `src/rules.lp` | Detects base-class slots reused in a derived vftable so the merge rule can skip them. Prolog handles this implicitly via `reasonVFTableSizeGTE_B` / `reasonVFTableSizeLTE_B` and union-find. |
| Choice rules `{ }` + integrity constraints `:-` | `src/guess.lp`, `src/insanity.lp` | The "guess/constraint/optimize" skeleton is the ASP equivalent of OOAnalyzer's forward reasoning + chronological backtracking. |
| `#maximize` lexicographic optimization | `src/optimize.lp` | OOAnalyzer uses a binary-search guessing loop (`tryBinarySearch`). Clingo delegates search to the solver with `@2/@1/@0` priority levels. |
| No transitive `sameClass` constraint for `insanityContradictoryMerges` | `src/insanity.lp` | Prolog's `insanityContradictoryMerges` only checks direct `reasonMergeClasses` + `reasonNOTMergeClasses` conflicts. A transitive `sameClass` constraint (`:- objectInObject(M1, M2, _), sameClass(M1, M2).`) is strictly stronger and caused UNSAT on real `.facts` files. |
| `factRealDestructor` as ASP choice rule | `src/rules.lp` | Prolog's `guessRealDestructor` only considers methods called by a confirmed deleting destructor. The Clingo prototype encodes this directly as `{ factRealDestructor(M) } :- callTarget(D, M), factDeletingDestructor(D), ...` rather than guessing all `noCallsAfter` methods. |

---

## Maintenance notes

- When adding a new Clingo rule, check if it maps to an OOAnalyzer predicate and update **Section 1** accordingly.
- When porting an OOAnalyzer rule to Clingo, move it from **Section 1** to the AGENTS.md correspondence table and add any new Clingo-specific helpers to **Section 2**.
- Prefer predicate names over line numbers when referencing source files — line numbers drift as code evolves.
- Verify counts with: `grep -c "^reasonFoo_" pharos/share/prolog/oorules/rules.pl`
