% ============================================================
% RULES
% ============================================================

% certainConstructorOrDestructor: method writes a confirmed vftable or vbtable
% into its own this-pointer.
% Counterpart: certainConstructorOrDestructor/1 (rules.pl:731)
%!trace_rule {"% must be a constructor or destructor because it writes a vftable into its own this-pointer", Method}
certainConstructorOrDestructor(Method) :-
    vfTableWrite(Insn, Method, Offset, VFTable),
    possibleVFTableWrite(Insn, Method, ThisPtr, Offset, VFTable),
    thisParamFuncParameter(Method, ThisPtr).

%!trace_rule {"% must be a constructor or destructor because it writes a vbtable into its own this-pointer", Method}
certainConstructorOrDestructor(Method) :-
    vbTableWrite(Insn, Method, Offset, VBTable),
    possibleVBTableWrite(Insn, Method, ThisPtr, Offset, VBTable),
    thisParamFuncParameter(Method, ThisPtr).

% reasonConstructor/1: symbol property evidence proves a constructor.
% Counterpart: reasonConstructor/1 (rules.pl:209)
%!trace_rule {"% is a constructor because a symbol says so", Method}
constructor(Method) :-
    symbolProperty(Method, constructor).                                  % rules.pl:209

% reasonConstructor: VBTable writes happen only in constructors.
% Counterpart: reasonConstructor (rules.pl:204)
%!trace_rule {"% is a constructor because it writes a vbtable", Method}
constructor(Method) :-
    vbTableWrite(_, Method, _, _).

% reasonRealDestructor/1: symbol property evidence proves a real destructor.
% Counterpart: reasonRealDestructor/1 (rules.pl:394)
%!trace_rule {"% is a real destructor because a symbol says so", Method}
realDestructor(Method) :-
    symbolProperty(Method, realDestructor).                               % rules.pl:394

% reasonDeletingDestructor/1: delete(this) evidence proves a deleting destructor.
% Counterpart: reasonDeletingDestructor/1 (rules.pl:585)
%!trace_rule {"% is a deleting destructor because it calls delete(this)", Method}
deletingDestructor(Method) :-
    method(Method),
    insnCallsDelete(_Insn, Method, ThisPtr),
    thisParamFuncParameter(Method, ThisPtr).                              % rules.pl:585

% reasonDeletingDestructor/1: symbol property evidence proves a deleting destructor.
% Counterpart: reasonDeletingDestructor/1 (rules.pl:595)
%!trace_rule {"% is a deleting destructor because a symbol says so", Method}
deletingDestructor(Method) :-
    symbolProperty(Method, deletingDestructor).                           % rules.pl:595

% reasonNOTConstructor_D: methods in confirmed vftable entries cannot be constructors.
% Counterpart: reasonNOTConstructor_D (rules.pl:297)
%!trace_rule {"% is not a constructor because it appears in a vftable entry", Method}
-constructor(Method) :-
    vfTableEntry(_VFTable, _Offset, Entry),
    dethunk(Entry, Method).

% reasonNOTConstructor_H: if a method's class has a confirmed vftable that the
% method doesn't install, the method is not a constructor.
% Imported methods (with symbolClass evidence) are exempt since we may lack
% visibility into their vftable writes.
% Counterpart: reasonNOTConstructor_H (rules.pl:345)
%!trace_rule {"% is not a constructor because it does not install vftable % which belongs to its class", Method, VFTable}
-constructor(Method) :-
    vfTable(VFTable),
    method(Method),
    &sameClass(VFTable, Method),
    not possibleVFTableWrite(_, Method, _, _, VFTable),
    not symbolClass(Method, _, _, _).

% reasonNOTDeletingDestructor_F: if delete() is detected in the program but
% this method doesn't call delete on its own this-pointer, it's not a deleting
% destructor.
% Two rule bodies faithfully translate the Prolog disjunction: a method that
% calls delete on an unknown pointer (no this-pointer info) is conservatively
% NOT ruled out.
% Counterpart: reasonNOTDeletingDestructor_F (rules.pl:667)
%!trace_rule {"% is not a deleting destructor because delete() exists in the program but % does not call delete(this)", Method, Method}
-deletingDestructor(Method) :-
    insnCallsDelete(_, _, _),
    possibleMethod(Method),
    not insnCallsDeleteAnyMethod(Method).

