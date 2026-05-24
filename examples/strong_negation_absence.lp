% strong_negation_absence.lp
% Purpose: absence-vs-contrary check for methods.
% Expected:
%   - SATISFIABLE (no guess-triggering facts; no optimization objective)
%   - derives -factMethod(9000) internally
%   - does not emit factMethod(9000)

possibleMethod(9000).

:- not -factMethod(9000).
:- factMethod(9000).
