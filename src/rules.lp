% ============================================================
% THUNK RESOLUTION
% ============================================================

% Follow thunk chains to find the actual implementing method.
dethunk(E, E) :- possibleVFTableEntry(_, _, E), not thunk(E, _).  % Counterpart: dethunk (initial.pl:313) / eventualThunk (initial.pl:304)
dethunk(T, T) :- thunk(_, T), not thunk(T, _).                    % Counterpart: dethunk

% Catch-all identity: Prolog's dethunk returns the input unchanged when it is not a thunk.
dethunk(M, M) :- possibleMethod(M), not thunk(M, _).

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

% inheritedVftableEntry: DISABLED -- caused interaction problems on real binaries.
% The idea: a slot in a derived vftable reusing the same method from the base should
% not trigger a class merge between the derived class writer and that method.
% Prolog handles this implicitly (no spurious merges because guessMergeClassesB is a
% guess, not a hard rule).  See TODO.md for the potential OOAnalyzer improvement.
%
% % Case 1: explicit vftable overwrite (derived constructor writes both vftables).
% inheritedVftableEntry(Vderived, Off, M) :-
%     factVFTableOverwrite(_, _, Vbase, Vderived),
%     factVFTableEntry(Vbase, Off, M),
%     factVFTableEntry(Vderived, Off, M).
%
% % Case 2: inheritance without explicit overwrite via factDerivedClass.
% inheritedVftableEntry(Vderived, Off, M) :-
%     factDerivedClass(Outer, Inner, 0),
%     factVFTableWrite(Outer, 0, Vderived), factVFTableWrite(Inner, 0, Vbase),
%     Vbase != Vderived,
%     factVFTableEntry(Vbase, Off, M),
%     factVFTableEntry(Vderived, Off, M).

% ============================================================
% VBTABLE DERIVED FACTS
% ============================================================

factVBTableWrite(M, Off, V) :- possibleVBTableWrite(M, Off, V), factVBTable(V).  % Counterpart: factVBTableWrite (setup.pl:66)

factVBTableEntry(V, Off, Value) :-                                    % Counterpart: factVBTableEntry (setup.pl:67)
    possibleVBTableEntry(V, Off, Value), factVBTable(V).

% ============================================================
% METHOD IDENTIFICATION
% ============================================================

factMethod(M) :- factVFTableEntry(_, _, M), not purecall(M).           % Counterpart: reasonMethod_* (A-P, rules.pl:28)
factMethod(M) :- factVFTableWrite(M, _, _).                           % Counterpart: reasonMethod_*
factMethod(M) :- factConstructor(M), possibleMethod(M).              % Counterpart: reasonMethod_*
factMethod(M) :- factRealDestructor(M), possibleMethod(M).             % Counterpart: reasonMethod_*
factMethod(M) :- factDeletingDestructor(M), possibleMethod(M).         % Counterpart: reasonMethod_*
factMethod(M) :- symbolClass(M, _).                                    % Counterpart: reasonMethod_*
factMethod(M) :- symbolProperty(M, _).                                 % Counterpart: reasonMethod_*
factMethod(Callee) :- callTarget(Caller, Callee), factMethod(Caller), possibleMethod(Callee).  % Counterpart: reasonMethod_*

% reasonMethod_L: precise this-call propagation at offset 0.
factMethod(M) :- methodCallAtOffset(_, Caller, M, 0), factMethod(Caller), thisParamFuncParameter(M, _).

% reasonMethod_O: a __thiscall method passes its this-pointer as arg 0 to a __cdecl target.
factMethod(M) :-
    factMethod(Proven),
    callingConvention(Proven, "__thiscall"),
    thisParamFuncParameter(Proven, ThisPtr),
    callParameter(Insn, Proven, 0, ThisPtr),
    callTarget(Insn, Proven, Target),
    dethunk(Target, M),
    callingConvention(M, "__cdecl").

% reasonMethod_P: the same this-pointer is passed to two callees; one is already a proven method.
factMethod(M) :-
    callParameter(Insn1, Func, 0, ThisPtr),
    callTarget(Insn1, Func, Target1),
    dethunk(Target1, Proven),
    factMethod(Proven),
    callParameter(Insn2, Func, 0, ThisPtr),
    callTarget(Insn2, Func, Target2),
    dethunk(Target2, M),
    callingConvention(M, "__cdecl").

% reasonMethod_Q: a thunk that chains to a proven method is itself a method.
% DISABLED: causes UNSAT on ooex4/5/6/9 -- see diagnosis below.
% factMethod(M) :- thunk(M, Called), factMethod(Called).

% factNOTMethod: explicit negation for possible methods that are not confirmed.
% Counterpart: factNOTMethod (setup.pl:45 / guess.pl)
factNOTMethod(M) :- possibleMethod(M), not factMethod(M).

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
factConstructor(M) :- returnsSelf(M), noCallsBefore(M), not factNOTConstructor(M), possibleConstructor(M).  % Counterpart: guessConstructor2 (guess.pl:592)
factConstructor(M) :- factVFTableWrite(M, 0, _), not factNOTConstructor(M), possibleConstructor(M).         % Counterpart: guessConstructor3 (guess.pl:612)

