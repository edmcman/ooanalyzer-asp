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
%   possibleVBTableWrite(M, Off, V)          -- M writes VBTable V at object offset Off
%   possibleVBTableEntry(V, Off, Value)      -- entry Value at offset Off in VBTable V

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
#defined possibleVBTableWrite/3.
#defined possibleVBTableEntry/3.

% ============================================================
% GUESSES
% ============================================================

{ factVFTable(V) } :- possibleVFTableWrite(_, _, V).  % Counterpart: guessVFTable (guess.pl:180)
% RTTI definitively confirms vftables — no guess needed for these.
factVFTable(V) :- rTTICompleteObjectLocator(V, _).       % Counterpart: factVFTable (hard fact, setup.pl:55)

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
{ factDerivedClass(Outer, Inner, Off) } :- objectInObject(Outer, Inner, Off).  % Counterpart: guessDerivedClass (guess.pl:317)

% Guess: does a class have no base class?
{ factClassHasNoBase(C) } :- classRep(C).  % Counterpart: guessClassHasNoBase / guessClassHasNoBaseB / guessClassHasNoBaseSpecial (guess.pl:746, 732, 781)

% Guess: is candidate V actually a VBTable?
{ factVBTable(V) } :- possibleVBTableWrite(_, _, V).  % Counterpart: guessVBTable (guess.pl:215)

% ============================================================
% MERGE CANDIDATES — domain restriction for scaling
% ============================================================
% Only generate mergeClasses choices for structurally related pairs.
% This avoids O(n²) grounding for binaries with thousands of methods.

% Same vftable writers or writer+entry
mergeCandidate(M1, M2) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2.  % Counterpart: guessMergeClassesD (guess.pl:1215)
mergeCandidate(M1, M2) :- factVFTableWrite(M1, _, V), factVFTableEntry(V, _, M2), M1 < M2.    % Counterpart: guessMergeClassesB (guess.pl:1050)
mergeCandidate(M1, M2) :- factVFTableWrite(M2, _, V), factVFTableEntry(V, _, M1), M1 < M2.    % Counterpart: guessMergeClassesB

