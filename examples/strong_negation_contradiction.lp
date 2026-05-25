% strong_negation_contradiction.lp
% Purpose: minimal reachable sanity conflict for diagnostic mode.
% Expected:
%   - normal mode: UNSATISFIABLE (two real destructors forced into one class)
%   - --const diagnose=1: UNSATISFIABLE because signed p/-p clashes are
%     Clingo-incoherent before violate/2 atoms can report them

symbolProperty(1300, realDestructor).
symbolProperty(1400, realDestructor).
symbolClass(1300, none, classA, none).
symbolClass(1400, none, classA, none).
