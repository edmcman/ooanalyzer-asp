% ============================================================
% RULES
% ============================================================

% reasonDerivedClass_B base evidence: the base constructor writes a confirmed
% non-overwritten vftable at offset zero, and it differs from the derived table.
reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor) :-
    vfTable(DerivedVFTable),
    vfTableWrite(_, BaseConstructor, 0, BaseVFTable),
    not vfTableOverwrite(BaseConstructor, BaseVFTable, _, 0),
    DerivedVFTable != BaseVFTable.                                       % rules.pl:1866

% reasonDerivedClass_B base evidence: imported/MFC-style bases may have symbol
% evidence even when their base-class vftable write is not visible.
reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor) :-
    vfTable(DerivedVFTable),
    symbolClass(BaseConstructor, _, _, _).                               % rules.pl:1877

% reasonDerivedClass_D: RTTI says this is a non-virtual base class.
% Counterpart: reasonDerivedClass_D (rules.pl:1968)
%!trace_rule {"% derives from % at offset % because RTTI says so", DerivedClass, BaseClass, Offset}
derivedClass(DerivedClass, BaseClass, Offset) :-
    rTTIEnabledAndValid,
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, Offset, 0xffffffff, 0),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass).                                    % rules.pl:1968

% reasonDerivedClass_E: RTTI says this is a virtual base class.
% Counterpart: reasonDerivedClass_E (rules.pl:1981)
%!trace_rule {"% derives from % because RTTI says it is a virtual base", DerivedClass, BaseClass}
derivedClass(DerivedClass, BaseClass, Offset) :-
    rTTIEnabledAndValid,
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, _M, P, V),
    P != 0xffffffff,
    possibleVBTableWrite(_Insn, Method, _ThisPtr, P, VBTableAddr),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass),
    &sameClass(Method, DerivedClass),
     possibleVBTableEntry(VBTableAddr, V, Entry),
     Offset = P + Entry.                                                  % rules.pl:1981

% reasonDerivedClass_F: VBTable-based virtual inheritance (non-RTTI path).
% Counterpart: reasonDerivedClass_F (rules.pl:1999)
%!trace_rule {"% derives from % at offset % because VBTable evidence", DerivedClass, BaseClass, Offset}
derivedClass(DerivedClass, BaseClass, Offset) :-
    objectInObject(DerivedClass, BaseClass, Offset),
    vbTableEntry(VBTableAddress, TableOffset, OffsetFromVBPtr),
    TableOffset > 0,
    vbTableWrite(_, Method, VBPtrOffset, VBTableAddress),
    &sameClass(Method, DerivedClass),
    Offset = OffsetFromVBPtr + VBPtrOffset.                              % rules.pl:1999

% reasonDerivedClass_B: derived constructor calls base constructor, with
% matching confirmed vftable writes proving inheritance rather than embedding.
%!trace_rule {"% derives from % at offset % because the derived constructor calls the base constructor with matching vftable writes", DerivedConstructor, BaseConstructor, ObjectOffset}
derivedClass(DerivedConstructor, BaseConstructor, ObjectOffset) :-
    not rTTIEnabledAndValid,
    validMethodCallAtOffset(_, DerivedConstructor, BaseConstructor, ObjectOffset),
    ObjectOffset >= 0,
    constructor(DerivedConstructor),
    constructor(BaseConstructor),
    DerivedConstructor != BaseConstructor,
    vfTableWrite(_, DerivedConstructor, ObjectOffset, DerivedVFTable),
    not vfTableOverwrite(DerivedConstructor, DerivedVFTable, _, ObjectOffset),
    reasonDerivedClassBBaseEvidence(DerivedVFTable, BaseConstructor).           % rules.pl:1834

% ============================================================
% derivedClassRelationship — witness-only; no sameClass closure.
%
% Phase 1 (/2 reachability) and Phase 2 (/3 bounded offset) keep their
% two-phase structure and recursion-pruning negations, but the sameClass-
% closure rules are deleted.  Use sites query these predicates with
% &sameClass to join across equivalence classes.
% ============================================================

