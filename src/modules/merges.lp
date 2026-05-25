% ============================================================
% CLASS MERGING
% ============================================================

% Merge domain: methods and vftables can be members of recovered classes.
mergeEntity(M) :- method(M).
mergeEntity(V) :- vfTable(V).

% sortPair: canonical ordered pair for merge predicates.
sortPair(A, B, A, B) :- mergeEntity(A), mergeEntity(B), A < B.
sortPair(A, B, B, A) :- mergeEntity(A), mergeEntity(B), B < A.

% reasonMergeClasses_G: symbols with the same class name identify the same class.
mergeClasses(A, B) :-
    symbolClass(Method1, _, ClassName, _),
    symbolClass(Method2, _, ClassName, _),
    Method1 != Method2,
    sortPair(Method1, Method2, A, B).                                      % rules.pl:2881

% reasonMergeClasses_J: RTTI can identify multiple vftables as belonging to the same class.
mergeClasses(A, B) :-
    rTTITDA2VFTable(TDA, VFTable1),
    rTTITDA2VFTable(TDA, VFTable2),
    VFTable1 != VFTable2,
    sortPair(VFTable1, VFTable2, A, B).                                    % rules.pl:2925

% Compact transitive closure over hard merges.
merged(A, B) :- mergeClasses(A, B).
merged(B, A) :- mergeClasses(A, B).

sameClass(A, A) :- mergeEntity(A).
sameClass(A, C) :- sameClass(A, B), merged(B, C).

% ============================================================
% GUESS
% ============================================================

% guessMergeClasses_B: vftable writer may be on the same class as vftable entries.
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn, Writer, _ObjectOffset, VFTable),
    vfTableEntry(VFTable, _VFTableOffset, Entry),
    not purecall(Entry),
    sortPair(Writer, Entry, A, B).                                      % guess.pl:1050

% guessMergeClasses_D: methods writing the same vftable at the same offset may be the same class.
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn1, Method1, ObjectOffset, VFTable),
    vfTableWrite(_Insn2, Method2, ObjectOffset, VFTable),
    Method1 != Method2,
    sortPair(Method1, Method2, A, B).                                   % guess.pl:1215

mergeCandidate(A, B) :- strongMergeCandidate(A, B).

% guessMergeClasses: choose merge or not-merge for each candidate pair.
1 { mergeClasses(A, B); -mergeClasses(A, B) } 1 :- mergeCandidate(A, B). % guess.pl:1084
#heuristic mergeClasses(A, B) : mergeCandidate(A, B). [1@1, true]

% Optimization reward for confirmed strong merges (priority @2).
strongMergeReward(M1, M2) :- mergeClasses(M1, M2), strongMergeCandidate(M1, M2).

#maximize { 10@2, merge, M1, M2 : strongMergeReward(M1, M2) }.

#show mergeClasses/2.
#show sameClass/2.
