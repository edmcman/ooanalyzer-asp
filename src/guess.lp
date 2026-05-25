% ============================================================
% VFTABLE IDENTIFICATION
% ============================================================

% possibleVFTable: candidate domain for guessing.
% Counterpart: possibleVFTable/1 (guess.pl:175)
possibleVFTable(VFTable) :-
    possibleVFTableEntry(VFTable, _Offset, Entry),
    possibleVFTableWrite(_Insn, Func, _ThisPtr, _Offset2, _Expanded, VFTable),
    ( factMethod(Func) ; factMethod(Entry) ).

% guessVFTable: choose factVFTable or -factVFTable for each candidate.
% Counterpart: guessVFTable (guess.pl:180)
1 { factVFTable(VFTable) ; -factVFTable(VFTable) } 1 :- possibleVFTable(VFTable).
#heuristic factVFTable(VFTable) : possibleVFTable(VFTable). [1@2, true]
