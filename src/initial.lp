% ============================================================
% INITIAL DERIVATIONS -- map full-arity OOAnalyzer facts to the
% simplified predicates expected by the prototype rules.
% Counterpart: pharos/share/prolog/oorules/initial.pl
% ============================================================

% ----------------------------------------------------------------
% Pointer size from fileInfo
% ----------------------------------------------------------------
pointerSize(ArchBytes) :- fileInfo(_, _, _, ArchBytes).

% ----------------------------------------------------------------
% possibleVFTableWrite / possibleVBTableWrite projections
% Drop instruction, this-pointer, and expanded-this-pointer.
% Counterpart: initial.pl:13-16
% ----------------------------------------------------------------
possibleVFTableWrite(Insn, Function, ThisPtr, Offset, VFTable) :-
    possibleVFTableWrite(Insn, Function, ThisPtr, Offset, _ExpandedThisPtr, VFTable). % initial.pl:13
possibleVBTableWrite(Insn, Function, ThisPtr, Offset, VBTable) :-
    possibleVBTableWrite(Insn, Function, ThisPtr, Offset, _ExpandedThisPtr, VBTable). % initial.pl:15
possibleVFTableWrite(M, Off, V) :- possibleVFTableWrite(_, M, _, Off, V).
possibleVBTableWrite(M, Off, V) :- possibleVBTableWrite(_, M, _, Off, V).

% ----------------------------------------------------------------
% possibleVFTableEntry: recursive walk over initialMemory starting
% at each confirmed VFTable pointer.  Stops at VFTable overwrites.
% Counterpart: initial.pl:38-57
% ----------------------------------------------------------------
vftableWriteAtAddress(Address) :- possibleVFTableWrite(_, _, _, _, Address).

% Base case 1: from confirmed VFTable writes.
possibleVFTableEntry(VFTable, 0, Entry) :-
    possibleVFTableWrite(_, _, _, _, VFTable),
    initialMemory(VFTable, Entry).

% Base case 2: from RTTI Complete Object Locator.
possibleVFTableEntry(VFTable, 0, Entry) :-
    rTTICompleteObjectLocator(Pointer, _, _, _, _, _),
    pointerSize(PtrSize),
    VFTable = Pointer + PtrSize,
    initialMemory(VFTable, Entry).

possibleVFTableEntry(VFTable, NewOffset, Entry) :-
    possibleVFTableEntry(VFTable, Offset, _),
    pointerSize(PtrSize),
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
vbtableWriteAtAddress(Address) :- possibleVBTableWrite(_, _, _, _, Address).

possibleVBTableEntry(VBTable, 0, Value) :-
    possibleVBTableWrite(_, _, _, _, VBTable),
    initialMemory(VBTable, Value).

possibleVBTableEntry(VBTable, NewOffset, Value) :-
    possibleVBTableEntry(VBTable, Offset, _),
    pointerSize(PtrSize),
    NewOffset = Offset + PtrSize,
    Address = VBTable + NewOffset,
    not vbtableWriteAtAddress(Address),
    initialMemory(Address, Value).

% ----------------------------------------------------------------
% possibleVFTableOverwrite: a constructor writes two different
% vftables at the same object offset.
% Counterpart: initial.pl:383-389
% ----------------------------------------------------------------
possibleVFTableOverwrite(Insn1, Insn2, Func, ObjectOffset, VFTable1, VFTable2) :-
    possibleVFTableWrite(Insn1, Func, ThisPtr, ObjectOffset, VFTable1),
    possibleVFTableWrite(Insn2, Func, ThisPtr, ObjectOffset, VFTable2),
    VFTable1 != VFTable2,
    Insn1 < Insn2.                                                         % initial.pl:383

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
% rTTITDA2VFTable: maps a type descriptor to its primary vftable address.
% Counterpart: rTTITDA2VFTable/2 (rtti.pl:19)
% ----------------------------------------------------------------
rTTITDA2VFTable(TDA, VFTable) :-
    rTTITypeDescriptor(TDA, _TIVTable, _Name, _DName),
    rTTICompleteObjectLocator(Pointer, _COLA, TDA, _CHDA, _Offset, _O2),
    pointerSize(PtrSize),
    VFTable = Pointer + PtrSize.

% ----------------------------------------------------------------
% rTTIEnabled: user flag set by the driver when RTTI detection succeeded.
% Counterpart: ooprolog.pl:227 (asserted by driver; modelled here as a constant)
% ----------------------------------------------------------------
#const rtti_enabled = 1.
rTTIEnabled :- rtti_enabled != 0.

% ----------------------------------------------------------------
% rTTIValid: RTTI data is internally consistent.
% Counterpart: rtti.pl:269-281 and its helper predicates
% ----------------------------------------------------------------

% Every TDA address referenced from any RTTI structure.
% Counterpart: rTTIAllTypeDescriptors/1 (rtti.pl:248-256)
rTTIAllTypeDescriptors(TDA) :- rTTITypeDescriptor(TDA, _, _, _).
rTTIAllTypeDescriptors(TDA) :- rTTICompleteObjectLocator(_, _, TDA, _, _, _).
rTTIAllTypeDescriptors(TDA) :- rTTIBaseClassDescriptor(_, TDA, _, _, _, _, _, _).

% Counterpart: rTTIHasTypeDescriptor/1 (rtti.pl:258-262)
rTTIHasTypeDescriptor(TDA) :- rTTITypeDescriptor(TDA, _, _, _).

% TDAs that must have a circular self-reference in the RTTI block.
% Counterpart: rTTIShouldHaveSelfRef/1 (rtti.pl:237-240)
rTTIShouldHaveSelfRef(TDA) :-
    rTTITypeDescriptor(TDA, _, _, _),
    rTTICompleteObjectLocator(_, _, TDA, _, _, _).

