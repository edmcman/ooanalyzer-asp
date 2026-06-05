% ============================================================
% RULES
% ============================================================

% reasonVFTable (843): RTTI evidence confirms a vftable.
%!trace_rule {"% is a confirmed vftable because RTTI says so", VFTable}
vfTable(VFTable) :-
    rTTIEnabledAndValid,
    rTTITDA2VFTable(_TDA, VFTable).                                        % rules.pl:843

% reasonVFTableOverwrite (976): destructor direction — arguments reversed from possibleVFTableOverwrite.
%!trace_rule {"% overwrites vftable % with % at offset % because it is a destructor", Method, VFTable2, VFTable1, Offset}
vfTableOverwrite(Method, VFTable2, VFTable1, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    vfTable(VFTable1),
    vfTable(VFTable2),
    certainConstructorOrDestructor(Method),
    not constructor(Method).                                              % rules.pl:976

% reasonVFTableOverwrite (962): constructor direction — VFTable1 overwritten by VFTable2.
%!trace_rule {"% overwrites vftable % with % at offset % because it is a constructor", Method, VFTable1, VFTable2, Offset}
vfTableOverwrite(Method, VFTable1, VFTable2, Offset) :-
    possibleVFTableOverwrite(_Insn1, _Insn2, Method, Offset, VFTable1, VFTable2),
    vfTable(VFTable1),
    vfTable(VFTable2),
    constructor(Method).                                               % rules.pl:962

% reasonVFTableWrite (939): confirmed vftable write.
%!trace_rule {"% writes confirmed vftable % at offset %", Method, VFTable, Offset}
vfTableWrite(Insn, Method, Offset, VFTable) :-
    vfTable(VFTable),
    possibleVFTableWrite(Insn, Method, _ThisPtr, Offset, VFTable).         % rules.pl:939

% reasonVFTableEntry (1233): first entry in a confirmed VFTable is always valid.
%!trace_rule {"vftable % entry at offset 0: % because the first entry is always valid", VFTable, Entry}
vfTableEntry(VFTable, 0, Entry) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, 0, Entry).                              % rules.pl:1233

% reasonVFTableEntry (1239): propagation from known entry — all offsets <= max valid are valid.
%!trace_rule {"vftable % entry at offset %: % because it precedes a later known entry", VFTable, Offset, Entry}
vfTableEntry(VFTable, Offset, Entry) :-
    vfTableEntry(VFTable, ExistingOffset, _),
    possibleVFTableEntry(VFTable, Offset, Entry),
    Offset <= ExistingOffset.                                               % rules.pl:1239

% reasonVFTableEntry (1239): the chosen vftable extent, replacing
% factVFTableSizeGTE in ASP, admits all entries whose full pointer lies
% inside the table.
%!trace_rule {"vftable % entry at offset %: % because it fits within the chosen vftable size", VFTable, Offset, Entry}
vfTableEntry(VFTable, Offset, Entry) :-
    vfTableSize(VFTable, Size),
    pointerSize(PtrSize),
    possibleVFTableEntry(VFTable, Offset, Entry),
    Offset + PtrSize <= Size.                                             % rules.pl:1239

% reasonVFTableEntry (1247): entry confirmed by virtual function call evidence.
%!trace_rule {"vftable % entry at offset %: % because a virtual call references it", VFTable, Offset, Entry}
vfTableEntry(VFTable, Offset, Entry) :-
    virtualFunctionCall(_Insn, _Method, _ObjectOffset, VFTable, Offset),
    possibleVFTableEntry(VFTable, Offset, Entry).                         % rules.pl:1247

% NEW RULE (no Prolog counterpart): a confirmed method at a possible entry
% slot forces the entry. Ties vftable extent to method evidence so the
% solver cannot narrow a vftable to dodge merge constraints.
%!trace_rule {"vftable % entry at offset %: % because % is a confirmed method", VFTable, Offset, Entry, Method}
vfTableEntry(VFTable, Offset, Entry) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Method),
    method(Method).

% reasonNOTVFTableEntry_D: RTTI COL addresses are not valid vftable entries.
% Counterpart: reasonNOTVFTableEntry_D (rules.pl:1303)
%!trace_rule {"vftable % entry at offset %: % is invalid because RTTI COL data is not a function pointer", VFTable, Offset, Entry}
-vfTableEntry(VFTable, Offset, Entry) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, Offset, Entry),
    ComputedAddress = VFTable + Offset,
    rTTICompleteObjectLocator(ComputedAddress, _Address, _TDAddress, _CHDAddress, _O1, _O2).  % rules.pl:1303