-deletingDestructor(Method) :-
    insnCallsDelete(_, _, _),
    possibleMethod(Method),
    insnCallsDeleteAnyMethod(Method),
    thisParamFuncParameter(Method, _),
    not callsDeleteOnSelf(Method).

% reasonNOTDeletingDestructor_G: if Method's class is known to have a vftable
% but Method itself does not appear in any vftable, then Method is not a
% deleting destructor.
%
% NOTE: The Prolog version (rules.pl:687) is WRONG — it asserts "deleting
% destructors must be virtual" unconditionally. Confirmed on mysql.exe:
% yaSSL's *Impl classes (AES, DES, MD5, SHA, ...) have ground-truth
% nonvirtual scalar_deleting_destructor thunks that the Prolog rule
% misclassifies. Pharos hides the unsoundness via forward-chaining ordering
% (concludeNOTDeletingDestructor is skipped if factDeletingDestructor is
% already asserted); our classical-negation port surfaces it as UNSAT. The
% fix here narrows the rule to fire only when the class has a vftable, so
% classes without their own vftable are exempt.
% Counterpart: reasonNOTDeletingDestructor_G (rules.pl:687)
%!trace_rule {"% is not a deleting destructor because its class has a vftable but % does not appear in any vftable", Method, Method}
-deletingDestructor(Method) :-
    method(Method),
    vfTable(VFTable),
    &sameClass(VFTable, Method),
    not possiblyVirtual(Method).

% reasonNOTDeletingDestructor_H: a thiscall method with more than 2 parameters
% cannot be a deleting destructor (ecx=this + 1 flag arg max).
% Counterpart: reasonNOTDeletingDestructor_H (rules.pl:695)
% Uses 3 distinct param positions instead of #count to avoid grounding blowup.
%!trace_rule {"% is not a deleting destructor because it has more than 2 parameters", Method}
-deletingDestructor(Method) :-
    possibleMethod(Method),
    callingConvention(Method, "__thiscall"),
    funcParameter(Method, P1, _),
    funcParameter(Method, P2, _),
    funcParameter(Method, P3, _),
    P1 != P2,
    P1 != P3,
    P2 != P3.

% ============================================================
% CONSTRAINTS
% ============================================================

% A method that writes a vftable/vbtable into its own this-pointer must be
% exactly one of: constructor, real destructor, or deleting destructor.
% Covers:
%   reasonConstructor (rules.pl:192) — elimination: only remaining candidate
%   reasonRealDestructor (rules.pl:388) — elimination: only remaining candidate
%   reasonDeletingDestructor (rules.pl:575) — elimination: only remaining candidate
%!trace_rule {"% is exactly one of constructor, real destructor, or deleting destructor", Method}
1 { constructor(Method) ; realDestructor(Method) ; deletingDestructor(Method) } 1 :-
    certainConstructorOrDestructor(Method).

% ============================================================
% GUESS
% ============================================================

% Perfect case: not possibly virtual, writes a vftable, no uninitialized reads.
guessConstructor1Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method),
    possibleVFTableWrite(_, Method, _, _, _),
    not uninitializedReads(Method).

% Likely case: not possibly virtual, writes a vftable, uninitialized reads allowed.
guessConstructor2Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method),
    possibleVFTableWrite(_, Method, _, _, _).

% Non-virtual, no uninitialized reads (vftable not required).
guessConstructor3Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method),
    not uninitializedReads(Method).

% Unlikely non-virtual case (no vftable required, uninitialized reads allowed).
guessConstructor4Domain(Method) :-
    method(Method),
    possibleConstructor(Method),
    not possiblyVirtual(Method).

