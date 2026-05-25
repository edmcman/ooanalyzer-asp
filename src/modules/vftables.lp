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
% GUESS
% ============================================================

% possibleVFTable: candidate domain for guessing.
% Counterpart: possibleVFTable/1 (guess.pl:175)
possibleVFTable(VFTable) :-
    possibleVFTableEntry(VFTable, _Offset, Entry),
    possibleVFTableWrite(_Insn, Func, _ThisPtr, _Offset2, VFTable),
    method(Func) ; method(Entry).

% guessVFTable: choose vfTable or -vfTable for each candidate.
% Counterpart: guessVFTable (guess.pl:180)
1 { vfTable(VFTable) ; -vfTable(VFTable) } 1 :- possibleVFTable(VFTable).
#heuristic vfTable(VFTable) : possibleVFTable(VFTable). [1@2, true]

% Optimization reward for confirmed vftables (priority @2).
guessVFTableReward(VFTable) :- vfTable(VFTable), possibleVFTable(VFTable).

#maximize { 1@2, vfTable, V : guessVFTableReward(V) }.

% ============================================================
% SANITY
% ============================================================

% insanityConstructorInVFTable: constructors may not appear as vftable entries.
% Counterpart: insanity.pl:49
insanity(insanityConstructorInVFTable, (VFTable,Offset,Constructor)) :-
    vfTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Constructor),
    constructor(Constructor).

#show vfTable/1.
#show -vfTable/1.
#show vfTableWrite/4.
#show vfTableOverwrite/4.
#show vfTableEntry/3.
