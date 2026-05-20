% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes = sets of methods) from binary analysis facts.
%
% Input facts (provided in a separate file):
%   possibleVFTableWrite(M, Off, V)          -- M writes vftable V at object offset Off
%   possibleVFTableEntry(V, Off, E)          -- entry E at offset Off in vftable V (may be thunk)
%   possibleVFTableOverwrite(M, Off, V1, V2) -- M overwrites V1 with V2 at Off (ctor sequence)
%   returnsSelf(M)          -- M returns the this pointer (ECX → EAX)
%   noCallsBefore(M)        -- no OO calls precede M (constructor hint)
%   noCallsAfter(M)         -- no OO calls follow M (destructor hint)
%   callsDelete(M)          -- M calls delete/free on the this pointer
%   uninitializedReads(M)   -- M reads members before initializing them (NOT-ctor signal)
%   callTarget(Caller, Callee) -- Callee is directly called by Caller
%   callAtOffset(Caller, Callee, Off) -- Callee is called by Caller passing this+Off
%   thunk(Thunk, Target)    -- Thunk is a JMP-only stub; Target is the real function
%   purecall(M)             -- M is a pure-virtual stub (not a real method)
%   symbolClass(M, Class)   -- debug symbol: M belongs to Class
%   symbolProperty(M, Prop) -- Prop ∈ {constructor, realDestructor, deletingDestructor}
%   rTTICompleteObjectLocator(V, TDA) -- COL at V-8 links vftable V to type descriptor TDA
%   rTTITypeDescriptor(TDA, Name)     -- TDA has mangled type name Name
%   rTTIInheritsFrom(DerivedTDA, BaseTDA, Offset) -- non-virtual base at byte Offset

#defined callTarget/2.
#defined callsDelete/1.
#defined returnsSelf/1.
#defined noCallsBefore/1.
#defined noCallsAfter/1.
#defined uninitializedReads/1.
#defined symbolClass/2.
#defined symbolProperty/2.
#defined possibleVFTableEntry/3.
#defined possibleVFTableWrite/3.
#defined possibleVFTableOverwrite/4.
#defined thunk/2.
#defined purecall/1.
#defined callAtOffset/3.
#defined rTTICompleteObjectLocator/2.
#defined rTTITypeDescriptor/2.
#defined rTTIInheritsFrom/3.

% ============================================================
% GUESSES
% ============================================================

{ factVFTable(V) } :- possibleVFTableWrite(_, _, V).
% RTTI definitively confirms vftables — no guess needed for these.
factVFTable(V) :- rTTICompleteObjectLocator(V, _).

{ mergeClasses(M1, M2) } :- factMethod(M1), factMethod(M2), M1 < M2.

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
{ factDerivedClass(Outer, Inner, Off) } :- objectInObject(Outer, Inner, Off).

% Guess: does a class have no base class?
{ factClassHasNoBase(C) } :- classRep(C).

% ============================================================
% THUNK RESOLUTION
% ============================================================

% Follow thunk chains to find the actual implementing method.
dethunk(E, E) :- possibleVFTableEntry(_, _, E), not thunk(E, _).
dethunk(T, T) :- thunk(_, T), not thunk(T, _).
dethunk(T, M) :- thunk(T, X), dethunk(X, M).

% factVFTableEntry: actual method at each confirmed slot after thunk resolution.
factVFTableEntry(V, Off, M) :- possibleVFTableEntry(V, Off, E), factVFTable(V), dethunk(E, M).

% factVFTableSizeGTE: lower bound on vftable size in bytes (max offset + pointer size).
factVFTableSizeGTE(V, Size) :-
    factVFTable(V),
    Size = #max { Off + 4 : factVFTableEntry(V, Off, _) }.

% ============================================================
% DERIVED FACTS: confirmed vftable writes and overwrites
% ============================================================

factVFTableWrite(M, Off, V) :- possibleVFTableWrite(M, Off, V), factVFTable(V).

