% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes as sets of methods) from binary analysis facts.
%
% Input facts (provided in a separate file):
%   poss_vftable_write(Method, ObjOffset, VFTable)
%     -- Method writes VFTable pointer at ObjOffset into the this-pointer
%   poss_vftable_entry(VFTable, EntryOffset, Method)
%     -- Method appears at EntryOffset in VFTable
%   returns_self(Method)          -- Method returns the this pointer (ECX in EAX)
%   no_calls_before(Method)       -- No OO calls precede this method (constructor hint)
%   no_calls_after(Method)        -- No OO calls follow this method (destructor hint)
%   calls_delete(Method)          -- Method calls delete/free on this pointer
%   call_target(Caller, Callee)   -- Caller calls Callee
%   symbol_class(Method, Class)   -- Debug symbol: Method belongs to Class
%   symbol_property(Method, Prop) -- Prop in {constructor, realDestructor, deletingDestructor}

% Declare pure input predicates that may be absent in some examples.
% Without these, Clingo warns "atom does not occur in any rule head."
#defined call_target/2.
#defined calls_delete/1.
#defined returns_self/1.
#defined no_calls_before/1.
#defined no_calls_after/1.
#defined symbol_class/2.
#defined symbol_property/2.
#defined poss_vftable_entry/3.
#defined poss_vftable_write/3.

% ============================================================
% GUESSES
% ============================================================

% Is V a valid virtual function table?
{ vftable(V) } :- poss_vftable_write(_, _, V).

% Guess whether to merge any two methods into the same class.
% Forced merges are required by a constraint below; optional merges
% are chosen by the optimizer.
{ merge(M1, M2) } :- method(M1), method(M2), M1 < M2.

% ============================================================
% RULES: derived facts from confirmed vftables
% ============================================================

% Once a vftable is confirmed, ALL its writes and entries are accepted.
% (This prevents the solver from selectively dropping entries to avoid
% forced merges — real OOAnalyzer uses binary-search backtracking instead.)
vftable_write(M, Off, V) :- poss_vftable_write(M, Off, V), vftable(V).
vftable_entry(V, Off, M) :- poss_vftable_entry(V, Off, M), vftable(V).

% ============================================================
% RULES: method identification
% ============================================================

method(M) :- vftable_entry(_, _, M).
method(M) :- vftable_write(M, _, _).
method(M) :- constructor(M).
method(M) :- real_destructor(M).
method(M) :- deleting_destructor(M).
method(M) :- symbol_class(M, _).
method(M) :- symbol_property(M, _).
% A method called by a known method is also a method
method(Callee) :- call_target(Caller, Callee), method(Caller).

% ============================================================
% RULES: constructor / destructor classification
% ============================================================

dtor_signal(M) :- symbol_property(M, realDestructor).
dtor_signal(M) :- symbol_property(M, deletingDestructor).
dtor_signal(M) :- calls_delete(M).

constructor(M) :- symbol_property(M, constructor).
% Heuristic: returns this + no OO calls before + no destructor signals
constructor(M) :- returns_self(M), no_calls_before(M), not dtor_signal(M).
% Heuristic: installs a primary vftable (at offset 0) and not a destructor
constructor(M) :- vftable_write(M, 0, _), not dtor_signal(M).

real_destructor(M) :- symbol_property(M, realDestructor).
% Heuristic: no OO calls after, not a constructor, doesn't call delete
real_destructor(M) :- no_calls_after(M), not constructor(M), not calls_delete(M).

deleting_destructor(M) :- symbol_property(M, deletingDestructor).
deleting_destructor(M) :- calls_delete(M), not constructor(M).

% ============================================================
% RULES: forced merges (strong evidence — must happen)
% ============================================================

% Multiple constructors writing the SAME vftable at the same offset → same class
% (e.g., overloaded constructors)
forced_merge(M1, M2) :-
    vftable_write(M1, Off, V), vftable_write(M2, Off, V), M1 < M2.

% A method in a vftable belongs to the class whose constructor writes that vftable
forced_merge(M1, M2) :- vftable_write(M1, 0, V), vftable_entry(V, _, M2), M1 < M2.
forced_merge(M1, M2) :- vftable_write(M2, 0, V), vftable_entry(V, _, M1), M1 < M2.

% Debug symbols resolve class membership directly
forced_merge(M1, M2) :- symbol_class(M1, C), symbol_class(M2, C), M1 < M2.

% All forced merges must actually occur
:- forced_merge(M1, M2), not merge(M1, M2).

% ============================================================
% CLASS COMPUTATION: equivalence classes via transitive closure
% ============================================================

same_class(M, M) :- method(M).
same_class(M1, M2) :- merge(M1, M2).
same_class(M2, M1) :- same_class(M1, M2).
same_class(M1, M3) :- same_class(M1, M2), same_class(M2, M3).

% Class representative: minimum-address method in the equivalence class
has_lesser(M) :- same_class(M, M2), M2 < M.
class_rep(M)  :- method(M), not has_lesser(M).
class_of(M, R) :- same_class(M, R), class_rep(R).

% ============================================================
% SANITY CHECKS — hard constraints; any violation kills the model
% ============================================================

% Constructors are not virtual (cannot appear in a vftable)
% PAPER: Sanity-VirtualConstructor
:- constructor(M), vftable_entry(_, _, M).

% A method cannot be both a constructor and a destructor
% PAPER: Sanity-DoubleDuty
:- constructor(M), real_destructor(M).
:- constructor(M), deleting_destructor(M).

% A class has at most one real destructor
% PAPER: Sanity-MultipleRealDestructors
:- real_destructor(D1), real_destructor(D2), D1 < D2,
   class_of(D1, C), class_of(D2, C).

% A vftable cannot be shared by two different classes at the same object offset
% PAPER: Sanity-VFTables
:- vftable_write(M1, Off, V), vftable_write(M2, Off, V), M1 < M2,
   class_of(M1, C1), class_of(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same object offset
% belong to different classes (different primary vftable ↔ different class)
:- vftable_write(M1, Off, V1), vftable_write(M2, Off, V2),
   M1 != M2, V1 != V2, class_of(M1, C), class_of(M2, C).

% Entries in confirmed vftables must be methods
:- vftable_entry(_, _, M), not method(M).

% ============================================================
% OPTIMIZATION
% ============================================================

% Priority 2 (higher): confirm as many vftables as possible.
% Priority 1 (lower): then merge as many methods as possible.
% This mirrors OOAnalyzer's ordering: vftable guesses before merge guesses.
#maximize { 1@2, V : vftable(V) }.
#maximize { 1@1, M1, M2 : merge(M1, M2) }.

% ============================================================
% OUTPUT
% ============================================================

#show class_of/2.
#show class_rep/1.
#show constructor/1.
#show real_destructor/1.
#show deleting_destructor/1.
#show vftable/1.
#show vftable_write/3.
#show vftable_entry/3.
