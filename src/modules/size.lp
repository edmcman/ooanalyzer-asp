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

% reasonClassSizeGTE_E (3624) / CSize-3:
% A confirmed member access at MemberOffset of MemberSize bytes forces the
% accessing method's class to be at least MemberOffset + MemberSize bytes. The
% method is its own class witness (cf. GTE_G), so no &sameClass.
%!trace_rule {"class of method % is >= % bytes (member access at offset % size %)", Method, Offset + Size, Offset, Size}
classSizeGTE(Method, Offset + Size) :-
    validMethodMemberAccess(_Insn, Method, Offset, Size).

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

% reasonClassSizeLTE_B (3693) / CSize-0:
% Every constructor's class gets the universal upper bound (0x0fffffff), so
% every reportable class has a defined maximum size. Constructor-gated in the
% Prolog (factConstructor), not all classes; the witness is the constructor
% itself, so no &sameClass.
% ejs: Seems weird but Prolog actually checks for a constructor.
%
% COMMENTED OUT: inert in this port. 0x0fffffff is effectively infinity, and the
% only classSizeLTE consumer here is insanityClassSizeInvalid (L < GTE), where
% this bound can never be the violated one. Its sole purpose in the Prolog is to
% give reasonMaximumPossibleClassSize (min over LTEs) a value for every reportable
% class — and that predicate isn't ported yet and has no other consumers. Keeping
% it only added `...,268435455` noise to #show classSizeLTE. Re-enable when
% reasonMaximumPossibleClassSize is ported, since it becomes load-bearing then.
%!trace_rule {"class of constructor % is <= 0x0fffffff bytes (universal bound)", Constructor}
%classSizeLTE(Constructor, 268435455) :- constructor(Constructor).   % 0x0fffffff

% reasonClassSizeLTE_D (3716) / CSize-1:
% A base class is no larger than any of its derived classes, so a derived
% class's upper bound propagates up to its base. classRelationship(D, B) carries
% derived witness D and base witness B; the size-bearing witness WD need not be
% D itself, so join them across the derived class with &sameClass. The head
% records B as the base class's witness.
%!trace_rule {"base class of % is <= % bytes (derived class of % is)", B, Size, D}
classSizeLTE(B, Size) :-
    classRelationship(D, B),
    classSizeLTE(WD, Size),
    &sameClass(D, WD).

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

% insanityClassSizeInvalid (insanity.pl:84): a class's lower size bound may
% not exceed its upper bound. GTE and LTE witnesses may be different members
% of the class, so join them with &sameClass.
%!trace_rule {"class of % has size >= % but class of % has size <= %", W1, GTESize, W2, LTESize}
:- classSizeGTE(W1, GTESize),
   classSizeLTE(W2, LTESize),
   &sameClass(W1, W2),
   LTESize < GTESize.

% insanityMemberPastEndOfObject (insanity.pl:177): a certain member may not
% extend past its class's upper size bound. The member witness (accessing
% method) and the LTE witness may be different members, so join with &sameClass.
%!trace_rule {"member at offset % size % on class of % exceeds upper bound % (class of %)", Offset, Size, Method, ObjectSize, W}
:- certainMemberOnClass(Method, Offset, Size),
   classSizeLTE(W, ObjectSize),
   &sameClass(Method, W),
   Offset + Size > ObjectSize.

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
% A candidate size is dominated if a strictly larger one exists for the same vftable.
notMaxCandidateVFTableSize(VFTable, Size) :-
    candidateVFTableSize(VFTable, Size),
    candidateVFTableSize(VFTable, Larger),
    Larger > Size.

% The maximum is the undominated candidate — avoids #max{} over a choice-dependent set,
% which would produce #inf during grounding when vfTable hasn't been decided yet.
maxCandidateVFTableSize(VFTable, Size) :-
    candidateVFTableSize(VFTable, Size),
    not notMaxCandidateVFTableSize(VFTable, Size).

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