% Both vftables must be confirmed for an overwrite to count.
factVFTableOverwrite(M, Off, V1, V2) :-
    possibleVFTableOverwrite(M, Off, V1, V2), factVFTable(V1), factVFTable(V2).

% inheritedVftableEntry: a slot in a derived vftable that reuses the same method
% pointer as the base vftable at the same offset.  Such entries belong to the base
% class and must not be merged into the derived class via vftable-entry rules.
inheritedVftableEntry(Vderived, Off, M) :-
    factVFTableOverwrite(_, _, Vbase, Vderived),
    factVFTableEntry(Vbase, Off, M),
    factVFTableEntry(Vderived, Off, M).

% ============================================================
% METHOD IDENTIFICATION
% ============================================================

factMethod(M) :- factVFTableEntry(_, _, M), not purecall(M).
factMethod(M) :- factVFTableWrite(M, _, _).
factMethod(M) :- factConstructor(M).
factMethod(M) :- factRealDestructor(M).
factMethod(M) :- factDeletingDestructor(M).
factMethod(M) :- symbolClass(M, _).
factMethod(M) :- symbolProperty(M, _).
factMethod(Callee) :- callTarget(Caller, Callee), factMethod(Caller).

% ============================================================
% CONSTRUCTOR / DESTRUCTOR CLASSIFICATION
% ============================================================

% factNOTConstructor: strong evidence M is NOT a constructor.
% Mirrors reasonNOTConstructor_B (real dtor), _C (deleting dtor), _D (in vftable).
factNOTConstructor(M) :- factRealDestructor(M).
factNOTConstructor(M) :- factDeletingDestructor(M).
factNOTConstructor(M) :- factVFTableEntry(_, _, M).  % virtual methods cannot be constructors
factNOTConstructor(M) :- uninitializedReads(M).
factNOTConstructor(M) :- callsDelete(M).

factConstructor(M) :- symbolProperty(M, constructor).
factConstructor(M) :- returnsSelf(M), noCallsBefore(M), not factNOTConstructor(M).
factConstructor(M) :- factVFTableWrite(M, 0, _), not factNOTConstructor(M).

factRealDestructor(M) :- symbolProperty(M, realDestructor).
factRealDestructor(M) :- noCallsAfter(M), not factConstructor(M), not callsDelete(M).

factDeletingDestructor(M) :- symbolProperty(M, deletingDestructor).
factDeletingDestructor(M) :- callsDelete(M), not factConstructor(M).

% ============================================================
% INHERITANCE / EMBEDDING DETECTION
% ============================================================

% objectInObject: constructor Outer calls constructor Inner at this+Off.
% Mirrors factObjectInObject / reasonDerivedClass_B pattern.
objectInObject(Outer, Inner, Off) :-
    factConstructor(Outer), factConstructor(Inner), Outer != Inner,
    callAtOffset(Outer, Inner, Off), Off >= 0.

% Hard derivation from vftable overwrite: the method that installs V1 without
% overwriting is the base constructor; the overwriting method is derived.
factDerivedClass(Outer, Inner, Off) :-
    factVFTableOverwrite(Outer, Off, V1, _),
    factVFTableWrite(Inner, 0, V1), not factVFTableOverwrite(Inner, 0, _, V1),
    Outer != Inner.

% When objectInObject holds but factDerivedClass does not, it's an embedded member.
factEmbeddedObject(Outer, Inner, Off) :-
    objectInObject(Outer, Inner, Off), not factDerivedClass(Outer, Inner, Off).

% Hard derivation from RTTI (reasonDerivedClass_D): RTTI inheritance is authoritative.
factDerivedClass(Outer, Inner, Off) :-
    rTTICompleteObjectLocator(V1, TDA1), rTTICompleteObjectLocator(V2, TDA2),
    rTTIInheritsFrom(TDA1, TDA2, Off),
    factVFTableWrite(Outer, 0, V1), not factVFTableOverwrite(Outer, 0, _, V1),
    factVFTableWrite(Inner, 0, V2), not factVFTableOverwrite(Inner, 0, _, V2).

