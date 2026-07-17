% reasonMethod_K: callees receiving the same object pointer are methods when
% one callee is already proven to be a method.

symbolClass(1000, "known", "Example", "knownMethod").
thisPtrUsage(1, 9000, object_ptr, 1000).
thisPtrUsage(2, 9000, object_ptr, 2000).
