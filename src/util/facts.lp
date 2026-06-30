% OOAnalyzer prototype in Clingo
% Recovers C++ class structure (classes = sets of methods) from binary analysis facts.
%
% Full-arity OOAnalyzer .facts predicates (from binary analysis):
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
% src/util/initial.lp derives the simplified predicates (A) from the full ones (B).

% ----------------------------------------------------------------
% Derived predicates (produced by src/util/initial.lp)
% ----------------------------------------------------------------
#defined possibleVFTableEntry/3.
#defined possibleVBTableEntry/3.
#defined possibleMethod/1.
#defined possibleConstructor/1.
#defined possibleDestructor/1.
#defined methodCallAtOffset/4.
#defined validMethodCallAtOffset/4.
#defined thisPtrParam/2.
#defined genericThisPtrABIParam/1.
#defined thisPtrUsage/4.

% ----------------------------------------------------------------
% Base facts (from .facts files, usable directly)
% ----------------------------------------------------------------
#defined returnsSelf/1.
#defined noCallsBefore/1.
#defined noCallsAfter/1.
#defined uninitializedReads/1.
#defined symbolProperty/2.
#defined thunk/2.
#defined purecall/1.

% ----------------------------------------------------------------
% Not yet implemented (forward-declared for future rules)
% ----------------------------------------------------------------
#defined virtualFunctionCall/5.
% reasonReusedImplementation_A/B not yet ported; guards merge rules until it lands.
#defined reusedImplementation/1.

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
