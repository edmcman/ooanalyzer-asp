% ============================================================
% SANITY CHECKS
%
% Normal mode (default):   clingo ooanalyzer.lp ...
% Diagnostic mode:         clingo --const diagnose=1 ooanalyzer.lp ...
%   -> violate(Tag, Witness) atoms in the model show which constraints fire.
% ============================================================

#const diagnose = 0.
diagnosing :- diagnose != 0.

% ----------------------------------------------------------------
% Prolog correspondence helpers used only by sanity checks.
% ----------------------------------------------------------------

% Counterpart helper: reasonClassRelationship (rules.pl:2107)
insanityClassRelationship(Outer, Inner) :- objectInObject(Outer, Inner, _).
insanityClassRelationship(Outer, Inner) :- objectInObject(Outer, Middle, _), Outer != Middle, insanityClassRelationship(Middle, Inner), Middle != Inner.

% Counterpart helper: reasonConstructor (rules.pl:186,204,209)
insanityReasonConstructor(M) :- factConstructor(M).
insanityReasonConstructor(M) :- factVBTableWrite(M, _, _).
insanityReasonConstructor(M) :- symbolProperty(M, constructor).

% ----------------------------------------------------------------
% insanity/2: all conditions that must be false in every valid model.
% Each rule is labeled with the insanity.pl rule it implements.
% ----------------------------------------------------------------

% insanityNoBaseConsistency (insanity.pl:8)
insanity(insanityNoBaseConsistency, (Class,Base,Off)) :- factClassHasNoBase(Class), factDerivedClass(Class, Base, Off).
insanity(insanityNoBaseConsistency, (Class,Base,Off)) :- factClassHasNoBase(Class), sameClass(Class, Derived), factDerivedClass(Derived, Base, Off), Class != Derived.

% insanityVFTableOnTwoClasses (insanity.pl:18)
insanity(insanityVFTableOnTwoClasses, (V,M1,M2)) :-
    factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2,
    find(M1, Class1), factClassHasNoBase(Class1),
    find(M2, Class2), factClassHasNoBase(Class2), Class1 != Class2,
    not possibleVFTableOverwrite(M1, _, _, _),
    not possibleVFTableOverwrite(M2, _, _, _).

% insanityConstructorInVFTable (insanity.pl:48)
insanity(insanityConstructorInVFTable, (V,Off,M)) :- factVFTableEntry(V, Off, M), factConstructor(M).

% insanityInheritanceTwice (insanity.pl:64)
insanity(insanityInheritanceTwice, (A,B,O1,O2)) :- factDerivedClass(A, B, O1), objectInObject(A, B, O2), O1 != O2.

% insanityInheritanceAfterNonInheritance (insanity.pl:104) is not active in sanityChecks/1.
% The Prolog file says it was disabled because virtual inheritance violates the check.

% insanityClassSizeInvalid (insanity.pl:84)
insanity(insanityClassSizeInvalid, (Class,LTESize,GTESize)) :- factClassSizeLTE(Class, LTESize), factClassSizeGTE(Class, GTESize), LTESize < GTESize.

% insanityVFTableSizeInvalid (insanity.pl:126)
insanity(insanityVFTableSizeInvalid, (V,LTESize,GTESize)) :- factVFTable(V), factVFTableSizeLTE(V, LTESize), factVFTableSizeGTE(V, GTESize), LTESize < GTESize.

% insanityEmbeddedObjectLarger (insanity.pl:143)
insanity(insanityEmbeddedObjectLarger, (OuterClass,InnerClass,Off,OuterSize,InnerSize)) :-
    factEmbeddedObject(Outer1, Inner1, Off),
    find(Outer1, OuterClass), find(Inner1, InnerClass),
    factClassSizeLTE(OuterClass, OuterSize), factClassSizeGTE(InnerClass, InnerSize),
    OuterSize < Off + InnerSize.

% insanityObjectCycle (insanity.pl:162)
insanity(insanityObjectCycle, (Class1,Class2)) :- insanityClassRelationship(Class1, Class2), insanityClassRelationship(Class2, Class1), Class1 < Class2.

% insanityMemberPastEndOfObject (insanity.pl:177)
insanity(insanityMemberPastEndOfObject, (Class,Off,Size,ObjectSize)) :- certainMemberOnClass(Class, Off, Size), factClassSizeLTE(Class, ObjectSize), Off + Size > ObjectSize.

% insanityBaseVFTableLarger (insanity.pl:197)
insanity(insanityBaseVFTableLarger, (DerivedV,BaseV,DerivedSize,BaseSize)) :-
    factVFTableWrite(DerivedCtor, ObjectOffset, DerivedV),
    factVFTableWrite(BaseCtor, 0, BaseV),
    find(DerivedCtor, DerivedClass), find(BaseCtor, BaseClass),
    factDerivedClass(DerivedClass, BaseClass, ObjectOffset),
    factVFTableSizeLTE(DerivedV, DerivedSize), factVFTableSizeGTE(BaseV, BaseSize),
    DerivedSize < BaseSize.

% insanityConstructorAndNotConstructor (insanity.pl:214)
insanity(insanityConstructorAndNotConstructor, M) :- factConstructor(M), factNOTConstructor(M).

% insanityConstructorAndRealDestructor (insanity.pl:226)
insanity(insanityConstructorAndRealDestructor, M) :- factConstructor(M), factRealDestructor(M).

% insanityConstructorAndDeletingDestructor (insanity.pl:240)
insanity(insanityConstructorAndDeletingDestructor, M) :- factConstructor(M), factDeletingDestructor(M).

% insanityTwoRealDestructorsOnClass (insanity.pl:253)
insanity(insanityTwoRealDestructorsOnClass, (D1,D2)) :- factRealDestructor(D1), factRealDestructor(D2), D1 < D2, find(D1, Class), find(D2, Class).

% insanityContradictoryMerges (insanity.pl:271)
insanity(insanityContradictoryMerges, (M1,M2)) :- mergeClasses(M1, M2), reasonNOTMergeClasses(M1, M2).

% insanityContradictoryNOTConstructor (insanity.pl:284)
insanity(insanityContradictoryNOTConstructor, M) :- factConstructor(M), factNOTConstructor(M).

% insanityContradictoryNOTConstructor (insanity.pl:295)
insanity(insanityContradictoryNOTConstructor, M) :- insanityReasonConstructor(M), factNOTConstructor(M).

% insanityEmbeddedAndNot (insanity.pl:307)
insanity(insanityEmbeddedAndNot, (A,B,C)) :- factEmbeddedObject(A, B, C), factNOTEmbeddedObject(A, B, C).

% ----------------------------------------------------------------
% Dispatch: hard constraint (normal) or soft violate (diagnostic).
% ----------------------------------------------------------------
:- not diagnosing, insanity(_, _).
violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).
#show violate/2.
