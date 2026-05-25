% ============================================================
% VFTABLE IDENTIFICATION
% ============================================================

% reasonVFTable (843): RTTI evidence confirms a vftable.
factVFTable(VFTable) :-
    rTTIEnabled,
    rTTIValid,
    rTTITDA2VFTable(_TDA, VFTable).                                        % rules.pl:843

% ============================================================
% THUNK RESOLUTION
% ============================================================

% Follow thunk chains to the real implementing method.
dethunk(E, E) :- possibleVFTableEntry(_, _, E), not thunk(E, _).
dethunk(T, T) :- thunk(_, T), not thunk(T, _).
dethunk(M, M) :- possibleMethod(M), not thunk(M, _).
dethunk(T, M) :- thunk(T, X), dethunk(X, M).

% ============================================================
% METHOD IDENTIFICATION
% ============================================================

% reasonMethod_B: constructors are methods.
factMethod(M) :- factConstructor(M).                                       % rules.pl:52

% reasonMethod_C: real destructors are methods.
factMethod(M) :- factRealDestructor(M).                                    % rules.pl:56

% reasonMethod_D: deleting destructors are methods.
factMethod(M) :- factDeletingDestructor(M).                                % rules.pl:60

% reasonMethod_E: symbol class association proves method.
factMethod(M) :- symbolClass(M, _).                                        % rules.pl:64

% reasonMethod_F: any symbol property proves method.
factMethod(M) :- symbolProperty(M, _).                                     % rules.pl:68

% reasonMethod_G: entries in confirmed vftables are methods (factVFTableEntry already dethunks).
factMethod(M) :- factVFTableEntry(_, _, M).                                % rules.pl:73

% reasonMethod_H: method writes a confirmed vftable into its own this-pointer.
% Uses 6-arity possibleVFTableWrite directly to retain ThisPtr for the join.
factMethod(Method) :-
    possibleVFTableWrite(_Insn, Method, ThisPtr, _Offset, _Expanded, VFTable),
    factVFTable(VFTable),
    thisParamFuncParameter(Method, ThisPtr).                               % rules.pl:80
