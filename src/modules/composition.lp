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
derivedClass(DerivedClass, BaseClass, Offset) :-
    rTTIEnabledAndValid,
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, Offset, 0xffffffff, 0),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass),
    not sameClass(DerivedClass, BaseClass).                              % rules.pl:1968

% reasonDerivedClass_E: RTTI says this is a virtual base class.
% Counterpart: reasonDerivedClass_E (rules.pl:1981)
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
derivedClass(DerivedClass, BaseClass, Offset) :-
    objectInObject(DerivedClass, BaseClass, Offset),
    vbTableEntry(VBTableAddress, TableOffset, OffsetFromVBPtr),
    TableOffset > 0,
    vbTableWrite(_, Method, VBPtrOffset, VBTableAddress),
    sameClass(Method, DerivedClass),
    Offset = OffsetFromVBPtr + VBPtrOffset.                              % rules.pl:1999

% reasonDerivedClass_B: derived constructor calls base constructor, with
% matching confirmed vftable writes proving inheritance rather than embedding.
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

% reasonDerivedClassRelationship (2063): base case — direct derivation.
derivedClassRelationship(DerivedMethod, BaseMethod, Off) :-
    derivedClass(DerivedMethod, BaseMethod, Off).

% reasonDerivedClassRelationship (2069): transitive through intermediate class.
derivedClassRelationship(DerivedMethod, BaseMethod, Off) :-
    derivedClassRelationship(DerivedMethod, MiddleMethod1, Off1),
    sameClass(MiddleMethod1, MiddleMethod2),
    derivedClassRelationship(MiddleMethod2, BaseMethod, Off2),
    Off = Off1 + Off2.

% Arity-2 variant.
derivedClassRelationship(DerivedMethod, BaseMethod) :-
    derivedClassRelationship(DerivedMethod, BaseMethod, _).

% objectInObject_B / objectInObject_C: OIO holds when either inheritance or
% embedding is known for the same witness methods.
objectInObject(Outer, Inner, Off) :- derivedClass(Outer, Inner, Off).   % rules.pl:1568
objectInObject(Outer, Inner, Off) :- embeddedObject(Outer, Inner, Off). % rules.pl:1577

% Close over sameClass
objectInObject_closed(A, B, Off) :- objectInObject(A, B, Off).
objectInObject_closed(B, C, Off) :- objectInObject_closed(A, C, Off), sameClass(A, B).
objectInObject_closed(A, C, Off) :- objectInObject_closed(A, B, Off), sameClass(B, C).

% reasonClassRelationship_internal: direct object composition/inheritance.
% classRelationship_closed/2 is closed over sameClass/2 via its defining rules.
classRelationship_closed(DerivedClass, BaseClass) :-
    objectInObject_closed(DerivedClass, BaseClass, _Offset).                    % rules.pl:2114

% reasonClassRelationship_internal: transitive object composition/inheritance.
classRelationship_closed(DerivedClass, BaseClass) :-
    classRelationship_closed(DerivedClass, MiddleClass),
    objectInObject_closed(MiddleClass, BaseClass, _Offset).                     % rules.pl:2119

% reasonClassHasNoBase (2136): RTTI says this class has no base class.
classHasNoBase(Class) :-
    rTTIEnabledAndValid,
    rTTINoBase(TDA),
    rTTITDA2Class(TDA, Class).                                             % rules.pl:2136

% reasonClassHasNoDerived (2152): RTTI says no class derives from this one.
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
:- embeddedObject(Outer, Inner, Off), derivedClass(Outer, Inner, Off).  % rules.pl:1791,1960,2025 / insanity.pl:308

% insanityNoBaseConsistency: a class with no base cannot also be a derived class.
insanity(noBaseConsistency, Class) :-
    classHasNoBase(Class),
    derivedClass_closed(Class, _, _).                                    % insanity.pl:8

% ============================================================
% OUTPUT
% ============================================================

#show derivedClass/3.
#show objectInObject/3.
