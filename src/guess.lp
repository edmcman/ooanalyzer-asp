% ============================================================
% VFTABLE IDENTIFICATION
% ============================================================

% possibleVFTable: candidate domain for guessing.
% Counterpart: possibleVFTable/1 (guess.pl:175)
possibleVFTable(VFTable) :-
    possibleVFTableEntry(VFTable, _Offset, Entry),
    possibleVFTableWrite(_Insn, Func, _ThisPtr, _Offset2, _Expanded, VFTable),
    method(Func) ; method(Entry).

% guessVFTable: choose vfTable or -vfTable for each candidate.
% Counterpart: guessVFTable (guess.pl:180)
1 { vfTable(VFTable) ; -vfTable(VFTable) } 1 :- possibleVFTable(VFTable).
#heuristic vfTable(VFTable) : possibleVFTable(VFTable). [1@2, true]