% --- Phase 1: /2 reachability closure (bounded by methods²) ----------------
derivedClassRelationship(D, B) :- derivedClass(D, B, _).

dCR_step2(D, B) :-
    derivedClass(D, M, _),
    derivedClassRelationship(M, B),
    D != M,
    not &sameClass(D, M),
    M != B,
    not &sameClass(M, B).

derivedClassRelationship(D, B) :- dCR_step2(D, B).

% --- Phase 2: /3 with bounded Off domain -----------------------------------
primitiveOffset(0).
primitiveOffset(Off) :- derivedClass(_, _, Off).

relevantOffset(Off, 1) :- primitiveOffset(Off).
relevantOffset(Off1 + Off2, N + 1) :-
    relevantOffset(Off1, N),
    primitiveOffset(Off2),
    maxOffsetDepth(MaxD),
    N < MaxD,
    maxClassSize(MaxS),
    Off1 + Off2 <= MaxS.
relevantOffset(Off) :- relevantOffset(Off, _).

derivedClassRelationship(D, B, Off) :- derivedClass(D, B, Off).

dCR_step3(D, B, Off) :-
    derivedClass(D, M, Off1),
    derivedClassRelationship(M, B, Off2),
    Off = Off1 + Off2,
    relevantOffset(Off),
    D != M,
    not &sameClass(D, M),
    M != B,
    not &sameClass(M, B).

derivedClassRelationship(D, B, Off) :- dCR_step3(D, B, Off).

% ============================================================
% objectInObject
%
% objectInObject is witness-only (no sameClass closure).  Use sites join
% across equivalence classes via &sameClass.  Its transitive closure lives in
% the propagator as the &classRelationship/&classRelationshipVia theory atoms
% (see the classRelationship section below).
% ============================================================

% objectInObject_B / objectInObject_C
%!trace_rule {"% contains % at offset % because of inheritance", Outer, Inner, Off}
objectInObject(Outer, Inner, Off) :- derivedClass(Outer, Inner, Off).     % rules.pl:1568
%!trace_rule {"% contains % at offset % because of embedding", Outer, Inner, Off}
objectInObject(Outer, Inner, Off) :- embeddedObject(Outer, Inner, Off).   % rules.pl:1577

% reasonObjectInObject_D (rules.pl:1589): the outer constructor calls the inner
% constructor passing this+Offset at a NON-ZERO offset, the two are not the same
% class, and are not already class-related — so inner is an object within outer.
% Witness-only head (records the constructors, not class reps), per convention.
% Offset>0 folds iso_dif(Offset,0) into Offset>=0.  The hasPendingVFTableMerge
% guards are omitted: they only defend Prolog's forward-chaining ordering, which
% ASP does not have (&sameClass always gives final class identity).
%
% Prolog's grand-ancestor guard not(reasonClassRelationship(OuterClass,
% InnerClass)) maps to the &classRelationshipVia theory atom: a containment
% path whose first intermediate class differs from class(InnerCtor).  The Via
% form excludes the direct OuterCtor->InnerCtor edge, so the guard never
% depends on this rule's own head (Prolog is immune to that odd loop because
% its forward-chaining fixpoint checks the relationship *before* asserting the
% new edge); being a theory atom, it also adds no founding recursion.
%!trace_rule {"% contains % at offset % because the outer constructor calls the inner constructor there", OuterCtor, InnerCtor, Offset}
objectInObject(OuterCtor, InnerCtor, Offset) :-
    validMethodCallAtOffset(_CallInsn, OuterCtor, InnerCtor, Offset),
    Offset > 0,
    constructor(OuterCtor),
    constructor(InnerCtor),
    OuterCtor != InnerCtor,
    not &sameClass(OuterCtor, InnerCtor),
    not &classRelationshipVia(OuterCtor, InnerCtor).                      % rules.pl:1589