% The circular self-reference: COL -> CHDA -> BCDA -> TDA and back.
% bcd_has_CHD_pointer (0x40): if set, BCHDA must equal CHDA.
% Counterpart: rTTISelfRef/6 (rtti.pl:38-63)
rTTISelfRef(TDA, COLA, CHDA, BCDA, VFTable) :-
    rTTITypeDescriptor(TDA, _, _, _),
    rTTICompleteObjectLocator(Pointer, COLA, TDA, CHDA, _, _),
    pointerSize(PtrSize),
    VFTable = Pointer + PtrSize,
    rTTIClassHierarchyDescriptor(CHDA, _, BCDA),
    rTTIBaseClassDescriptor(BCDA, TDA, _, 0, 0xffffffff, 0, BaseAttributes, _),
    BaseAttributes & 64 = 0.     % bcd_has_CHD_pointer not set: BCHDA unconstrained

rTTISelfRef(TDA, COLA, CHDA, BCDA, VFTable) :-
    rTTITypeDescriptor(TDA, _, _, _),
    rTTICompleteObjectLocator(Pointer, COLA, TDA, CHDA, _, _),
    pointerSize(PtrSize),
    VFTable = Pointer + PtrSize,
    rTTIClassHierarchyDescriptor(CHDA, _, BCDA),
    rTTIBaseClassDescriptor(BCDA, TDA, _, 0, 0xffffffff, 0, BaseAttributes, CHDA),
    BaseAttributes & 64 = 64.    % bcd_has_CHD_pointer set: BCHDA must equal CHDA

rTTIHasSelfRef(TDA) :- rTTISelfRef(TDA, _, _, _, _).

% Invalid when any base class descriptor attribute >= 0x80.
% Counterpart: rTTIInvalidBaseAttributes/0 (rtti.pl:198-202)
rTTIInvalidBaseAttributes :-
    rTTIBaseClassDescriptor(_, _, _, _, _, _, Attributes, _),
    Attributes >= 0x80.
rTTIInvalidBaseAttributes :-
    rTTIBaseClassDescriptor(_, _, _, _, _, _, Attributes, _),
    Attributes < 0.

% Invalid when hierarchy attributes are not in {0, 1, 3, 5, 7}.
% Counterpart: rTTIInvalidHierarchyAttributes/0 (rtti.pl:214-235)
rTTIInvalidHierarchyAttributes :-
    rTTIClassHierarchyDescriptor(_, A, _),
    A != 0, A != 1, A != 3, A != 5, A != 7.

% Ancestor walk used by direct-inheritance validation.
rTTIAncestorOf(DerivedTDA, AncestorTDA) :-
    rTTICompleteObjectLocator(_, _, DerivedTDA, CHDA, _, _),
    rTTIClassHierarchyDescriptor(CHDA, _, BCDA),
    rTTIBaseClassDescriptor(BCDA, AncestorTDA, _, _, _, _, _, _),
    AncestorTDA != DerivedTDA.

rTTIInheritsIndirectlyFrom(DerivedTDA, AncestorTDA) :-
    rTTIAncestorOf(DerivedTDA, BaseTDA),
    rTTIAncestorOf(BaseTDA, AncestorTDA).

% Direct non-virtual inheritance without the P/V filter, used only for validation.
% bcd_virtual_base_of_contained_object = 0x10.
% Counterpart: rTTIInheritsDirectlyFrom/6 (rtti.pl:83-108)
rTTIDirectNonVirtual(DerivedTDA, AncestorTDA, M, P, V) :-
    rTTICompleteObjectLocator(_, _, DerivedTDA, CHDA, _, _),
    rTTIClassHierarchyDescriptor(CHDA, _, BCDA),
    rTTIBaseClassDescriptor(BCDA, AncestorTDA, _, M, P, V, AttrValue, _),
    AttrValue & 16 = 0,
    AncestorTDA != DerivedTDA,
    not rTTIInheritsIndirectlyFrom(DerivedTDA, AncestorTDA).

% Counterpart: rTTIInvalidDirectInheritanceP/0 (rtti.pl:204-207)
rTTIInvalidDirectInheritanceP :- rTTIDirectNonVirtual(_, _, _, P, _), P != 0xffffffff.

% Counterpart: rTTIInvalidDirectInheritanceV/0 (rtti.pl:209-212)
rTTIInvalidDirectInheritanceV :- rTTIDirectNonVirtual(_, _, _, _, V), V != 0.

rTTIInvalidRTTI :- rTTIAllTypeDescriptors(TDA), not rTTIHasTypeDescriptor(TDA).
rTTIInvalidRTTI :- rTTIShouldHaveSelfRef(TDA),  not rTTIHasSelfRef(TDA).
rTTIInvalidRTTI :- rTTIInvalidBaseAttributes.
rTTIInvalidRTTI :- rTTIInvalidHierarchyAttributes.
rTTIInvalidRTTI :- rTTIInvalidDirectInheritanceP.
rTTIInvalidRTTI :- rTTIInvalidDirectInheritanceV.

rTTIValid :-
    rTTIEnabled,
    rTTIAllTypeDescriptors(_),
    rTTIShouldHaveSelfRef(_),
    not rTTIInvalidRTTI.

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
genericThisPtrABIParam(rcx) :- fileInfo(_, _, "MSVC_64", _).
genericThisPtrABIParam(rdi) :- fileInfo(_, _, "SYSV_64", _).
genericThisPtrABIParam(0)   :- fileInfo(_, _, "SYSV_32", _).

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
    factMethod(Callee),
    Offset < 0x100000.

callAtOffset(Caller, Callee, Off) :- validMethodCallAtOffset(_, Caller, Callee, Off).
