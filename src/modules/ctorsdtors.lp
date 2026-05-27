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

% reasonNOTDeletingDestructor_G: deleting destructors must be virtual.
% Counterpart: reasonNOTDeletingDestructor_G (rules.pl:687)
%!trace_rule {"% is not a deleting destructor because deleting destructors must be virtual", Method}
-deletingDestructor(Method) :-
    method(Method),
    not possiblyVirtual(Method).

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

% Unified domain for choice generation.
guessConstructorDomain(Method) :- guessConstructor1Domain(Method).
guessConstructorDomain(Method) :- guessConstructor2Domain(Method).

1 { constructor(Method) ; -constructor(Method) } 1 :- guessConstructorDomain(Method).

% Stronger heuristic for the perfect case (no uninitialized reads).
#heuristic constructor(Method) : guessConstructor1Domain(Method). [2@0, true]
#heuristic constructor(Method) : guessConstructor2Domain(Method). [1@0, true]

% ============================================================
% REWARDS
% ============================================================

% Optimization rewards: perfect case gets more than likely case.
guessConstructor1Reward(Method) :- constructor(Method), guessConstructor1Domain(Method).
guessConstructor2OnlyReward(Method) :- constructor(Method), guessConstructor2Domain(Method), not guessConstructor1Domain(Method).

#maximize { 5@0, ctor1, M : guessConstructor1Reward(M) }.
#maximize { 1@0, ctor2, M : guessConstructor2OnlyReward(M) }.

% ============================================================
% CONSTRAINTS
% ============================================================

constructorDestructorKind(Method, constructor) :-
    constructor(Method).
constructorDestructorKind(Method, realDestructor) :-
    realDestructor(Method).
constructorDestructorKind(Method, deletingDestructor) :-
    deletingDestructor(Method).

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
insanity(insanityMultipleConstructorDestructorKinds, (Method,Count)) :-
    method(Method),
    Count = #count { Kind : constructorDestructorKind(Method, Kind) },
    Count > 1.

% insanityTwoRealDestructorsOnClass: a class may not have more than one real destructor.
% Counterpart: insanityTwoRealDestructorsOnClass (insanity.pl:253)
%!trace_rule {"% and % are two real destructors on the same class", D1, D2}
insanity(insanityTwoRealDestructorsOnClass, (D1, D2)) :-
    realDestructor(D1),
    realDestructor(D2),
    D1 < D2,
    sameClass(D1, D2).

%!show_trace constructor(M).
%!show_trace realDestructor(M).
%!show_trace deletingDestructor(M).
%!show_trace -constructor(M).
%!show_trace -deletingDestructor(M).
%!trace {"% is a constructor", M} constructor(M).
%!trace {"% is a real destructor", M} realDestructor(M).
%!trace {"% is a deleting destructor", M} deletingDestructor(M).
%!trace {"% is not a constructor", M} -constructor(M).
%!trace {"% is not a deleting destructor", M} -deletingDestructor(M).

#show constructor/1.
#show realDestructor/1.
#show deletingDestructor/1.