% &occupiedByOther(Outer, Inner, Offset): some object of a class OTHER than
% Inner already sits at Offset in Outer.  This is the odd-loop-safe form of
% _E's Prolog guard
% not(factObjectInObject(OuterClass, _, Offset)): a literal port would let _E's
% own head (inner = Inner) satisfy the negated objectInObject(Outer, _, Offset)
% and unfound the rule.  Excluding Inner's own class means the head can never
% trip its own guard, while two distinct-class candidates at one offset form a
% benign even loop (the physical "an offset holds one class" exclusivity).
% Slightly weaker than Prolog (which blocks on ANY object at the offset); a
% same-class object already there is harmless redundancy.  The propagator
% performs this existential class-membership check over indexed candidate
% objectInObject edges, avoiding the recursive ordinary helper's large
% grounding SCC on muparser.

% reasonObjectInObject_E (rules.pl:1625): outer ctor calls inner ctor at Offset,
% the two are not the same class, and no object of another class already sits at
% Offset — so inner is an object within outer.  Unlike _D this fires at Offset=0
% too.  Prolog's dynFactNOTMergeClasses(InnerClass,OuterClass) has no ASP
% equivalent — there is no "proven not mergeable" fact distinct from the model's
% class partition — so it maps to the solve-time literal not &sameClass, matching
% _D.  hasPendingVFTableMerge guards omitted (no ASP forward-chaining phase);
% iso_dif(InnerCtor,OuterCtor) -> OuterCtor != InnerCtor.
%!trace_rule {"% contains % at offset % because the outer ctor calls the distinct inner ctor there", OuterCtor, InnerCtor, Offset}
objectInObject(OuterCtor, InnerCtor, Offset) :-
    validMethodCallAtOffset(_CallInsn, OuterCtor, InnerCtor, Offset),
    Offset >= 0,
    constructor(OuterCtor),
    constructor(InnerCtor),
    OuterCtor != InnerCtor,
    not &sameClass(OuterCtor, InnerCtor),
    not &occupiedByOther(OuterCtor, InnerCtor, Offset).                   % rules.pl:1625

