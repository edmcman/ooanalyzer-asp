% ============================================================
% OPTIMIZATION
% ============================================================


% Priority 2: confirm as many candidate tables as possible.
#maximize {
    1@2, vft, V : guessVFTableReward(V);
    1@2, vbt, V : guessVBTableReward(V)
}.        % Counterpart: guessVFTable / guessVBTable priorities

% Priority 1: maximize class merges (minimize class count).
% Late-merge guesses are weaker evidence and receive a smaller reward.
#maximize {
    10@1, strongMerge, M1, M2 : strongMergeReward(M1, M2);
    1@1, lateMerge, M1, M2 : lateMergeReward(M1, M2)
}.        % Counterpart: guessMergeClasses / guessLateMergeClasses priorities

% Priority 0: prefer Derived > Embedded > other low-confidence guesses.
#maximize {
    100@0, derived, Outer, Inner, Off : guessDerivedClassReward(Outer, Inner, Off);
    10@0, embedded, Outer, Inner, Off : factEmbeddedObject(Outer, Inner, Off);
    1@0, noBaseCtor, M : guessClassHasNoBaseCtorReward(M);
    1@0, noBaseMethod, M : guessClassHasNoBaseMethodReward(M);
    1@0, realDtor, M : guessRealDestructorReward(M)
}.
