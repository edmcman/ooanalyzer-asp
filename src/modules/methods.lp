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

% guessMethod_A-G: evidence tiers used by Prolog to propose unresolved methods.
% doNotGuessHelper is procedural; an ASP choice is already fixed when ordinary
% reasoning proves either polarity.
% Counterparts: guessMethodA-G (guess.pl:382-519)
guessMethodA(M) :-
    explicitThisCallConvention(M),
    methodMemberAccess(_Insn, M, Offset, _Size),
    Offset < 100.

guessMethodB(M) :-
    method(Caller),
    thisParamFuncParameter(Caller, ThisPtr1),
    thisPtrOffset(ThisPtr1, _Offset, ThisPtr2),
    thisPtrUsage(_Insn, Caller, ThisPtr2, M).

guessMethodC(M) :-
    explicitThisCallConvention(M),
    methodMemberAccess(_Insn1, M, Offset, _Size1),
    Offset < 100,
    validMethodCallAtOffset(_Insn2, Caller, M, _Size2),
    method(Caller).

guessMethodD(M) :-
    explicitThisCallConvention(M),
    validMethodMemberAccess(_Insn0, M, Offset, _Size0),
    Offset < 100,
    validMethodCallAtOffset(_Insn1, Caller1, M, _Size1),
    validMethodCallAtOffset(_Insn2, Caller2, M, _Size2),
    Caller1 != Caller2,
    validMethodCallAtOffset(_Insn3, Caller3, M, _Size3),
    Caller1 != Caller3.

guessMethodE(M) :-
    explicitThisCallConvention(M),
    validMethodMemberAccess(_Insn0, M, Offset, _Size0),
    Offset < 100,
    thisPtrUsage(_Insn1, Caller, ThisPtr, M),
    thisPtrUsage(_Insn2, Caller, ThisPtr, Method2),
    M != Method2,
    thisPtrUsage(_Insn3, Caller, ThisPtr, Method3),
    M != Method3.

guessMethodF(M) :-
    explicitThisCallConvention(M),
    validMethodMemberAccess(_Insn, M, Offset, _Size),
    Offset < 100,
    1 { possibleConstructor(M); possibleDestructor(M) }.

guessMethodG(M) :-
    explicitThisCallConvention(M),
    thisPtrUsage(_Insn, Caller, _ThisPtr, M),
    method(Caller),
    1 { possibleConstructor(M); possibleDestructor(M) }.

% Keep the prototype's existing broad choice domain for simplified inputs.
% A-G refine decision order only, matching Prolog's procedural guess ladder
% without removing stable models from the ASP encoding.
guessMethodDomain(M) :- possibleMethod(M).

%!trace_rule {"% could be a method", M}
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
% Preserve the Prolog A-to-G source order inside the method-family slot.
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodA(M). [607@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodB(M). [606@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodC(M). [605@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodD(M). [604@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodE(M). [603@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodF(M). [602@prolog_order_priority, level]
#heuristic method(M) : prolog_order_priority > 0, guessEnabled(method), guessMethodG(M). [601@prolog_order_priority, level]
#heuristic method(M) :
    prolog_order_priority > 0,
    guessEnabled(method),
    guessMethodDomain(M). [1@prolog_order_priority, true]

% ============================================================
% REWARDS
% ============================================================

% Weakest reward: prefer more methods over fewer (below all other priorities).
guessMethodReward(M) :- method(M), guessMethodDomain(M).
#maximize { method_reward_weight@0, method, M : guessMethodReward(M) }.

#heuristic guessMethodReward(M) :
    enable_reward_heuristics != 0,
    guessMethodDomain(M). [method_reward_weight@reward_heuristic_priority, true]

%!trace {"% is a method", M} method(M).

#show method/1.
