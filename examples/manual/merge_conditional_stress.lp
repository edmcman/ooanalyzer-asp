% merge_conditional_stress.lp -- mixed static/conditional merge stress test.
%
% This is the canonical TinyXml-like merge stress toy.  It keeps the rewarding
% hub -> leaf merge shape, but splits leaf-leaf mutexes into:
%
%   1. static facts
%   2. ordinary conditional gates
%   3. theory-shaped conditions through &sameClass witness pairs
%
% The default mixed mode has only a minority of fact-level static mutexes.  With
% conditional gates forced on, every leaf pair in a group is still mutually
% exclusive, so the expected optimum is one strong merge per group:
%
%   default 8x16 optimum: -80
%
% Useful runs:
%
%   # Default mixed mode: about 20% static mutexes, remaining mutexes conditional.
%   uv run python ooanalyzer.py examples/manual/merge_conditional_stress.lp \
%       -n -1 --heuristic=domain \
%       --opt-strategy=usc,oll,disjoint,succinct,stratify \
%       --restart-on-model --stats --benchmark --quiet=2
%
%   # Mostly static mode, approximating the old all-static stress toy.
%   uv run python ooanalyzer.py examples/manual/merge_conditional_stress.lp \
%       --const static_mutex_mod=1 --const conditional_gate_default=0 \
%       -n -1 --heuristic=domain \
%       --opt-strategy=usc,oll,disjoint,succinct,stratify \
%       --restart-on-model --stats --benchmark --quiet=2
%
%   # Conditional mutexes disabled: only static mutex facts remain, so each
%   # group can select more than one hub-leaf merge.
%   uv run python ooanalyzer.py examples/manual/merge_conditional_stress.lp \
%       --const conditional_gate_default=0 \
%       -n -1 --heuristic=domain \
%       --opt-strategy=usc,oll,disjoint,succinct,stratify \
%       --restart-on-model --stats --benchmark --quiet=2
%
% Tunables:
%
%   stress_groups              number of hub groups
%   stress_leaves              leaves per hub
%   static_mutex_mod           pair is static when hash % static_mutex_mod == 0
%   conditional_mutex_mod      non-static pair is gate-conditional when
%                              hash % conditional_mutex_mod == 0; the rest are
%                              theory-shaped conditional pairs
%   conditional_gate_default   0 = disabled, 1 = forced on, 2 = solver-choice
%   stress_witnesses_per_group number of conditional buckets per group

fileInfo("dummy", "dummy", "MSVC_32", 4).

#const stress_groups = 8.
#const stress_leaves = 16.
#const static_mutex_mod = 5.
#const conditional_mutex_mod = 2.
#const conditional_gate_default = 1.
#const stress_witnesses_per_group = 4.

stressGroup(1..stress_groups).
stressLeaf(1..stress_leaves).
stressBucket(1..stress_witnesses_per_group).

stressHub(G, 1100000 + G * 1000) :-
    stressGroup(G).
stressLeafId(G, L, 1100000 + G * 1000 + L) :-
    stressGroup(G),
    stressLeaf(L).

method(Hub) :- stressHub(_, Hub).
method(Leaf) :- stressLeafId(_, _, Leaf).
constructor(Hub) :- stressHub(_, Hub).

strongMergeCandidate(Hub, Leaf) :-
    stressHub(G, Hub),
    stressLeafId(G, _, Leaf).

stressPair(G, L1, L2, Leaf1, Leaf2) :-
    stressLeafId(G, L1, Leaf1),
    stressLeafId(G, L2, Leaf2),
    L1 < L2.

stressPairHash(G, L1, L2, Hash) :-
    stressPair(G, L1, L2, _, _),
    Hash = G * 17 + L1 * 31 + L2 * 7.

stressPairBucket(G, L1, L2, B) :-
    stressPairHash(G, L1, L2, Hash),
    B = 1 + (Hash \ stress_witnesses_per_group).

