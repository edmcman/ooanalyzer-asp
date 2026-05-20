% ============================================================
% SANITY CHECKS
% ============================================================

% insanityVirtualConstructor: constructors cannot appear in vftables
:- factConstructor(M), factVFTableEntry(_, _, M).                         % Counterpart: insanityConstructorInVFTable (insanity.pl:48)

% insanityDoubleDuty: method cannot be both constructor and destructor
:- factConstructor(M), factRealDestructor(M).                           % Counterpart: insanityConstructorAndRealDestructor (insanity.pl:226)
:- factConstructor(M), factDeletingDestructor(M).                         % Counterpart: insanityConstructorAndDeletingDestructor (insanity.pl:240)

% insanityContradictoryNOTConstructor
:- factConstructor(M), factNOTConstructor(M).                               % Counterpart: insanityConstructorAndNotConstructor (insanity.pl:214)

% insanityMultipleRealDestructors: at most one real destructor per class
:- factRealDestructor(D1), factRealDestructor(D2), D1 < D2,            % Counterpart: insanityTwoRealDestructorsOnClass (insanity.pl:253)
   find(D1, C), find(D2, C).

% insanityVFTables: a vftable cannot be shared by two classes at the same offset
:- factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2, % Counterpart: insanityVFTableOnTwoClasses (insanity.pl:18)
   find(M1, C1), find(M2, C2), C1 != C2.

% Two constructors writing DIFFERENT vftables at the same offset -> different classes
:- factVFTableWrite(M1, Off, V1), factVFTableWrite(M2, Off, V2),         % Counterpart: reasonNOTMergeClasses_E (rules.pl:3123) / insanityContradictoryMerges
   M1 != M2, V1 != V2, find(M1, C), find(M2, C).

% VFTable entries must resolve to real methods
:- factVFTableEntry(_, _, M), not factMethod(M).                         % Counterpart: reasonMethod_* (A-P) enforcement

% insanityObjectCycle: circular inheritance is impossible
:- factDerivedClass(A, B, _), factDerivedClass(B, A, _).                  % Counterpart: insanityObjectCycle (insanity.pl:162)

% Prolog's insanityContradictoryMerges only checks direct merge conflicts
% (reasonMergeClasses + reasonNOTMergeClasses), not transitive sameClass.
% The direct conflict is already enforced by:
%   :- reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2).
% in rules.lp.  Do NOT add a transitive sameClass constraint here --
% it is stronger than Prolog and causes UNSAT on real .facts files.

% A derived vftable must be at least as large as the base vftable it overwrites.
:- factVFTableOverwrite(_, _, Vbase, Vderived),                          % Counterpart: insanityBaseVFTableLarger (insanity.pl:196)
   factVFTableSizeGTE(Vbase, Sbase), factVFTableSizeGTE(Vderived, Sderived),
   Sderived < Sbase.
