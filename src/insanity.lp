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
% insanity/2: all conditions that must be false in every valid model.
% Each rule is labeled with the insanity.pl rule it implements.
% ----------------------------------------------------------------

% insanityConstructorInVFTable: constructors may not appear as vftable entries.
% Counterpart: insanity.pl:49
insanity(insanityConstructorInVFTable, (VFTable,Offset,Constructor)) :-
    vfTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Constructor),
    constructor(Constructor).

constructorDestructorKind(Method, constructor) :-
    constructor(Method).
constructorDestructorKind(Method, realDestructor) :-
    realDestructor(Method).
constructorDestructorKind(Method, deletingDestructor) :-
    deletingDestructor(Method).

% User-approved ASP sanity check: a method has at most one constructor/destructor kind.
% Covers:
%   insanityConstructorAndRealDestructor/1 (insanity.pl:227)
%   insanityConstructorAndDeletingDestructor/1 (insanity.pl:241)
% Also covers real/deleting overlap, which is not a separate named Prolog insanity rule.
insanity(insanityMultipleConstructorDestructorKinds, (Method,Count)) :-
    method(Method),
    Count = #count { Kind : constructorDestructorKind(Method, Kind) },
    Count > 1.

% ----------------------------------------------------------------
% Dispatch: hard constraint (normal) or soft violate (diagnostic).
% ----------------------------------------------------------------
:- not diagnosing, insanity(_, _).
violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).
#show violate/2.
