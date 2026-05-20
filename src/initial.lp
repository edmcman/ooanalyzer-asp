% ============================================================
% INITIAL DERIVATIONS -- map full-arity OOAnalyzer facts to the
% simplified predicates expected by the prototype rules.
% Counterpart: pharos/share/prolog/oorules/initial.pl
% ============================================================

% ----------------------------------------------------------------
% Pointer size from fileInfo
% ----------------------------------------------------------------
ptrSize(ArchBytes) :- fileInfo(_, _, _, ArchBytes).

% ----------------------------------------------------------------
% possibleVFTableWrite / possibleVBTableWrite projections
% Drop instruction, this-pointer, and expanded-this-pointer.
% Counterpart: initial.pl:13-16
% ----------------------------------------------------------------
possibleVFTableWrite(M, Off, V) :- possibleVFTableWrite(_, M, _, Off, _, V).
possibleVBTableWrite(M, Off, V) :- possibleVBTableWrite(_, M, _, Off, _, V).

% ----------------------------------------------------------------
% possibleVFTableEntry: recursive walk over initialMemory starting
% at each confirmed VFTable pointer.  Stops at VFTable overwrites.
% Counterpart: initial.pl:38-57
% ----------------------------------------------------------------
vftableWriteAtAddress(Address) :- possibleVFTableWrite(_, _, _, _, _, Address).

possibleVFTableEntry(VFTable, 0, Entry) :-
    initialMemory(VFTable, Entry),
    not vftableWriteAtAddress(VFTable).

possibleVFTableEntry(VFTable, NewOffset, Entry) :-
    possibleVFTableEntry(VFTable, Offset, _),
    ptrSize(PtrSize),
    NewOffset = Offset + PtrSize,
    Address = VFTable + NewOffset,
    not vftableWriteAtAddress(Address),
    initialMemory(Address, Entry),
    Entry > 0x1000.

% ----------------------------------------------------------------
% possibleVBTableEntry: recursive walk over initialMemory starting
% at each confirmed VBTable pointer.  Stops at VBTable overwrites.
% Counterpart: initial.pl:59-71
% ----------------------------------------------------------------
vbtableWriteAtAddress(Address) :- possibleVBTableWrite(_, _, _, _, _, Address).

possibleVBTableEntry(VBTable, 0, Value) :-
    initialMemory(VBTable, Value),
    not vbtableWriteAtAddress(VBTable).

possibleVBTableEntry(VBTable, NewOffset, Value) :-
    possibleVBTableEntry(VBTable, Offset, _),
    ptrSize(PtrSize),
    NewOffset = Offset + PtrSize,
    Address = VBTable + NewOffset,
    not vbtableWriteAtAddress(Address),
    initialMemory(Address, Value).

% ----------------------------------------------------------------
% possibleVFTableOverwrite: a constructor writes two different
% vftables at the same object offset.
% Counterpart: initial.pl:383-389
% ----------------------------------------------------------------
possibleVFTableOverwrite(M, Off, V1, V2) :-
    possibleVFTableWrite(I1, M, _, Off, _, V1),
    possibleVFTableWrite(I2, M, _, Off, _, V2),
    I1 < I2.

% ----------------------------------------------------------------
% callTarget: drop instruction address.
% Counterpart: N/A (Clingo-specific projection)
% ----------------------------------------------------------------
callTarget(Caller, Callee) :- callTarget(_, Caller, Callee).

% ----------------------------------------------------------------
% callsDelete: extract the function from insnCallsDelete.
% Counterpart: N/A (Clingo-specific projection)
% ----------------------------------------------------------------
callsDelete(M) :- insnCallsDelete(_, M, _).

% ----------------------------------------------------------------
% symbolClass: drop mangled name and method name.
% Counterpart: N/A (Clingo-specific projection)
% ----------------------------------------------------------------
symbolClass(M, Class) :- symbolClass(M, _, Class, _).

% ----------------------------------------------------------------
% rTTICompleteObjectLocator: vftable = pointer + ptrSize.
% Counterpart: rTTITDA2VFTable (rtti.pl:18-23)
% ----------------------------------------------------------------
rTTICompleteObjectLocator(V, TDA) :-
    rTTICompleteObjectLocator(Pointer, _, TDA, _, _, _),
    ptrSize(PtrSize),
    V = Pointer + PtrSize.

% ----------------------------------------------------------------
% rTTITypeDescriptor: drop VFTable check and demangled name.
% Counterpart: N/A (Clingo-specific projection)
% ----------------------------------------------------------------
rTTITypeDescriptor(TDA, Name) :- rTTITypeDescriptor(TDA, _, Name, _).

% ----------------------------------------------------------------
% rTTIInheritsFrom: non-virtual inheritance from RTTI descriptors.
% Counterpart: rTTIInheritsFrom/6 (rtti.pl:131-134) with P=0xffffffff, V=0.
%
% NOTE: This requires rTTIClassHierarchyDescriptor/3 with its
% BaseClasses list expanded into individual facts by the preprocessor.
% ----------------------------------------------------------------
rTTIInheritsFrom(DerivedTDA, BaseTDA, Offset) :-
    rTTICompleteObjectLocator(_, _, DerivedTDA, CHDA, _, _),
    rTTIClassHierarchyDescriptor(CHDA, _, BCDA),
    rTTIBaseClassDescriptor(BCDA, BaseTDA, _, Offset, _, _, _, CHDA),
    DerivedTDA != BaseTDA.

% ----------------------------------------------------------------
% callAtOffset: derived from callTarget + thisPtrOffset + thunk.
% Counterpart: methodCallAtOffset (initial.pl:175-191)
%
% NOTE: This is a simplified version. Full OOAnalyzer also uses
% thisPtrDefinition/4 and funcParameter/callParameter matching.
% ----------------------------------------------------------------
callAtOffset(Caller, Callee, Off) :-
    callTarget(_, Caller, Thunk),
    dethunk(Thunk, Callee),
    thisPtrOffset(_, Off, _).
