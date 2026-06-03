% ============================================================
% RULES
% ============================================================

% Merge domain: methods and vftables can be members of recovered classes.
mergeEntity(M) :- method(M).
mergeEntity(V) :- vfTable(V).

% reasonMergeClasses_G: symbols with the same class name identify the same class.
% Symmetric: both methods from symbolClass; Method1 < Method2 gives each pair once.
% Counterpart: reasonMergeClasses_G (rules.pl:2881)
%!trace_rule {"% and % are the same class because symbols share the class name %", Method1, Method2, ClassName}
mergeClasses(Method1, Method2) :-
    symbolClass(Method1, _, ClassName, _),
    symbolClass(Method2, _, ClassName, _),
    Method1 < Method2.                                                       % rules.pl:2881

% reasonMergeClasses_J: RTTI can identify multiple vftables as belonging to the same class.
% Symmetric: both vftables from rTTITDA2VFTable for the same TDA.
% Counterpart: reasonMergeClasses_J (rules.pl:2925)
%!trace_rule {"% and % are the same class because RTTI maps vftables % and % to the same TDA %", VFTable1, VFTable2, VFTable1, VFTable2, TDA}
mergeClasses(VFTable1, VFTable2) :-
    rTTITDA2VFTable(TDA, VFTable1),
    rTTITDA2VFTable(TDA, VFTable2),
    VFTable1 < VFTable2.                                                     % rules.pl:2925

% reasonMergeClasses_E: two classes that are both direct bases of the same derived class
% at the same offset must be the same class.
% Symmetric: both witnesses from derivedClass at the same offset.
% Counterpart: reasonMergeClasses_E (rules.pl:2847)
%!trace_rule {"% and % are the same class because both are bases of % at offset %", W1, W2, DC1, ObjectOffset}
mergeClasses(W1, W2) :-
    derivedClass(DC1, W1, ObjectOffset),
    derivedClass(DC2, W2, ObjectOffset),
    &sameClass(DC1, DC2),
    W1 < W2.                                                                 % rules.pl:2847

% reasonMergeVFTables: merge vftable with the class that owns it.
% Deterministic derivation; propagator handles either argument order.
% Counterpart: reasonMergeVFTables (rules.pl:2722)
%!trace_rule {"merge vftable % with class % because vftable belongs to this class", VFTable, Method}
mergeClasses(VFTable, Method) :- vftableBelongsToClass(VFTable, _, Method). % rules.pl:2722

% reasonNOTMergeClasses_E: methods writing different vftables at offset 0
% cannot be the same class, unless both cross-write the other's vftable.
% Symmetric: both methods from vfTableWrite at offset 0.
% Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
%!trace_rule {"% and % must NOT be merged because they write different vftables % and % at offset 0", Method1, Method2, VFTable1, VFTable2}
-mergeClasses(Method1, Method2) :-
    vfTableWrite(_Insn1, Method1, 0, VFTable1),
    vfTableWrite(_Insn2, Method2, 0, VFTable2),
    VFTable1 != VFTable2,
    Method1 < Method2,
    not vfTableWrite(_, Method1, 0, VFTable2),
    not vfTableWrite(_, Method2, 0, VFTable1).                               % rules.pl:3123

% reasonNOTMergeClasses_F: same derived class has two bases at different offsets — they cannot merge.
% Symmetric: both witnesses from derivedClass under the same derived class.
% Counterpart: reasonNOTMergeClasses_F (rules.pl:3158)
%!trace_rule {"% and % must NOT be merged because % has them as bases at different offsets % and %", W1, W2, DC1, Offset1, Offset2}
-mergeClasses(W1, W2) :-
    derivedClass(DC1, W1, Offset1),
    derivedClass(DC2, W2, Offset2),
    &sameClass(DC1, DC2),
    Offset1 != Offset2,
    W1 < W2.                                                                 % rules.pl:3158

% reasonNOTMergeClasses_C: any method called by both derived and base belongs to base,
% not derived — so derived class and that method's class cannot merge.
% Witness: DC (derived), BC (base from derivedClass). DC2 ~ DC, BC2 ~ BC via &sameClass.
% Counterpart: reasonNOTMergeClasses_C / _C_asymmetric (rules.pl:3090, 3111)
%!trace_rule {"% and % cannot merge because method % is called by both derived % and base %", DC, Method, Method, DC, BC}
reasonNOTMergeClassesCAsymmetric(DC, Method) :-
    derivedClass(DC, BC, _ObjectOffset),
    classCallsMethod(DC2, Method), &sameClass(DC, DC2),
    classCallsMethod(BC2, Method), &sameClass(BC, BC2).