% ============================================================
% CLASS → VFTABLE MAPPING
% ============================================================

% factVFTableBelongsToClass(V, Off, C): vftable V belongs to class C at object offset Off.
% Mirrors reasonVFTableBelongsToClass.
factVFTableBelongsToClass(V, Off, C) :- factVFTableWrite(M, Off, V), find(M, C).

% ============================================================
% reasonMergeClasses — forced merges (must happen)
% ============================================================

% Multiple methods writing the SAME vftable at the same offset → same class
reasonMergeClasses(M1, M2) :-
    factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2.

% Methods in a vftable belong to the class whose constructor writes it.
% Skip inherited entries — those belong to the base class.
reasonMergeClasses(M1, M2) :-
    factVFTableWrite(M1, _, V), factVFTableEntry(V, Off, M2),
    not inheritedVftableEntry(V, Off, M2), M1 < M2.
reasonMergeClasses(M1, M2) :-
    factVFTableWrite(M2, _, V), factVFTableEntry(V, Off, M1),
    not inheritedVftableEntry(V, Off, M1), M1 < M2.

% Debug symbols resolve class membership directly (reasonMergeClasses_G)
reasonMergeClasses(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.

% reasonMergeClasses_E: two methods both the inner (base) of the same derived at same offset
reasonMergeClasses(B1, B2) :-
    factDerivedClass(_, B1, Off), factDerivedClass(_, B2, Off), B1 < B2.

% Deleting destructor calls real destructor → same class
reasonMergeClasses(M1, M2) :-
    factDeletingDestructor(M1), factRealDestructor(M2), callTarget(M1, M2), M1 < M2.
reasonMergeClasses(M1, M2) :-
    factDeletingDestructor(M2), factRealDestructor(M1), callTarget(M2, M1), M1 < M2.

:- reasonMergeClasses(M1, M2), not mergeClasses(M1, M2).

% ============================================================
% reasonNOTMergeClasses — forced not-merges (mergeClasses must not happen)
% ============================================================

% Outer and inner of objectInObject are distinct classes
reasonNOTMergeClasses(M1, M2) :- objectInObject(M1, M2, _), M1 < M2.
reasonNOTMergeClasses(M1, M2) :- objectInObject(M2, M1, _), M1 < M2.

% Base vs. derived from vftable overwrite
reasonNOTMergeClasses(M1, M2) :-
    factVFTableWrite(M1, 0, V), not factVFTableOverwrite(M1, 0, _, V),
    factVFTableOverwrite(M2, 0, V, _), M1 < M2.
reasonNOTMergeClasses(M1, M2) :-
    factVFTableWrite(M2, 0, V), not factVFTableOverwrite(M2, 0, _, V),
    factVFTableOverwrite(M1, 0, V, _), M1 < M2.

% reasonNOTMergeClasses_F: two bases of the same derived at different offsets
reasonNOTMergeClasses(B1, B2) :-
    factDerivedClass(D, B1, Off1), factDerivedClass(D, B2, Off2),
    Off1 != Off2, B1 < B2.

% RTTI: two vftables with different type descriptors belong to different classes
reasonNOTMergeClasses(M1, M2) :-
    rTTICompleteObjectLocator(V1, TDA1), rTTICompleteObjectLocator(V2, TDA2),
    TDA1 != TDA2,
    factVFTableWrite(M1, _, V1), factVFTableWrite(M2, _, V2), M1 < M2.

:- reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2).

% ============================================================
% CLASS COMPUTATION: equivalence classes via transitive closure
% ============================================================

sameClass(M, M)   :- factMethod(M).
sameClass(M1, M2) :- mergeClasses(M1, M2).
sameClass(M2, M1) :- sameClass(M1, M2).
sameClass(M1, M3) :- sameClass(M1, M2), sameClass(M2, M3).

