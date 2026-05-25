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

% I am not totally sure that we want method guessing to be so broad.
% guessMethodA: choose method or -method for each possibleMethod candidate.
% Counterpart: guessMethodA (guess.pl:382)
guessMethodDomain(M) :- possibleMethod(M).
1 { method(M) ; -method(M) } 1 :- guessMethodDomain(M).
#heuristic method(M) : guessMethodDomain(M). [1@0, true]

#show method/1.
