% strong_negation_absence.lp
% Purpose: absence-vs-contrary check for methods.
% Expected:
%   - SAT/OPTIMUM
%   - emits factNOTMethod(9000)
%   - does not emit -factMethod(9000) (no signed method-negation channel exists)

possibleMethod(9000).
