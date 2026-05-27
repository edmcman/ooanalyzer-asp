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
%!trace_rule {"% and % are the same class because both are bases of % at offset %", A, B, DerivedClass, ObjectOffset}
mergeClasses(A, B) :-
    derivedClass_closed(DerivedClass, Class1, ObjectOffset),
    derivedClass_closed(DerivedClass, Class2, ObjectOffset),
    not sameClass(Class1, Class2),
    sortPair(Class1, Class2, A, B).                                        % rules.pl:2847

% reasonNOTMergeClasses_E: methods writing different vftables at offset 0
% cannot be the same class, unless both cross-write the other's vftable.
% Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
%!trace_rule {"% and % must NOT be merged because they write different vftables % and % at offset 0", A, B, VFTable1, VFTable2}
-mergeClasses(A, B) :-
    vfTableWrite(_Insn1, Method1, 0, VFTable1),
    vfTableWrite(_Insn2, Method2, 0, VFTable2),
    VFTable1 != VFTable2,
    sortPair(Method1, Method2, A, B),
    not sameClass(Method1, Method2),
    not vfTableWrite(_, Method1, 0, VFTable2),
    not vfTableWrite(_, Method2, 0, VFTable1).                              % rules.pl:3123

% reasonNOTMergeClasses_F: same derived class has two bases at different offsets — they cannot merge.
%!trace_rule {"% and % must NOT be merged because % has them as bases at different offsets % and %", A, B, DerivedClass, Offset1, Offset2}
-mergeClasses(A, B) :-
    derivedClass_closed(DerivedClass, Class1, Offset1),
    derivedClass_closed(DerivedClass, Class2, Offset2),
    Offset1 != Offset2,
    sortPair(Class1, Class2, A, B).                                        % rules.pl:3158

% reasonNOTMergeClasses_C: any method called by both derived and base belongs to base,
% not derived — so derived class and that method's class cannot merge.
% Counterpart: reasonNOTMergeClasses_C / _C_asymmetric (rules.pl:3090, 3111)
%!trace_rule {"% and % cannot merge because method % is called by both derived % and base %", DerivedClass, MethodClass, Method, DerivedClass, BaseClass}
reasonNOTMergeClassesCAsymmetric(DerivedClass, MethodClass) :-
    derivedClass_closed(DerivedClass, BaseClass, _ObjectOffset),
    classCallsMethod(DerivedClass, Method),
    classCallsMethod(BaseClass, Method),
    sameClass(Method, MethodClass),
    not sameClass(DerivedClass, MethodClass).

%!trace_rule {"% and % must NOT be merged because a method is called by both derived and base class", A, B}
-mergeClasses(A, B) :-
    reasonNOTMergeClassesCAsymmetric(DerivedClass, MethodClass),
    sortPair(DerivedClass, MethodClass, A, B).                            % rules.pl:3111

% reasonNOTMergeClasses_J: classes in a composition/inheritance relationship cannot merge.
% Counterpart: reasonNOTMergeClasses_J (rules.pl:3212)
%!trace_rule {"% and % must NOT be merged because % is composed of or derived from %", A, B, X, Y}
-mergeClasses(A, B) :-
    classRelationship_closed(X, Y),
    sortPair(X, Y, A, B).                                                % rules.pl:3212

% reasonNOTMergeClasses_I: RTTI says two TDAs map to different classes.
% Counterpart: reasonNOTMergeClasses_I (rules.pl:3196)
%!trace_rule {"% and % must NOT be merged because RTTI TDAs % and % map to different classes", A, B, TDA1, TDA2}
-mergeClasses(A, B) :-
    rTTIEnabledAndValid,
    rTTITDA2Class(TDA1, Class1),
    rTTITDA2Class(TDA2, Class2),
    TDA1 != TDA2,
    not sameClass(Class1, Class2),
    sortPair(Class1, Class2, A, B).                                          % rules.pl:3196

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

% Compact transitive closure over hard merges.
merged(A, B) :- mergeClasses(A, B).
merged(B, A) :- mergeClasses(A, B).

sameClass(A, A) :- mergeEntity(A).
sameClass(A, C) :- sameClass(A, B), merged(B, C).

% ============================================================
% GUESS
% ============================================================

% guessMergeClasses_B: vftable writer may be on the same class as vftable entries.
%!trace_rule {"% and % are strong merge candidates because writer % shares vftable % with entry %", A, B, Writer, VFTable, Entry}
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn, Writer, _ObjectOffset, VFTable),
    vfTableEntry(VFTable, _VFTableOffset, Entry),
    not purecall(Entry),
    sortPair(Writer, Entry, A, B).                                      % guess.pl:1050

% guessMergeClasses_D: methods writing the same vftable at the same offset may be the same class.
%!trace_rule {"% and % are strong merge candidates because they both write vftable % at offset %", A, B, VFTable, ObjectOffset}
strongMergeCandidate(A, B) :-
    vfTableWrite(_Insn1, Method1, ObjectOffset, VFTable),
    vfTableWrite(_Insn2, Method2, ObjectOffset, VFTable),
    Method1 != Method2,
    sortPair(Method1, Method2, A, B).                                   % guess.pl:1215

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

%!show_trace sameClass(A, B).
%!show_trace mergeClasses(A, B).
%!show_trace -mergeClasses(A, B).
%!trace {"% and % are the same class", A, B} sameClass(A, B).
%!trace {"% and % should be merged", A, B} mergeClasses(A, B).
%!trace {"% and % must NOT be merged", A, B} -mergeClasses(A, B).

#show sameClass/2.
