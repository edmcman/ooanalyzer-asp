% ============================================================
% RULES
% ============================================================

% reasonDerivedClass_B base evidence: the base constructor writes a confirmed
% non-overwritten vftable at offset zero, and it differs from the derived table.
reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor) :-
    vfTable(DerivedVFTable),
    vfTableWrite(_, BaseConstructor, 0, BaseVFTable),
    not vfTableOverwrite(BaseConstructor, BaseVFTable, _, 0),
    DerivedVFTable != BaseVFTable.                                       % rules.pl:1866

% reasonDerivedClass_B base evidence: imported/MFC-style bases may have symbol
% evidence even when their base-class vftable write is not visible.
reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor) :-
    vfTable(DerivedVFTable),
    symbolClass(BaseConstructor, _, _, _).                               % rules.pl:1877

% reasonDerivedClass_D: RTTI says this is a non-virtual base class.
% Counterpart: reasonDerivedClass_D (rules.pl:1968)
%!trace_rule {"% derives from % at offset % because RTTI says so", DerivedClass, BaseClass, Offset}
derivedClass(DerivedClass, BaseClass, Offset) :-
    rTTIEnabledAndValid,
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, Offset, 0xffffffff, 0),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass),
    not sameClass(DerivedClass, BaseClass).                              % rules.pl:1968

% reasonDerivedClass_E: RTTI says this is a virtual base class.
% Counterpart: reasonDerivedClass_E (rules.pl:1981)
%!trace_rule {"% derives from % because RTTI says it is a virtual base", DerivedClass, BaseClass}
derivedClass(DerivedClass, BaseClass, Offset) :-
    rTTIEnabledAndValid,
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, _M, P, V),
    P != 0xffffffff,
    possibleVBTableWrite(_Insn, Method, _ThisPtr, P, VBTableAddr),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass),
    not sameClass(DerivedClass, BaseClass),
    sameClass(Method, DerivedClass),
     possibleVBTableEntry(VBTableAddr, V, Entry),
     Offset = P + Entry.                                                  % rules.pl:1981

% reasonDerivedClass_F: VBTable-based virtual inheritance (non-RTTI path).
% Counterpart: reasonDerivedClass_F (rules.pl:1999)
%!trace_rule {"% derives from % at offset % because VBTable evidence", DerivedClass, BaseClass, Offset}
derivedClass(DerivedClass, BaseClass, Offset) :-
    objectInObject(DerivedClass, BaseClass, Offset),
    vbTableEntry(VBTableAddress, TableOffset, OffsetFromVBPtr),
    TableOffset > 0,
    vbTableWrite(_, Method, VBPtrOffset, VBTableAddress),
    sameClass(Method, DerivedClass),
    Offset = OffsetFromVBPtr + VBPtrOffset.                              % rules.pl:1999

% reasonDerivedClass_B: derived constructor calls base constructor, with
% matching confirmed vftable writes proving inheritance rather than embedding.
%!trace_rule {"% derives from % at offset % because the derived constructor calls the base constructor with matching vftable writes", DerivedConstructor, BaseConstructor, ObjectOffset}
derivedClass(DerivedConstructor, BaseConstructor, ObjectOffset) :-
    not rTTIEnabledAndValid,
    validMethodCallAtOffset(_, DerivedConstructor, BaseConstructor, ObjectOffset),
    ObjectOffset >= 0,
    constructor(DerivedConstructor),
    constructor(BaseConstructor),
    DerivedConstructor != BaseConstructor,
    vfTableWrite(_, DerivedConstructor, ObjectOffset, DerivedVFTable),
    not vfTableOverwrite(DerivedConstructor, DerivedVFTable, _, ObjectOffset),
    reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor).           % rules.pl:1834

% Close over class merges
derivedClass_closed(DerivedClass, BaseClass, ObjectOffset) :-
    derivedClass(DerivedClass, BaseClass, ObjectOffset).

derivedClass_closed(DerivedClass2, BaseClass, ObjectOffset) :-
    derivedClass_closed(DerivedClass1, BaseClass, ObjectOffset),
    sameClass(DerivedClass1, DerivedClass2).

derivedClass_closed(DerivedClass, BaseClass2, ObjectOffset) :-
    derivedClass_closed(DerivedClass, BaseClass1, ObjectOffset),
    sameClass(BaseClass1, BaseClass2).

% reasonDerivedClassRelationship (2063, 2069). The Prolog runs on class IDs with
% SLG tabling for termination. A literal method-level port has two problems:
%
%   1. Symmetric recursion (drcRel × sameClass × drcRel) materializes a quadratic-
%      in-fixpoint cross product per round.
%   2. Off = Off1 + Off2 is unbounded — every iteration that finds a new Off keeps
%      the fixpoint open. With the grounder considering every potential sameClass
%      cycle, Off ratchets upward indefinitely. Baseline on oo.lp grounded Off
%      values from 0 to 1536 (129 multiples of 12).
%
% Two-phase decomposition:
%
% Phase 1 — /2 reachability closure. No Off, so the fixpoint is bounded by
% methods² regardless of cycles. This is the cheap predicate that captures "D has
% B as a transitive ancestor"; most uses care about existence only.
%
% Phase 2 — /3 with explicit Off, computed only over the bounded sum-of-primitives
% domain (relevantOffset). This is the grounding-time analog of Prolog's
% `(integer(Off) -> Off1 < Off; true)` mode pruning — ASP has no modes, so we
% bound at the head. Depth cap (maxOffsetDepth) prevents the relevantOffset
% domain from itself growing without bound.
%
% != guards filter at grounding time; not sameClass guards add class-level
% semantics at solve time (sameClass is in a non-stratified SCC, so the negation
% is deferred and cannot break the grounding loop).

