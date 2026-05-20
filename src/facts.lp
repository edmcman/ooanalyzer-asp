% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes = sets of methods) from binary analysis facts.
%
% Two input vocabularies are supported:
%
%   (A) Simplified predicates (hand-written examples):
%       possibleVFTableWrite(M, Off, V)
%       possibleVFTableEntry(V, Off, E)
%       possibleVFTableOverwrite(M, Off, V1, V2)
%       callTarget(Caller, Callee)
%       callAtOffset(Caller, Callee, Off)
%       callsDelete(M)
%       symbolClass(M, Class)
%       rTTICompleteObjectLocator(V, TDA)
%       rTTITypeDescriptor(TDA, Name)
%       possibleVBTableWrite(M, Off, V)
%       possibleVBTableEntry(V, Off, Value)
%
%   (B) Full-arity OOAnalyzer .facts predicates (from binary analysis):
%       possibleVFTableWrite(Insn, M, ThisPtr, Off, ExpandedThisPtr, V)
%       possibleVBTableWrite(Insn, M, ThisPtr, Off, ExpandedThisPtr, V)
%       callTarget(Insn, Caller, Callee)
%       insnCallsDelete(Insn, M, ThisPtr)
%       symbolClass(M, MangledName, Class, MethodName)
%       rTTICompleteObjectLocator(Pointer, Address, TDA, CHDAddress, Offset, CDOffset)
%       rTTITypeDescriptor(Address, VFTable, Name, DemangledName)
%       rTTIClassHierarchyDescriptor(Address, Attributes, BaseClasses)
%       rTTIBaseClassDescriptor(Address, TypeDescriptorAddress, NumBases, WhereM, WhereP, WhereV, Attributes, ClassHierarchyDescriptor)
%       initialMemory(Address, Value)
%       thisPtrOffset(ThisPtr1, Offset, ThisPtr2)
%       thisPtrDefinition(ThisPtr, ThisPtrExpression, DefinerOrNull, Func)
%       methodMemberAccess(Insn, Method, Offset, Size)
%       thunk(Thunk, Target)
%       symbolProperty(M, Prop)
%       purecall(M)
%       returnsSelf(M)
%       noCallsBefore(M)
%       noCallsAfter(M)
%       uninitializedReads(M)
%       callingConvention(Function, Convention)
%       funcParameter(Function, Position, SVHash)
%       funcReturn(Function, Position, SVHash)
%       callParameter(Instruction, Function, Position, SVHash)
%       callReturn(Instruction, Function, Position, SVHash)
%       fileInfo(FileMD5, Filename, ABI, ArchBytes)
%       thisPtrAllocation(Insn, Function, ThisPtr, Type, Size)
%       possibleVirtualFunctionCall(Insn, Function, ThisPtr, VTableOffset, VFuncOffset)
%
% src/initial.lp derives the simplified predicates (A) from the full ones (B).

% ----------------------------------------------------------------
% Simplified predicates (directly usable by the prototype)
% ----------------------------------------------------------------
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
#defined possibleMethod/1.
#defined possibleConstructor/1.
#defined possibleDestructor/1.
#defined factNOTMethod/1.
#defined methodCallAtOffset/4.
#defined validMethodCallAtOffset/4.
#defined thisPtrParam/2.
#defined genericThisPtrABIParam/1.

% ----------------------------------------------------------------
% Full-arity OOAnalyzer initial facts (from .facts files)
% ----------------------------------------------------------------
#defined fileInfo/4.
#defined insnCallsDelete/3.
#defined insnCallsNew/3.
#defined possibleVFTableWrite/6.
#defined possibleVBTableWrite/6.
#defined callTarget/3.
#defined callParameter/4.
#defined callReturn/4.
#defined funcParameter/3.
#defined funcReturn/3.
#defined callingConvention/2.
#defined symbolClass/4.
#defined rTTICompleteObjectLocator/6.
#defined rTTITypeDescriptor/4.
#defined rTTIClassHierarchyDescriptor/3.
#defined rTTIBaseClassDescriptor/8.
#defined initialMemory/2.
#defined thisPtrOffset/3.
#defined thisPtrDefinition/4.
#defined methodMemberAccess/4.
#defined thisPtrAllocation/5.
#defined possibleVirtualFunctionCall/5.
#defined symbolGlobalObject/3.
