% strong_negation_contradiction.lp
% Purpose: minimal reachable sanity conflict for diagnostic mode.
% Expected:
%   - normal mode: UNSATISFIABLE (two real destructors forced into one class)
%   - --const diagnose=1: SATISFIABLE with violate(insanityTwoRealDestructorsOnClass,...)
%     because the conflict is semantic (caught by insanity/2), not a signed p/-p clash

symbolProperty(1300, realDestructor).
symbolProperty(1400, realDestructor).
symbolClass(1300, none, classA, none).
symbolClass(1400, none, classA, none).