% ============================================================
% reasonClassRelationship (rules.pl:2114/2119) — computed by the
% &classRelationship/2 and &classRelationshipVia/2 theory atoms in the Rust
% propagator: reachability over true objectInObject edges with vertices
% quotiented by the &sameClass classes.  &classRelationship(A, B) holds iff a
% >=1-edge containment path leads from class(A) to class(B);
% &classRelationshipVia(A, B) additionally requires the path's first
% intermediate class to differ from class(B) (reasonObjectInObject_D's guard).
%
% This replaces the former recursive ASP closure: its &sameClass joins, pulled
% into a loop through reasonObjectInObject_D/_E's negative guards, exploded the
% solve-time SCC from 1.4k to 1.35M nodes on TinyXml and stopped the solver
% completing any model.
%
% classRelationshipCand/2 is the grounding domain for positive consumers
% (reasonNOTMergeClasses_J, reasonClassSizeLTE_D): a positive transitive
% closure over candidate containment edges built from the same sources as the
% derivedClass/_D/_E rules but with static predicates only (no &sameClass, no
% negation).  Over-approximation is safe: extra instances are just theory
% atoms the propagator refutes.
% ============================================================

% Candidate containment edges: ctor-calls-ctor sources (reasonDerivedClass_B,
% reasonObjectInObject_D/_E; constructor/1 is contained in possibleConstructor/1) ...
oioCandEdge(Outer, Inner) :-
    validMethodCallAtOffset(_Insn, Outer, Inner, Offset),
    Offset >= 0,
    possibleConstructor(Outer),
    possibleConstructor(Inner),
    Outer != Inner.
% ... and RTTI-declared inheritance (reasonDerivedClass_D/_E sources; both
% rTTIInheritsFrom and rTTITDA2Class are static, from initial.lp).
oioCandEdge(DerivedClass, BaseClass) :-
    rTTIInheritsFrom(DerivedTDA, BaseTDA, _Attributes, _M, _P, _V),
    rTTITDA2Class(DerivedTDA, DerivedClass),
    rTTITDA2Class(BaseTDA, BaseClass).

classRelationshipCand(X, Y) :- oioCandEdge(X, Y).
classRelationshipCand(X, Y) :-
    classRelationshipCand(X, M),
    oioCandEdge(M, Y).

% ============================================================
% classAtOffset — the class that sits at a byte offset within an outer class.
%
% Faithful port of reasonClassAtOffset/3 (rules.pl:2495-2539): transitive
% closure over objectInObject (embedding OR inheritance) edges with accumulated
% offset.  Structured exactly like derivedClassRelationship/3 above — linear
% recursion (one objectInObject witness edge chained on the *same* middle
% witness to the recursive closure), head bounded by relevantOffset, cycles
% pruned with not &sameClass.  No relevantOffset change is needed: every
% objectInObject offset is grounded by a base derivedClass edge, so the
% existing primitiveOffset(Off) :- derivedClass(_,_,Off) already covers them.
% ============================================================
%!trace_rule {"% has % at offset % (direct composition/inheritance)", Outer, Inner, Off}
classAtOffset(Outer, Inner, Off) :- objectInObject(Outer, Inner, Off).

%!trace_rule {"% has % at offset % (transitive through %)", Outer, Inner, Off, M}
cAO_step(Outer, Inner, Off) :-
    objectInObject(Outer, M, Off1),
    classAtOffset(M, Inner, Off2),
    Off = Off1 + Off2,
    relevantOffset(Off),
    Outer != M, not &sameClass(Outer, M),
    M != Inner, not &sameClass(M, Inner).

classAtOffset(Outer, Inner, Off) :- cAO_step(Outer, Inner, Off).

% ------------------------------------------------------------
% isOffsetPrecise (rules.pl:2551) as a property of (Outer, Off).
%
% reasonClassRelatedMethod_C guards on
%   forall(reasonClassAtOffset(Outer, Off, _AnyInner, Seq), isOffsetPrecise(Seq))
% i.e. EVERY path from Outer to that offset must have its maximal leading
% zero-offset run consist entirely of derivedClass (inheritance) hops — no
% embeddedObject hop may appear before the first non-zero hop.  We compute the
% negation constructively: a path is imprecise iff, walking zero-offset hops
% out of Outer, one of them is an embedding.  A leading embedded zero-hop taints
% any continuation reaching the total Off; a leading derived zero-hop is clean
% and the taint must come from deeper (same Off, since +0).  offsetPrecise then
% negates existence of any such path.  offsetImprecise is positive-recursive and
% stratified below the negation, mirroring the not classHasInnerAtZero pattern.
offsetImprecise(Outer, Off) :- embeddedObject(Outer, M, 0), classAtOffset(M, _, Off).
offsetImprecise(Outer, 0)   :- embeddedObject(Outer, _, 0).
offsetImprecise(Outer, Off) :- derivedClass(Outer, M, 0), offsetImprecise(M, Off).

offsetPrecise(Outer, Off) :- classAtOffset(Outer, _, Off), not offsetImprecise(Outer, Off).

% reasonClassHasNoBase (2136): RTTI says this class has no base class.
%!trace_rule {"% has no base class because RTTI says so", Class}
classHasNoBase(Class) :-
    rTTIEnabledAndValid,
    rTTINoBase(TDA),
    rTTITDA2Class(TDA, Class).                                             % rules.pl:2136

% reasonClassHasNoDerived (2152): RTTI says no class derives from this one.
%!trace_rule {"% has no derived class because RTTI says so", Class}
classHasNoDerived(Class) :-
    rTTIEnabledAndValid,
    rTTITDA2Class(TDA, Class),
    not rTTIAncestorOf(_, TDA).                                            % rules.pl:2152

% ============================================================
% GUESS
% ============================================================

% guessDerivedClass / reasonDerivedClass_C: every OIO is classified as embedded or derived
% (at least one). When derivedClass has no support the choice is deterministic
% (reasonEmbeddedObject_A). The derived branch encodes reasonDerivedClass_C:
% objectInObject + NOT embeddedObject → derivedClass.
%!trace_rule {"% is either embedded in or derived from % at offset %", Outer, Inner, Off}
1 { embeddedObject(Outer, Inner, Off) ; derivedClass(Outer, Inner, Off) } :-
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off).          % guess.pl:317 / rules.pl:1740 / rules.pl:1960

