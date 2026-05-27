% ============================================================
% RULES
% ============================================================

% reasonVFTableSizeGTE (1337): confirmed entries require the chosen extent
% to include the full pointer at that offset.
vfTableGTE(VFTable, Offset) :-
    vfTableEntry(VFTable, Offset, _Entry).

% ============================================================
% GUESS
% ============================================================

% Exact-size candidate domain: byte extents that end immediately after a
% discovered possible vftable entry. This replaces Prolog's lower/upper-bound
% fact accumulation with one chosen extent.
candidateVFTableSize(VFTable, Size) :-
    vfTable(VFTable),
    possibleVFTableEntry(VFTable, Offset, _Entry),
    pointerSize(PtrSize),
    Size = Offset + PtrSize.

% Choose one exact extent for each confirmed vftable.
1 { vfTableSize(VFTable, Size) : candidateVFTableSize(VFTable, Size) } 1 :-
    vfTable(VFTable).

% ============================================================
% CONSTRAINTS
% ============================================================

:- vfTableSize(VFTable, Size),
   vfTableGTE(VFTable, Offset),
   pointerSize(PtrSize),
   Offset + PtrSize > Size.

% ============================================================
% REWARDS
% ============================================================

% Prefer larger extents only as a low-priority tie-breaker.
#maximize { Size@-2, vfTableSize, VFTable : vfTableSize(VFTable, Size) }.

% ============================================================
% OUTPUT
% ============================================================

%!show_trace vfTableSize(V, S).
%!trace {"vftable % is % bytes", V, S} vfTableSize(V, S).

#show vfTableSize/2.
