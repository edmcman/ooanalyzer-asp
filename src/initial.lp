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

% Base case 1: from confirmed VFTable writes.
possibleVFTableEntry(VFTable, 0, Entry) :-
    possibleVFTableWrite(_, _, _, _, _, VFTable),
    initialMemory(VFTable, Entry).

% Base case 2: from RTTI Complete Object Locator.
possibleVFTableEntry(VFTable, 0, Entry) :-
    rTTICompleteObjectLocator(Pointer, _, _, _, _, _),
    ptrSize(PtrSize),
    VFTable = Pointer + PtrSize,
    initialMemory(VFTable, Entry).

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
    possibleVBTableWrite(_, _, _, _, _, VBTable),
    initialMemory(VBTable, Value).

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
    rTTIBaseClassDescriptor(BCDA, BaseTDA, _, Offset, 0xffffffff, 0, _, _),  % WhereP=0xffffffff,WhereV=0: non-virtual only; ignore CHDA in BCD (shared BCDs point to their own hierarchy)
    DerivedTDA != BaseTDA.

% ----------------------------------------------------------------
% possibleMethod: at least some evidence that Address is a function.
% Counterpart: initial.pl:78-85
% ----------------------------------------------------------------
possibleMethod(Address) :- callingConvention(Address, _).
possibleMethod(Address) :- thunk(Address, _).
possibleMethod(Address) :- noCallsAfter(Address).
possibleMethod(Address) :- noCallsBefore(Address).
possibleMethod(Address) :- returnsSelf(Address).
possibleMethod(Address) :- purecall(Address).
possibleMethod(Address) :- callTarget(_, Address, _).

% ----------------------------------------------------------------
% possibleConstructor / possibleDestructor
% Counterpart: initial.pl:20-29
% ----------------------------------------------------------------
possibleConstructor(M) :- returnsSelf(M), noCallsBefore(M).
possibleConstructor(M) :- symbolProperty(M, constructor).

possibleDestructor(M) :- noCallsAfter(M).
possibleDestructor(M) :- symbolProperty(M, realDestructor).
possibleDestructor(M) :- symbolProperty(M, deletingDestructor).

% ----------------------------------------------------------------
% thisPtrParam: which parameter carries the this-pointer.
% Counterpart: util.pl:140-160
% ----------------------------------------------------------------
thisPtrParam(Function, ecx) :- callingConvention(Function, "__thiscall").
thisPtrParam(Function, rcx) :- callingConvention(Function, "__x64call").
thisPtrParam(Function, 0)   :- callingConvention(Function, "__sysv32call").
thisPtrParam(Function, rdi) :- callingConvention(Function, "__sysv64call").
thisPtrParam(Function, Param) :-
    callingConvention(Function, "genericthisptr"),
    genericThisPtrABIParam(Param).

genericThisPtrABIParam(ecx) :- fileInfo(_, _, "MSVC_32", _).
genericThisPtrABIParam(ecx) :- fileInfo(_, _, "mSVC_32", _).
genericThisPtrABIParam(rcx) :- fileInfo(_, _, "MSVC_64", _).
genericThisPtrABIParam(rcx) :- fileInfo(_, _, "mSVC_64", _).
genericThisPtrABIParam(rdi) :- fileInfo(_, _, "SYSV_64", _).
genericThisPtrABIParam(rdi) :- fileInfo(_, _, "sYSV_64", _).
genericThisPtrABIParam(0)   :- fileInfo(_, _, "SYSV_32", _).
genericThisPtrABIParam(0)   :- fileInfo(_, _, "sYSV_32", _).

% ----------------------------------------------------------------
% thisParamFuncParameter / thisParamCallParameter
% Counterpart: util.pl:181-192
% ----------------------------------------------------------------
thisParamFuncParameter(Function, ThisPtr) :-
    thisPtrParam(Function, Param),
    funcParameter(Function, Param, ThisPtr).

thisParamCallParameter(Insn, CallerFunc, Callee, ThisPtr) :-
    thisPtrParam(Callee, Param),
    callParameter(Insn, CallerFunc, Param, ThisPtr).

% ----------------------------------------------------------------
% thisPtrUsage: at call site Insn within Function, ThisPtr is passed
% as the this-pointer to Method.
% Counterpart: initial.pl:193-205
% ----------------------------------------------------------------
thisPtrUsage(Insn, Function, ThisPtr, Method) :-
    callTarget(Insn, Function, Thunk),
    dethunk(Thunk, Method),
    thisPtrParam(Method, Param),
    callParameter(Insn, Function, Param, ThisPtr).

% ----------------------------------------------------------------
% methodCallAtOffset / validMethodCallAtOffset / callAtOffset
% Counterpart: methodCallAtOffset (initial.pl:175-191)
% ----------------------------------------------------------------
methodCallAtOffset(Insn, Caller, Callee, Offset) :-
    thisParamFuncParameter(Caller, CallerThisPtr),
    callTarget(Insn, Caller, Thunk),
    dethunk(Thunk, Callee),
    thisParamCallParameter(Insn, Caller, Callee, CalleeThisPtr),
    thisPtrOffset(CallerThisPtr, Offset, CalleeThisPtr).

methodCallAtOffset(Insn, Caller, Callee, 0) :-
    thisParamFuncParameter(Caller, ThisPtr),
    callTarget(Insn, Caller, Thunk),
    dethunk(Thunk, Callee),
    thisParamCallParameter(Insn, Caller, Callee, ThisPtr).

validMethodCallAtOffset(Insn, Caller, Callee, Offset) :-
    methodCallAtOffset(Insn, Caller, Callee, Offset),
    possibleMethod(Callee),
    Offset < 0x100000.

callAtOffset(Caller, Callee, Off) :- validMethodCallAtOffset(_, Caller, Callee, Off).
