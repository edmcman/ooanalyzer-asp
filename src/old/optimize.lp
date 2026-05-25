% ============================================================
% OPTIMIZATION
% ============================================================


% Priority 2: confirm as many candidate tables as possible.
#maximize {
    1@2, vft, V : guessVFTableReward(V);
    1@2, vbt, V : guessVBTableReward(V)
}.

% Priority 1: maximize inheritance, embedding, good merges
% Late-merge guesses are weaker evidence and receive a smaller reward.
#maximize {
    100@1, derived, Outer, Inner, Off : guessDerivedClassReward(Outer, Inner, Off);
    10@1, embedded, Outer, Inner, Off : factEmbeddedObject(Outer, Inner, Off);
    10@1, strongMerge, M1, M2 : strongMergeReward(M1, M2)
}.

% Priority 0: Other guesses

#maximize {
    1@0, noBaseCtor, M : guessClassHasNoBaseCtorReward(M);
    1@0, noBaseMethod, M : guessClassHasNoBaseMethodReward(M);
    1@0, realDtor, M : guessRealDestructorReward(M)
    % 1@0, lateMerge, M1, M2 : lateMergeReward(M1, M2)
}.
