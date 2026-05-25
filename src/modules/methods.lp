% ============================================================
% METHOD IDENTIFICATION
% ============================================================

% reasonMethod_B: constructors are methods.
method(M) :- constructor(M).                                       % rules.pl:52

% reasonMethod_C: real destructors are methods.
method(M) :- realDestructor(M).                                    % rules.pl:56

% reasonMethod_D: deleting destructors are methods.
method(M) :- deletingDestructor(M).                                % rules.pl:60

% reasonMethod_E: symbol class association proves method.
method(M) :- symbolClass(M, _).                                        % rules.pl:64

% reasonMethod_F: any symbol property proves method.
method(M) :- symbolProperty(M, _).                                     % rules.pl:68

% reasonMethod_G: entries in confirmed vftables are methods (vfTableEntry already dethunks).
method(M) :- vfTableEntry(_, _, M).                                % rules.pl:73

% reasonMethod_H: method writes a confirmed vftable into its own this-pointer.
% Uses 6-arity possibleVFTableWrite directly to retain ThisPtr for the join.
method(Method) :-
    possibleVFTableWrite(_Insn, Method, ThisPtr, _Offset, _Expanded, VFTable),
    vfTable(VFTable),
    thisParamFuncParameter(Method, ThisPtr).                               % rules.pl:80

#show method/1.
