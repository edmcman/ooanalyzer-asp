% Minimal example demonstrating the self-defeating loop with direct mergeClasses derivation.
% Two methods share the same symbolClass. The hard merge rule derives mergeClasses,
% which changes find/2, which invalidates the original derivation.
% Result: UNSAT (no stable model).

possibleMethod(1000).
possibleMethod(1100).
symbolClass(1000, "Foo").
symbolClass(1100, "Foo").
