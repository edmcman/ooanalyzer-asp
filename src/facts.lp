% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes = sets of methods) from binary analysis facts.
%
% Input facts (provided in a separate file):
%   possibleVFTableWrite(M, Off, V)          -- M writes vftable V at object offset Off
%   possibleVFTableEntry(V, Off, E)          -- entry E at offset Off in vftable V (may be thunk)
%   possibleVFTableOverwrite(M, Off, V1, V2) -- M overwrites V1 with V2 at Off (ctor sequence)
%   returnsSelf(M)          -- M returns the this pointer (ECX -> EAX)
%   noCallsBefore(M)        -- no OO calls precede M (constructor hint)
%   noCallsAfter(M)         -- no OO calls follow M (destructor hint)
%   callsDelete(M)          -- M calls delete/free on the this pointer
%   uninitializedReads(M)   -- M reads members before initializing them (NOT-ctor signal)
%   callTarget(Caller, Callee) -- Callee is directly called by Caller
%   callAtOffset(Caller, Callee, Off) -- Callee is called by Caller passing this+Off
%   thunk(Thunk, Target)    -- Thunk is a JMP-only stub; Target is the real function
%   purecall(M)             -- M is a pure-virtual stub (not a real method)
%   symbolClass(M, Class)   -- debug symbol: M belongs to Class
%   symbolProperty(M, Prop) -- Prop \in {constructor, realDestructor, deletingDestructor}
%   rTTICompleteObjectLocator(V, TDA) -- COL at V-8 links vftable V to type descriptor TDA
%   rTTITypeDescriptor(TDA, Name)     -- TDA has mangled type name Name
%   rTTIInheritsFrom(DerivedTDA, BaseTDA, Offset) -- non-virtual base at byte Offset
%   possibleVBTableWrite(M, Off, V)          -- M writes VBTable V at object offset Off
%   possibleVBTableEntry(V, Off, Value)      -- entry Value at offset Off in VBTable V

#defined callTarget/2.
#defined callsDelete/1.
#defined returnsSelf/1.
#defined noCallsBefore/1.
#defined noCallsAfter/1.
#defined uninitializedReads/1.
#defined symbolClass/2.
#defined symbolProperty/2.
#defined possibleVFTableEntry/3.
#defined possibleVFTableWrite/3.
#defined possibleVFTableOverwrite/4.
#defined thunk/2.
#defined purecall/1.
#defined callAtOffset/3.
#defined rTTICompleteObjectLocator/2.
#defined rTTITypeDescriptor/2.
#defined rTTIInheritsFrom/3.
#defined possibleVBTableWrite/3.
#defined possibleVBTableEntry/3.
