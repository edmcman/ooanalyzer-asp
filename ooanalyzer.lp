% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes as sets of methods) from binary analysis facts.
%
% Input facts (provided in a separate file):
%   poss_vftable_write(M, Off, V)        -- M writes vftable V at object offset Off
%   poss_vftable_entry(V, Off, E)        -- entry E at offset Off in vftable V (may be thunk)
%   poss_vftable_overwrite(M, Off, V1, V2) -- M overwrites V1 with V2 at Off (ctor sequence)
%   returns_self(M)          -- M returns the this pointer (ECX → EAX)
%   no_calls_before(M)       -- no OO calls precede M (constructor hint)
%   no_calls_after(M)        -- no OO calls follow M (destructor hint)
%   calls_delete(M)          -- M calls delete/free on the this pointer
%   uninitialized_reads(M)   -- M reads members before initializing them (NOT-ctor signal)
%   call_target(Caller, Callee) -- Callee is directly called by Caller
%   call_at_offset(Caller, Callee, Off) -- Callee is called by Caller passing this+Off
%   thunk(Thunk, Target)     -- Thunk is a JMP-only stub; Target is the real function
%   purecall(M)              -- M is a pure-virtual stub (not a real method)
%   symbol_class(M, Class)   -- debug symbol: M belongs to Class
%   symbol_property(M, Prop) -- Prop ∈ {constructor, realDestructor, deletingDestructor}
%   rtti_complete_object_locator(V, TDA) -- COL at V-8 links vftable V to type descriptor TDA
%   rtti_type_descriptor(TDA, Name)      -- TDA has mangled type name Name
%   rtti_inherits_from(DerivedTDA, BaseTDA, Offset) -- non-virtual base at byte Offset

#defined call_target/2.
#defined calls_delete/1.
#defined returns_self/1.
#defined no_calls_before/1.
#defined no_calls_after/1.
#defined uninitialized_reads/1.
#defined symbol_class/2.
#defined symbol_property/2.
#defined poss_vftable_entry/3.
#defined poss_vftable_write/3.
#defined poss_vftable_overwrite/4.
#defined thunk/2.
#defined purecall/1.
#defined call_at_offset/3.
#defined rtti_complete_object_locator/2.
#defined rtti_type_descriptor/2.
#defined rtti_inherits_from/3.

% ============================================================
% GUESSES
% ============================================================

{ vftable(V) } :- poss_vftable_write(_, _, V).
% RTTI definitively confirms vftables — no guess needed for these.
vftable(V) :- rtti_complete_object_locator(V, _).

{ merge(M1, M2) } :- method(M1), method(M2), M1 < M2.

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
{ derived_class(Outer, Inner, Off) } :- ctor_calls_ctor(Outer, Inner, Off).

% Guess: does a class have no base class?
{ class_has_no_base(C) } :- class_rep(C).

% ============================================================
% THUNK RESOLUTION
% ============================================================

% Follow thunk chains to find the actual implementing method.
% Two base cases: a non-thunk vftable entry, and a non-thunk thunk target.
dethunk(E, E) :- poss_vftable_entry(_, _, E), not thunk(E, _).
dethunk(T, T) :- thunk(_, T), not thunk(T, _).
dethunk(T, M) :- thunk(T, X), dethunk(X, M).

% Effective vftable entry: actual method at each confirmed slot after thunk resolution.
effective_entry(V, Off, M) :- poss_vftable_entry(V, Off, E), vftable(V), dethunk(E, M).

% ============================================================
% DERIVED FACTS: confirmed vftable writes and overwrites
% ============================================================

vftable_write(M, Off, V) :- poss_vftable_write(M, Off, V), vftable(V).

% Both vftables must be confirmed for an overwrite to count.
vftable_overwrite(M, Off, V1, V2) :-
    poss_vftable_overwrite(M, Off, V1, V2), vftable(V1), vftable(V2).

% ============================================================
% METHOD IDENTIFICATION
% ============================================================

method(M) :- effective_entry(_, _, M), not purecall(M).
method(M) :- vftable_write(M, _, _).
method(M) :- constructor(M).
method(M) :- real_destructor(M).
method(M) :- deleting_destructor(M).
method(M) :- symbol_class(M, _).
method(M) :- symbol_property(M, _).
method(Callee) :- call_target(Caller, Callee), method(Caller).

% ============================================================
% CONSTRUCTOR / DESTRUCTOR CLASSIFICATION
% ============================================================

% not_constructor: strong evidence M is NOT a constructor.
% Mirrors reasonNOTConstructor_B (real dtor), _C (deleting dtor), _D (virtual = in vftable).
not_constructor(M) :- real_destructor(M).
not_constructor(M) :- deleting_destructor(M).
not_constructor(M) :- effective_entry(_, _, M).  % virtual methods cannot be constructors
not_constructor(M) :- uninitialized_reads(M).
not_constructor(M) :- calls_delete(M).            % direct guard: delete-calling is not ctor