% Both heads are genuine inputs: the choice is lower-bounded rather than
% exactly-one, so prioritizing just one head would leave the other available as
% an unprioritized decision.
#heuristic embeddedObject(Outer, Inner, Off) :
    all_input_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [1@all_input_priority, level]
#heuristic derivedClass(Outer, Inner, Off) :
    all_input_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [1@all_input_priority, level]

% Prolog tries inheritance before embedding and places this family before
% method guessing.  Target the two choice heads explicitly because the ASP
% choice is lower-bounded rather than exactly-one.
#heuristic derivedClass(Outer, Inner, Off) :
    prolog_order_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [700@prolog_order_priority, level]
#heuristic derivedClass(Outer, Inner, Off) :
    prolog_order_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [1@prolog_order_priority, true]
#heuristic embeddedObject(Outer, Inner, Off) :
    prolog_order_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [700@prolog_order_priority, level]
#heuristic embeddedObject(Outer, Inner, Off) :
    prolog_order_priority > 0,
    guessEnabled(derived_class),
    objectInObject(Outer, Inner, Off). [1@prolog_order_priority, false]

% ============================================================
% REWARDS
% ============================================================

% guessDerivedClass: prefer inheritance over embedding when both are possible.
guessDerivedClassReward(Outer, Inner, Off) :-
    derivedClass(Outer, Inner, Off),
    objectInObject(Outer, Inner, Off).

#maximize { 10@0, guessDerivedClass, Outer, Inner, Off : guessDerivedClassReward(Outer, Inner, Off) }.

#heuristic guessDerivedClassReward(Outer, Inner, Off) :
    enable_reward_heuristics != 0,
    objectInObject(Outer, Inner, Off). [10@reward_heuristic_priority, true]

% NEW RULE: penalize embedding a class that is already known to be a base.
embedsKnownBasePenalty(Outer, Inner, Off) :-
    embeddedObject(Outer, Inner, Off),
    derivedClass(_, Inner, _).

#minimize { 20@0, embedsKnownBase, Outer, Inner, Off : embedsKnownBasePenalty(Outer, Inner, Off) }.

% NEW RULE: reward when a class with a purecall vftable entry is inherited from.
purecallNotMostDerivedReward(Derived, Base, Off) :-
    derivedClass(Derived, Base, Off),
    &sameClass(Base, VFTable),
    vfTableEntry(VFTable, _, Entry),
    purecall(Entry).

#maximize { 40@0, purecallNotMostDerived, Derived, Base, Off : purecallNotMostDerivedReward(Derived, Base, Off) }.

% ============================================================
% CONSTRAINTS
% ============================================================

% reasonNOTEmbeddedObject / reasonNOTDerivedClass / reasonDerivedClass_C / insanityEmbeddedAndNot:
% derivedClass and embeddedObject are mutually exclusive.
:- embeddedObject(Outer, Inner, Off), derivedClass(Outer, Inner, Off).  % rules.pl:1791,1960,2025 / insanity.pl:308

% insanityNoBaseConsistency: a class with no base cannot also be a derived class.
%!trace_rule {"% has no base class but is also a derived class", Class}
:- classHasNoBase(Class),
    derivedClass(W, _, _),
    &sameClass(Class, W).                                                   % insanity.pl:8

% ============================================================
% OUTPUT
% ============================================================

%!trace {"% derives from % at offset %", Outer, Inner, Off} derivedClass(Outer, Inner, Off).
%!trace {"% embeds % at offset %", Outer, Inner, Off} embeddedObject(Outer, Inner, Off).
%!trace {"% contains % at offset %", Outer, Inner, Off} objectInObject(Outer, Inner, Off).
%!trace {"% has no base class", V} classHasNoBase(V).
%!trace {"% has no derived class", V} classHasNoDerived(V).

#show derivedClass/3.
#show objectInObject/3.