% reasonNOTVFTableEntry_B: vftables cannot overlap.
% Counterpart: reasonNOTVFTableEntry_B (rules.pl:1282)
%!trace_rule {"vftable % entry at offset %: % is invalid because vftables cannot overlap", VFTableAddress, Offset, Entry}
-vfTableEntry(VFTableAddress, Offset, Entry) :-
    vfTable(VFTableAddress),
    possibleVFTableEntry(VFTableAddress, Offset, Entry),
    Offset != 0,
    ComputedAddress = VFTableAddress + Offset,
    vfTable(ComputedAddress).                                             % rules.pl:1282

% reasonNOTVFTableEntry_C: once a previous possible entry is not confirmed,
% later possible entries are outside the contiguous vftable.
% Counterpart: reasonNOTVFTableEntry_C (rules.pl:1292)
%!trace_rule {"vftable % entry at offset %: % is invalid because a previous entry was not confirmed", VFTable, Offset, Entry}
-vfTableEntry(VFTable, Offset, Entry) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, Offset, Entry),
    Offset != 0,
    pointerSize(PtrSize),
    ComputedOffset = Offset - PtrSize,
    possibleVFTableEntry(VFTable, ComputedOffset, OtherEntry),
    not vfTableEntry(VFTable, ComputedOffset, OtherEntry).                 % rules.pl:1292

% reasonNOTVFTableEntry_E: constructors cannot be valid vftable entries.
% Counterpart: reasonNOTVFTableEntry_E (rules.pl:1313)
%!trace_rule {"vftable % entry at offset %: % is invalid because constructors cannot be vftable entries", VFTable, Offset, Entry}
-vfTableEntry(VFTable, Offset, Entry) :-
    possibleVFTableEntry(VFTable, Offset, Entry),
    dethunk(Entry, Method),
    constructor(Method).                                                  % rules.pl:1313

% ============================================================
% VFTABLE BELONGS TO CLASS
% ============================================================
% reasonVFTableBelongsToClass (rules.pl:1007 / 1118)
% vftableBelongsToClass(VFTable, Offset, Method): Method's class owns VFTable at Offset
% in its own object (not an embedded sub-object). Method is a class witness; callers
% use sameClass to join to the class.

% VFTable is written at offset 0 by some method (indicates it may be a base-class vftable reused).
vftableBelongsToClassInstalledAtZero(VFTable) :-
    vfTableWrite(_, _, 0, VFTable).                                          % rules.pl:1075 / 1183

% Helper: confirmed write to VFTable by Method that is not part of a ctor/dtor overwrite
% sequence. These are the writes the propagator uses to decide &allWritersInClass/2.
nonOverwritingWrite(Method, Offset, VFTable) :-
    vfTableWrite(_, Method, Offset, VFTable),
    not vfTableOverwrite(Method, VFTable, _, Offset).

% Core candidate: confirmed write to method's own this-pointer, not overwritten.
% possibleVFTableWrite + thisParamFuncParameter guards against inlined sub-constructor writes.
% Class = Method: the installing method is its own class witness.
vftableBelongsToClassCandidate(Method, Offset, VFTable, Method) :-
    vfTableWrite(Insn, Method, Offset, VFTable),
    possibleVFTableWrite(Insn, Method, ThisPtr, Offset, VFTable),
    thisParamFuncParameter(Method, ThisPtr),
    not vfTableOverwrite(Method, VFTable, _, Offset).                        % rules.pl:1007-1031 / 1118-1140

% Ownership sub-case A (Offset != 0): ancestor at Offset has a vftable we need to replace.
% Base reuse check: VFTable must not also be written at offset 0 (which would indicate reuse).
% W is the derivedClassRelationship witness for Class's side; &sameClass(Class, W) bridges.
vftableBelongsToClassOwns(Method, Offset, VFTable, Class) :-
    vftableBelongsToClassCandidate(Method, Offset, VFTable, Class),
    Offset != 0,
    derivedClassRelationship(W, AncestorWitness, Offset),
    &sameClass(Class, W),
    vftableBelongsToClass(_, 0, AncestorWitness),
    not vftableBelongsToClassInstalledAtZero(VFTable).                       % rules.pl:1057-1058 / 1165-1166

% Ownership sub-case B (Offset = 0): ancestor at offset 0 has a vftable we need to replace.
vftableBelongsToClassOwns(Method, 0, VFTable, Class) :-
    vftableBelongsToClassCandidate(Method, 0, VFTable, Class),
    derivedClassRelationship(W, AncestorWitness, 0),
    &sameClass(Class, W),
    vftableBelongsToClass(_, 0, AncestorWitness).                            % rules.pl:1057-1058 / 1165-1166

