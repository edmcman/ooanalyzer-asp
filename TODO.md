# OOAnalyzer Rule Coverage

Tracks the port of `pharos/share/prolog/oorules/rules.pl` (~3734 lines) to Clingo.

**Status:** `[ ]` todo · `[~]` partial · `[x]` done

**Rule types:**
- `reason*` (rules.pl) → Clingo derivation rules
- `guess*` (guess.pl) → Clingo choice rules + optimization
- `insanity*` (insanity.pl) → Clingo `:- constraints`

---

## Solver Engineering

- [ ] Put `sortPair` in theory
- [ ] Put `nextRegularMethod` in theory

---

## 1. Method (`method`)

### Deductive (rules.pl:26–177)
- [x] `reasonMethod_A` (48) — existing `method` (identity rule; covered by input fact / choice rule architecture)
- [x] `reasonMethod_B` (52) — `constructor` → method
- [x] `reasonMethod_C` (56) — `realDestructor` → method
- [x] `reasonMethod_D` (60) — `deletingDestructor` → method
- [x] `reasonMethod_E` (64) — `symbolClass` → method
- [x] `reasonMethod_F` (68) — `symbolProperty` → method
- [x] `reasonMethod_G` (73) — `vfTableEntry` → method
- [x] `reasonMethod_H` (80) — `vfTableWrite` → method
- [ ] `reasonMethod_I` (85) — `vbTableWrite` → method
- [x] `reasonMethod_J` (99) — `classCallsMethod` → method
- [ ] `reasonMethod_K` (103) — `thisPtrUsage` → method
- [x] `reasonMethod_L` (109) — `methodCallAtOffset` → method
- [ ] `reasonMethod_M` (118) — `thisPtrAllocation` → method
- [ ] `reasonMethod_N` (133) — thiscall calling convention
- [ ] `reasonMethod_O` (142) — thiscall via `thisPtrParam`

### Guess (guess.pl)
- [x] `guessMethod_A` (guess.pl:382)
- [ ] `guessMethod_B`–`guessMethod_G` (remaining priority variants)

---

## 2. Constructor (`constructor`)

