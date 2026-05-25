% ============================================================
% CONSTRUCTOR / DESTRUCTOR HELPERS
% ============================================================

% certainConstructorOrDestructor: method writes a confirmed vftable or vbtable
% into its own this-pointer.
% Counterpart: certainConstructorOrDestructor/1 (rules.pl:731)
certainConstructorOrDestructor(Method) :-
    vfTableWrite(Insn, Method, Offset, VFTable),
    possibleVFTableWrite(Insn, Method, ThisPtr, Offset, VFTable),
    thisParamFuncParameter(Method, ThisPtr).

certainConstructorOrDestructor(Method) :-
    vbTableWrite(Insn, Method, Offset, VBTable),
    possibleVBTableWrite(Insn, Method, ThisPtr, Offset, VBTable),
    thisParamFuncParameter(Method, ThisPtr).

% ============================================================
% VFTABLE IDENTIFICATION
% ============================================================

% reasonVFTable (843): RTTI evidence confirms a vftable.
vfTable(VFTable) :-
    rTTIEnabled,
    rTTIValid,
    rTTITDA2VFTable(_TDA, VFTable).                                        % rules.pl:843

% reasonVFTableOverwrite (976): destructor direction — arguments reversed from possibleVFTableOverwrite.
vfTableOverwrite(Method, VFTable2, VFTable1, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    vfTable(VFTable1),
    vfTable(VFTable2),
    certainConstructorOrDestructor(Method),
    not constructor(Method).                                              % rules.pl:976

% reasonVFTableOverwrite (962): constructor direction — VFTable1 overwritten by VFTable2.
vfTableOverwrite(Method, VFTable1, VFTable2, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    vfTable(VFTable1),
    vfTable(VFTable2),
    constructor(Method).                                               % rules.pl:962

% reasonVFTableWrite (939): confirmed vftable write.
vfTableWrite(Insn, Method, Offset, VFTable) :-
    vfTable(VFTable),
    possibleVFTableWrite(Insn, Method, _ThisPtr, Offset, VFTable).         % rules.pl:939

% reasonVFTableEntry (1233): first entry in a confirmed VFTable is always valid.
vfTableEntry(VFTable, 0, Entry) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, 0, Entry).                              % rules.pl:1233

% reasonVFTableEntry (1239): propagation from known entry — all offsets <= max valid are valid.
vfTableEntry(VFTable, Offset, Entry) :-
    vfTableEntry(VFTable, ExistingOffset, _),
    possibleVFTableEntry(VFTable, Offset, Entry),
    Offset <= ExistingOffset.                                               % rules.pl:1239

% reasonVFTableEntry (1239): VFTable size lower bound gives the max valid entry offset.
vfTableEntry(VFTable, Offset, Entry) :-
    vfTableSizeGTE(VFTable, Size),
    pointerSize(PtrSize),
    ExistingOffset = Size - PtrSize,
    possibleVFTableEntry(VFTable, Offset, Entry),
    Offset <= ExistingOffset.                                               % rules.pl:1239

% reasonVFTableEntry (1247): entry confirmed by virtual function call evidence.
vfTableEntry(VFTable, Offset, Entry) :-
    virtualFunctionCall(_Insn, _Method, _ObjectOffset, VFTable, Offset),
    possibleVFTableEntry(VFTable, Offset, Entry).                         % rules.pl:1247

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
