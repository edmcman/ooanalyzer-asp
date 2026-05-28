% Xclingo trace annotations (disabled by default).
% Include this file to re-enable detailed trace output:
%   #include "src/util/show_trace.lp".

% ctorsdtors module (5 lines)
%!show_trace constructor(M).
%!show_trace realDestructor(M).
%!show_trace deletingDestructor(M).
%!show_trace -constructor(M).
%!show_trace -deletingDestructor(M).

% vftables module (5 lines)
%!show_trace vfTable(V).
%!show_trace vfTableEntry(V, Off, E).
%!show_trace vfTableWrite(I, M, Off, V).
%!show_trace vfTableOverwrite(M, V1, V2, Off).
%!show_trace -vfTableEntry(V, Off, E).

% methods module (1 line)
%!show_trace method(M).

% composition module (6 lines)
%!show_trace derivedClass(Outer, Inner, Off).
%!show_trace embeddedObject(Outer, Inner, Off).
%!show_trace objectInObject(Outer, Inner, Off).
%!show_trace classRelationship_closed(A, B).
%!show_trace classHasNoBase(V).
%!show_trace classHasNoDerived(V).

% classes module (1 line)
%!show_trace classCallsMethod(V, M).

% size module (1 line)
%!show_trace vfTableSize(V, S).

% merges module (3 lines, kept as NOshow_trace)
%!NOshow_trace sameClass(A, B).
%!NOshow_trace mergeClasses(A, B).
%!NOshow_trace -mergeClasses(A, B).