### Deductive (rules.pl:186–242)
- [x] `reasonConstructor` (186) — existing `constructor` (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonConstructor` (192) — elimination: only remaining candidate (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonConstructor` (204) — `vbTableWrite` → constructor
- [x] `reasonConstructor` (209) — `symbolProperty(constructor)`
- [ ] `reasonConstructor` (214) — inheritance special case

### NOT Constructor (rules.pl:260–373)
- [x] `reasonNOTConstructor_A` (276) — existing `notConstructor` (identity rule; covered by input fact / strong-negation architecture)
- [x] `reasonNOTConstructor_B` (281) — is real destructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [x] `reasonNOTConstructor_C` (288) — is deleting destructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [x] `reasonNOTConstructor_D` (297) — appears in vftable (strong negation; replaces `insanityConstructorInVFTable`)
- [ ] `reasonNOTConstructor_F` (316) — called by non-constructor
- [ ] `reasonNOTConstructor_G` (327) — vftable entry requirement
- [x] `reasonNOTConstructor_H` (345) — vftable not installed by method on same class
- [ ] `reasonNOTConstructor_I` (359) — negative offset call
- [ ] `reasonNOTConstructor_J` (367) — called after constructor

### Guess (guess.pl)
- [x] `guessConstructor1` (guess.pl:574) — writes vftable, not possibly virtual, no uninitialized reads
- [x] `guessConstructor2` (guess.pl:592) — writes vftable, not possibly virtual, uninitialized reads ok
- [ ] `guessConstructor3` (guess.pl:612)
- [ ] `guessConstructor4` (guess.pl:631)
- [ ] `guessNOTConstructor`
- [ ] `guessUnlikelyConstructor`

### Constraints (insanity.pl)
- [x] `insanityConstructorAndRealDestructor` — covered by `insanityMultipleConstructorDestructorKinds`
- [x] `insanityConstructorAndDeletingDestructor` — covered by `insanityMultipleConstructorDestructorKinds`
- [x] `insanityContradictoryNOTConstructor` — ctor ∩ ¬ctor = ∅ (enforced by ASP classical negation; `constructor(M)` and `-constructor(M)` cannot coexist)

---

## 3. Real Destructor (`realDestructor`)

### Deductive (rules.pl:382–404)
- [x] `reasonRealDestructor` (382) — existing `realDestructor` (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonRealDestructor` (388) — elimination (only remaining candidate) (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonRealDestructor` (394) — `symbolProperty(realDestructor)`

### NOT Real Destructor (rules.pl:422–560)
- [x] `reasonNOTRealDestructor_A` (438) — existing `factNOTRealDestructor` (identity rule; covered by input fact / strong-negation architecture)
- [x] `reasonNOTRealDestructor_B` (443) — is constructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [x] `reasonNOTRealDestructor_C` (448) — is deleting destructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [ ] `reasonNOTRealDestructor_D` (453) — call ordering violation
- [ ] `reasonNOTRealDestructor_E` (462) — single destructor per class
- [ ] `reasonNOTRealDestructor_F` (476) — self-destruction pattern
- [ ] `reasonNOTRealDestructor_G` (488) — vftable writes present
- [ ] `reasonNOTRealDestructor_I` (543) — parameter count
- [ ] `reasonNOTRealDestructor_J` (554) — negative offset

### Guess (guess.pl)
- [ ] `guessRealDestructor`
- [ ] `guessFinalRealDestructor` (4 variants)

### Constraints (insanity.pl)
- [x] `insanityTwoRealDestructorsOnClass` — at most one real destructor per class

---

## 4. Deleting Destructor (`deletingDestructor`)

### Deductive (rules.pl:569–595)
- [x] `reasonDeletingDestructor` (569) — existing `deletingDestructor` (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonDeletingDestructor` (575) — elimination (only remaining candidate) (covered by choice rule + insanityMultipleConstructorDestructorKinds)
- [x] `reasonDeletingDestructor` (585) — delete(this) logic
- [x] `reasonDeletingDestructor` (595) — `symbolProperty(deletingDestructor)`
- [x] helper `possiblyVirtual/1` (initial.pl:338) — possible vftable entry evidence

### NOT Deleting Destructor (rules.pl:612–712)
- [x] `reasonNOTDeletingDestructor_A` (627) — existing `factNOTDeletingDestructor` (identity rule; covered by input fact / strong-negation architecture)
- [x] `reasonNOTDeletingDestructor_B` (632) — is constructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [x] `reasonNOTDeletingDestructor_C` (637) — is real destructor (covered by `insanityMultipleConstructorDestructorKinds` + choice rule)
- [ ] `reasonNOTDeletingDestructor_D` (642) — call ordering violation
- [ ] `reasonNOTDeletingDestructor_E` (648) — self-deletion pattern
- [x] `reasonNOTDeletingDestructor_F` (667) — delete not detected
- [x] `reasonNOTDeletingDestructor_G` (687) — virtual requirement missing
- [x] `reasonNOTDeletingDestructor_H` (695) — parameter count
- [ ] `reasonNOTDeletingDestructor_I` (705) — negative offset

### Guess (guess.pl)
- [ ] `guessDeletingDestructor`
- [ ] `guessFinalDeletingDestructor`

---

## 5. VFTable (`vfTable`)

### Identification (rules.pl:838–923)
- [x] `reasonVFTable` (838) — existing `vfTable` (identity rule; covered by input fact architecture)
- [x] `reasonVFTable` (843) — RTTI evidence
- [ ] `reasonVFTable` (851) — virtual call evidence
- [ ] `reasonNOTVFTable_A` (883) — address is a method
- [ ] `reasonNOTVFTable_B` (887) — address is a VBTable
- [ ] `reasonNOTVFTable_C` (891) — global object pointer
- [ ] `reasonNOTVFTable_D` (895) — RTTI TypeDescriptor
- [ ] `reasonNOTVFTable_E` (901) — RTTI COL
- [ ] `reasonNOTVFTable_F` (907) — RTTI CHD
- [ ] `reasonNOTVFTable_G` (913) — RTTI BCD
- [ ] `reasonNOTVFTable_H` (919) — vftable entry chain conflict

### Write (rules.pl:931–944)
- [x] `reasonVFTableWrite` (931) — existing `vfTableWrite` (identity rule; covered by input fact architecture)
- [x] `reasonVFTableWrite` (939) — `possibleVFTableWrite` + confirmed `vfTable`

### Overwrite (rules.pl:962–992)
- [x] `reasonVFTableOverwrite` (962) — constructor direction (base → derived)
- [x] `reasonVFTableOverwrite` (976) — destructor direction (derived → base)

### Entry (rules.pl:1228–1322)
- [~] `reasonVFTableEntry` (1228) — existing `vfTableEntry` (no-op in ASP, skipped)
- [x] `reasonVFTableEntry` (1233) — offset 0 from class membership
- [x] `reasonVFTableEntry` (1239) — propagation from known entry / VFTable size lower bound
- [x] `reasonVFTableEntry` (1247) — from virtual function call
- [~] `reasonNOTVFTableEntry_A` (1276) — existing `notVFTableEntry` (no-op in ASP, skipped)
- [x] `reasonNOTVFTableEntry_B` (1282) — table address invalid
- [x] `reasonNOTVFTableEntry_C` (1292) — previous slot is not a confirmed entry (breaks contiguity)
- [x] `reasonNOTVFTableEntry_D` (1303) — RTTI COL address is not a vftable entry
- [x] `reasonNOTVFTableEntry_E` (1313) — entry dethunks to a constructor

### Belongs-to-Class (rules.pl:1007–1228)
- [x] `reasonVFTableBelongsToClass` (1007) — clause 1 (via VFTable write)
- [x] `reasonVFTableBelongsToClass` (1118) — clause 2 (via inheritance)

### Sizing (rules.pl:1333–1406)
- [x] `reasonVFTableSizeGTE` (1333) — existing fact (identity rule; covered by input fact architecture)
- [x] `reasonVFTableSizeGTE` (1337) — from known entries via exact `vfTableSize` coverage constraint
- [ ] `reasonVFTableSizeGTE` (1350) — from derived class table
- [x] `reasonVFTableSizeLTE` (1388) — existing fact (identity rule; covered by input fact architecture)
- [ ] `reasonVFTableSizeLTE` (1392) — from table entry gap
- [ ] `reasonVFTableSizeLTE` (1406) — from derived/base relationship

### Merge (rules.pl:2722)
- [x] `reasonMergeVFTables` (2722) — merge vftable with the class that owns it

### Guess (guess.pl)
- [x] `guessVFTable` (guess.pl:180)
- [ ] `guessVFTableEntry1` (priority 1)
- [ ] `guessVFTableEntry2` (priority 2)

### Constraints (insanity.pl)
- [ ] `insanityVFTableOnTwoClasses` — vftable belongs to at most one class
- [ ] `insanityVFTableSizeInvalid` — LTE < GTE is UNSAT
- [ ] `insanityBaseVFTableLarger` — base vftable ≤ derived vftable
- [~] `insanityConstructorInVFTable` — superseded by `reasonNOTConstructor_D` strong negation

---

## 6. VBTable (`vbTable`)

### Deductive (rules.pl:1471–1535)
- [x] `reasonVBTable` (1471) — existing `vbTable` (identity rule; covered by input fact architecture)
- [ ] `reasonVBTable` (1476) — `possibleVBTableWrite` evidence
- [x] `reasonVBTableWrite` (1487) — existing `vbTableWrite` (identity rule; covered by input fact architecture)
- [ ] `reasonVBTableWrite` (1491) — `possibleVBTableWrite` + confirmed table
- [x] `reasonVBTableEntry` (1504) — existing fact (identity rule; covered by input fact architecture)
- [ ] `reasonVBTableEntry` (1509) — from `initialMemory` at table offset
- [ ] `reasonVBTableEntry` (1516) — propagation
- [ ] `reasonVBTableEntry` (1523) — from size constraint

### Guess (guess.pl)
- [ ] `guessVBTable`

---

## 7. Virtual Function Call (`factVirtualFunctionCall`)

### Deductive (rules.pl:1434–1460)
- [ ] `reasonVirtualFunctionCall` (1434) — direct virtual call
- [ ] `reasonVirtualFunctionCall` (1454) — via callee resolution

### Guess (guess.pl)
- [ ] `guessVirtualFunctionCall`

---

## 8. Object-in-Object / Embedded Object

### ObjectInObject (rules.pl:1552–1729)
- [x] `reasonObjectInObject_A` (1564) — from `derivedClass`
- [x] `reasonObjectInObject_B` (1568) — from `embeddedObject`
- [ ] `reasonObjectInObject_C` (1577) — from VFTable write at non-zero offset
- [ ] `reasonObjectInObject_D` (1589) — from VBTable write pattern
- [ ] `reasonObjectInObject_E` (1625) — from `callAtOffset` pattern
- [ ] `reasonObjectInObject_F` (1672) — from class size constraints

### EmbeddedObject (rules.pl:1730–1791)
- [x] `reasonEmbeddedObject_A` (1740) — from objectInObject + ¬derived (deterministic when derivedClass has no support)
- [ ] `reasonEmbeddedObject_B` (1745) — from member access at offset
- [ ] `reasonEmbeddedObject_C` (1753) — from VFTable write at offset
- [ ] `reasonEmbeddedObject_D` (1761) — from constructor call pattern
- [x] `reasonNOTEmbeddedObject` (1791) — when derivation is proven (covered by `:- embeddedObject, derivedClass`)

### Guess (guess.pl)
- [ ] `tryEmbeddedObject` (3 variants) — rewards not yet ported

### Constraints (insanity.pl)
- [ ] `insanityEmbeddedObjectLarger` — inner object ≤ outer object size
- [ ] `insanityObjectCycle` — no cycles in object containment
- [ ] `insanityInheritanceTwice` — no duplicate inheritance at different offsets
- [x] `insanityEmbeddedAndNot` — covered by `:- embeddedObject, derivedClass`


---

## 9. Derived Class / Inheritance (`derivedClass`)

### Deductive (rules.pl:1811–1999)
- [x] `reasonDerivedClass_A` (1823) — identity
- [x] `reasonDerivedClass_B` (1834) — VFTable overwrite pattern (ctor sequence)
- [x] `reasonDerivedClass_C` (1960) — objectInObject + NOT embeddedObject → derivedClass (ported as guess rule + mutual-exclusion constraint in composition.lp)
- [x] `reasonDerivedClass_D` (1968) — RTTI non-virtual base
- [x] `reasonDerivedClass_E` (1981) — RTTI virtual base via VBTable entry
- [x] `reasonDerivedClass_F` (1999) — VBTable entry + write confirms virtual base offset (non-RTTI path)

### NOT Derived Class (rules.pl:2025–2036)
- [x] `reasonNOTDerivedClass` (2025) — existing `factNOTDerivedClass` (identity rule; covered by input fact / strong-negation architecture)
- [x] `reasonNOTDerivedClass` (2036) — contradicts embedded object (covered by `:- embeddedObject, derivedClass`)

### Class Relationships (rules.pl:2063–2130)
- [x] `reasonDerivedClassRelationship` (2063) — direct derivation
- [x] `reasonDerivedClassRelationship` (2069) — transitive through ancestor
- [x] `reasonClassRelationship_internal` (2114) — derived → base (direct)
- [x] `reasonClassRelationship_internal` (2119) — transitive chain

### Has No Base (rules.pl:2131–2175)
- [x] `reasonClassHasNoBase` (2131) — existing fact (identity rule; covered by input fact architecture)
- [x] `reasonClassHasNoBase` (2136) — RTTI rTTINoBase → classHasNoBase
- [x] `reasonClassHasNoDerived` (2152) — RTTI TDA with no rTTIAncestorOf entry → classHasNoDerived

### Has Unknown Base (rules.pl:2175–2339)
- [ ] `reasonClassHasUnknownBase_A` (2188) — VFTable entry inherited but base unknown
- [ ] `reasonClassHasUnknownBase_B` (2194) — class calls method from unknown base
- [ ] `reasonClassHasUnknownBase_C1` (2207) — ancestor VFTable entry appears in derived
- [ ] `reasonClassHasUnknownBase_C2` (2242) — ancestor constructor called but unmapped
- [ ] `reasonClassHasUnknownBase_C3` (2282) — derived VFTable lacks base entry
- [ ] `reasonClassHasUnknownBase_D` (2318) — embedded object with no base
- [ ] `reasonClassHasUnknownBase_E` (2331) — class calls method of unrelated class

### Guess (guess.pl)
- [x] `guessDerivedClass` (3 variants)
- [ ] `guessClassHasNoBase_B`
- [ ] `guessClassHasNoBaseSpecial`
- [ ] `guessCommitClassHasNoBase`
- [ ] `guessClassHasNoDerived`
- [ ] `guessClassHasNoDerivedSpecial`
- [ ] `guessCommitClassHasNoDerived`

### Constraints (insanity.pl)
- [x] `insanityNoBaseConsistency` — `hasNoBase` ∩ `derivedClass` = ∅

---

## 10. Class Merging (`mergeClasses` / `sameClass`)

### Merge (rules.pl:2748–2939)
- [ ] `reasonMergeClasses_B` (2792) — method class merges with base class
- [ ] `reasonMergeClasses_C` (2822) — existing class association
- [x] `reasonMergeClasses_E` (2847) — two classes both direct bases of same derived at same offset must merge
- [x] `reasonMergeClasses_G` (2881) — symbols with same class name
- [ ] `reasonMergeClasses_H` (2895) — derived constructor calls base
- [x] `reasonMergeClasses_J` (2925) — RTTI says two VFTables belong to same class
- [x] `reasonMergeClasses_K` (2939) — class-related method and both classes have no base

### NOT Merge (rules.pl:3041–3383)
- [ ] `reasonNOTMergeClasses_A` (3073) — different base classes
- [x] `reasonNOTMergeClasses_C` (3111) — one is derived of other
- [x] `reasonNOTMergeClasses_C_asymmetric` (3090) — asymmetric derivation
- [x] `reasonNOTMergeClasses_E` (3123) — write distinct VFTables at offset 0
- [x] `reasonNOTMergeClasses_F` (3158) — same derived class has two bases at different offsets
- [x] `reasonNOTMergeClasses_G` (3177) — subsumed by reasonNOTMergeClasses_J (objectInObject ⊆ classRelationship_closed)
- [x] `reasonNOTMergeClasses_I` (3196) — different RTTI TDAs/classes
- [x] `reasonNOTMergeClasses_J` (3212) — classes in a composition/inheritance relationship cannot merge
- [x] `reasonNOTMergeClasses_K` (3222) — conflicting symbol class names
- [ ] `reasonNOTMergeClasses_L` (3240) — overlapping object layouts
- [ ] `reasonNOTMergeClasses_M` (3256) — size contradiction (GTE > LTE)
- [ ] `reasonNOTMergeClasses_O` (3296) — called method member access exceeds caller class size
- [ ] `reasonNOTMergeClasses_P` (3318) — different constructors at same offset
- [x] `reasonNOTMergeClasses_Q` (3352) — symbol class name missing/mismatch within class
- [x] `reasonNOTMergeClasses_R` (3366) — derived vftable installed by called method

### Guess (guess.pl)
- [x] `guessMergeClasses_B`
- [ ] `guessMergeClasses_C1`–`guessMergeClasses_C4`
- [x] `guessMergeClasses_D`
- [ ] `guessMergeClasses_G`
- [ ] `guessLateMergeClasses_F1`, `_F2`
- [x] `guessLateMergeClasses_G1` — constructor bonus on weak merge candidates
- [x] `guessLateMergeClasses_G2` — classRelatedMethod weak merge candidates
- [ ] `guessNOTMergeClasses`

### Constraints (insanity.pl)
- [ ] `insanityContradictoryMerges` — `mergeClasses` ∩ `¬mergeClasses` = ∅

---

## 11. Class Size (`classSizeGTE` / `classSizeLTE`)

### Size Lower Bound (rules.pl:3487–3661)
- [x] `reasonClassSizeGTE_A` (3500) — existing fact (identity rule; covered by input fact architecture)
- [x] `reasonClassSizeGTE_B` (3505) — all proven methods/vftables give size ≥ 0 (`size.lp`)
- [x] `reasonClassSizeGTE_C` (3519) — derived class inherits base class lower bound — subsumed by `_B` + `_F` (re-add only if `_B` is dropped)
- [x] `reasonClassSizeGTE_D` (3609) — from heap allocation size tracked to constructor (`size.lp`)
- [ ] `reasonClassSizeGTE_E` (3624) — from member access offset + member size
- [x] `reasonClassSizeGTE_F` (3637) — from embedded object: outer offset + inner size (`size.lp`)
- [x] `reasonClassSizeGTE_G` (3653) — from vftable write at ObjectOffset + PtrSize (`size.lp`)

### Size Upper Bound (rules.pl:3679–3722)
- [x] `reasonClassSizeLTE_A` (3689) — existing fact (identity rule; covered by input fact architecture)
- [x] `reasonClassSizeLTE_B` (3693) — universal upper bound (0x0fffffff) for every constructor's class; ported but **commented out** in `size.lp` as inert
- [x] `reasonClassSizeLTE_C` (3703) — from heap allocation size tracked to constructor (`size.lp`; shares `thisPtrAssociatedWithConstructor` with `GTE_D`)
- [ ] `reasonClassSizeLTE_D` (3716) — from base class in derived layout

### Constraints (insanity.pl)
- [x] `insanityClassSizeInvalid` — LTE < GTE is UNSAT (`size.lp`; GTE/LTE witnesses joined via `&sameClass`)
- [ ] `insanityMemberPastEndOfObject` — member offset + size > class LTE

---

## 12. Class–Method Relations

### Related Methods (rules.pl:2354–2496)
- [x] `reasonClassRelatedMethod_A` (2361) — `classCallsMethod` implies class-related method (undirected)
- [x] `reasonClassRelatedMethod_B` (2372) — method called by class method
- [ ] `reasonClassRelatedMethod_C` (2414) — method of embedded inner class

### Class Calls Method (rules.pl:2449–2496)
- [ ] `reasonClassCallsMethod` (2449) — direct call within class
- [x] `reasonClassCallsMethod_B` (2462) — call via class relationship
- [x] `reasonClassCallsMethod_C` (2481) — inherited call

### Class at Offset (rules.pl:2505–2538)
- [ ] `reasonClassAtOffset` (2534) — outer class has inner at byte offset

### Reused / Shared Implementation (rules.pl:2643–2704, 3398)
- [ ] `reasonReusedImplementation_A` (2652) — method appears in multiple VFTables of distinct classes
- [ ] `reasonReusedImplementation_B` (2704) — method shared via thunk chain
- [ ] `reasonSharedImplementation` (3398) — shared base implementation