% Same debug symbol class
mergeCandidate(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.                      % Counterpart: reasonMergeClasses_G (rules.pl:2881)

% objectInObject relationships
mergeCandidate(M1, M2) :- objectInObject(M1, M2, _), M1 < M2.                                   % Counterpart: reasonNOTMergeClasses_G (rules.pl:3177) / guessDerivedClass
mergeCandidate(M1, M2) :- objectInObject(M2, M1, _), M1 < M2.                                   % Counterpart: reasonNOTMergeClasses_G

% Two inners of the same outer (reasonMergeClasses_E)
mergeCandidate(M1, M2) :- objectInObject(Outer, M1, _), objectInObject(Outer, M2, _), M1 < M2. % Counterpart: reasonMergeClasses_E (rules.pl:2847)

% Call relationships
mergeCandidate(M1, M2) :- callTarget(M1, M2), M1 < M2.                                         % Counterpart: guessMergeClassesC1-C4 (guess.pl:1103, 1146, 1169, 1187)
mergeCandidate(M1, M2) :- callTarget(M2, M1), M1 < M2.                                         % Counterpart: guessMergeClassesC1-C4
mergeCandidate(M1, M2) :- callAtOffset(M1, M2, 0), M1 < M2.                                    % Counterpart: reasonMergeClasses_C (rules.pl:2822) / factClassCallsMethod
mergeCandidate(M1, M2) :- callAtOffset(M2, M1, 0), M1 < M2.                                    % Counterpart: reasonMergeClasses_C

% Vftable overwrite relationships
mergeCandidate(M1, M2) :- factVFTableOverwrite(M1, _, _, V), factVFTableWrite(M2, _, V), M1 < M2. % Counterpart: reasonDerivedClass_B (rules.pl:1834) / guessMergeClassesD
mergeCandidate(M1, M2) :- factVFTableOverwrite(M2, _, _, V), factVFTableWrite(M1, _, V), M1 < M2. % Counterpart: reasonDerivedClass_B

% VBTable relationships
mergeCandidate(M1, M2) :- factVBTableWrite(M1, Off, V), factVBTableWrite(M2, Off, V), M1 < M2. % Counterpart: reasonDerivedClass_F (rules.pl:1999) / guessMergeClassesB-like

% Deleting destructor / real destructor chain
mergeCandidate(M1, M2) :- factDeletingDestructor(M1), factRealDestructor(M2), callTarget(M1, M2), M1 < M2. % Counterpart: guessMergeClasses (destructor chain, guess.pl:1084)
mergeCandidate(M1, M2) :- factDeletingDestructor(M2), factRealDestructor(M1), callTarget(M2, M1), M1 < M2. % Counterpart: guessMergeClasses

{ mergeClasses(M1, M2) } :- mergeCandidate(M1, M2).                                              % Counterpart: guessMergeClasses (guess.pl:1084) / guessLateMergeClasses (guess.pl:860)

% ============================================================
% THUNK RESOLUTION
% ============================================================

% Follow thunk chains to find the actual implementing method.
dethunk(E, E) :- possibleVFTableEntry(_, _, E), not thunk(E, _).  % Counterpart: dethunk (initial.pl:313) / eventualThunk (initial.pl:304)
dethunk(T, T) :- thunk(_, T), not thunk(T, _).                    % Counterpart: dethunk

dethunk(T, M) :- thunk(T, X), dethunk(X, M).                     % Counterpart: dethunk

% factVFTableEntry: actual method at each confirmed slot after thunk resolution.
factVFTableEntry(V, Off, M) :- possibleVFTableEntry(V, Off, E), factVFTable(V), dethunk(E, M).  % Counterpart: factVFTableEntry (setup.pl:59) / guessVFTableEntry (guess.pl:286)

% factVFTableSizeGTE: lower bound on vftable size in bytes (max offset + pointer size).
factVFTableSizeGTE(V, Size) :-                                      % Counterpart: reasonVFTableSizeGTE_B (partial, rules.pl:1366)
    factVFTable(V),
    Size = #max { Off + 4 : factVFTableEntry(V, Off, _) }.

% ============================================================
% DERIVED FACTS: confirmed vftable writes and overwrites
% ============================================================

factVFTableWrite(M, Off, V) :- possibleVFTableWrite(M, Off, V), factVFTable(V).  % Counterpart: factVFTableWrite (setup.pl:57)

% Both vftables must be confirmed for an overwrite to count.
factVFTableOverwrite(M, Off, V1, V2) :-                              % Counterpart: factVFTableOverwrite (setup.pl:58)
    possibleVFTableOverwrite(M, Off, V1, V2), factVFTable(V1), factVFTable(V2).

% inheritedVftableEntry: a slot in a derived vftable that reuses the same method
% pointer as the base vftable at the same offset.  Such entries belong to the base
% class and must not be merged into the derived class via vftable-entry rules.
inheritedVftableEntry(Vderived, Off, M) :-                           % *** XXX NO COUNTERPART *** (Clingo-specific; closest: reasonVFTableSizeGTE_B / reasonVFTableSizeLTE_B)
    factVFTableOverwrite(_, _, Vbase, Vderived),
    factVFTableEntry(Vbase, Off, M),
    factVFTableEntry(Vderived, Off, M).

% ============================================================
% VBTABLE DERIVED FACTS
% ============================================================

factVBTableWrite(M, Off, V) :- possibleVBTableWrite(M, Off, V), factVBTable(V).  % Counterpart: factVBTableWrite (setup.pl:66)

factVBTableEntry(V, Off, Value) :-                                    % Counterpart: factVBTableEntry (setup.pl:67)
    possibleVBTableEntry(V, Off, Value), factVBTable(V).

% ============================================================
% METHOD IDENTIFICATION
% ============================================================

factMethod(M) :- factVFTableEntry(_, _, M), not purecall(M).           % Counterpart: reasonMethod_* (A–P, rules.pl:28)
factMethod(M) :- factVFTableWrite(M, _, _).                           % Counterpart: reasonMethod_*
factMethod(M) :- factConstructor(M).                                  % Counterpart: reasonMethod_*
factMethod(M) :- factRealDestructor(M).                               % Counterpart: reasonMethod_*
factMethod(M) :- factDeletingDestructor(M).                           % Counterpart: reasonMethod_*
factMethod(M) :- symbolClass(M, _).                                    % Counterpart: reasonMethod_*
factMethod(M) :- symbolProperty(M, _).                                % Counterpart: reasonMethod_*
factMethod(Callee) :- callTarget(Caller, Callee), factMethod(Caller).  % Counterpart: reasonMethod_*

% ============================================================
% CONSTRUCTOR / DESTRUCTOR CLASSIFICATION
% ============================================================

% factNOTConstructor: strong evidence M is NOT a constructor.
% Mirrors reasonNOTConstructor_B (real dtor), _C (deleting dtor), _D (in vftable).
factNOTConstructor(M) :- factRealDestructor(M).                      % Counterpart: reasonNOTConstructor_B (rules.pl:282)
factNOTConstructor(M) :- factDeletingDestructor(M).                   % Counterpart: reasonNOTConstructor_C (rules.pl:289)
factNOTConstructor(M) :- factVFTableEntry(_, _, M).  % virtual methods cannot be constructors  % Counterpart: reasonNOTConstructor_D (rules.pl:297)
factNOTConstructor(M) :- uninitializedReads(M).                       % Counterpart: reasonNOTConstructor_F (rules.pl:...)
factNOTConstructor(M) :- callsDelete(M).                              % Counterpart: reasonNOTConstructor_G (rules.pl:...)

factConstructor(M) :- symbolProperty(M, constructor).                  % Counterpart: guessConstructor1 (guess.pl:574)
factConstructor(M) :- returnsSelf(M), noCallsBefore(M), not factNOTConstructor(M).  % Counterpart: guessConstructor2 (guess.pl:592)
factConstructor(M) :- factVFTableWrite(M, 0, _), not factNOTConstructor(M).         % Counterpart: guessConstructor3 (guess.pl:612)

factRealDestructor(M) :- symbolProperty(M, realDestructor).          % Counterpart: guessRealDestructor (guess.pl:1395)
factRealDestructor(M) :- noCallsAfter(M), not factConstructor(M), not callsDelete(M).  % Counterpart: guessRealDestructor

factDeletingDestructor(M) :- symbolProperty(M, deletingDestructor).    % Counterpart: guessDeletingDestructor (guess.pl:1504)
factDeletingDestructor(M) :- callsDelete(M), not factConstructor(M).   % Counterpart: guessDeletingDestructor

% ============================================================
% INHERITANCE / EMBEDDING DETECTION
% ============================================================

% objectInObject: constructor Outer calls constructor Inner at this+Off.
% Mirrors factObjectInObject / reasonDerivedClass_B pattern.
objectInObject(Outer, Inner, Off) :-                                    % Counterpart: factObjectInObject (setup.pl:70)
    factConstructor(Outer), factConstructor(Inner), Outer != Inner,
    callAtOffset(Outer, Inner, Off), Off >= 0.

% Hard derivation from vftable overwrite: the method that installs V1 without
% overwriting is the base constructor; the overwriting method is derived.
factDerivedClass(Outer, Inner, Off) :-                                  % Counterpart: reasonDerivedClass_B (rules.pl:1834)
    factVFTableOverwrite(Outer, Off, V1, _),
    factVFTableWrite(Inner, 0, V1), not factVFTableOverwrite(Inner, 0, _, V1),
    Outer != Inner.

% When objectInObject holds but factDerivedClass does not, it's an embedded member.
factEmbeddedObject(Outer, Inner, Off) :-                               % Counterpart: factEmbeddedObject (setup.pl:73) / tryEmbeddedObject (guess.pl:337)
    objectInObject(Outer, Inner, Off), not factDerivedClass(Outer, Inner, Off).

% Hard derivation from RTTI (reasonDerivedClass_D): RTTI inheritance is authoritative.
factDerivedClass(Outer, Inner, Off) :-                                  % Counterpart: reasonDerivedClass_D (rules.pl:1968)
    rTTICompleteObjectLocator(V1, TDA1), rTTICompleteObjectLocator(V2, TDA2),
    rTTIInheritsFrom(TDA1, TDA2, Off),
    factVFTableWrite(Outer, 0, V1), not factVFTableOverwrite(Outer, 0, _, V1),
    factVFTableWrite(Inner, 0, V2), not factVFTableOverwrite(Inner, 0, _, V2).

% Virtual base detection from VBTables (reasonDerivedClass_F).
% If objectInObject holds and a VBTable entry gives the matching offset,
% the relationship is virtual inheritance, not embedding.
factDerivedClass(Outer, Inner, Off) :-                                  % Counterpart: reasonDerivedClass_F (rules.pl:1999)
    objectInObject(Outer, Inner, Off),
    factVBTableWrite(Outer, VBPtrOff, V),
    factVBTableEntry(V, TableOff, OffsetFromVBPtr),
    TableOff > 0,
    Off = VBPtrOff + OffsetFromVBPtr,
    Outer != Inner.

% ============================================================
% CLASS → VFTABLE MAPPING
% ============================================================

% factVFTableBelongsToClass(V, Off, C): vftable V belongs to class C at object offset Off.
% Mirrors reasonVFTableBelongsToClass.
factVFTableBelongsToClass(V, Off, C) :- factVFTableWrite(M, Off, V), find(M, C).  % Counterpart: reasonVFTableBelongsToClass (rules.pl:1007)

% ============================================================
% reasonMergeClasses — forced merges (must happen)
% ============================================================

% Multiple methods writing the SAME vftable at the same offset → same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesD (guess.pl:1215) / reasonMergeClasses (rules.pl:2748)
    factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2.

% Methods in a vftable belong to the class whose constructor writes it.
% Skip inherited entries — those belong to the base class.
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesB (guess.pl:1050)
    factVFTableWrite(M1, _, V), factVFTableEntry(V, Off, M2),
    not inheritedVftableEntry(V, Off, M2), M1 < M2.
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesB
    factVFTableWrite(M2, _, V), factVFTableEntry(V, Off, M1),
    not inheritedVftableEntry(V, Off, M1), M1 < M2.

% Debug symbols resolve class membership directly (reasonMergeClasses_G)
reasonMergeClasses(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.  % Counterpart: reasonMergeClasses_G (rules.pl:2881)

% reasonMergeClasses_E: two methods both the inner (base) of the same derived at same offset
reasonMergeClasses(B1, B2) :-                                           % Counterpart: reasonMergeClasses_E (rules.pl:2847)
    factDerivedClass(_, B1, Off), factDerivedClass(_, B2, Off), B1 < B2.

% Deleting destructor calls real destructor → same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClasses (destructor chain, guess.pl:1084)
    factDeletingDestructor(M1), factRealDestructor(M2), callTarget(M1, M2), M1 < M2.
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClasses
    factDeletingDestructor(M2), factRealDestructor(M1), callTarget(M2, M1), M1 < M2.

% VBTable merges: same VBTable writers → same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesB-like (VBTable analogue, no exact Prolog rule)
    factVBTableWrite(M1, Off, V), factVBTableWrite(M2, Off, V), M1 < M2.

:- reasonMergeClasses(M1, M2), not mergeClasses(M1, M2).               % Counterpart: insanityContradictoryMerges (insanity.pl:271) / guessMergeClasses enforcement

% ============================================================
% reasonNOTMergeClasses — forced not-merges (mergeClasses must not happen)
% ============================================================

% Outer and inner of objectInObject are distinct classes
reasonNOTMergeClasses(M1, M2) :- objectInObject(M1, M2, _), M1 < M2.   % Counterpart: reasonNOTMergeClasses_G (rules.pl:3177)
reasonNOTMergeClasses(M1, M2) :- objectInObject(M2, M1, _), M1 < M2.   % Counterpart: reasonNOTMergeClasses_G

% Base vs. derived from vftable overwrite
reasonNOTMergeClasses(M1, M2) :-                                         % Counterpart: reasonNOTMergeClasses_C / reasonNOTMergeClasses_C_asymmetric (rules.pl:3090, 3111)
    factVFTableWrite(M1, 0, V), not factVFTableOverwrite(M1, 0, _, V),
    factVFTableOverwrite(M2, 0, V, _), M1 < M2.
reasonNOTMergeClasses(M1, M2) :-                                         % Counterpart: reasonNOTMergeClasses_C
    factVFTableWrite(M2, 0, V), not factVFTableOverwrite(M2, 0, _, V),
    factVFTableOverwrite(M1, 0, V, _), M1 < M2.

% reasonNOTMergeClasses_F: two bases of the same derived at different offsets
reasonNOTMergeClasses(B1, B2) :-                                         % Counterpart: reasonNOTMergeClasses_F (rules.pl:3158)
    factDerivedClass(D, B1, Off1), factDerivedClass(D, B2, Off2),
    Off1 != Off2, B1 < B2.

% RTTI: two vftables with different type descriptors belong to different classes
reasonNOTMergeClasses(M1, M2) :-                                         % Counterpart: reasonNOTMergeClasses_I (rules.pl:3196)
    rTTICompleteObjectLocator(V1, TDA1), rTTICompleteObjectLocator(V2, TDA2),
    TDA1 != TDA2,
    factVFTableWrite(M1, _, V1), factVFTableWrite(M2, _, V2), M1 < M2.

:- reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2).                  % Counterpart: insanityContradictoryMerges (insanity.pl:271)

% ============================================================
% CLASS COMPUTATION: equivalence classes via transitive closure
% ============================================================

sameClass(M, M)   :- factMethod(M).                                      % Counterpart: sameClass (Prolog transitive closure, rules.pl)
sameClass(M1, M2) :- mergeClasses(M1, M2).                               % Counterpart: sameClass
sameClass(M2, M1) :- sameClass(M1, M2).                                  % Counterpart: sameClass
sameClass(M1, M3) :- sameClass(M1, M2), sameClass(M2, M3).              % Counterpart: sameClass

hasLesser(M) :- sameClass(M, M2), M2 < M.                              % Counterpart: classRep helper (*** XXX NO COUNTERPART *** Clingo-specific min selection)
classRep(M)  :- factMethod(M), not hasLesser(M).                         % Counterpart: classRep (Prolog union-find, rules.pl)
find(M, R)   :- sameClass(M, R), classRep(R).  % mirrors Prolog's find/2  % Counterpart: find/2 (Prolog union-find, rules.pl)

% ============================================================
% CLASS PROPERTIES
% ============================================================

% Hard derivation: RTTI with no inheritance entries means this class has no base.
factClassHasNoBase(C) :-                                                 % Counterpart: guessClassHasNoBaseSpecial (guess.pl:781) / insanityNoBaseConsistency (insanity.pl:8)
    rTTICompleteObjectLocator(V, TDA), factVFTableWrite(M, 0, V), find(M, C),
    not rTTIInheritsFrom(TDA, _, _).

% Constraint: a derived class cannot also have no base.
:- factClassHasNoBase(C), factDerivedClass(M, _, _), find(M, C).       % Counterpart: insanityNoBaseConsistency (insanity.pl:8)

% factClassCallsMethod: methods called by a class passing the same this-pointer.
% Mirrors factClassCallsMethod (validMethodCallAtOffset at offset 0).
factClassCallsMethod(C, M) :-                                             % Counterpart: factClassCallsMethod (setup.pl:83)
    find(Caller, C), callAtOffset(Caller, M, 0), factMethod(M).

% reasonMergeClasses_C: two no-base classes where one calls a method of the other
reasonMergeClasses(R1, R2) :-                                             % Counterpart: reasonMergeClasses_C (rules.pl:2822)
    factClassHasNoBase(R1), factClassHasNoBase(R2), R1 != R2, R1 < R2,
    factClassCallsMethod(R1, M), find(M, R2).

% ============================================================
% SANITY CHECKS
% ============================================================

% insanityVirtualConstructor: constructors cannot appear in vftables
:- factConstructor(M), factVFTableEntry(_, _, M).                         % Counterpart: insanityConstructorInVFTable (insanity.pl:48)

% insanityDoubleDuty: method cannot be both constructor and destructor
:- factConstructor(M), factRealDestructor(M).                           % Counterpart: insanityConstructorAndRealDestructor (insanity.pl:226)
:- factConstructor(M), factDeletingDestructor(M).                         % Counterpart: insanityConstructorAndDeletingDestructor (insanity.pl:240)

% insanityContradictoryNOTConstructor
:- factConstructor(M), factNOTConstructor(M).                               % Counterpart: insanityConstructorAndNotConstructor (insanity.pl:214)

% insanityMultipleRealDestructors: at most one real destructor per class
:- factRealDestructor(D1), factRealDestructor(D2), D1 < D2,            % Counterpart: insanityTwoRealDestructorsOnClass (insanity.pl:253)
   find(D1, C), find(D2, C).

% insanityVFTables: a vftable cannot be shared by two classes at the same offset
:- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2, % Counterpart: insanityVFTableOnTwoClasses (insanity.pl:18)
   find(M1, C1), find(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same offset → different classes
:- factVFTableWrite(M1, Off, V1), factVFTableWrite(M2, Off, V2),         % Counterpart: reasonNOTMergeClasses_E (rules.pl:3123) / insanityContradictoryMerges
   M1 != M2, V1 != V2, find(M1, C), find(M2, C).

% VFTable entries must resolve to real methods
:- factVFTableEntry(_, _, M), not factMethod(M).                         % Counterpart: reasonMethod_* (A–P) enforcement

% insanityObjectCycle: circular inheritance is impossible
:- factDerivedClass(A, B, _), factDerivedClass(B, A, _).                  % Counterpart: insanityObjectCycle (insanity.pl:162)

% objectInObject pairs must be in distinct classes
:- objectInObject(M1, M2, _), sameClass(M1, M2).                        % Counterpart: reasonNOTMergeClasses_G (insanity.pl:3177) / insanityContradictoryMerges

% A derived vftable must be at least as large as the base vftable it overwrites.
:- factVFTableOverwrite(_, _, Vbase, Vderived),                          % Counterpart: insanityBaseVFTableLarger (insanity.pl:196)
   factVFTableSizeGTE(Vbase, Sbase), factVFTableSizeGTE(Vderived, Sderived),
   Sderived < Sbase.

% ============================================================
% OPTIMIZATION
% ============================================================

% Priority 2: confirm as many vftables as possible
% Priority 1: maximize class merges (minimize class count)
% Priority 0: prefer factDerivedClass at offset 0; prefer more factClassHasNoBase
#maximize { 1@2, V : factVFTable(V); 1@2, V : factVBTable(V) }.        % Counterpart: guessVFTable / guessVBTable / guessDerivedClass / guessClassHasNoBase / guessMergeClasses priorities (Prolog uses binary-search guess ordering)
#maximize { 1@1, M1, M2 : mergeClasses(M1, M2) }.                        % Counterpart: guessMergeClasses priority
#maximize { 1@0, Outer, Inner : factDerivedClass(Outer, Inner, 0) }.      % Counterpart: guessDerivedClass priority
#maximize { 1@0, C : factClassHasNoBase(C) }.                            % Counterpart: guessClassHasNoBase priority

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
#show factVBTable/1.
#show factVBTableWrite/3.
#show factVBTableEntry/3.
