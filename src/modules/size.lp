% ============================================================
% RULES
% ============================================================

% reasonVFTableSizeGTE (1337): confirmed entries require the chosen extent
% to include the full pointer at that offset.
%!trace_rule {"vftable % must extend past offset % because of a confirmed entry", VFTable, Offset}
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
%!trace_rule {"choose size for vftable %", VFTable}
1 { vfTableSize(VFTable, Size) : candidateVFTableSize(VFTable, Size) } 1 :-
    guessEnabled(vftable_size),
    vfTable(VFTable).

% Domain heuristic: the highest-priority objective already prefers larger
% extents, so try the largest candidate before branch-and-bound has to climb.
#heuristic vfTableSize(VFTable, Size) :
    guessEnabled(vftable_size),
    candidateVFTableSize(VFTable, Size). [Size@3, true]

% ============================================================
% CONSTRAINTS
% ============================================================

% Constraint: chosen vftable extent must accommodate all confirmed entries.
:- vfTableSize(VFTable, Size),
   vfTableGTE(VFTable, Offset),
   pointerSize(PtrSize),
   Offset + PtrSize > Size.

% ============================================================
% REWARDS
% ============================================================

% Prefer larger extents at the highest priority.  Encode the selected size as
% MaxCandidateSize - Gap instead of a raw candidate-size reward so branch-and-
% bound has an explicit per-vftable gap to close.
maxCandidateVFTableSize(VFTable, MaxSize) :-
    vfTable(VFTable),
    MaxSize = #max { Size : candidateVFTableSize(VFTable, Size) }.

vfTableSizeGap(VFTable, Gap) :-
    vfTableSize(VFTable, Size),
    maxCandidateVFTableSize(VFTable, MaxSize),
    Gap = MaxSize - Size.

vftableSizeTotal(Total) :-
    Total = #sum { Size, VFTable : vfTableSize(VFTable, Size) }.

:- min_vftable_size_total > 0,
   vftableSizeTotal(Total),
   Total < min_vftable_size_total.

:- max_vftable_size_total > 0,
   vftableSizeTotal(Total),
   Total > max_vftable_size_total.

#maximize { MaxSize@3, vfTableMaxSize, VFTable : maxCandidateVFTableSize(VFTable, MaxSize) }.
#minimize { Gap@3, vfTableSizeGap, VFTable : vfTableSizeGap(VFTable, Gap) }.

% ============================================================
% OUTPUT
% ============================================================

%!trace {"vftable % is % bytes", V, S} vfTableSize(V, S).

#show vftableSizeTotal/1.
#show vfTableSize/2.
