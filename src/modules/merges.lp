% ============================================================
% RULES
% ============================================================

% Merge domain: methods and vftables can be members of recovered classes.
mergeEntity(M) :- method(M).
mergeEntity(V) :- vfTable(V).

% sortPair: canonical ordered pair for merge predicates.
sortPair(A, B, A, B) :- mergeEntity(A), mergeEntity(B), A < B.
sortPair(A, B, B, A) :- mergeEntity(A), mergeEntity(B), B < A.

% reasonMergeClasses_G: symbols with the same class name identify the same class.
%!trace_rule {"% and % are the same class because symbols share the class name %", A, B, ClassName}
mergeClasses(A, B) :-
    symbolClass(Method1, _, ClassName, _),
    symbolClass(Method2, _, ClassName, _),
    Method1 != Method2,
    sortPair(Method1, Method2, A, B).                                      % rules.pl:2881

% reasonMergeClasses_J: RTTI can identify multiple vftables as belonging to the same class.
%!trace_rule {"% and % are the same class because RTTI maps vftables % and % to the same TDA %", A, B, VFTable1, VFTable2, TDA}
mergeClasses(A, B) :-
    rTTITDA2VFTable(TDA, VFTable1),
    rTTITDA2VFTable(TDA, VFTable2),
    VFTable1 != VFTable2,
    sortPair(VFTable1, VFTable2, A, B).                                    % rules.pl:2925

% reasonMergeClasses_E: two classes that are both direct bases of the same derived class
% at the same offset must be the same class.
% Witness: DC1 ~ DC2 (same derived); W1, W2 are the base witnesses.
%!trace_rule {"% and % are the same class because both are bases of % at offset %", A, B, DC1, ObjectOffset}
mergeClasses(A, B) :-
    derivedClass(DC1, W1, ObjectOffset),
    derivedClass(DC2, W2, ObjectOffset),
    &sameClass(DC1, DC2),
    not &sameClass(W1, W2),
    sortPair(W1, W2, A, B).                                                % rules.pl:2847

% reasonNOTMergeClasses_E: methods writing different vftables at offset 0
% cannot be the same class, unless both cross-write the other's vftable.
% Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
%!trace_rule {"% and % must NOT be merged because they write different vftables % and % at offset 0", A, B, VFTable1, VFTable2}
-mergeClasses(A, B) :-
    vfTableWrite(_Insn1, Method1, 0, VFTable1),
    vfTableWrite(_Insn2, Method2, 0, VFTable2),
    VFTable1 != VFTable2,
    sortPair(Method1, Method2, A, B),
    not &sameClass(Method1, Method2),
    not vfTableWrite(_, Method1, 0, VFTable2),
    not vfTableWrite(_, Method2, 0, VFTable1).                             % rules.pl:3123

% reasonNOTMergeClasses_F: same derived class has two bases at different offsets — they cannot merge.
% Witness: DC1 ~ DC2 (same derived); W1, W2 are the base witnesses at different offsets.
%!trace_rule {"% and % must NOT be merged because % has them as bases at different offsets % and %", A, B, DC1, Offset1, Offset2}
-mergeClasses(A, B) :-
    derivedClass(DC1, W1, Offset1),
    derivedClass(DC2, W2, Offset2),
    &sameClass(DC1, DC2),
    Offset1 != Offset2,
    sortPair(W1, W2, A, B).                                                % rules.pl:3158

% reasonNOTMergeClasses_C: any method called by both derived and base belongs to base,
% not derived — so derived class and that method's class cannot merge.
% Witness: DC (derived), BC (base from derivedClass). DC2 ~ DC, BC2 ~ BC via &sameClass.
% Counterpart: reasonNOTMergeClasses_C / _C_asymmetric (rules.pl:3090, 3111)
%!trace_rule {"% and % cannot merge because method % is called by both derived % and base %", DC, Method, Method, DC, BC}
reasonNOTMergeClassesCAsymmetric(DC, Method) :-
    derivedClass(DC, BC, _ObjectOffset),
    classCallsMethod(DC2, Method), &sameClass(DC, DC2),
    classCallsMethod(BC2, Method), &sameClass(BC, BC2),
    not &sameClass(DC, Method).

%!trace_rule {"% and % must NOT be merged because a method is called by both derived and base class", A, B}
-mergeClasses(A, B) :-
    reasonNOTMergeClassesCAsymmetric(DC, Method),
    sortPair(DC, Method, A, B).                                            % rules.pl:3111

% reasonNOTMergeClasses_J: classes in a composition/inheritance relationship cannot merge.
% Witness: (X, Y) from classRelationship (transitive over objectInObject via &sameClass join).
% Counterpart: reasonNOTMergeClasses_J (rules.pl:3212)
%!trace_rule {"% and % must NOT be merged because % is composed of or derived from %", A, B, X, Y}
-mergeClasses(A, B) :-
    classRelationship(X, Y),
    not &sameClass(X, Y),
    sortPair(X, Y, A, B).                                                  % rules.pl:3212

% reasonNOTMergeClasses_I: RTTI says two TDAs map to different classes.
% rTTITDA2Class/2 is witness-based: (TDA, VFTable) where VFTable is the class witness.
% Counterpart: reasonNOTMergeClasses_I (rules.pl:3196)
%!trace_rule {"% and % must NOT be merged because RTTI TDAs % and % map to different classes", A, B, TDA1, TDA2}
-mergeClasses(A, B) :-
    rTTIEnabledAndValid,
    rTTITDA2Class(TDA1, W1),
    rTTITDA2Class(TDA2, W2),
    TDA1 != TDA2,
    not &sameClass(W1, W2),
    sortPair(W1, W2, A, B).                                                % rules.pl:3196