% reasonNOTMergeClasses_I: RTTI says two TDAs map to different classes.
% Symmetric: both witnesses from rTTITDA2Class for different TDAs.
% Counterpart: reasonNOTMergeClasses_I (rules.pl:3196)
%!trace_rule {"% and % must NOT be merged because RTTI TDAs % and % map to different classes", W1, W2, TDA1, TDA2}
-mergeClasses(W1, W2) :-
    rTTIEnabledAndValid,
    rTTITDA2Class(TDA1, W1),
    rTTITDA2Class(TDA2, W2),
    TDA1 != TDA2,
    W1 < W2.                                                                 % rules.pl:3196

% reasonNOTMergeClasses_K: methods with conflicting symbol class names cannot merge.
% Symmetric: both methods from symbolClass.
% Counterpart: reasonNOTMergeClasses_K (rules.pl:3222)
%!trace_rule {"% and % must NOT be merged because symbol class names % and % conflict", Method1, Method2, ClassName1, ClassName2}
-mergeClasses(Method1, Method2) :-
    symbolClass(Method1, _MangledName1, ClassName1, _MethodName1),
    symbolClass(Method2, _MangledName2, ClassName2, _MethodName2),
    ClassName1 != ClassName2,
    Method1 < Method2.                                                       % rules.pl:3222

% Asymmetric not-merge signals — bodies contribute to notMergeUnsorted in natural
% variable order; two canonical rules at the bottom emit -mergeClasses(min, max).

notMergeUnsorted(DC, Method) :- reasonNOTMergeClassesCAsymmetric(DC, Method).      % rules.pl:3111

% reasonNOTMergeClasses_J: classes in a composition/inheritance relationship cannot merge.
% Witness: (X, Y) from classRelationship (transitive over objectInObject via &sameClass join).
% Counterpart: reasonNOTMergeClasses_J (rules.pl:3212)
%!trace_rule {"% and % must NOT be merged because % is composed of or derived from %", X, Y, X, Y}
notMergeUnsorted(X, Y) :- classRelationship(X, Y).                                  % rules.pl:3212

% reasonNOTMergeClasses_R: If a derived class calls a method that installs the
% derived class' vftable, the called method cannot be on the base class.
% Witness: DC (derived), BC (base from derivedClass).
% Counterpart: reasonNOTMergeClasses_R (rules.pl:3366)
%!trace_rule {"% and % must NOT be merged because method % called by derived % writes its vftable at offset %", BC, CalledMethod, CalledMethod, DC1, Offset}
notMergeUnsorted(BC, CalledMethod) :-
    classCallsMethod(DC1, CalledMethod),
    not purecall(CalledMethod),
    derivedClass(DC2, BC, Offset),
    &sameClass(DC1, DC2),
    vfTableWrite(_Insn, CalledMethod, Offset, V),
    &sameClass(V, DC1).                                                             % rules.pl:3366

% reasonNOTMergeClasses_Q: methods without a symbol for a known class name
% cannot merge with methods whose symbol identifies that class.
% Counterpart: reasonNOTMergeClasses_Q (rules.pl:3352)
%!trace_rule {"% and % must NOT be merged because % lacks a symbol for the class name %", MethodWithSymbol, OtherMethod, OtherMethod, ClassName}
notMergeUnsorted(MethodWithSymbol, OtherMethod) :-
    symbolClass(MethodWithSymbol, _MangledName1, ClassName, _MethodName1),
    method(MethodWithSymbol),
    ClassName != type_info,
    method(OtherMethod),
    not symbolClass(OtherMethod, _, ClassName, _).                                  % rules.pl:3352

% Canonical -mergeClasses for all asymmetric signals: two rules cover both orderings.
-mergeClasses(A, B) :- notMergeUnsorted(A, B), A < B.
-mergeClasses(A, B) :- notMergeUnsorted(B, A), A < B.

% A not-merge fact forbids direct or transitive same-class membership.  This is
% bounded by existing -mergeClasses/2 atoms; it does not generate all pairs.
:- -mergeClasses(A, B), &sameClass(A, B).

% ============================================================
% GUESS
% ============================================================

% guessMergeClasses_B: vftable writer may be on the same class as vftable entries.
% Asymmetric: Writer from vfTableWrite, Entry from vfTableEntry.
%!trace_rule {"% and % are strong merge candidates because method % installs vftable % that contains entry %", A, B, Writer, VFTable, Entry}
strongMergeCandidateUnsorted(Writer, Entry) :-
    vfTableWrite(_Insn, Writer, _ObjectOffset, VFTable),
    vfTableEntry(VFTable, _VFTableOffset, Entry),
    not purecall(Entry).                                                     % guess.pl:1050