% --- Phase 1: /2 reachability closure (bounded by methods²) ----------------
% Decomposed: sameClass join removed from the recursive body.  Instead,
%   (1) extend dCR by one derivedClass edge (no sameClass join), then
%   (2) close over sameClass via two linear rules.
% The alternating fixpoint replaces the old 3-way join
%   derivedClass × sameClass × dCR
% with cheaper 2-way joins per round:
%   extension:  derivedClass × dCR      (no sameClass)
%   closure:    dCR × sameClass         (linear, like _closed)
derivedClassRelationship(D, B) :- derivedClass(D, B, _).

dCR_step2(D, B) :-
    derivedClass(D, M, _),
    derivedClassRelationship(M, B),
    D != M,
    not sameClass(D, M),
    M != B,
    not sameClass(M, B).

derivedClassRelationship(D, B) :- dCR_step2(D, B).

derivedClassRelationship(D2, B) :- derivedClassRelationship(D1, B), sameClass(D1, D2).
derivedClassRelationship(D, B2) :- derivedClassRelationship(D, B1), sameClass(B1, B2).

derivedClassRelationship_closed(D, B) :- derivedClassRelationship(D, B).
derivedClassRelationship_closed(D2, B) :-
    derivedClassRelationship_closed(D1, B), sameClass(D1, D2).
derivedClassRelationship_closed(D, B2) :-
    derivedClassRelationship_closed(D, B1), sameClass(B1, B2).

% --- Phase 2: /3 with bounded Off domain -----------------------------------
% Build the relevant-offset domain: 0 plus all sums of derivedClass offsets that
% satisfy BOTH bounds in src/util/config.lp:
%   * maxOffsetDepth — chain length cap (sums of up to N primitives).
%   * maxClassSize   — absolute byte ceiling on any sum.
% Intersecting both bounds keeps the domain small when primitive offsets are
% dense (size cap dominates) and when they are sparse (depth cap dominates).
primitiveOffset(0).
primitiveOffset(Off) :- derivedClass(_, _, Off).

relevantOffset(Off, 1) :- primitiveOffset(Off).
relevantOffset(Off1 + Off2, N + 1) :-
    relevantOffset(Off1, N),
    primitiveOffset(Off2),
    maxOffsetDepth(MaxD),
    N < MaxD,
    maxClassSize(MaxS),
    Off1 + Off2 <= MaxS.
relevantOffset(Off) :- relevantOffset(Off, _).

derivedClassRelationship(D, B, Off) :- derivedClass(D, B, Off).

dCR_step3(D, B, Off) :-
    derivedClass(D, M, Off1),
    derivedClassRelationship(M, B, Off2),
    Off = Off1 + Off2,
    relevantOffset(Off),
    D != M,
    not sameClass(D, M),
    M != B,
    not sameClass(M, B).

derivedClassRelationship(D, B, Off) :- dCR_step3(D, B, Off).

derivedClassRelationship(D2, B, Off) :- derivedClassRelationship(D1, B, Off), sameClass(D1, D2).
derivedClassRelationship(D, B2, Off) :- derivedClassRelationship(D, B1, Off), sameClass(B1, B2).

derivedClassRelationship_closed(D, B, Off) :- derivedClassRelationship(D, B, Off).
derivedClassRelationship_closed(D2, B, Off) :-
    derivedClassRelationship_closed(D1, B, Off), sameClass(D1, D2).
derivedClassRelationship_closed(D, B2, Off) :-
    derivedClassRelationship_closed(D, B1, Off), sameClass(B1, B2).

% objectInObject_B / objectInObject_C: OIO holds when either inheritance or
% embedding is known for the same witness methods.
%!trace_rule {"% contains % at offset % because of inheritance", Outer, Inner, Off}
objectInObject(Outer, Inner, Off) :- derivedClass(Outer, Inner, Off).   % rules.pl:1568
%!trace_rule {"% contains % at offset % because of embedding", Outer, Inner, Off}
objectInObject(Outer, Inner, Off) :- embeddedObject(Outer, Inner, Off). % rules.pl:1577

% Close over sameClass
objectInObject_closed(A, B, Off) :- objectInObject(A, B, Off).
objectInObject_closed(B, C, Off) :- objectInObject_closed(A, C, Off), sameClass(A, B).
objectInObject_closed(A, C, Off) :- objectInObject_closed(A, B, Off), sameClass(B, C).

