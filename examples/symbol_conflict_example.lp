% symbol_conflict_example.lp
% Purpose: methods with different symbol class names cannot merge.
% Expected:
%   - SATISFIABLE
%   - -mergeClasses(1000,2000)

symbolClass(1000, none, classA, methodA).
symbolClass(2000, none, classB, methodB).

#show -mergeClasses/2.