strongMergeCandidate(A, B) :- strongMergeCandidateUnsorted(A, B), A < B.
strongMergeCandidate(A, B) :- strongMergeCandidateUnsorted(B, A), A < B.

% guessMergeClasses_D: methods writing the same vftable at the same offset may be the same class.
% Symmetric: both methods from vfTableWrite for the same VFTable and ObjectOffset.
%!trace_rule {"% and % are strong merge candidates because they both write vftable % at offset %", Method1, Method2, VFTable, ObjectOffset}
strongMergeCandidate(Method1, Method2) :-
    vfTableWrite(_Insn1, Method1, ObjectOffset, VFTable),
    vfTableWrite(_Insn2, Method2, ObjectOffset, VFTable),
    Method1 < Method2.                                                       % guess.pl:1215

mergeCandidate(A, B) :- strongMergeCandidate(A, B).

% guessLateMergeClasses_G2: class-related method is a weak merge candidate
% when not purecall and not known virtual.
% Asymmetric: conditions on Y (second argument of classRelatedMethod).
% Counterpart: guessLateMergeClasses_G2 / _G1 (guess.pl:923, 879)
weakMergeCandidateUnsorted(X, Y) :-
    classRelatedMethod(X, Y),
    not purecall(Y),
    not knownVirtualMethod(Y).

weakMergeCandidate(A, B) :- weakMergeCandidateUnsorted(A, B), A < B.
weakMergeCandidate(A, B) :- weakMergeCandidateUnsorted(B, A), A < B.

mergeCandidate(A, B) :- weakMergeCandidate(A, B).

% guessMergeClasses: choose merge or not-merge for each candidate pair.
%!trace_rule {"guess whether % and % are the same class or not", A, B}
1 { mergeClasses(A, B); -mergeClasses(A, B) } 1 :-
    guessEnabled(merge),
    mergeCandidate(A, B).                                                   % guess.pl:1084
% Heuristic disabled so we get an initial model faster
%#heuristic mergeClasses(A, B) : mergeCandidate(A, B). [1@1, true]

% ============================================================
% REWARDS
% ============================================================

% Optimization reward for confirmed strong merges (priority @2).
strongMergeReward(M1, M2) :- mergeClasses(M1, M2), strongMergeCandidate(M1, M2).

#maximize { 10@0, merge, M1, M2 : strongMergeReward(M1, M2) }.

% Base G2 reward: prefer weak merges when chosen.
weakMergeReward(M1, M2) :- mergeClasses(M1, M2), weakMergeCandidate(M1, M2).
#maximize { 1@0, weak_merge, M1, M2 : weakMergeReward(M1, M2) }.

% G1 constructor bonus: extra reward when either side's class has a constructor.
% Uses &sameClass to check class membership at solver time.
% Counterpart: guessLateMergeClasses_G1 constructor condition (guess.pl:879)
weakG1Bonus(M1, M2) :-
    guessEnabled(weak_g1_bonus),
    mergeClasses(M1, M2), weakMergeCandidate(M1, M2),
    constructor(Ctor), &sameClass(M1, Ctor).
weakG1Bonus(M1, M2) :-
    guessEnabled(weak_g1_bonus),
    mergeClasses(M1, M2), weakMergeCandidate(M1, M2),
    constructor(Ctor), &sameClass(M2, Ctor).
#maximize { 2@0, weak_g1, M1, M2 : weakG1Bonus(M1, M2) }.

% Disabled for now: this non-Prolog adjacency reward grounds a quadratic
% aggregate over large method domains (for example mysql.exe.lp).
%
% regularMethod(M) :- method(M), not constructor(M).
%
% nextRegularMethod(M1, M2) :-
%     regularMethod(M1),
%     M2 = #min{ M3 : regularMethod(M3), M3 > M1 }.
%
% adjacentMethodCandidate(M1, M2) :- nextRegularMethod(M1, M2).
%
% #maximize { 1@0, adjacent, M1, M2 : mergeClasses(M1, M2), adjacentMethodCandidate(M1, M2) }.
% #heuristic mergeClasses(A, B) : mergeCandidate(A, B), adjacentMethodCandidate(A, B). [1@0, true]

%!NOshow_trace mergeClasses(A, B).
%!NOshow_trace -mergeClasses(A, B).
%!trace {"% and % should be merged", A, B} mergeClasses(A, B).

#show mergeClasses/2.
