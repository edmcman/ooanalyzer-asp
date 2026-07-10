% ============================================================
% RULES
% ============================================================

% reasonMethod_B: constructors are methods.
%!trace_rule {"% is a method because it is a known constructor", M}
method(M) :- constructor(M).                                       % rules.pl:52

% reasonMethod_C: real destructors are methods.
%!trace_rule {"% is a method because it is a known real destructor", M}
method(M) :- realDestructor(M).                                    % rules.pl:56

% reasonMethod_D: deleting destructors are methods.
%!trace_rule {"% is a method because it is a known deleting destructor", M}
method(M) :- deletingDestructor(M).                                % rules.pl:60

% reasonMethod_E: symbol class association proves method.
%!trace_rule {"% is a method because a symbol associates it with a class", M}
method(M) :- symbolClass(M, _, _, _).                                        % rules.pl:64

% reasonMethod_F: any symbol property proves method.
%!trace_rule {"% is a method because it has a symbol property", M}
method(M) :- symbolProperty(M, _).                                     % rules.pl:68

% reasonMethod_G: confirmed vftable entries prove their dethunked targets are methods.
%!trace_rule {"% is a method because it is the dethunked target of a confirmed vftable entry", Method}
method(Method) :-
    vfTableEntry(_, _, Entry),
    dethunk(Entry, Method).                                           % rules.pl:73

% reasonMethod_H: method writes a confirmed vftable into its own this-pointer.
% Counterpart: reasonMethod_H (rules.pl:80)
%!trace_rule {"% is a method because it writes a confirmed vftable into its own this-pointer", Method}
method(Method) :-
    possibleVFTableWrite(_Insn, Method, ThisPtr, _Offset, VFTable),
    vfTable(VFTable),
    thisParamFuncParameter(Method, ThisPtr).                               % rules.pl:80

% reasonMethod_J: methods called by a class are methods.
% Counterpart: reasonMethod_J (rules.pl:99)
%!trace_rule {"% is a method because a known class calls it", Method}
method(Method) :-
    classCallsMethod(_Class, Method).                                      % rules.pl:99

% reasonMethod_L: caller is a method and calls callee at offset 0 → callee is a method.
% Counterpart: reasonMethod_L (rules.pl:109)
%!trace_rule {"% is a method because % calls it at this-offset 0", Method, Caller}
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
%!trace_rule {"% could be a method", M}
guessMethodDomain(M) :- possibleMethod(M).
1 { method(M) ; -method(M) } 1 :-
    guessEnabled(method),
    guessMethodDomain(M).
#heuristic method(M) :
    enable_input_heuristics != 0,
    guessEnabled(method),
    guessMethodDomain(M). [1@method_heuristic_priority, true]
#heuristic method(M) :
    all_input_priority > 0,
    guessEnabled(method),
    guessMethodDomain(M). [1@all_input_priority, level]

% Prolog guesses methods after currently available vftables/inheritance, but
% before vftable entries and constructor/destructor classification.
#heuristic method(M) :
    prolog_order_priority > 0,
    guessEnabled(method),
    guessMethodDomain(M). [600@prolog_order_priority, level]
#heuristic method(M) :
    prolog_order_priority > 0,
    guessEnabled(method),
    guessMethodDomain(M). [1@prolog_order_priority, true]

% ============================================================
% REWARDS
% ============================================================

% Weakest reward: prefer more methods over fewer (below all other priorities).
guessMethodReward(M) :- method(M), guessMethodDomain(M).
#maximize { 10@0, method, M : guessMethodReward(M) }.

#heuristic guessMethodReward(M) :
    enable_reward_heuristics != 0,
    guessMethodDomain(M). [10@reward_heuristic_priority, true]

%!trace {"% is a method", M} method(M).

#show method/1.