constructor(M) :- symbol_property(M, constructor).
constructor(M) :- returns_self(M), no_calls_before(M), not not_constructor(M).
constructor(M) :- vftable_write(M, 0, _), not not_constructor(M).

real_destructor(M) :- symbol_property(M, realDestructor).
real_destructor(M) :- no_calls_after(M), not constructor(M), not calls_delete(M).

deleting_destructor(M) :- symbol_property(M, deletingDestructor).
deleting_destructor(M) :- calls_delete(M), not constructor(M).

% ============================================================
% INHERITANCE / EMBEDDING DETECTION
% ============================================================

% When a constructor calls another constructor at this+Off, the callee's class is
% embedded in the caller's class at offset Off (reasonDerivedClass_B pattern).
ctor_calls_ctor(Outer, Inner, Off) :-
    constructor(Outer), constructor(Inner), Outer != Inner,
    call_at_offset(Outer, Inner, Off), Off >= 0.

% Hard derivation from vftable overwrite: when a constructor overwrites V1 with V2,
% the method that installs V1 without overwriting is the base constructor,
% and the overwriting method is the derived constructor.
derived_class(Outer, Inner, 0) :-
    vftable_overwrite(Outer, 0, V1, _),
    vftable_write(Inner, 0, V1), not vftable_overwrite(Inner, 0, _, V1),
    Outer != Inner.

% When ctor_calls_ctor holds but derived_class does not, it's an embedded member.
embedded_object(Outer, Inner, Off) :-
    ctor_calls_ctor(Outer, Inner, Off), not derived_class(Outer, Inner, Off).

% Hard derivation from RTTI: inheritance is authoritative when RTTI is present.
% rtti_inherits_from(DerivedTDA, BaseTDA, Offset) with matching vftable writers.
derived_class(Outer, Inner, Off) :-
    rtti_complete_object_locator(V1, TDA1), rtti_complete_object_locator(V2, TDA2),
    rtti_inherits_from(TDA1, TDA2, Off),
    vftable_write(Outer, 0, V1), not vftable_overwrite(Outer, 0, _, V1),
    vftable_write(Inner, 0, V2), not vftable_overwrite(Inner, 0, _, V2).

% ============================================================
% CLASS → VFTABLE MAPPING
% ============================================================

% vftable_class(V, Off, C): vftable V is associated with class C at object offset Off.
% Useful for inheritance reasoning and output. Mirrors reasonVFTableBelongsToClass.
vftable_class(V, Off, C) :- vftable_write(M, Off, V), class_of(M, C).

% ============================================================
% FORCED MERGES (strong evidence — must happen)
% ============================================================

% Multiple methods writing the SAME vftable at the same offset → same class
forced_merge(M1, M2) :-
    vftable_write(M1, Off, V), vftable_write(M2, Off, V), M1 < M2.

% Methods in a vftable belong to the class whose constructor writes it at offset 0
forced_merge(M1, M2) :- vftable_write(M1, 0, V), effective_entry(V, _, M2), M1 < M2.
forced_merge(M1, M2) :- vftable_write(M2, 0, V), effective_entry(V, _, M1), M1 < M2.

% Debug symbols resolve class membership directly
forced_merge(M1, M2) :- symbol_class(M1, C), symbol_class(M2, C), M1 < M2.

% reasonMergeClasses_E: two methods are both the inner (base) of the same derived class
% at the same offset → they must be in the same class.
forced_merge(B1, B2) :-
    derived_class(_, B1, Off), derived_class(_, B2, Off), B1 < B2.

% Deleting destructor calls real destructor → same class.
forced_merge(M1, M2) :-
    deleting_destructor(M1), real_destructor(M2), call_target(M1, M2), M1 < M2.
forced_merge(M1, M2) :-
    deleting_destructor(M2), real_destructor(M1), call_target(M2, M1), M1 < M2.

:- forced_merge(M1, M2), not merge(M1, M2).

% ============================================================
% FORCED NOT-MERGES (different classes — merge must not happen)
% ============================================================

% Outer and inner constructor represent distinct classes by construction.
forced_not_merge(M1, M2) :- ctor_calls_ctor(M1, M2, _), M1 < M2.
forced_not_merge(M1, M2) :- ctor_calls_ctor(M2, M1, _), M1 < M2.

% Base vs. derived: the constructor that installs V without overwriting is the base;
% the constructor that overwrites V is derived. They must be in different classes.
forced_not_merge(M1, M2) :-
    vftable_write(M1, 0, V), not vftable_overwrite(M1, 0, _, V),
    vftable_overwrite(M2, 0, V, _), M1 < M2.
