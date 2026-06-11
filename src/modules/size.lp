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

% thisPtrConstructorCommon (rules.pl:3534): a heap allocation of known nonzero
% size whose this-pointer is passed to a constructor.
thisPtrConstructorCommon(Function, Constructor, ThisPtr) :-
    constructor(Constructor),
    thisPtrUsage(_, Function, ThisPtr, Constructor),
    thisPtrAllocation(_, Function, ThisPtr, type_Heap, Size),
    Size != 0.

% Class-wide join for the Prolog disjunction
% (factDerivedClass(Class, _, 0); factDerivedClass(_, Class, 0)):
% Constructor's class participates in inheritance at offset 0, on either side.
ctorClassInheritsAtZero(Constructor) :-
    thisPtrConstructorCommon(_, Constructor, _),
    derivedClass(D, _Base, 0),
    &sameClass(Constructor, D).
ctorClassInheritsAtZero(Constructor) :-
    thisPtrConstructorCommon(_, Constructor, _),
    derivedClass(_Derived, B, 0),
    &sameClass(Constructor, B).

% Some member of Constructor's class is contained in another object at offset 0
% (class-wide form of factObjectInObject(_Derived, Class, 0)).
ctorClassIsInnerAtZero(Constructor) :-
    thisPtrConstructorCommon(_, Constructor, _),
    objectInObject(_Outer, W, 0),
    &sameClass(Constructor, W).

% thisPtrAssociatedWithConstructor clause 1 (rules.pl:3571), Debug=inheritance:
% inheritance at offset 0, the constructor installs a vftable, but Function has
% no possible vftable write through ThisPtr at offset 0 — so the allocation is
% for the constructor's own class, not a derived one with an inlined ctor.
%!trace_rule {"allocation in % is constructed by % (inheritance at 0, no caller vftable write)", Function, Constructor}
thisPtrAssociatedWithConstructor(Function, Constructor, ThisPtr) :-
    thisPtrConstructorCommon(Function, Constructor, ThisPtr),
    ctorClassInheritsAtZero(Constructor),
    vfTableWrite(_, Constructor, 0, _VFTable),
    not possibleVFTableWrite(_, Function, ThisPtr, 0, _).

% thisPtrAssociatedWithConstructor clause 2 (rules.pl:3590), Debug=nobaseorderived:
% no base, no derived, and not currently embedded in anything at offset 0, so no
% other class's object can start at the allocation.
%!trace_rule {"allocation in % is constructed by % (no base or derived)", Function, Constructor}
thisPtrAssociatedWithConstructor(Function, Constructor, ThisPtr) :-
    thisPtrConstructorCommon(Function, Constructor, ThisPtr),
    classHasNoBase(WB),
    &sameClass(Constructor, WB),
    classHasNoDerived(WD),
    &sameClass(Constructor, WD),
    not ctorClassIsInnerAtZero(Constructor).

% reasonClassSizeGTE_D (3609) / CSize-2 and reasonClassSizeLTE_C (3703) / CSize-2:
% an allocation site of known size tracked to the constructor bounds the class
% size in both directions (i.e. fixes the exact size).
%!trace_rule {"class of % is exactly % bytes (heap allocation in %)", Constructor, Size, Function}
classSizeGTE(Constructor, Size) :-
    thisPtrAssociatedWithConstructor(Function, Constructor, ThisPtr),
    thisPtrAllocation(_, Function, ThisPtr, type_Heap, Size).

classSizeLTE(Constructor, Size) :-
    thisPtrAssociatedWithConstructor(Function, Constructor, ThisPtr),
    thisPtrAllocation(_, Function, ThisPtr, type_Heap, Size).

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
#show classSizeLTE/2.
#show vftableSizeTotal/1.
#show vfTableSize/2.
