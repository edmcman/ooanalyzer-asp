% ============================================================
% CLASS SIZE RULES
% ============================================================

% reasonClassSizeGTE_C — REMOVED. Subsumed by _F now that _B (every class >= 0)
% is present: for any transitively-related inner, _F yields Offset + innerSize,
% which dominates _C's offset-less innerSize. _F's per-edge recursion needs every
% intermediate class to carry a size, which _B guarantees.

% reasonClassSizeGTE_B (3505) / CSize-0:
% Every proven method or vftable belongs to a class, and all classes have
% non-negative size. The element is its own class witness, so no &sameClass.
% mergeEntity/1 (merges.lp) is already the proven method-or-vftable union.
%!trace_rule {"class of % is >= 0 bytes", Element}
classSizeGTE(Element, 0) :- mergeEntity(Element).

% reasonClassSizeGTE_F (3637) / CSize-4:
% An embedded or inherited inner object at Offset forces the enclosing class to
% be large enough to contain it: at least Offset + the inner class's min size.
% The inner witness from objectInObject and the witness carrying the size need
% not be the same member, so join them across the class with &sameClass.
%!trace_rule {"class of % is >= % bytes (contains class of % at offset %)", Class, Off + InnerSize, InnerClass, Off}
classSizeGTE(Class, Off + InnerSize) :-
    objectInObject(Class, InnerClass, Off),
    classSizeGTE(Wi, InnerSize),
    &sameClass(InnerClass, Wi),
    Off + InnerSize <= max_class_size.

% reasonClassSizeGTE_G (3653) / CSize-5:
% A vftable pointer installed at ObjectOffset requires the object to be at
% least ObjectOffset + PtrSize bytes.
%!trace_rule {"class of method % is >= % bytes (vftable write at offset %)", Method, Offset + PtrSize, Offset}
classSizeGTE(Method, Offset + PtrSize) :-
    vfTableWrite(_, Method, Offset, _VFTable),
    pointerSize(PtrSize).

% ============================================================
% VFTABLE SIZE RULES
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

#show classSizeGTE/2.
#show vftableSizeTotal/1.
#show vfTableSize/2.
