% ============================================================
% GUESSES
% ============================================================

{ factVFTable(V) } :- possibleVFTableWrite(_, _, V).  % Counterpart: guessVFTable (guess.pl:180)
% RTTI definitively confirms vftables -- no guess needed for these.
factVFTable(V) :- rTTICompleteObjectLocator(V, _).       % Counterpart: factVFTable (hard fact, setup.pl:55)

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
{ factDerivedClass(Outer, Inner, Off) } :- objectInObject(Outer, Inner, Off).  % Counterpart: guessDerivedClass (guess.pl:317)

% Guess: does a class have no base class?
{ factClassHasNoBase(C) } :- classRep(C).  % Counterpart: guessClassHasNoBase / guessClassHasNoBaseB / guessClassHasNoBaseSpecial (guess.pl:746, 732, 781)

% Guess: is candidate V actually a VBTable?
{ factVBTable(V) } :- possibleVBTableWrite(_, _, V).  % Counterpart: guessVBTable (guess.pl:215)

% ============================================================
% MERGE CANDIDATES -- domain restriction for scaling
% ============================================================
% Only generate mergeClasses choices for structurally related pairs.
% This avoids O(n^2) grounding for binaries with thousands of methods.

% Same vftable writers or writer+entry
mergeCandidate(M1, M2) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2.  % Counterpart: guessMergeClassesD (guess.pl:1215)
mergeCandidate(M1, M2) :- factVFTableWrite(M1, _, V), factVFTableEntry(V, _, M2), not purecall(M2), M1 < M2.  % Counterpart: guessMergeClassesB (guess.pl:1050)
mergeCandidate(M1, M2) :- factVFTableWrite(M2, _, V), factVFTableEntry(V, _, M1), not purecall(M1), M1 < M2.  % Counterpart: guessMergeClassesB

% Same debug symbol class
mergeCandidate(M1, M2) :- symbolClass(M1, C), symbolClass(M2, C), M1 < M2.                      % Counterpart: reasonMergeClasses_G (rules.pl:2881)

% objectInObject relationships
mergeCandidate(M1, M2) :- objectInObject(M1, M2, _), M1 < M2.                                   % Counterpart: reasonNOTMergeClasses_G (rules.pl:3177) / guessDerivedClass
mergeCandidate(M1, M2) :- objectInObject(M2, M1, _), M1 < M2.                                   % Counterpart: reasonNOTMergeClasses_G

% Two inners of the same outer (reasonMergeClasses_E)
mergeCandidate(M1, M2) :- objectInObject(Outer, M1, _), objectInObject(Outer, M2, _), M1 < M2. % Counterpart: reasonMergeClasses_E (rules.pl:2847)

% Call relationships
mergeCandidate(M1, M2) :- callTarget(M1, M2), not purecall(M2), M1 < M2.                         % Counterpart: guessMergeClassesC1-C4 (guess.pl:1103, 1146, 1169, 1187)
mergeCandidate(M1, M2) :- callTarget(M2, M1), not purecall(M1), M1 < M2.                         % Counterpart: guessMergeClassesC1-C4
mergeCandidate(M1, M2) :- callAtOffset(M1, M2, 0), not purecall(M2), M1 < M2.                    % Counterpart: reasonMergeClasses_C (rules.pl:2822) / factClassCallsMethod
mergeCandidate(M1, M2) :- callAtOffset(M2, M1, 0), not purecall(M1), M1 < M2.                    % Counterpart: reasonMergeClasses_C

% Vftable overwrite relationships
mergeCandidate(M1, M2) :- factVFTableOverwrite(M1, _, _, V), factVFTableWrite(M2, _, V), M1 < M2. % Counterpart: reasonDerivedClass_B (rules.pl:1834) / guessMergeClassesD
mergeCandidate(M1, M2) :- factVFTableOverwrite(M2, _, _, V), factVFTableWrite(M1, _, V), M1 < M2. % Counterpart: reasonDerivedClass_B

% VBTable relationships
mergeCandidate(M1, M2) :- factVBTableWrite(M1, Off, V), factVBTableWrite(M2, Off, V), M1 < M2. % Counterpart: reasonDerivedClass_F (rules.pl:1999) / guessMergeClassesB-like

% Deleting destructor / real destructor chain
mergeCandidate(M1, M2) :- factDeletingDestructor(M1), factRealDestructor(M2), callTarget(M1, M2), M1 < M2. % Counterpart: guessMergeClasses (destructor chain, guess.pl:1084)
mergeCandidate(M1, M2) :- factDeletingDestructor(M2), factRealDestructor(M1), callTarget(M2, M1), M1 < M2. % Counterpart: guessMergeClasses

% guessLateMergeClassesF2: singleton methods in a confirmed vftable should be mergeable
% with the class that owns the vftable.
mergeCandidate(M1, M2) :-
    factVFTableEntry(V, _, M2), not purecall(M2),
    factVFTableBelongsToClass(V, _, C),
    find(M1, C),
    M1 < M2.

{ mergeClasses(M1, M2) } :- mergeCandidate(M1, M2).                                              % Counterpart: guessMergeClasses (guess.pl:1084) / guessLateMergeClasses (guess.pl:860)
