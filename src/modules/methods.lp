% ============================================================
% RULES
% ============================================================

% reasonMethod_B: constructors are methods.
method(M) :- constructor(M).                                       % rules.pl:52

% reasonMethod_C: real destructors are methods.
method(M) :- realDestructor(M).                                    % rules.pl:56

% reasonMethod_D: deleting destructors are methods.
method(M) :- deletingDestructor(M).                                % rules.pl:60

% reasonMethod_E: symbol class association proves method.
method(M) :- symbolClass(M, _, _, _).                                        % rules.pl:64

% reasonMethod_F: any symbol property proves method.
method(M) :- symbolProperty(M, _).                                     % rules.pl:68

% reasonMethod_G: entries in confirmed vftables are methods (vfTableEntry already dethunks).
method(M) :- vfTableEntry(_, _, M).                                % rules.pl:73

% reasonMethod_H: method writes a confirmed vftable into its own this-pointer.
% Counterpart: reasonMethod_H (rules.pl:80)
method(Method) :-
    possibleVFTableWrite(_Insn, Method, ThisPtr, _Offset, VFTable),
    vfTable(VFTable),
    thisParamFuncParameter(Method, ThisPtr).                               % rules.pl:80

% reasonMethod_J: methods called by a class are methods.
% Counterpart: reasonMethod_J (rules.pl:99)
method(Method) :-
    classCallsMethod(_Class, Method).                                      % rules.pl:99

% reasonMethod_L: caller is a method and calls callee at offset 0 → callee is a method.
% Counterpart: reasonMethod_L (rules.pl:109)
method(Method) :-
    method(Caller),
    methodCallAtOffset(_, Caller, Method, 0),  % Intentionally NOT validMethodCallAtOffset
    thisParamFuncParameter(Method, _).

% I am not totally sure that we want method guessing to be so broad.

% ============================================================
% GUESS
% ============================================================

% guessMethodA: choose method or -method for each possibleMethod candidate.
% Counterpart: guessMethodA (guess.pl:382)
guessMethodDomain(M) :- possibleMethod(M).
1 { method(M) ; -method(M) } 1 :- guessMethodDomain(M).
#heuristic method(M) : guessMethodDomain(M). [1@0, true]

% ============================================================
% REWARDS
% ============================================================

% Weakest reward: prefer more methods over fewer (below all other priorities).
guessMethodReward(M) :- method(M), guessMethodDomain(M).
#maximize { 1@-1, method, M : guessMethodReward(M) }.

%!show_trace method(M).
%!trace {"% is a method", M} method(M).

#show method/1.