% Fact-level mutexes.  With the default static_mutex_mod=5, this is roughly 20%
% of leaf-leaf pairs.
staticMutexPair(G, L1, L2, Leaf1, Leaf2) :-
    stressPair(G, L1, L2, Leaf1, Leaf2),
    stressPairHash(G, L1, L2, Hash),
    static_mutex_mod > 0,
    0 = Hash \ static_mutex_mod.

-mergeClasses(Leaf1, Leaf2) :-
    staticMutexPair(_, _, _, Leaf1, Leaf2).

% Ordinary conditional mutexes.  These are forced in the default mode using a
% constraint rather than facts, so they are not fact-level static.
conditionalMutexPair(G, L1, L2, Leaf1, Leaf2, B) :-
    stressPair(G, L1, L2, Leaf1, Leaf2),
    stressPairBucket(G, L1, L2, B),
    stressPairHash(G, L1, L2, Hash),
    not staticMutexPair(G, L1, L2, Leaf1, Leaf2),
    conditional_mutex_mod > 0,
    0 = Hash \ conditional_mutex_mod.

conditionalMutexBucket(G, B) :-
    conditionalMutexPair(G, _, _, _, _, B).

{ conditionalMutexEnabled(G, B) } :-
    conditional_gate_default != 0,
    conditionalMutexBucket(G, B).

:- conditional_gate_default = 1,
   conditionalMutexBucket(G, B),
   not conditionalMutexEnabled(G, B).

-mergeClasses(Leaf1, Leaf2) :-
    conditionalMutexPair(G, _, _, Leaf1, Leaf2, B),
    conditionalMutexEnabled(G, B).

% Theory-shaped conditional mutexes.  The witness merge is forced through the
% same gate style as above; the actual leaf mutex sees only &sameClass.
theoryMutexPair(G, L1, L2, Leaf1, Leaf2, B) :-
    stressPair(G, L1, L2, Leaf1, Leaf2),
    stressPairBucket(G, L1, L2, B),
    not staticMutexPair(G, L1, L2, Leaf1, Leaf2),
    not conditionalMutexPair(G, L1, L2, Leaf1, Leaf2, B).

theoryMutexBucket(G, B) :-
    theoryMutexPair(G, _, _, _, _, B).

stressTheoryWitnessLeft(G, B, 2100000 + G * 1000 + B * 10 + 1) :-
    theoryMutexBucket(G, B).
stressTheoryWitnessRight(G, B, 2100000 + G * 1000 + B * 10 + 2) :-
    theoryMutexBucket(G, B).

method(W) :- stressTheoryWitnessLeft(_, _, W).
method(W) :- stressTheoryWitnessRight(_, _, W).

{ theoryMutexWitnessActive(G, B) } :-
    conditional_gate_default != 0,
    theoryMutexBucket(G, B).

:- conditional_gate_default = 1,
   theoryMutexBucket(G, B),
   not theoryMutexWitnessActive(G, B).

mergeClasses(W1, W2) :-
    theoryMutexWitnessActive(G, B),
    stressTheoryWitnessLeft(G, B, W1),
    stressTheoryWitnessRight(G, B, W2),
    W1 < W2.

-mergeClasses(Leaf1, Leaf2) :-
    theoryMutexPair(G, _, _, Leaf1, Leaf2, B),
    stressTheoryWitnessLeft(G, B, W1),
    stressTheoryWitnessRight(G, B, W2),
    &sameClass(W1, W2).

#show stressGroup/1.
#show stressLeaf/1.
#show stressHub/2.
#show stressLeafId/3.
#show stressPairBucket/4.
#show staticMutexPair/5.
#show conditionalMutexPair/6.
#show conditionalMutexEnabled/2.
#show theoryMutexPair/6.
#show theoryMutexWitnessActive/2.
#show strongMergeCandidate/2.
#show strongMergeReward/2.
#show mergeCandidate/2.
#show mergeClasses/2.
#show -mergeClasses/2.