% reasonNOTMergeClasses_R: If a derived class calls a method that installs the
% derived class' vftable, the called method cannot be on the base class.
% Witness: DC (derived), BC (base from derivedClass).
% Counterpart: reasonNOTMergeClasses_R (rules.pl:3366)
%!trace_rule {"% and % must NOT be merged because method % called by derived % writes its vftable at offset %", A, B, CalledMethod, DC, Offset}
-mergeClasses(A, B) :-
    classCallsMethod(DC1, CalledMethod),
    not purecall(CalledMethod),
    derivedClass(DC2, BC, Offset),
    &sameClass(DC1, DC2),
    vfTableWrite(_Insn, CalledMethod, Offset, V),
    &sameClass(V, DC1),
    not &sameClass(BC, CalledMethod),
    sortPair(BC, CalledMethod, A, B).                                       % rules.pl:3366

% reasonNOTMergeClasses_K: methods with conflicting symbol class names
% cannot belong to the same recovered class.
% Counterpart: reasonNOTMergeClasses_K (rules.pl:3222)
%!trace_rule {"% and % must NOT be merged because symbol class names % and % conflict", A, B, ClassName1, ClassName2}
-mergeClasses(A, B) :-
    symbolClass(Method1, _MangledName1, ClassName1, _MethodName1),
    symbolClass(Method2, _MangledName2, ClassName2, _MethodName2),
    ClassName1 != ClassName2,
    sortPair(Method1, Method2, A, B).                                      % rules.pl:3222

% reasonNOTMergeClasses_Q: methods without a symbol for a known class name
% cannot merge with methods whose symbol identifies that class.
% Counterpart: reasonNOTMergeClasses_Q (rules.pl:3352)
%!trace_rule {"% and % must NOT be merged because % lacks a symbol for the class name %", A, B, OtherMethod, ClassName}
-mergeClasses(A, B) :-
    symbolClass(MethodWithSymbol, _MangledName1, ClassName, _MethodName1),
    method(MethodWithSymbol),
    ClassName != type_info,
    method(OtherMethod),
    not symbolClass(OtherMethod, _, ClassName, _),
    sortPair(MethodWithSymbol, OtherMethod, A, B).                         % rules.pl:3352

% reasonMergeVFTables: merge vftable with the class that owns it.
% Counterpart: reasonMergeVFTables (rules.pl:2722)
%!trace_rule {"merge vftable % with class % because vftable belongs to this class", VFTable, Method}
mergeClasses(VFTable, Method) :- vftableBelongsToClass(VFTable, Offset, Method).

% ============================================================
% GUESS
% ============================================================

% guessMergeClasses_B: vftable writer may be on the same class as vftable entries.
%!trace_rule {"% and % are strong merge candidates because method % installs vftable % that contains entry %", A, B, Writer, VFTable, Entry}
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn, Writer, _ObjectOffset, VFTable),
    vfTableEntry(VFTable, _VFTableOffset, Entry),
    not purecall(Entry),
    sortPair(Writer, Entry, A, B).                                         % guess.pl:1050

% guessMergeClasses_D: methods writing the same vftable at the same offset may be the same class.
%!trace_rule {"% and % are strong merge candidates because they both write vftable % at offset %", A, B, VFTable, ObjectOffset}
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn1, Method1, ObjectOffset, VFTable),
    vfTableWrite(_Insn2, Method2, ObjectOffset, VFTable),
    Method1 != Method2,
    sortPair(Method1, Method2, A, B).                                      % guess.pl:1215

mergeCandidate(A, B) :- strongMergeCandidate(A, B).

% guessMergeClasses: choose merge or not-merge for each candidate pair.
%!trace_rule {"guess whether % and % are the same class or not", A, B}
1 { mergeClasses(A, B); -mergeClasses(A, B) } 1 :- mergeCandidate(A, B). % guess.pl:1084
#heuristic mergeClasses(A, B) : mergeCandidate(A, B). [1@1, true]

% ============================================================
% REWARDS
% ============================================================

% Optimization reward for confirmed strong merges (priority @2).
strongMergeReward(M1, M2) :- mergeClasses(M1, M2), strongMergeCandidate(M1, M2).

#maximize { 10@2, merge, M1, M2 : strongMergeReward(M1, M2) }.

% New non-prolog merging reward: adjacent regular methods are more likely to be
% on the same class. This is true at least for non-debug executables.
regularMethod(M) :- method(M), not constructor(M).

nextRegularMethod(M1, M2) :-
    regularMethod(M1),
    M2 = #min{ M3 : regularMethod(M3), M3 > M1 }.

adjacentMethodCandidate(A, B) :-
    nextRegularMethod(M1, M2),
    sortPair(M1, M2, A, B).

#maximize { 1@0, adjacent, M1, M2 : mergeClasses(M1, M2), adjacentMethodCandidate(M1, M2) }.
#heuristic mergeClasses(A, B) : mergeCandidate(A, B), adjacentMethodCandidate(A, B). [1@0, true]

%!NOshow_trace mergeClasses(A, B).
%!NOshow_trace -mergeClasses(A, B).
%!trace {"% and % should be merged", A, B} mergeClasses(A, B).

#show mergeClasses/2.
#show -mergeClasses/2.
