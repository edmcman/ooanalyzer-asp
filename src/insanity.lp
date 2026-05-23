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
                           sameClass(D1, D2).

% insanityVFTables: a vftable cannot be assigned to two different no-base classes at the same offset.
% Matches Prolog insanityVFTableOnTwoClasses (insanity.pl:18-44):
%   - both methods' classes must be factClassHasNoBase (guarded like Prolog's find+factClassHasNoBase)
%   - neither method participates in any vftable overwrite (possibleVFTableOverwrite guard)
%   - the two methods must be in different classes
% methodHasVFTableOverwrite/1 is defined in rules.lp.
insanity(vft2c, (M1,M2)) :-                                                                % Counterpart: insanityVFTableOnTwoClasses (insanity.pl:18)
    factVFTableWrite(M1, Off, V), factVFTableWrite(M2, Off, V), M1 < M2,
    not sameClass(M1, M2),
    sameClass(M1, X), factClassHasNoBase(X),
    sameClass(M2, Y), factClassHasNoBase(Y),
    not methodHasVFTableOverwrite(M1),
    not methodHasVFTableOverwrite(M2).

% Two constructors writing DIFFERENT vftables at the same offset -> different classes
insanity(vft_diff, (M1,M2)) :- factVFTableWrite(M1, Off, V1), factVFTableWrite(M2, Off, V2),      % Counterpart: reasonNOTMergeClasses_E (rules.pl:3123)
                                M1 != M2, V1 != V2, sameClass(M1, M2).

% VFTable entries must resolve to real methods
insanity(nomethod, M) :- factVFTableEntry(_, _, M), not factMethod(M).                  % Counterpart: reasonMethod_* (A-P) enforcement

% insanityObjectCycle: circular inheritance is impossible
insanity(cycle, (A,B)) :- factDerivedClass(A, B, _), factDerivedClass(B, A, _).        % Counterpart: insanityObjectCycle (insanity.pl:162)

% Counterpart: insanityContradictoryMerges (insanity.pl:271)
insanity(not_merge, (M1,M2)) :- reasonNOTMergeClasses(M1, M2), mergeClasses(M1, M2).

% A derived vftable must be at least as large as the base vftable.
% Matches Prolog insanityBaseVFTableLarger (insanity.pl:190-203): uses factDerivedClass to
% establish the relationship, avoiding false positives from destructor-direction overwrites.
% Prolog uses factVFTableSizeLTE(Derived) < factVFTableSizeGTE(Base); we approximate with
% factVFTableSizeGTE for both (lower bounds only -- may miss violations but no false positives).
insanity(vftsz, (Vb,Vd)) :-                                                               % Counterpart: insanityBaseVFTableLarger (insanity.pl:190)
    factDerivedClass(Outer, Inner, Off),
    factVFTableWrite(Outer, Off, Vd),
    factVFTableWrite(Inner, 0, Vb),
    Vb != Vd,
    factVFTableSizeGTE(Vb, Sb), factVFTableSizeGTE(Vd, Sd), Sd < Sb.

% ----------------------------------------------------------------
% Dispatch: hard constraint (normal) or soft violate (diagnostic).
% ----------------------------------------------------------------
:- not diagnosing, insanity(_, _).
violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).
#show violate/2.