forced_not_merge(M1, M2) :-
    vftable_write(M2, 0, V), not vftable_overwrite(M2, 0, _, V),
    vftable_overwrite(M1, 0, V, _), M1 < M2.

% reasonNOTMergeClasses_F: two classes that are both bases of the same derived at
% different offsets cannot be the same class (multiple inheritance).
forced_not_merge(B1, B2) :-
    derived_class(D, B1, Off1), derived_class(D, B2, Off2),
    Off1 != Off2, B1 < B2.

% RTTI: two vftables with different type descriptors belong to different classes.
forced_not_merge(M1, M2) :-
    rtti_complete_object_locator(V1, TDA1), rtti_complete_object_locator(V2, TDA2),
    TDA1 != TDA2,
    vftable_write(M1, _, V1), vftable_write(M2, _, V2), M1 < M2.

:- forced_not_merge(M1, M2), merge(M1, M2).

% ============================================================
% CLASS COMPUTATION: equivalence classes via transitive closure
% ============================================================

same_class(M, M)  :- method(M).
same_class(M1, M2) :- merge(M1, M2).
same_class(M2, M1) :- same_class(M1, M2).
same_class(M1, M3) :- same_class(M1, M2), same_class(M2, M3).

has_lesser(M)  :- same_class(M, M2), M2 < M.
class_rep(M)   :- method(M), not has_lesser(M).
class_of(M, R) :- same_class(M, R), class_rep(R).

% ============================================================
% CLASS PROPERTIES
% ============================================================

% Hard derivation: RTTI with no inheritance entries means this class has no base.
class_has_no_base(C) :-
    rtti_complete_object_locator(V, TDA), vftable_write(M, 0, V), class_of(M, C),
    not rtti_inherits_from(TDA, _, _).

% Constraint: a class known to be derived cannot also have no base.
:- class_has_no_base(C), derived_class(M, _, _), class_of(M, C).

% class_calls_method: methods called by a class passing the same this-pointer.
% Mirrors factClassCallsMethod (validMethodCallAtOffset at offset 0).
class_calls_method(C, M) :-
    class_of(Caller, C), call_at_offset(Caller, M, 0), method(M).

% reasonMergeClasses_C: two no-base classes where one calls a method of the other
% must be merged (the method belongs to the calling class).
forced_merge(R1, R2) :-
    class_has_no_base(R1), class_has_no_base(R2), R1 != R2, R1 < R2,
    class_calls_method(R1, M), class_of(M, R2).

% ============================================================
% SANITY CHECKS
% ============================================================

% insanityVirtualConstructor: constructors cannot appear in vftables
:- constructor(M), effective_entry(_, _, M).

% insanityDoubleDuty: method cannot be both constructor and destructor
:- constructor(M), real_destructor(M).
:- constructor(M), deleting_destructor(M).

% insanityContradictoryNOTConstructor
:- constructor(M), not_constructor(M).

% insanityMultipleRealDestructors: at most one real destructor per class
:- real_destructor(D1), real_destructor(D2), D1 < D2,
   class_of(D1, C), class_of(D2, C).

% insanityVFTables: a vftable cannot be shared by two classes at the same offset
:- vftable_write(M1, Off, V), vftable_write(M2, Off, V), M1 < M2,
   class_of(M1, C1), class_of(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same offset → different classes
:- vftable_write(M1, Off, V1), vftable_write(M2, Off, V2),
   M1 != M2, V1 != V2, class_of(M1, C), class_of(M2, C).

% Effective entries must resolve to real methods
:- effective_entry(_, _, M), not method(M).

% insanityObjectCycle: circular inheritance/embedding is impossible
:- derived_class(A, B, _), derived_class(B, A, _).

% Derived/embedded pairs must be in distinct classes
:- ctor_calls_ctor(M1, M2, _), same_class(M1, M2).

% ============================================================
% OPTIMIZATION
% ============================================================

% Priority 2: confirm as many vftables as possible
% Priority 1: maximize class merges (minimize class count)
% Priority 0: prefer derived_class at offset 0; prefer more class_has_no_base assignments
#maximize { 1@2, V : vftable(V) }.
#maximize { 1@1, M1, M2 : merge(M1, M2) }.
#maximize { 1@0, Outer, Inner : derived_class(Outer, Inner, 0) }.
#maximize { 1@0, C : class_has_no_base(C) }.

% ============================================================
% OUTPUT
% ============================================================

#show class_of/2.
#show class_rep/1.
#show class_has_no_base/1.
#show constructor/1.
#show not_constructor/1.
#show real_destructor/1.
#show deleting_destructor/1.
#show vftable/1.
#show vftable_write/3.
#show vftable_overwrite/4.
#show vftable_class/3.
#show effective_entry/3.
#show derived_class/3.
#show embedded_object/3.
