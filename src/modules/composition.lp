% ============================================================
% DEFINED
% ============================================================

#defined objectInObject/3.
#defined objectInObject_closed/3.
#defined embeddedObject/3.

% objectInObject/3 is closed over sameClass/2 at its defining rules, so
% classRelationship/2 only needs to compute reachability over objectInObject.

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
    reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor),
    not classRelationship(DerivedConstructor, BaseConstructor).           % rules.pl:1834

% Close over class merges
derivedClass_closed(DerivedClass, BaseClass, ObjectOffset) :-
    derivedClass(DerivedClass, BaseClass, ObjectOffset).

derivedClass_closed(DerivedClass2, BaseClass, ObjectOffset) :-
    derivedClass_closed(DerivedClass1, BaseClass, ObjectOffset),
    sameClass(DerivedClass1, DerivedClass2).

derivedClass_closed(DerivedClass, BaseClass2, ObjectOffset) :-
    derivedClass_closed(DerivedClass, BaseClass1, ObjectOffset),
    sameClass(BaseClass1, BaseClass2).

% objectInObject_B / objectInObject_C: OIO holds when either inheritance or
% embedding is known for the same witness methods.
objectInObject(Outer, Inner, Off) :- derivedClass(Outer, Inner, Off).   % rules.pl:1568
objectInObject(Outer, Inner, Off) :- embeddedObject(Outer, Inner, Off). % rules.pl:1577

% Close over sameClass
objectInObject_closed(A, B, Off) :- objectInObject(A, B, Off).
objectInObject_closed(B, C, Off) :- objectInObject_closed(A, C, Off), sameClass(A, B).
objectInObject_closed(A, C, Off) :- objectInObject_closed(A, B, Off), sameClass(B, C).

% reasonClassRelationship_internal: direct object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    objectInObject_closed(DerivedClass, BaseClass, _Offset).                    % rules.pl:2114

% reasonClassRelationship_internal: transitive object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    classRelationship(DerivedClass, MiddleClass),
    objectInObject_closed(MiddleClass, BaseClass, _Offset).                     % rules.pl:2119

% ============================================================
% GUESS
% ============================================================

% guessDerivedClass: every OIO is classified as embedded or derived (at least one).
% When derivedClass has no support the choice is deterministic (reasonEmbeddedObject_A).
1 { embeddedObject(Outer, Inner, Off) ; derivedClass(Outer, Inner, Off) } :-
    objectInObject(Outer, Inner, Off).                    % guess.pl:317 / rules.pl:1740

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

% reasonNOTEmbeddedObject / reasonNOTDerivedClass / insanityEmbeddedAndNot:
% derivedClass and embeddedObject are mutually exclusive.
:- embeddedObject(Outer, Inner, Off), derivedClass(Outer, Inner, Off).  % rules.pl:1791,2025 / insanity.pl:308

% ============================================================
% OUTPUT
% ============================================================

#show derivedClass/3.
#show objectInObject/3.
