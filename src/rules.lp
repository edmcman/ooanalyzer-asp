% ============================================================
% CONSTRUCTOR / DESTRUCTOR HELPERS
% ============================================================

% certainConstructorOrDestructor: method writes a confirmed vftable or vbtable
% into its own this-pointer.
% Counterpart: certainConstructorOrDestructor/1 (rules.pl:731)
certainConstructorOrDestructor(Method) :-
    factVFTableWrite(Insn, Method, Offset, VFTable),
    possibleVFTableWrite(Insn, Method, ThisPtr, Offset, VFTable),
    thisParamFuncParameter(Method, ThisPtr).

certainConstructorOrDestructor(Method) :-
    factVBTableWrite(Insn, Method, Offset, VBTable),
    possibleVBTableWrite(Insn, Method, ThisPtr, Offset, VBTable),
    thisParamFuncParameter(Method, ThisPtr).

% ============================================================
% VFTABLE IDENTIFICATION
% ============================================================

% reasonVFTable (843): RTTI evidence confirms a vftable.
factVFTable(VFTable) :-
    rTTIEnabled,
    rTTIValid,
    rTTITDA2VFTable(_TDA, VFTable).                                        % rules.pl:843

% reasonVFTableOverwrite (976): destructor direction — arguments reversed from possibleVFTableOverwrite.
factVFTableOverwrite(Method, VFTable2, VFTable1, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    factVFTable(VFTable1),
    factVFTable(VFTable2),
    certainConstructorOrDestructor(Method),
    -factConstructor(Method).                                              % rules.pl:976

% reasonVFTableOverwrite (962): constructor direction — VFTable1 overwritten by VFTable2.
factVFTableOverwrite(Method, VFTable1, VFTable2, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    factVFTable(VFTable1),
    factVFTable(VFTable2),
    factConstructor(Method).                                               % rules.pl:962

% reasonVFTableWrite (939): confirmed vftable write.
factVFTableWrite(Insn, Method, Offset, VFTable) :-
    factVFTable(VFTable),
    possibleVFTableWrite(Insn, Method, _ThisPtr, Offset, VFTable).         % rules.pl:939

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
