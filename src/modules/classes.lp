% ============================================================
% RULES
% ============================================================

% reasonClassCallsMethod_C: same-this direct call means the caller's class
% calls the callee method.
% Counterpart: reasonClassCallsMethod_C (rules.pl:2481)
%!trace_rule {"% calls % because of a direct call on the same this-pointer", Method1, Method2}
classCallsMethod(Method1, Method2) :-
    validMethodCallAtOffset(_Insn, Method1, Method2, 0).                  % rules.pl:2481

% reasonClassCallsMethod_B: a class can call methods in its vftable, excluding
% purecall stubs.
% Counterpart: reasonClassCallsMethod_B (rules.pl:2462)
%!trace_rule {"% calls % because it is a vftable entry of %", VFTable, Method2, VFTable}
classCallsMethod(VFTable, Method2) :-
    vfTableEntry(VFTable, _TableOffset, Entry2),
    dethunk(Entry2, Method2),
    not purecall(Entry2),
    not purecall(Method2).                                                % rules.pl:2462

%!trace {"% calls %", V, M} classCallsMethod(V, M).

% classRelatedMethod: undirected version of classCallsMethod.
% Prolog _A rule (rules.pl:2361): every classCallsMethod implies classRelatedMethod.
classRelatedMethod(A, B) :- classCallsMethod(A, B).
classRelatedMethod(A, B) :- classCallsMethod(B, A).

% Class-wide form of "Class contains some object at offset 0": some member of
% C's class is the outer of an objectInObject at 0. Domain restricted to the
% entities reasonClassRelatedMethod_B queries.
classHasInnerAtZero(C) :- thisPtrUsageEntity(C), objectInObject(W, _, 0), &sameClass(C, W).
thisPtrUsageEntity(F) :- thisPtrUsage(_, F, _, _).
thisPtrUsageEntity(M) :- thisPtrUsage(_, _, _, M).

% reasonClassRelatedMethod_B: two distinct methods used with the same this-pointer
% in the same function are related, but direction is not safe.
% Counterpart: reasonClassRelatedMethod_B (rules.pl:2372)
%!trace_rule {"% is related to % because both are called on the same this-pointer in %", Method1, Method2, Function}
classRelatedMethod(Method1, Method2) :-
    thisPtrUsage(_Insn1, Function, ThisPtr, Method1),
    thisPtrUsage(_Insn2, Function, ThisPtr, Method2),
    method(Method1),
    method(Method2),
    Method1 != Method2,
    % Ed thinks this is not needed: https://github.com/cmu-sei/pharos/issues/328
    % not classHasInnerAtZero(Function),
    not classHasInnerAtZero(Method2).                                       % rules.pl:2372

% reasonClassRelatedMethod_C: an outer method calls an inner method on a
% this-pointer that is Offset bytes into the outer this-pointer, and the outer
% class has an object (embedded or base) at that offset.  The inner class at
% that offset is then related to the inner method.  Requires the offset to be
% "precise" (every path to it is inheritance in its leading zero-offset run) so
% we do not relate a method that actually belongs to an embedded member.
% classAtOffset / offsetPrecise are defined in composition.lp.
% find(OuterMethod, OuterClass) becomes the &sameClass(OuterMethod, OC) join;
% both iso_dif checks compare class reps, so they map to not &sameClass.
% Counterpart: reasonClassRelatedMethod_C (rules.pl:2414)
%!trace_rule {"% is related to % because an outer method % calls it on a this-pointer % bytes into an object at that offset", InnerClass, InnerMethod, OuterMethod, Offset}
classRelatedMethod(InnerClass, InnerMethod) :-
    thisPtrUsage(_Insn, OuterMethod, InnerThisPtr, InnerMethod),
    thisPtrOffset(_OuterThisPtr, Offset, InnerThisPtr),
    classAtOffset(OC, InnerClass, Offset),
    &sameClass(OuterMethod, OC),
    not &sameClass(OC, InnerClass),
    not &sameClass(InnerClass, InnerMethod),
    offsetPrecise(OC, Offset).                                              % rules.pl:2414

% knownVirtualMethod: method is known to be virtual.
% Prolog (rules.pl:780): symbolProperty(Method, virtual) or factMethodInVFTable.
% Uses vfTableEntry (confirmed entries) not possibleVFTableEntry (candidates).
knownVirtualMethod(M) :- vfTableEntry(_, _, Entry), dethunk(Entry, M).
knownVirtualMethod(M) :- symbolProperty(M, virtual).

#show classCallsMethod/2.
#show classRelatedMethod/2.
