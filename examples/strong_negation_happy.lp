% strong_negation_happy.lp
% Purpose: minimal signed-negation happy path for constructor contrary evidence.
% Expected:
%   - SATISFIABLE (exit 10; this minimal fixture has no optimization objective)
%   - emits -factConstructor(100)
%   - does not emit factConstructor(100)

symbolProperty(100, realDestructor).
