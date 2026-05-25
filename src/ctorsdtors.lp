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
