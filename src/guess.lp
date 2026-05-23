% ============================================================
% GUESSES
% ============================================================

{ factVFTable(V) } :- possibleVFTableWrite(_, _, V).  % Counterpart: guessVFTable (guess.pl:180)
% RTTI definitively confirms vftables -- no guess needed for these.
factVFTable(V) :- rTTICompleteObjectLocator(V, _).       % Counterpart: factVFTable (hard fact, setup.pl:55)

% Guess whether a constructor-calls-constructor relationship is inheritance or embedding.
{ factDerivedClass(Outer, Inner, Off) } :- objectInObject(Outer, Inner, Off).  % Counterpart: guessDerivedClass (guess.pl:317)

% Guess: does a class have no base class?
knownBaseClassMember(M) :- sameClass(M, D), factDerivedClass(D, _, _).

{ factClassHasNoBase(M) } :- factConstructor(M), factVFTableWrite(M, 0, V),
    not factVFTableWrite(M, _, V2) : factVFTable(V2), V2 != V,
    not knownBaseClassMember(M).  % Counterpart: guessClassHasNoBaseB (guess.pl:732)
{ factClassHasNoBase(M) } :- factMethod(M), not knownBaseClassMember(M).  % Counterpart: guessClassHasNoBaseSpecial (guess.pl:781)

% Guess: is candidate V actually a VBTable?
{ factVBTable(V) } :- possibleVBTableWrite(_, _, V).  % Counterpart: guessVBTable (guess.pl:215)

% ============================================================
% MERGE CANDIDATES -- domain restriction for scaling
% ============================================================
% Only generate mergeClasses choices for structurally related pairs.
% This avoids O(n^2) grounding for binaries with thousands of methods.

% guessMergeClassesD: same vftable writers
mergeCandidate(C1, C2) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), sortPair(M1, M2, C1, C2).  % Counterpart: guessMergeClassesD (guess.pl:1215)

% guessMergeClassesB: vftable writer and its entries
mergeCandidate(C1, C2) :- factVFTableWrite(Writer, _, V), factVFTableEntry(V, _, Entry), not purecall(Entry), sortPair(Writer, Entry, C1, C2).  % Counterpart: guessMergeClassesB (guess.pl:1050)

% Call relationships (guessMergeClassesC1-C4 + reasonMergeClasses_C)
mergeCandidate(C1, C2) :- callTarget(Caller, Callee), not purecall(Callee), sortPair(Caller, Callee, C1, C2).  % Counterpart: guessMergeClassesC1-C4 (guess.pl:1103, 1146, 1169, 1187)
mergeCandidate(C1, C2) :-
    callAtOffset(Caller, Callee, 0), not purecall(Callee),
    sortPair(Caller, Callee, C1, C2).                                  % Counterpart: reasonMergeClasses_C (rules.pl:2822) / factClassCallsMethod

% Deleting destructor / real destructor chain
mergeCandidate(C1, C2) :- factDeletingDestructor(DD), factRealDestructor(RD), callTarget(DD, RD), sortPair(DD, RD, C1, C2).  % Counterpart: guessMergeClasses (destructor chain)

% guessLateMergeClassesF2: singleton methods in a confirmed vftable should be mergeable
% with the class that owns the vftable.
mergeCandidate(C1, C2) :-
    factVFTableEntry(V, _, M), not purecall(M),
    factVFTableBelongsToClass(V, _, C),
    sortPair(M, C, C1, C2).

{ mergeClasses(M1, M2) } :- mergeCandidate(M1, M2).                                              % Counterpart: guessMergeClasses (guess.pl:1084) / guessLateMergeClasses (guess.pl:860)
