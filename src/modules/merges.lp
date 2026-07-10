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

% reasonMergeClasses_B: a method in the vftable of a no-base class must be on
% that class — it cannot belong to a base, because there is none.
% Witness-only head: BaseVFTable ~ BaseClass (findVFTable, i.e. vftable in its
% class), Method ~ MethodClass, so mergeClasses(BaseVFTable, Method) induces the
% same partition as merging BaseClass with MethodClass.
% not reusedImplementation(Method) guards against a shared method pulled into the
% wrong class (see reasonReusedImplementation_B in vftables.lp).
% Counterpart: reasonMergeClasses_B (rules.pl:2792)
%!trace_rule {"% and % are the same class because method % is in vftable % of a no-base class", BaseVFTable, Method, Method, BaseVFTable}
reasonMergeClassesBUnsorted(BaseVFTable, Method) :-
    vfTable(BaseVFTable),
    classHasNoBase(NoBase),
    &sameClass(BaseVFTable, NoBase),
    methodInVFTable(BaseVFTable, _Offset, Method),
    not reusedImplementation(Method).                                         % rules.pl:2792

mergeClasses(A, B) :- reasonMergeClassesBUnsorted(A, B), A < B.
mergeClasses(A, B) :- reasonMergeClassesBUnsorted(B, A), A < B.

% reasonMergeClasses_C: when a class with no base and no object at offset zero
% calls a method whose class has the same properties, the method belongs to the
% caller class. Both Class and Method are concrete witnesses; classHasNoBase
% and classHasInnerAtZero are joined to their induced classes through
% &sameClass (the latter join is defined in classes.lp).
% Counterpart: reasonMergeClasses_C (rules.pl:2822)
%!trace_rule {"% and % are the same class because % calls % and both classes have no base or object at offset zero", Class, Method, Class, Method}
reasonMergeClassesCUnsorted(Class, Method) :-
    classCallsMethod(Class, Method),
    not purecall(Method),
    classHasNoBase(NoBase1),
    &sameClass(Class, NoBase1),
    not classHasInnerAtZero(Class),
    classHasNoBase(NoBase2),
    &sameClass(Method, NoBase2),
    not classHasInnerAtZero(Method).                                      % rules.pl:2822

mergeClasses(A, B) :- reasonMergeClassesCUnsorted(A, B), A < B.
mergeClasses(A, B) :- reasonMergeClassesCUnsorted(B, A), A < B.

% reasonMergeClasses_H: an entry beyond the sole base class primary vftable
% belongs to the derived class.  Preserve the Prolog VOffset > BaseSize test;
% vfTableSize is the ASP exact-size replacement for the Prolog LTE fact.
% findVFTable/2 preserves Prolog findVFTable(VFTable, Offset, Class), with the
% vftable itself serving as the concrete class witness.
% Counterpart: reasonMergeClasses_H (rules.pl:2895)
derivedClassHasOtherBase(Derived, Base) :-
    derivedClass(Derived, Base, _ObjectOffset),
    derivedClass(Derived2, OtherBase, _OtherOffset),
    &sameClass(Derived, Derived2),
    not &sameClass(Base, OtherBase).                                      % rules.pl:2905

% vfTableEntryBeyondSize factors the chosen-size comparison out of the main
% rule: joining vfTableSize with vfTableEntry there grounds size-candidates x
% entries per vftable pair (168k ground rules on TinyXml). Every vfTableEntry
% offset comes from possibleVFTableEntry, so that static projection is a safe
% offset domain.
vfTableEntryBeyondSize(VFTable, VOffset) :-
    vfTableSize(VFTable, Size),
    possibleVFTableEntry(VFTable, VOffset, _),
    VOffset > Size.

