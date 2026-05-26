% ============================================================
% RULES
% ============================================================

#defined objectInObject/3.

% objectInObject/3 is closed over sameClass/2 at its defining rules, so
% classRelationship/2 only needs to compute reachability over objectInObject.

% reasonClassRelationship_internal: direct object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    objectInObject(DerivedClass, BaseClass, _Offset).                    % rules.pl:2114

% reasonClassRelationship_internal: transitive object composition/inheritance.
classRelationship(DerivedClass, BaseClass) :-
    classRelationship(DerivedClass, MiddleClass),
    objectInObject(MiddleClass, BaseClass, _Offset).                     % rules.pl:2119