% reasonClassRelationship_internal: direct object composition/inheritance.
% classRelationship_closed/2 is closed over sameClass/2 via its defining rules.
%!trace_rule {"% has a class relationship with % because of direct composition/inheritance", DerivedClass, BaseClass}
classRelationship_closed(DerivedClass, BaseClass) :-
    objectInObject_closed(DerivedClass, BaseClass, _Offset).                    % rules.pl:2114

% reasonClassRelationship_internal: transitive object composition/inheritance.
%!trace_rule {"% has a class relationship with % because of transitive composition/inheritance through %", DerivedClass, BaseClass, MiddleClass}
classRelationship_closed(DerivedClass, BaseClass) :-
    classRelationship_closed(DerivedClass, MiddleClass),
    objectInObject_closed(MiddleClass, BaseClass, _Offset).                     % rules.pl:2119

% reasonClassHasNoBase (2136): RTTI says this class has no base class.
%!trace_rule {"% has no base class because RTTI says so", Class}
classHasNoBase(Class) :-
    rTTIEnabledAndValid,
    rTTINoBase(TDA),
    rTTITDA2Class(TDA, Class).                                             % rules.pl:2136

% reasonClassHasNoDerived (2152): RTTI says no class derives from this one.
%!trace_rule {"% has no derived class because RTTI says so", Class}
classHasNoDerived(Class) :-
    rTTIEnabledAndValid,
    rTTITDA2Class(TDA, Class),
    not rTTIAncestorOf(_, TDA).                                            % rules.pl:2152

% ============================================================
% GUESS
% ============================================================

% guessDerivedClass / reasonDerivedClass_C: every OIO is classified as embedded or derived
% (at least one). When derivedClass has no support the choice is deterministic
% (reasonEmbeddedObject_A). The derived branch encodes reasonDerivedClass_C:
% objectInObject + NOT embeddedObject → derivedClass.
%!trace_rule {"% is either embedded in or derived from % at offset %", Outer, Inner, Off}
1 { embeddedObject(Outer, Inner, Off) ; derivedClass(Outer, Inner, Off) } :-
    objectInObject(Outer, Inner, Off).          % guess.pl:317 / rules.pl:1740 / rules.pl:1960

% ============================================================
% REWARDS
% ============================================================

% guessDerivedClass: prefer inheritance over embedding when both are possible.
guessDerivedClassReward(Outer, Inner, Off) :-
    derivedClass(Outer, Inner, Off),
    objectInObject(Outer, Inner, Off).

#maximize { 1@1, guessDerivedClass, Outer, Inner, Off : guessDerivedClassReward(Outer, Inner, Off) }.

% NEW RULE (no Prolog equivalent): penalize embedding a class that is already known to be a
% base (inherited from) — embedding a base class elsewhere is likely a misclassification.
embedsKnownBasePenalty(Outer, Inner, Off) :-
    embeddedObject(Outer, Inner, Off),
    derivedClass(_, Inner, _).

#minimize { 1@1, embedsKnownBase, Outer, Inner, Off : embedsKnownBasePenalty(Outer, Inner, Off) }.

% NEW RULE (no Prolog equivalent): reward when a class whose vftable contains a
% purecall entry is inherited from. Abstract classes should not be leaf classes.
purecallNotMostDerivedReward(Derived, Base, Off) :-
    derivedClass(Derived, Base, Off),
    sameClass(Base, VFTable),
    vfTableEntry(VFTable, _, Entry),
    purecall(Entry).

#maximize { 1@1, purecallNotMostDerived, Derived, Base, Off : purecallNotMostDerivedReward(Derived, Base, Off) }.

% ============================================================
% CONSTRAINTS
% ============================================================

% reasonNOTEmbeddedObject / reasonNOTDerivedClass / reasonDerivedClass_C / insanityEmbeddedAndNot:
% derivedClass and embeddedObject are mutually exclusive.
% derivedClass and embeddedObject are mutually exclusive.
:- embeddedObject(Outer, Inner, Off), derivedClass(Outer, Inner, Off).  % rules.pl:1791,1960,2025 / insanity.pl:308

% insanityNoBaseConsistency: a class with no base cannot also be a derived class.
%!trace_rule {"% has no base class but is also a derived class", Class}
:- classHasNoBase(Class),
    derivedClass_closed(Class, _, _).                                    % insanity.pl:8

% ============================================================
% OUTPUT
% ============================================================

%!trace {"% derives from % at offset %", Outer, Inner, Off} derivedClass(Outer, Inner, Off).
%!trace {"% embeds % at offset %", Outer, Inner, Off} embeddedObject(Outer, Inner, Off).
%!trace {"% contains % at offset %", Outer, Inner, Off} objectInObject(Outer, Inner, Off).
%!trace {"% has a class relationship with %", A, B} classRelationship_closed(A, B).
%!trace {"% has no base class", V} classHasNoBase(V).
%!trace {"% has no derived class", V} classHasNoDerived(V).

#show derivedClass/3.
#show objectInObject/3.