hasLesser(M) :- sameClass(M, M2), M2 < M.
classRep(M)  :- factMethod(M), not hasLesser(M).
find(M, R)   :- sameClass(M, R), classRep(R).  % mirrors Prolog's find/2 (union-find lookup)

% ============================================================
% CLASS PROPERTIES
% ============================================================

% Hard derivation: RTTI with no inheritance entries means this class has no base.
factClassHasNoBase(C) :-
    rTTICompleteObjectLocator(V, TDA), factVFTableWrite(M, 0, V), find(M, C),
    not rTTIInheritsFrom(TDA, _, _).

% Constraint: a derived class cannot also have no base.
:- factClassHasNoBase(C), factDerivedClass(M, _, _), find(M, C).

% factClassCallsMethod: methods called by a class passing the same this-pointer.
% Mirrors factClassCallsMethod (validMethodCallAtOffset at offset 0).
factClassCallsMethod(C, M) :-
    find(Caller, C), callAtOffset(Caller, M, 0), factMethod(M).

% reasonMergeClasses_C: two no-base classes where one calls a method of the other
reasonMergeClasses(R1, R2) :-
    factClassHasNoBase(R1), factClassHasNoBase(R2), R1 != R2, R1 < R2,
    factClassCallsMethod(R1, M), find(M, R2).

% ============================================================
% SANITY CHECKS
% ============================================================

% insanityVirtualConstructor: constructors cannot appear in vftables
:- factConstructor(M), factVFTableEntry(_, _, M).

% insanityDoubleDuty: method cannot be both constructor and destructor
:- factConstructor(M), factRealDestructor(M).
:- factConstructor(M), factDeletingDestructor(M).

% insanityContradictoryNOTConstructor
:- factConstructor(M), factNOTConstructor(M).

% insanityMultipleRealDestructors: at most one real destructor per class
:- factRealDestructor(D1), factRealDestructor(D2), D1 < D2,
   find(D1, C), find(D2, C).

% insanityVFTables: a vftable cannot be shared by two classes at the same offset
:- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2,
   find(M1, C1), find(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same offset → different classes
:- factVFTableWrite(M1, Off, V1), factVFTableWrite(M2, Off, V2),
   M1 != M2, V1 != V2, find(M1, C), find(M2, C).

% VFTable entries must resolve to real methods
:- factVFTableEntry(_, _, M), not factMethod(M).

% insanityObjectCycle: circular inheritance is impossible
:- factDerivedClass(A, B, _), factDerivedClass(B, A, _).

% objectInObject pairs must be in distinct classes
:- objectInObject(M1, M2, _), sameClass(M1, M2).

% A derived vftable must be at least as large as the base vftable it overwrites.
:- factVFTableOverwrite(_, _, Vbase, Vderived),
   factVFTableSizeGTE(Vbase, Sbase), factVFTableSizeGTE(Vderived, Sderived),
   Sderived < Sbase.

% ============================================================
% OPTIMIZATION
% ============================================================

% Priority 2: confirm as many vftables as possible
% Priority 1: maximize class merges (minimize class count)
% Priority 0: prefer factDerivedClass at offset 0; prefer more factClassHasNoBase
#maximize { 1@2, V : factVFTable(V) }.
#maximize { 1@1, M1, M2 : mergeClasses(M1, M2) }.
#maximize { 1@0, Outer, Inner : factDerivedClass(Outer, Inner, 0) }.
#maximize { 1@0, C : factClassHasNoBase(C) }.

% ============================================================
% OUTPUT
% ============================================================

#show find/2.
#show classRep/1.
#show factClassHasNoBase/1.
#show factConstructor/1.
#show factNOTConstructor/1.
#show factRealDestructor/1.
#show factDeletingDestructor/1.
#show factVFTable/1.
#show factVFTableWrite/3.
#show factVFTableOverwrite/4.
#show factVFTableBelongsToClass/3.
#show factVFTableEntry/3.
#show factDerivedClass/3.
#show factEmbeddedObject/3.
