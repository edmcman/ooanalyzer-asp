% strong_negation_happy.lp
% Purpose: minimal signed-negation happy path for constructor contrary evidence.
% Expected:
%   - SATISFIABLE (exit 10; this minimal fixture has no optimization objective)
%   - derives -factConstructor(100) internally
%   - does not emit factConstructor(100)

symbolProperty(100, realDestructor).

:- not -factConstructor(100).
:- factConstructor(100).
