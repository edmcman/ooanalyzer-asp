% ============================================================
% OUTPUT
% ============================================================

#show find/2.
#show classRep/1.
#show mergeClasses/2.
#show factMethod/1.
#show factClassHasNoBase/1.

% Intentional signed output:
% -factVFTable/1, -factVBTable/1, and -mergeClasses/2 are explicit
% decision/must-not evidence. Noisy classification negatives remain internal.
% No signed embedded-object predicate is shown because Task 8 removed that family.
#show factConstructor/1.
#show factRealDestructor/1.
#show factDeletingDestructor/1.
#show -mergeClasses/2.
#show factVFTable/1.
#show -factVFTable/1.
#show factVFTableWrite/3.
#show factVFTableOverwrite/4.
#show factVFTableBelongsToClass/3.
#show factVFTableEntry/3.
#show factDerivedClass/3.
#show factEmbeddedObject/3.
#show factVBTable/1.
#show -factVBTable/1.
#show factVBTableWrite/3.
#show factVBTableEntry/3.
