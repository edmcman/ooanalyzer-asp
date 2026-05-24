% strong_negation_contradiction.lp
% Purpose: minimal reachable sanity conflict for diagnostic mode.
% Expected:
%   - normal mode: UNSATISFIABLE (two real destructors forced into one class)
%   - --const diagnose=1: OPTIMUM FOUND with violate(insanityTwoRealDestructorsOnClass, ...)
%     and violate(insanityContradictoryMerges, ...)

symbolProperty(1300, realDestructor).
symbolProperty(1400, realDestructor).
symbolClass(1300, classA).
symbolClass(1400, classA).
