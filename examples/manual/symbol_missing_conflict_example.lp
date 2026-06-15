% symbol_missing_conflict_example.lp
% Purpose: a method without a matching class symbol cannot merge with a
% symbol-identified class method, except for the special type_info case.
% Expected:
%   - SATISFIABLE
%   - -mergeClasses(1000,2000)
%   - no -mergeClasses(3000,4000)

symbolClass(1000, none, classA, methodA).
symbolProperty(2000, realDestructor).

symbolClass(3000, none, type_info, methodT).
symbolProperty(4000, realDestructor).

#show -mergeClasses/2.
