% ============================================================
% RULES
% ============================================================

% reasonClassCallsMethod_C: same-this direct call means the caller's class
% calls the callee method, unless they are already known to be the same class.
% Counterpart: reasonClassCallsMethod_C (rules.pl:2481)
classCallsMethod(Method1, Method2) :-
    validMethodCallAtOffset(_Insn, Method1, Method2, 0),
    not sameClass(Method1, Method2).                                      % rules.pl:2481

% reasonClassCallsMethod_B: a class can call methods in its vftable, excluding
% purecall stubs and methods already known to be on the same class.
% Counterpart: reasonClassCallsMethod_B (rules.pl:2462)
classCallsMethod(VFTable, Method2) :-
    vfTableEntry(VFTable, _TableOffset, Entry2),
    dethunk(Entry2, Method2),
    not purecall(Entry2),
    not purecall(Method2),
    not sameClass(VFTable, Method2).                                      % rules.pl:2462

#show classCallsMethod/2.
