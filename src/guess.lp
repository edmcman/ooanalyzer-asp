% ============================================================
% GUESSES
% ============================================================

guessVFTableDomain(V) :- possibleVFTableWrite(_, _, V).
1 { factVFTable(V); -factVFTable(V) } 1 :- guessVFTableDomain(V).  % Counterpart: guessVFTable (guess.pl:180)
#heuristic factVFTable(V) : guessVFTableDomain(V). [1@2, true]
guessVFTableReward(V) :- factVFTable(V), guessVFTableDomain(V).
% RTTI definitively confirms vftables -- no guess needed for these.
factVFTable(V) :- rTTICompleteObjectLocator(V, _).       % Counterpart: factVFTable (hard fact, setup.pl:55)

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
guessDerivedClassDomain(Outer, Inner, Off) :- objectInObject(Outer, Inner, Off).
{ factDerivedClass(Outer, Inner, Off) } :- guessDerivedClassDomain(Outer, Inner, Off).  % Counterpart: guessDerivedClass (guess.pl:317)
#heuristic factDerivedClass(Outer, Inner, Off) : guessDerivedClassDomain(Outer, Inner, Off). [100@0, true]
guessDerivedClassReward(Outer, Inner, Off) :- factDerivedClass(Outer, Inner, Off), guessDerivedClassDomain(Outer, Inner, Off).

% Guess: does a class have no base class?
knownBaseClassMember(M) :- sameClass(M, D), factDerivedClass(D, _, _).

guessClassHasNoBaseCtorDomain(M) :- factConstructor(M), factVFTableWrite(M, 0, V),
    not factVFTableWrite(M, _, V2) : factVFTable(V2), V2 != V,
    not knownBaseClassMember(M).
{ factClassHasNoBase(M) } :- guessClassHasNoBaseCtorDomain(M).  % Counterpart: guessClassHasNoBaseB (guess.pl:732)
#heuristic factClassHasNoBase(M) : guessClassHasNoBaseCtorDomain(M). [1@0, true]
guessClassHasNoBaseCtorReward(M) :- factClassHasNoBase(M), guessClassHasNoBaseCtorDomain(M).

guessClassHasNoBaseMethodDomain(M) :- factMethod(M), not knownBaseClassMember(M).
{ factClassHasNoBase(M) } :- guessClassHasNoBaseMethodDomain(M).  % Counterpart: guessClassHasNoBaseSpecial (guess.pl:781)
#heuristic factClassHasNoBase(M) : guessClassHasNoBaseMethodDomain(M). [1@0, true]
guessClassHasNoBaseMethodReward(M) :- factClassHasNoBase(M), guessClassHasNoBaseMethodDomain(M).

% Guess: is candidate V actually a VBTable?
guessVBTableDomain(V) :- possibleVBTableWrite(_, _, V).
1 { factVBTable(V); -factVBTable(V) } 1 :- guessVBTableDomain(V).  % Counterpart: guessVBTable (guess.pl:215)
#heuristic factVBTable(V) : guessVBTableDomain(V). [1@2, true]
guessVBTableReward(V) :- factVBTable(V), guessVBTableDomain(V).

% Guess: is M the real destructor called by a deleting destructor?
guessRealDestructorDomain(M) :- noCallsAfter(M), not factConstructor(M), not callsDelete(M), possibleDestructor(M), possibleMethod(M),
                                callTarget(D, M), factDeletingDestructor(D).
{ factRealDestructor(M) } :- guessRealDestructorDomain(M).  % Counterpart: guessRealDestructor (guess.pl:1395)
#heuristic factRealDestructor(M) : guessRealDestructorDomain(M). [1@0, true]
guessRealDestructorReward(M) :- factRealDestructor(M), guessRealDestructorDomain(M).

% ============================================================
% MERGE CANDIDATES -- domain restriction for scaling
% ============================================================
% Only generate mergeClasses choices for structurally related pairs.
% This avoids O(n^2) grounding for binaries with thousands of methods.

% guessMergeClassesD: same vftable writers
strongMergeCandidate(C1, C2) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), sortPair(M1, M2, C1, C2).  % Counterpart: guessMergeClassesD (guess.pl:1215)

% guessMergeClassesB: vftable writer and its entries
strongMergeCandidate(C1, C2) :- factVFTableWrite(Writer, _, V), factVFTableEntry(V, _, Entry), not purecall(Entry), sortPair(Writer, Entry, C1, C2).  % Counterpart: guessMergeClassesB (guess.pl:1050)

% Call relationships (guessMergeClassesC1-C4 + reasonMergeClasses_C)
strongMergeCandidate(C1, C2) :- callTarget(Caller, Callee), not purecall(Callee), sortPair(Caller, Callee, C1, C2).  % Counterpart: guessMergeClassesC1-C4 (guess.pl:1103, 1146, 1169, 1187)
strongMergeCandidate(C1, C2) :-
    callAtOffset(Caller, Callee, 0), not purecall(Callee),
    sortPair(Caller, Callee, C1, C2).                                  % Counterpart: reasonMergeClasses_C (rules.pl:2822) / factClassCallsMethod

% Deleting destructor / real destructor chain
strongMergeCandidate(C1, C2) :- factDeletingDestructor(DD), factRealDestructor(RD), callTarget(DD, RD), sortPair(DD, RD, C1, C2).  % Counterpart: guessMergeClasses (destructor chain)

% guessLateMergeClassesF2: singleton methods in a confirmed vftable should be mergeable
% with the class that owns the vftable.
% ejs: how can we possibly represent this?
% The disabled rule keeps a typed empty domain so reward wiring stays warning-free.
lateMergeCandidate(C1, C2) :- strongMergeCandidate(C1, C2), C1 != C1.
%lateMergeCandidate(C1, C2) :-
%    factVFTableEntry(V, _, M), not purecall(M),
%    factVFTableBelongsToClass(V, _, C),
%    sortPair(M, C, C1, C2).

mergeCandidate(C1, C2) :- strongMergeCandidate(C1, C2).
mergeCandidate(C1, C2) :- lateMergeCandidate(C1, C2).

1 { mergeClasses(M1, M2); -mergeClasses(M1, M2) } 1 :- mergeCandidate(M1, M2).                   % Counterpart: guessMergeClasses (guess.pl:1084) / guessLateMergeClasses (guess.pl:860)
#heuristic mergeClasses(M1, M2) : mergeCandidate(M1, M2). [1@1, true]
strongMergeReward(M1, M2) :- mergeClasses(M1, M2), strongMergeCandidate(M1, M2).
lateMergeReward(M1, M2) :- mergeClasses(M1, M2), lateMergeCandidate(M1, M2).
