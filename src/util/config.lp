% Configuration constants for the prototype.
%
% Override on the clingo command line with --const, e.g.:
%   clingo --const max_class_size=512 --const max_offset_depth=6 ooanalyzer.lp ...
%
% Both bounds are intersected when constructing the relevantOffset domain that
% bounds the derivedClassRelationship/3 recursion (composition.lp). Off must
% satisfy depth <= max_offset_depth AND Off <= max_class_size.

% Cap on the number of derivedClass edges that may be summed when building
% relevantOffset. Higher = deeper transitive chains; the domain size scales
% roughly Pᴰ where P is the number of distinct primitive offsets in the input.
#const max_offset_depth = 4.

% Byte ceiling on accumulated offsets. No transitive ancestor sub-object can
% sit beyond this offset within any object. Lower values prune more aggressively
% when the primitive-offset GCD is small.
#const max_class_size = 256.

% Enable the guessLateMergeClasses_G1 constructor bonus. This is faithful to
% the Prolog scoring rule, but can ground many &sameClass checks on large inputs.
#const enable_weak_g1_bonus = 1.

% Diagnostic gates for isolating performance. Defaults preserve normal solving.
#const enable_guess_method = 1.
#const enable_guess_constructor = 1.
#const enable_guess_vftable = 1.
#const enable_guess_vftable_size = 1.
#const enable_guess_merge = 1.
#const enable_guess_derived_class = 1.

% Domain-heuristic experiment gates. Defaults preserve the existing
% input-choice-first behavior. Reward/output heuristics point at atoms used by
% #maximize rules, letting solver runs compare input versus objective-output
% branching without changing the optimization semantics.
#const enable_input_heuristics = 1.
#const enable_reward_heuristics = 0.
#const reward_heuristic_priority = 0.
#const method_heuristic_priority = 0.
#const vftable_base_heuristic_priority = 2.
#const vftable_heuristic_priority = 3.
#const vftable_size_heuristic_priority = 3.

% Merge input phase knobs for domain-heuristic experiments:
%   0 = conservative false phase (current default)
%   1 = optimistic true phase
%   2 = no explicit phase directive
#const weak_merge_input_phase = 0.
#const late_merge_input_phase = 0.

% Experimental only: make weak merges false-first until every possible vftable
% is selected at max size, then true-first. This is useful on TinyXml but is not
% a general default because some programs legitimately reject possible vftables,
% so the completion condition may never hold.
#const weak_merge_after_vftable_complete = 0.

% Optional staged-optimization bounds for mysql-scale performance experiments.
% A value of 0 disables each bound.  The high-priority vftable objective is the
% sum of selected vfTableSize/2 extents, so fixing this total lets later runs
% focus on the lower-priority merge/constructor rewards once a good vftable
% layer is known or proved separately.
#const min_vftable_size_total = 0.
#const max_vftable_size_total = 0.

% Dynamic guess gates: when enabled, each guess family is guarded by a solver
% atom that is initially biased false.  This lets the solver find a conservative
% model before opening expensive guess families for optimization.
#const enable_dynamic_guess_gates = 1.

maxOffsetDepth(max_offset_depth).
maxClassSize(max_class_size).

guessGate(method) :- enable_guess_method != 0.
guessGate(constructor) :- enable_guess_constructor != 0.
guessGate(vftable) :- enable_guess_vftable != 0.
guessGate(vftable_size) :- enable_guess_vftable_size != 0.
guessGate(merge) :- enable_guess_merge != 0.
guessGate(derived_class) :- enable_guess_derived_class != 0.
guessGate(weak_g1_bonus) :- enable_weak_g1_bonus != 0.

% Keep the merge guess family closed for the first conservative model. Other
% gates stay forced open because delaying method/vftable evidence can strand
% optimization before useful merge candidates are available.
dynamicallyGated(merge).

guessEnabled(Gate) :-
    enable_dynamic_guess_gates != 0,
    guessGate(Gate),
    not dynamicallyGated(Gate).

{ guessEnabled(Gate) } :-
    enable_dynamic_guess_gates != 0,
    guessGate(Gate),
    dynamicallyGated(Gate).

guessEnabled(Gate) :-
    enable_dynamic_guess_gates = 0,
    guessGate(Gate).

% Hybrid heuristic only applies to dynamically-gated gates: branch on them
% early (level=4), weakly prefer false (level=1) so phase saving and conflicts
% can flip the polarity once it appears in a learned clause.
#heuristic guessEnabled(Gate) :
    enable_dynamic_guess_gates != 0,
    guessGate(Gate),
    dynamicallyGated(Gate). [4, level]
#heuristic guessEnabled(Gate) :
    enable_dynamic_guess_gates != 0,
    guessGate(Gate),
    dynamicallyGated(Gate). [1, false]

#show guessEnabled/1.