factRealDestructor(M) :- symbolProperty(M, realDestructor).          % Counterpart: guessRealDestructor (guess.pl:1395)
{ factRealDestructor(M) } :- noCallsAfter(M), not factConstructor(M), not callsDelete(M), possibleDestructor(M), possibleMethod(M),
                               callTarget(D, M), factDeletingDestructor(D).

factDeletingDestructor(M) :- symbolProperty(M, deletingDestructor).    % Counterpart: guessDeletingDestructor (guess.pl:1504)
factDeletingDestructor(M) :- callsDelete(M), not factConstructor(M), possibleMethod(M).   % Counterpart: guessDeletingDestructor

% factNOTRealDestructor / factNOTDeletingDestructor
% Counterpart: reasonNOTRealDestructor_B/C/D (rules.pl:430-440)
factNOTRealDestructor(M) :- factConstructor(M).
factNOTRealDestructor(M) :- factDeletingDestructor(M).
factNOTRealDestructor(M) :- factMethod(M), not possibleDestructor(M).

factNOTDeletingDestructor(M) :- factConstructor(M).
factNOTDeletingDestructor(M) :- factRealDestructor(M).

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
% CLASS -> VFTABLE MAPPING
% ============================================================

% factVFTableBelongsToClass(V, Off, C): vftable V belongs to class C at object offset Off.
% Mirrors reasonVFTableBelongsToClass.
factVFTableBelongsToClass(V, Off, C) :- factVFTableWrite(M, Off, V), find(M, C).  % Counterpart: reasonVFTableBelongsToClass (rules.pl:1007)

% ============================================================
% reasonMergeClasses -- must merge
% ============================================================

% Multiple methods writing the SAME vftable at the same offset -> same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesD (guess.pl:1215) / reasonMergeClasses (rules.pl:2748)
    factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2.

% Methods in a vftable belong to the class whose constructor writes it.
% Counterpart: guessMergeClassesB (guess.pl:1050) -- this is a GUESS in Prolog, not a hard constraint.
% The mergeCandidate entries in guess.lp capture the same pairs as soft (optional) merges.
% Making this a hard reasonMergeClasses causes UNSAT on real binaries with sibling classes
% sharing inherited methods. Keep disabled; the optimizer's maximize-merges objective
% achieves the merge when it is valid.
% reasonMergeClasses(M1, M2) :- factVFTableWrite(M1, _, V), factVFTableEntry(V, Off, M2), not inheritedVftableEntry(V, Off, M2), M1 < M2.
% reasonMergeClasses(M1, M2) :- factVFTableWrite(M2, _, V), factVFTableEntry(V, Off, M1), not inheritedVftableEntry(V, Off, M1), M1 < M2.

% Debug symbols resolve class membership directly (reasonMergeClasses_G)
reasonMergeClasses(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.  % Counterpart: reasonMergeClasses_G (rules.pl:2881)

% reasonMergeClasses_E: two methods both the inner (base) of the same derived at same offset
reasonMergeClasses(B1, B2) :-                                           % Counterpart: reasonMergeClasses_E (rules.pl:2847)
    factDerivedClass(_, B1, Off), factDerivedClass(_, B2, Off), B1 < B2.

% Deleting destructor calls real destructor -> same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClasses (destructor chain, guess.pl:1084)
    factDeletingDestructor(M1), factRealDestructor(M2), callTarget(M1, M2), M1 < M2.
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClasses
    factDeletingDestructor(M2), factRealDestructor(M1), callTarget(M2, M1), M1 < M2.

% VBTable merges: same VBTable writers -> same class
reasonMergeClasses(M1, M2) :-                                           % Counterpart: guessMergeClassesB-like (VBTable analogue, no exact Prolog rule)
    factVBTableWrite(M1, Off, V), factVBTableWrite(M2, Off, V), M1 < M2.


% ============================================================
% reasonNOTMergeClasses -- must not merge
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


% ============================================================
% CLASS COMPUTATION: equivalence classes via transitive closure
% ============================================================

% Compact transitive closure: use merged/2 as the undirected edge predicate
% to eliminate the explicit symmetry rule and reduce grounding.
merged(M1, M2) :- mergeClasses(M1, M2).
merged(M2, M1) :- mergeClasses(M1, M2).

sameClass(M, M)   :- factMethod(M).
sameClass(M1, M3) :- sameClass(M1, M2), merged(M2, M3).

hasLesser(M) :- sameClass(M, M2), M2 < M.
classRep(M)  :- factMethod(M), not hasLesser(M).
find(M, R)   :- sameClass(M, R), classRep(R).

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
% Mirrors reasonClassCallsMethod_C (rules.pl:2463).  Intentionally does NOT require
% factMethod(M) so that reasonMethod_J can derive factMethod from it.
factClassCallsMethod(C, M) :-                                             % Counterpart: factClassCallsMethod (setup.pl:83)
    find(Caller, C), callAtOffset(Caller, M, 0).

% reasonMethod_J: a method called by another class via this+0 is a method.
factMethod(M) :- factClassCallsMethod(_, M).

% reasonMergeClasses_C: two no-base classes where one calls a method of the other
reasonMergeClasses(R1, R2) :-                                             % Counterpart: reasonMergeClasses_C (rules.pl:2822)
    factClassHasNoBase(R1), factClassHasNoBase(R2), R1 != R2, R1 < R2,
    factClassCallsMethod(R1, M), find(M, R2).
