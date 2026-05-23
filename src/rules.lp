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

factMethod(M) :- factVFTableEntry(_, _, M).                            % Counterpart: reasonMethod_G (rules.pl:73)
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

% thisPtrUsage/3: discard instruction for rules that don't need it.
thisPtrUsage(Function, ThisPtr, Method) :- thisPtrUsage(_, Function, ThisPtr, Method).

% reasonMethod_K: if a function passes a this-pointer to a known method,
% any other method called on the same this-pointer is also a method.
factMethod(M) :-
    thisPtrUsage(_, Func, ThisPtr, Method1),
    factMethod(Method1),
    thisPtrUsage(_, Func, ThisPtr, M),
    Method1 != M.

% reasonMethod_M: heap or global allocation flows to a this-pointer used to call a method.
factMethod(M) :-
    thisPtrAllocation(_, Func, ThisPtr, type_Heap, _),
    thisPtrUsage(_, Func, ThisPtr, M),
    thisParamFuncParameter(M, _).

factMethod(M) :-
    thisPtrAllocation(_, Func, ThisPtr, type_Global, _),
    thisPtrUsage(_, Func, ThisPtr, M),
    thisParamFuncParameter(M, _).

% reasonMethod_N: a function passes its own this-pointer to a known method,
% so the function itself is a method.
factMethod(Func) :-
    thisPtrUsage(_, Func, ThisPtr, Method),
    factMethod(Method),
    thisParamFuncParameter(Func, ThisPtr).

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
    not rTTIPresent,
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

% factVFTableBelongsToClass(V, Off, M): vftable V is written by method M at object offset Off.
% Mirrors reasonVFTableBelongsToClass.
factVFTableBelongsToClass(V, Off, M) :- factVFTableWrite(M, Off, V).  % Counterpart: reasonVFTableBelongsToClass (rules.pl:1007)

% ============================================================
% Hard merges -- must merge
% ============================================================

