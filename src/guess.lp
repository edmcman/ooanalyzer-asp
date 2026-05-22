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
mergeCandidate(C1, C2) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), find(M1, C1), find(M2, C2), C1 < C2.  % Counterpart: guessMergeClassesD (guess.pl:1215)
mergeCandidate(C1, C2) :- factVFTableWrite(Writer, _, V), factVFTableEntry(V, _, Entry), not purecall(Entry), find(Writer, C1), find(Entry, C2), C1 < C2.  % Counterpart: guessMergeClassesB (guess.pl:1050)
mergeCandidate(C1, C2) :- factVFTableWrite(Writer, _, V), factVFTableEntry(V, _, Entry), not purecall(Entry), find(Entry, C1), find(Writer, C2), C1 < C2.  % Counterpart: guessMergeClassesB

% Same debug symbol class
mergeCandidate(C1, C2) :- symbolClass(M1, C), symbolClass(M2, C), find(M1, C1), find(M2, C2), C1 < C2.  % Counterpart: reasonMergeClasses_G (rules.pl:2881)

% objectInObject relationships
mergeCandidate(C1, C2) :- objectInObject(M1, M2, _), find(M1, C1), find(M2, C2), C1 < C2.  % Counterpart: reasonNOTMergeClasses_G (rules.pl:3177) / guessDerivedClass
mergeCandidate(C1, C2) :- objectInObject(M1, M2, _), find(M2, C1), find(M1, C2), C1 < C2.  % Counterpart: reasonNOTMergeClasses_G

% Two inners of the same outer (reasonMergeClasses_E)
mergeCandidate(C1, C2) :- objectInObject(Outer, M1, _), objectInObject(Outer, M2, _), find(M1, C1), find(M2, C2), C1 < C2.  % Counterpart: reasonMergeClasses_E (rules.pl:2847)

% Call relationships
mergeCandidate(C1, C2) :- callTarget(Caller, Callee), not purecall(Callee), find(Caller, C1), find(Callee, C2), C1 < C2.  % Counterpart: guessMergeClassesC1-C4 (guess.pl:1103, 1146, 1169, 1187)
mergeCandidate(C1, C2) :- callTarget(Caller, Callee), not purecall(Callee), find(Callee, C1), find(Caller, C2), C1 < C2.  % Counterpart: guessMergeClassesC1-C4
mergeCandidate(C1, C2) :-
    callAtOffset(Caller, Callee, 0), not purecall(Callee),
    find(Caller, C1), find(Callee, C2), C1 < C2.                                                % Counterpart: reasonMergeClasses_C (rules.pl:2822) / factClassCallsMethod
mergeCandidate(C1, C2) :-
    callAtOffset(Caller, Callee, 0), not purecall(Callee),
    find(Callee, C1), find(Caller, C2), C1 < C2.

% Vftable overwrite relationships
mergeCandidate(C1, C2) :- factVFTableOverwrite(Ov, _, _, V), factVFTableWrite(Wr, _, V), find(Ov, C1), find(Wr, C2), C1 < C2.  % Counterpart: reasonDerivedClass_B (rules.pl:1834) / guessMergeClassesD
mergeCandidate(C1, C2) :- factVFTableOverwrite(Ov, _, _, V), factVFTableWrite(Wr, _, V), find(Wr, C1), find(Ov, C2), C1 < C2.  % Counterpart: reasonDerivedClass_B

% VBTable relationships
mergeCandidate(C1, C2) :- factVBTableWrite(M1, Off, V), factVBTableWrite(M2, Off, V), find(M1, C1), find(M2, C2), C1 < C2.  % Counterpart: reasonDerivedClass_F (rules.pl:1999) / guessMergeClassesB-like

% Deleting destructor / real destructor chain
mergeCandidate(C1, C2) :- factDeletingDestructor(DD), factRealDestructor(RD), callTarget(DD, RD), find(DD, C1), find(RD, C2), C1 < C2.  % Counterpart: guessMergeClasses (destructor chain, guess.pl:1084)
mergeCandidate(C1, C2) :- factDeletingDestructor(DD), factRealDestructor(RD), callTarget(DD, RD), find(RD, C1), find(DD, C2), C1 < C2.  % Counterpart: guessMergeClasses

% guessLateMergeClassesF2: singleton methods in a confirmed vftable should be mergeable
% with the class that owns the vftable.
mergeCandidate(C1, C2) :-
    factVFTableEntry(V, _, M), not purecall(M),
    factVFTableBelongsToClass(V, _, C1),
    find(M, C2), C1 < C2.
mergeCandidate(C1, C2) :-
    factVFTableEntry(V, _, M), not purecall(M),
    factVFTableBelongsToClass(V, _, C2),
    find(M, C1), C1 < C2.

{ mergeClasses(M1, M2) } :- mergeCandidate(M1, M2).                                              % Counterpart: guessMergeClasses (guess.pl:1084) / guessLateMergeClasses (guess.pl:860)
