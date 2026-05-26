% ============================================================
% RULES
% ============================================================

#defined objectInObject/3.
#defined objectInObject_closed/3.

% objectInObject/3 is closed over sameClass/2 at its defining rules, so
% classRelationship/2 only needs to compute reachability over objectInObject.

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

% reasonClassRelationship_internal: direct object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    objectInObject_closed(DerivedClass, BaseClass, _Offset).                    % rules.pl:2114

% reasonClassRelationship_internal: transitive object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    classRelationship(DerivedClass, MiddleClass),
    objectInObject_closed(MiddleClass, BaseClass, _Offset).                     % rules.pl:2119

#show derivedClass/3.