mergeClasses(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.  % Counterpart: reasonMergeClasses_G (rules.pl:2881)

mergeClasses(B1, B2) :- factDerivedClass(Derived, B1, Off), factDerivedClass(Derived, B2, Off), B1 < B2.  % Counterpart: reasonMergeClasses_E (rules.pl:2847)



% ============================================================
% reasonNOTMergeClasses -- must not merge
% ============================================================

% Outer and inner of objectInObject are distinct classes
reasonNOTMergeClasses(C1, C2) :- objectInObject(M1, M2, _), sortPair(M1, M2, C1, C2).  % Counterpart: reasonNOTMergeClasses_G (rules.pl:3177)

% Base vs. derived from vftable overwrite
reasonNOTMergeClasses_C_asymmetric(Inst, Over) :-                        % Counterpart: reasonNOTMergeClasses_C_asymmetric (rules.pl:3090)
    factVFTableWrite(Inst, 0, V), not factVFTableOverwrite(Inst, 0, _, V),
    factVFTableOverwrite(Over, 0, V, _).
reasonNOTMergeClasses(C1, C2) :- reasonNOTMergeClasses_C_asymmetric(A, B), sortPair(A, B, C1, C2).

% reasonNOTMergeClasses_F: two bases of the same derived at different offsets
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_F (rules.pl:3158)
    factDerivedClass(D, B1, Off1), factDerivedClass(D, B2, Off2),
    Off1 != Off2, sortPair(B1, B2, C1, C2).

% RTTI: two vftables with different type descriptors belong to different classes
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_I (rules.pl:3196)
    rTTICompleteObjectLocator(V1, TDA1), rTTICompleteObjectLocator(V2, TDA2),
    TDA1 != TDA2,
    factVFTableWrite(M1, _, V1), factVFTableWrite(M2, _, V2),
    sortPair(M1, M2, C1, C2).

% reasonNOTMergeClasses_E: two methods writing different vftables at offset 0
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
    factVFTableWrite(M1, 0, V1), factVFTableWrite(M2, 0, V2),
    V1 != V2,
    not factVFTableWrite(M1, 0, V2), not factVFTableWrite(M2, 0, V1),
    sortPair(M1, M2, C1, C2).

% reasonNOTMergeClasses_J: derived/base class relationship (transitive)
classRelationship(Derived, Base) :- factDerivedClass(Derived, Base, _).
classRelationship(Derived, Base) :- factDerivedClass(Derived, Middle, _), classRelationship(Middle, Base).

reasonNOTMergeClasses(C1, C2) :- classRelationship(M1, M2), sortPair(M1, M2, C1, C2).

% reasonNOTMergeClasses_K: methods with different symbolClass names
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_K (rules.pl:3222)
    symbolClass(M1, N1), symbolClass(M2, N2),
    N1 != N2, sortPair(M1, M2, C1, C2).

% reasonNOTMergeClasses_L: two classes each with a real destructor
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_L (rules.pl:3240)
    factRealDestructor(D1), factRealDestructor(D2),
    sortPair(D1, D2, C1, C2).

% reasonNOTMergeClasses_P: constructor/destructor called at offset > 0
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_P (rules.pl:3318)
    validMethodCallAtOffset(_, Caller, Method, Offset),
    Offset > 0, factMethod(Caller), factMethod(Method), factConstructor(Method),
    sortPair(Caller, Method, C1, C2).
reasonNOTMergeClasses(C1, C2) :-
    validMethodCallAtOffset(_, Caller, Method, Offset),
    Offset > 0, factMethod(Caller), factMethod(Method),
    factDeletingDestructor(Method), not factRealDestructor(Caller),
    sortPair(Caller, Method, C1, C2).
reasonNOTMergeClasses(C1, C2) :-
    validMethodCallAtOffset(_, Caller, Method, Offset),
    Offset > 0, factMethod(Caller), factMethod(Method), factRealDestructor(Method),
    sortPair(Caller, Method, C1, C2).

% reasonNOTMergeClasses_R: derived vftable installed by called method
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_R (rules.pl:3366)
    factClassCallsMethod(Derived, CalledMethod),
    not purecall(CalledMethod),
    factDerivedClass(Derived, Base, Offset),
    factVFTableWrite(CalledMethod, Offset, V),
    factVFTableBelongsToClass(V, Offset, Derived),
    sortPair(Base, CalledMethod, C1, C2).

% reasonNOTMergeClasses_Q: symbol consistency
reasonNOTMergeClasses(C1, C2) :-                                         % Counterpart: reasonNOTMergeClasses_Q (rules.pl:3352)
    symbolClass(M1, ClassName), factMethod(M2),
    not symbolClass(M2, ClassName),
    sortPair(M1, M2, C1, C2).


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

% sortPair: produce the canonical ordered pair of two IDs.
% Counterpart to Prolog's sort_tuple/2 -- avoids duplicating two-rule ordering patterns.
sortPair(A, B, A, B) :- factMethod(A), factMethod(B), A < B.
sortPair(A, B, B, A) :- factMethod(A), factMethod(B), B < A.

% ============================================================
% CLASS PROPERTIES
% ============================================================

% Hard derivation: RTTI with no inheritance entries means this method's class has no base.
factClassHasNoBase(M) :-                                                 % Counterpart: guessClassHasNoBaseSpecial (guess.pl:781) / insanityNoBaseConsistency (insanity.pl:8)
    rTTICompleteObjectLocator(V, TDA), factVFTableWrite(M, 0, V),
    factConstructor(M),
    not factVFTableOverwrite(M, 0, V, _),
    not factDerivedClass(M, _, _),
    not rTTIInheritsFrom(TDA, _, _).

% factClassCallsMethod: Caller directly calls M passing the same this-pointer.
% Mirrors reasonClassCallsMethod_C (rules.pl:2463).  Intentionally does NOT require
% factMethod(M) so that reasonMethod_J can derive factMethod from it.
factClassCallsMethod(Caller, M) :-                                        % Counterpart: factClassCallsMethod (setup.pl:83)
    callAtOffset(Caller, M, 0).

% reasonMethod_J: a method called by another class via this+0 is a method.
factMethod(M) :- factClassCallsMethod(_, M).

% reasonMergeClasses_C: two no-base classes where one calls a method of the other
mergeClasses(Caller, M) :-                                                   % Counterpart: reasonMergeClasses_C (rules.pl:2822)
    sameClass(Caller, CR), factClassHasNoBase(CR),
    callAtOffset(Caller, M, 0),
    sameClass(M, MR), factClassHasNoBase(MR),
    not purecall(M), Caller < M.
mergeClasses(M, Caller) :-
    sameClass(Caller, CR), factClassHasNoBase(CR),
    callAtOffset(Caller, M, 0),
    sameClass(M, MR), factClassHasNoBase(MR),
    not purecall(M), M < Caller.
