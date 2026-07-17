% reasonNOTMergeClasses_O: a called method accessing beyond the caller class's
% known upper bound cannot belong to the caller class.

classSizeLTE(1000, 4).
classCallsMethod(1000, 2000).
method(2000).
methodMemberAccess(1, 2000, 8, 4).

#show -mergeClasses/2.