%!trace_rule {"% and % are the same class because derived vftable % has entry % beyond sole base vftable %", Derived, Method, DerivedVFTable, VOffset, BaseVFTable}
reasonMergeClassesHUnsorted(Derived, Method) :-
    derivedClass(Derived, Base, _ObjectOffset),
    not derivedClassHasOtherBase(Derived, Base),
    findVFTable(DerivedVFTable, 0),
    &sameClass(DerivedVFTable, Derived),
    findVFTable(BaseVFTable, 0),
    % Implied (a table's entries cannot lie beyond its own chosen size);
    % stated only to prune grounding.
    BaseVFTable != DerivedVFTable,
    &sameClass(BaseVFTable, Base),
    vfTableEntryBeyondSize(BaseVFTable, VOffset),
    vfTableEntry(DerivedVFTable, VOffset, Method),
    not purecall(Method),
    not reusedImplementation(Method).                                      % rules.pl:2895

mergeClasses(A, B) :- reasonMergeClassesHUnsorted(A, B), A < B.
mergeClasses(A, B) :- reasonMergeClassesHUnsorted(B, A), A < B.

% reasonMergeClasses_K: if two methods are present on the same object, and
% neither class has a base, the methods must be on the same class.
% Asymmetric: Class1 comes from classRelatedMethod; Method is the related method.
% No-base facts are witness-based, so both sides join through &sameClass.
% Witness-only head: Prolog binds Class2 = find(Method) (functional), so the
% conclusion merges Class1's class with Method's class. Recording the witness
% Method instead of a free classHasNoBase(Class2) head avoids grounding the
% cross product classRelatedMethod x classHasNoBase, which otherwise makes every
% no-base witness (e.g. base vftables) a merge candidate with every related
% method. mergeClasses(Class1, Method) induces the same partition as
% mergeClasses(Class1, find(Method)) since Method is in find(Method)'s class.
% Counterpart: reasonMergeClasses_K (rules.pl:2939)
%!trace_rule {"% and % are the same class because % is related to % and neither class has a base", Class1, Method, Class1, Method}
reasonMergeClassesKUnsorted(Class1, Method) :-
    classRelatedMethod(Class1, Method),
    classHasNoBase(NoBase1),
    &sameClass(Class1, NoBase1),
    classHasNoBase(NoBase2),
    &sameClass(Method, NoBase2).                                             % rules.pl:2939

mergeClasses(A, B) :- reasonMergeClassesKUnsorted(A, B), A < B.
mergeClasses(A, B) :- reasonMergeClassesKUnsorted(B, A), A < B.

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
% Witness: DC (derived), BC (base from derivedClass). DC2/BC2 are discarded
% once the &sameClass check is made, so each ranges freely over
% classCallsMethod's caller domain, joined only by &sameClass.
% Counterpart: reasonNOTMergeClasses_C / _C_asymmetric (rules.pl:3090, 3111)
%!trace_rule {"% and % cannot merge because method % is called by both derived % and base %", DC, Method, Method, DC, BC}
reasonNOTMergeClassesCAsymmetric(DC, Method) :-
    derivedClass(DC, BC, _ObjectOffset),
    classCallsMethod(DC2, Method),
    classCallsMethod(BC2, Method),
    &sameClass(DC, DC2),
    &sameClass(BC, BC2).

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
% Witness: (X, Y) generated by classRelationshipCand (composition.lp), truth
% decided by the &classRelationship theory atom (containment reachability).
% Counterpart: reasonNOTMergeClasses_J (rules.pl:3212)
%!trace_rule {"% and % must NOT be merged because % is composed of or derived from %", X, Y, X, Y}
notMergeUnsorted(X, Y) :-
    classRelationshipCand(X, Y),
    &classRelationship(X, Y).                                                       % rules.pl:3212

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

% reasonNOTMergeClasses_P: a constructor or destructor called with a positive
% this-pointer offset operates on a subobject, so its class cannot be the
% callers class.  The cardinality body is the Prolog property disjunction;
% deleting destructors retain the real-destructor caller exception.
% Counterpart: reasonNOTMergeClasses_P (rules.pl:3318)
%!trace_rule {"% and % must NOT be merged because % calls constructor/destructor % at positive offset %", Caller, Method, Caller, Method, Offset}
reasonNOTMergeClassesPUnsorted(Caller, Method) :-
    validMethodCallAtOffset(_Insn, Caller, Method, Offset),
    Offset > 0,
    method(Caller),
    method(Method),
    Caller != Method,
    1 {
        constructor(Method);
        deletingDestructor(Method) : not realDestructor(Caller);
        realDestructor(Method)
    }.                                                                            % rules.pl:3318

notMergeUnsorted(Caller, Method) :- reasonNOTMergeClassesPUnsorted(Caller, Method).

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

weakMergeCandidate(A, B) :- weakMergeCandidateUnsorted(A, B), A < B, not strongMergeCandidate(A, B).
weakMergeCandidate(A, B) :- weakMergeCandidateUnsorted(B, A), A < B, not strongMergeCandidate(A, B).

mergeCandidate(A, B) :- weakMergeCandidate(A, B).

% guessLateMergeClasses_F2: a method that appears in a vftable already
% associated with a class is a late merge candidate for that class.  Prolog
% restricts this guess to methods that are singleton classes at the point the
% late-guess phase runs.  A literal single-shot ASP encoding is self-defeating:
% selecting the merge would make the method non-singleton and remove its own
% support.  Instead, reward the intended final same-class relationship once per
% method below; this declarative replacement was explicitly approved.
% methodInVFTable preserves the Prolog dethunking and purecall exclusions, and
% the vftable itself is the concrete class witness returned by findVFTable.
% Counterpart: guessLateMergeClassesF2 (guess.pl:842)
%!trace_rule {"% and % are late merge candidates because method % appears in owned vftable %", A, B, Method, VFTable}
lateF2CandidateUnsorted(VFTable, Method) :-
    methodInVFTable(VFTable, _Offset, Method),
    findVFTable(VFTable, _ObjectOffset).

lateF2Candidate(A, B) :- lateF2CandidateUnsorted(A, B), A < B.
lateF2Candidate(A, B) :- lateF2CandidateUnsorted(B, A), A < B.

mergeCandidate(A, B) :- lateF2Candidate(A, B).

% guessMergeClasses: choose merge or not-merge for each candidate pair.
%!trace_rule {"guess whether % and % are the same class or not", A, B}
1 { mergeClasses(A, B); -mergeClasses(A, B) } 1 :-
    guessEnabled(merge),
    mergeCandidate(A, B).                                                   % guess.pl:1084
% Establish a conservative initial partition before optimization: accept the
% strongest vftable-derived evidence first, but initially keep weaker and late
% candidates separate. Objective rewards and learned clauses can still flip
% either phase after the first model.
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    strongMergeCandidate(A, B). [100@2, true]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    weak_merge_input_phase = 0,
    weakMergeCandidate(A, B). [10@1, false]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    weak_merge_input_phase = 1,
    weak_merge_after_vftable_complete = 0,
    weakMergeCandidate(A, B). [10@1, true]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    weak_merge_input_phase = 1,
    weak_merge_after_vftable_complete != 0,
    weakMergeCandidate(A, B),
    not vftableLayerComplete. [10@1, false]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    weak_merge_input_phase = 1,
    weak_merge_after_vftable_complete != 0,
    weakMergeCandidate(A, B),
    vftableLayerComplete. [10@1, true]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    late_merge_input_phase = 0,
    lateF2Candidate(A, B),
    not strongMergeCandidate(A, B),
    not weakMergeCandidate(A, B). [5@1, false]
#heuristic mergeClasses(A, B) :
    enable_input_heuristics != 0,
    late_merge_input_phase = 1,
    lateF2Candidate(A, B),
    not strongMergeCandidate(A, B),
    not weakMergeCandidate(A, B). [5@1, true]

% ============================================================
% REWARDS
% ============================================================

% Optimization reward for confirmed strong merges (priority @2).
strongMergeReward(M1, M2) :- mergeClasses(M1, M2), strongMergeCandidate(M1, M2).

#maximize { 10@0, merge, M1, M2 : strongMergeReward(M1, M2) }.

#heuristic strongMergeReward(M1, M2) :
    enable_reward_heuristics != 0,
    strongMergeCandidate(M1, M2). [10@reward_heuristic_priority, true]

% Base G2 reward: prefer weak merges when chosen.
weakMergeReward(M1, M2) :- mergeClasses(M1, M2), weakMergeCandidate(M1, M2).
#maximize { 8@0, weak_merge, M1, M2 : weakMergeReward(M1, M2) }.

#heuristic weakMergeReward(M1, M2) :
    enable_reward_heuristics != 0,
    weakMergeCandidate(M1, M2). [8@reward_heuristic_priority, true]

% F2 is satisfied by final equivalence-class membership, whether direct or
% transitive.  Keying the objective by Method awards it at most once even when
% the same implementation appears in multiple owned vftables.
lateF2Reward(Method) :-
    lateF2CandidateUnsorted(VFTable, Method),
    &sameClass(VFTable, Method).

#maximize { 8@0, late_f2, Method : lateF2Reward(Method) }.

#heuristic lateF2Reward(Method) :
    enable_reward_heuristics != 0,
    lateF2CandidateUnsorted(_VFTable, Method). [8@reward_heuristic_priority, true]

% guessLateMergeClasses_F1 intentionally has no separate reward.  Its Prolog
% role is to order the F2 candidates whose owning class has no known base; the
% declarative F2 objective does not reproduce that procedural ordering.

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
#maximize { 9@0, weak_g1, M1, M2 : weakG1Bonus(M1, M2) }.

#heuristic weakG1Bonus(M1, M2) :
    enable_reward_heuristics != 0,
    weakMergeCandidate(M1, M2). [9@reward_heuristic_priority, true]

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
