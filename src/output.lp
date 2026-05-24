% ============================================================
% OUTPUT
% ============================================================

#show find/2.
#show classRep/1.
#show mergeClasses/2.
#show factMethod/1.
#show factNOTMethod/1.  % Legacy unconfirmed possible methods; not strong negation.
#show factClassHasNoBase/1.

% Intentional signed output:
% -factConstructor/1, -factRealDestructor/1, and -factDeletingDestructor/1
% are explicit contrary evidence. factNOTMethod/1 stays as legacy status output.
% No signed embedded-object predicate is shown because Task 8 removed that family.
#show factConstructor/1.
#show -factConstructor/1.
#show factRealDestructor/1.
#show -factRealDestructor/1.
#show factDeletingDestructor/1.
#show -factDeletingDestructor/1.
#show factVFTable/1.
#show factVFTableWrite/3.
#show factVFTableOverwrite/4.
#show factVFTableBelongsToClass/3.
#show factVFTableEntry/3.
#show factDerivedClass/3.
#show factEmbeddedObject/3.
#show factVBTable/1.
#show factVBTableWrite/3.
#show factVBTableEntry/3.