% Unified domain for choice generation.
guessConstructorDomain(Method) :- guessConstructor1Domain(Method).
guessConstructorDomain(Method) :- guessConstructor2Domain(Method).
guessConstructorDomain(Method) :- guessConstructor3Domain(Method).
guessConstructorDomain(Method) :- guessConstructor4Domain(Method).

1 { constructor(Method) ; -constructor(Method) } 1 :-
    guessEnabled(constructor),
    guessConstructorDomain(Method).

% Stronger heuristic for higher-priority tiers (1 > 2 > 3 > 4).
#heuristic constructor(Method) :
    guessEnabled(constructor),
    guessConstructor1Domain(Method). [4@0, true]
#heuristic constructor(Method) :
    guessEnabled(constructor),
    guessConstructor2Domain(Method). [3@0, true]
#heuristic constructor(Method) :
    guessEnabled(constructor),
    guessConstructor3Domain(Method). [2@0, true]
#heuristic constructor(Method) :
    guessEnabled(constructor),
    guessConstructor4Domain(Method). [1@0, true]

% ============================================================
% REWARDS
% ============================================================

% Optimization rewards: perfect case gets more than likely case.
guessConstructor1Reward(Method) :- constructor(Method), guessConstructor1Domain(Method).
guessConstructor2OnlyReward(Method) :- constructor(Method), guessConstructor2Domain(Method), not guessConstructor1Domain(Method).
guessConstructor3OnlyReward(Method) :- constructor(Method), guessConstructor3Domain(Method), not guessConstructor1Domain(Method).
guessConstructor4OnlyReward(Method) :- constructor(Method), guessConstructor4Domain(Method), not guessConstructor2Domain(Method), not guessConstructor3Domain(Method).

#maximize { 8@0, ctor1, M : guessConstructor1Reward(M) }.
#maximize { 4@0, ctor2, M : guessConstructor2OnlyReward(M) }.
#maximize { 2@0, ctor3, M : guessConstructor3OnlyReward(M) }.
#maximize { 1@0, ctor4, M : guessConstructor4OnlyReward(M) }.

% ============================================================
% CONSTRAINTS
% ============================================================

constructorDestructorKind(Method, constructor) :-
    constructor(Method).
constructorDestructorKind(Method, realDestructor) :-
    realDestructor(Method).
constructorDestructorKind(Method, deletingDestructor) :-
    deletingDestructor(Method).

% A method cannot have more than one constructor/destructor kind.
% Covers:
%   insanityConstructorAndRealDestructor (insanity.pl:226)
%   insanityConstructorAndDeletingDestructor (insanity.pl:240)
%   reasonNOTConstructor_B (rules.pl:281) — realDestructor → notConstructor
%   reasonNOTConstructor_C (rules.pl:288) — deletingDestructor → notConstructor
%   reasonNOTRealDestructor_B (rules.pl:443) — constructor → notRealDestructor
%   reasonNOTRealDestructor_C (rules.pl:448) — deletingDestructor → notRealDestructor
%   reasonNOTDeletingDestructor_B (rules.pl:632) — constructor → notDeletingDestructor
%   reasonNOTDeletingDestructor_C (rules.pl:637) — realDestructor → notDeletingDestructor
%!trace_rule {"% has multiple constructor/destructor kinds", Method}
:- method(Method), 1 < #count { Kind : constructorDestructorKind(Method, Kind) }.

% insanityTwoRealDestructorsOnClass: a class may not have more than one real destructor.
% Counterpart: insanityTwoRealDestructorsOnClass (insanity.pl:253)
%!trace_rule {"% and % are two real destructors on the same class", D1, D2}
:- realDestructor(D1), realDestructor(D2), D1 < D2, &sameClass(D1, D2).

%!trace {"% is a constructor", M} constructor(M).
%!trace {"% is a real destructor", M} realDestructor(M).
%!trace {"% is a deleting destructor", M} deletingDestructor(M).
%!trace {"% is not a constructor", M} -constructor(M).
%!trace {"% is not a deleting destructor", M} -deletingDestructor(M).

#show constructor/1.
#show realDestructor/1.
#show deletingDestructor/1.
