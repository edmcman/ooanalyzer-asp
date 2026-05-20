% ============================================================
% SANITY CHECKS
%
% Normal mode (default):   clingo ooanalyzer.lp ...
% Diagnostic mode:         clingo --const diagnose=1 ooanalyzer.lp ...
%   -> violate(Tag, Witness) atoms in the model show which constraints fire.
% ============================================================

#const diagnose = 0.
diagnosing :- diagnose != 0.

% ----------------------------------------------------------------
% insanity/2: all conditions that must be false in every valid model.
%
% Each rule here is one line.  The dispatch at the bottom converts them
% into either hard constraints or soft violate atoms depending on the mode.
% ----------------------------------------------------------------

% insanityVirtualConstructor: constructors cannot appear in vftables
insanity(vc, M) :- factConstructor(M), factVFTableEntry(_, _, M).                      % Counterpart: insanityConstructorInVFTable (insanity.pl:48)

% insanityDoubleDuty: method cannot be both constructor and destructor
insanity(dd_cr, M) :- factConstructor(M), factRealDestructor(M).                       % Counterpart: insanityConstructorAndRealDestructor (insanity.pl:226)
insanity(dd_cd, M) :- factConstructor(M), factDeletingDestructor(M).                   % Counterpart: insanityConstructorAndDeletingDestructor (insanity.pl:240)

% insanityContradictoryNOTConstructor
insanity(nc, M) :- factConstructor(M), factNOTConstructor(M).                          % Counterpart: insanityConstructorAndNotConstructor (insanity.pl:214)

% insanityMultipleRealDestructors: at most one real destructor per class
insanity(mrd, (D1,D2)) :- factRealDestructor(D1), factRealDestructor(D2), D1 < D2,    % Counterpart: insanityTwoRealDestructorsOnClass (insanity.pl:253)
                           find(D1, C), find(D2, C).

% insanityVFTables: a vftable cannot be shared by two classes at the same offset
insanity(vft2c, (M1,M2)) :- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2,  % Counterpart: insanityVFTableOnTwoClasses (insanity.pl:18)
                             find(M1, C1), find(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same offset -> different classes
insanity(vft_diff, (M1,M2)) :- factVFTableWrite(M1, Off, V1), factVFTableWrite(M2, Off, V2),      % Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
                                M1 != M2, V1 != V2, find(M1, C), find(M2, C).

% VFTable entries must resolve to real methods
insanity(nomethod, M) :- factVFTableEntry(_, _, M), not factMethod(M).                  % Counterpart: reasonMethod_* (A-P) enforcement

% insanityObjectCycle: circular inheritance is impossible
insanity(cycle, (A,B)) :- factDerivedClass(A, B, _), factDerivedClass(B, A, _).        % Counterpart: insanityObjectCycle (insanity.pl:162)

% insanityContradictoryMerges: reasonMergeClasses and reasonNOTMergeClasses must not conflict.
% Prolog only checks direct conflicts, not transitive sameClass -- same here.
% Do NOT add a transitive sameClass variant -- it is stronger than Prolog and causes UNSAT.
insanity(merge_req, (M1,M2)) :- reasonMergeClasses(M1, M2), not mergeClasses(M1, M2).    % Counterpart: insanityContradictoryMerges (insanity.pl:271)
insanity(not_merge, (M1,M2)) :- reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2).     % Counterpart: insanityContradictoryMerges (insanity.pl:271)

% A derived vftable must be at least as large as the base vftable it overwrites.
insanity(vftsz, (Vb,Vd)) :- factVFTableOverwrite(_, _, Vb, Vd),                        % Counterpart: insanityBaseVFTableLarger (insanity.pl:196)
                             factVFTableSizeGTE(Vb, Sb), factVFTableSizeGTE(Vd, Sd), Sd < Sb.

% ----------------------------------------------------------------
% Dispatch: hard constraint (normal) or soft violate (diagnostic).
% ----------------------------------------------------------------
:- not diagnosing, insanity(_, _).
violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).
#show violate/2.
