% strong_negation_choices.lp
% Purpose: signed exact-choice regression for guessed predicates.
% Expected:
%   - SAT/OPTIMUM
%   - emits -factVFTable(5000)
%   - emits -factVBTable(6000)
%   - emits -mergeClasses(100,200)

possibleMethod(100).
possibleMethod(200).
possibleConstructor(100).
possibleConstructor(200).
returnsSelf(100).
returnsSelf(200).
noCallsBefore(100).
noCallsBefore(200).

callTarget(100, 200).

possibleVFTableWrite(100, 0, 5000).
possibleVBTableWrite(100, 4, 6000).

:- factVFTable(5000).
:- factVBTable(6000).
:- mergeClasses(100, 200).
