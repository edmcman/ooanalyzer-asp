% Minimal example: two methods share the same symbolClass.
% The hard merge rule derives mergeClasses via raw method IDs (not find/2),
% so the self-defeating loop is avoided. Result: SAT with merged class.

possibleMethod(1000).
possibleMethod(1100).
symbolClass(1000, none, "Foo", none).
symbolClass(1100, none, "Foo", none).