% Ownership branch 2 (Offset = 0): "starting a new inheritance hierarchy" (rules.pl:1060-1071).
% The Prolog wrote branches 1 and 2 as `(reasonDerivedClassRelationship -> ...) ; (Offset=0,...)`,
% but the "one way / the other way" comments show the intent is a *disjunction* of two
% independent ownership conditions, not an if-then-else. Translating the `->` literally injects
% `not derivedClassRelationship(Class,_,0)` into branch 2, which closes an `a :- not a` odd loop
% (vftableBelongsToClass -> reasonMergeVFTables -> sameClass -> derivedClassRelationship -> not ->
% back) and makes RTTI inputs UNSAT. The OR reading drops that negation. The inner
% `(UsOrBase=Class ; reasonDerivedClassRelationship(Class,UsOrBase,0))` becomes two sub-cases:
% check no-embedding-at-0 on us (2a) or on our offset-0 base (2b).
% branch 2a: UsOrBase = Class
vftableBelongsToClassOwns(Method, 0, VFTable, Class) :-
    vftableBelongsToClassCandidate(Method, 0, VFTable, Class),
    not embeddedObject(Class, _, 0).                                         % rules.pl:1065,1069-1071
% branch 2b: UsOrBase = a base of Class at offset 0
vftableBelongsToClassOwns(Method, 0, VFTable, Class) :-
    vftableBelongsToClassCandidate(Method, 0, VFTable, Class),
    derivedClassRelationship(W, Base, 0),
    &sameClass(Class, W),
    not embeddedObject(Base, _, 0).                                          % rules.pl:1067,1069-1071

% Additional-check 1 (constructor): confirmed constructor with no possible overwrite at Offset.
%!trace_rule {"vftable % at offset % belongs to %'s class because it is a constructor and there is no overwrite", VFTable, Offset, Method}
vftableBelongsToClass(VFTable, Offset, Method) :-
    vftableBelongsToClassOwns(Method, Offset, VFTable, _),
    not possibleVFTableOverwrite(_, _, Method, Offset, VFTable, _),
    constructor(Method).                                                      % rules.pl:1090-1096 / 1198-1204

% Additional-check 2 (destructor): all non-overwriting writers of VFTable are in Class's
% equivalence class. Decided by the propagator via &allWritersInClass/2, which provides
% mergeClasses-grounded reason clauses — avoiding the weak nogoods produced by the former
% NAF-over-negative-theory-atom pattern (not vftableBelongsToClassOtherWriter).
%!trace_rule {"vftable % at offset % belongs to %'s class because no other class writes it", VFTable, Offset, Method}
vftableBelongsToClass(VFTable, Offset, Method) :-
    vftableBelongsToClassOwns(Method, Offset, VFTable, Class),
    &allWritersInClass(VFTable, Class).                                       % rules.pl:1101-1106 / 1209-1214

% Additional-check 3 (hasnobase): class has no known base class.
%!trace_rule {"vftable % at offset % belongs to %'s class because it has no base", VFTable, Offset, Method}
vftableBelongsToClass(VFTable, Offset, Method) :-
    vftableBelongsToClassOwns(Method, Offset, VFTable, Class),
    classHasNoBase(Class).                                                    % rules.pl:1109-1110 / 1217-1218

% ============================================================
% GUESS
% ============================================================

% possibleVFTable: candidate domain for guessing.
% Counterpart: possibleVFTable/1 (guess.pl:175)
possibleVFTable(VFTable) :-
    possibleVFTableEntry(VFTable, _Offset, Entry),
    possibleVFTableWrite(_Insn, Func, _ThisPtr, _Offset2, VFTable),
    1 { method(Func); method(Entry) }.

% guessVFTable: choose vfTable or -vfTable for each candidate.
% Counterpart: guessVFTable (guess.pl:180)
%!trace_rule {"guess whether % is a confirmed vftable or not", VFTable}
1 { vfTable(VFTable) ; -vfTable(VFTable) } 1 :-
    guessEnabled(vftable),
    possibleVFTable(VFTable).
#heuristic vfTable(VFTable) :
    guessEnabled(vftable),
    possibleVFTable(VFTable). [1@2, true]

% ============================================================
% REWARDS
% ============================================================

% Vftable-related reward lives in size.lp as Size@3 (vfTableSize). No
% separate per-vftable or per-entry reward here.


%!trace {"% is a confirmed vftable", V} vfTable(V).
%!trace {"vftable % entry at offset %: %", V, Off, E} vfTableEntry(V, Off, E).
%!trace {"% overwrites vftable % with % at offset %", M, V1, V2, Off} vfTableOverwrite(M, V1, V2, Off).

#show vfTable/1.
#show -vfTable/1.
#show vfTableWrite/4.
#show vfTableOverwrite/4.
#show vfTableEntry/3.
#show vftableBelongsToClass/3.
