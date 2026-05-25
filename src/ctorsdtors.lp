% ============================================================
% CONSTRUCTOR / DESTRUCTOR HELPERS
% ============================================================

% certainConstructorOrDestructor: method writes a confirmed vftable or vbtable
% into its own this-pointer.
% Counterpart: certainConstructorOrDestructor/1 (rules.pl:731)
certainConstructorOrDestructor(Method) :-
    vfTableWrite(Insn, Method, Offset, VFTable),
    possibleVFTableWrite(Insn, Method, ThisPtr, Offset, VFTable),
    thisParamFuncParameter(Method, ThisPtr).

certainConstructorOrDestructor(Method) :-
    vbTableWrite(Insn, Method, Offset, VBTable),
    possibleVBTableWrite(Insn, Method, ThisPtr, Offset, VBTable),
    thisParamFuncParameter(Method, ThisPtr).

% ============================================================
% CONSTRUCTOR / DESTRUCTOR IDENTIFICATION
% ============================================================

% reasonConstructor/1: symbol property evidence proves a constructor.
% Counterpart: reasonConstructor/1 (rules.pl:209)
constructor(Method) :-
    symbolProperty(Method, constructor).                                  % rules.pl:209

% reasonRealDestructor/1: symbol property evidence proves a real destructor.
% Counterpart: reasonRealDestructor/1 (rules.pl:394)
realDestructor(Method) :-
    symbolProperty(Method, realDestructor).                               % rules.pl:394

% reasonDeletingDestructor/1: delete(this) evidence proves a deleting destructor.
% Counterpart: reasonDeletingDestructor/1 (rules.pl:585)
deletingDestructor(Method) :-
    method(Method),
    insnCallsDelete(_Insn, Method, ThisPtr),
    thisParamFuncParameter(Method, ThisPtr).                              % rules.pl:585

% reasonDeletingDestructor/1: symbol property evidence proves a deleting destructor.
% Counterpart: reasonDeletingDestructor/1 (rules.pl:595)
deletingDestructor(Method) :-
    symbolProperty(Method, deletingDestructor).                           % rules.pl:595

% ----------------------------------------------------------------
% CONSTRUCTOR GUESSES
% Counterpart: guessConstructor1/2 (guess.pl:574, 592)
% ----------------------------------------------------------------

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

% Optimization reward.
guessConstructorReward(Method) :- constructor(Method), guessConstructorDomain(Method).

% ============================================================
% SANITY
% ============================================================

constructorDestructorKind(Method, constructor) :-
    constructor(Method).
constructorDestructorKind(Method, realDestructor) :-
    realDestructor(Method).
constructorDestructorKind(Method, deletingDestructor) :-
    deletingDestructor(Method).

insanity(insanityMultipleConstructorDestructorKinds, (Method,Count)) :-
    method(Method),
    Count = #count { Kind : constructorDestructorKind(Method, Kind) },
    Count > 1.

#show constructor/1.
#show realDestructor/1.
#show deletingDestructor/1.
