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

% knownVirtualMethod: method is known to be virtual.
% Prolog (rules.pl:780): symbolProperty(Method, virtual) or factMethodInVFTable.
% Uses vfTableEntry (confirmed entries) not possibleVFTableEntry (candidates).
knownVirtualMethod(M) :- vfTableEntry(_, _, Entry), dethunk(Entry, M).
knownVirtualMethod(M) :- symbolProperty(M, virtual).

#show classCallsMethod/2.
