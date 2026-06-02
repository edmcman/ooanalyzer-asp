% rtti_example.lp — inherit_example.lp augmented with RTTI facts
%
% Same binary layout as inherit_example.lp (Base + Derived), but RTTI is present.
% RTTI confirms vftables directly and provides authoritative inheritance structure.
%
% With RTTI:
%   - vfTable(3000) is confirmed by rTTICompleteObjectLocator, not just guessed
%   - derivedClass(2300, 2100, 0) comes from rTTIInheritsFrom (hard derivation)
%   - classHasNoBase(2100's class) from RTTI (Base has no base)
%
% Expected output:
%   classRep(2100)  methods: {2100, 2200, 2210, 3100}   constructor(2100) deletingDestructor(2210)
%   classRep(2300)  methods: {2300, 3200, 3300}   constructor(2300)
%   derivedClass(2300, 2100, 0)

% ----------------------------------------------------------------
% Structural facts (same as inherit_example.lp)
% ----------------------------------------------------------------
possibleVFTableWrite(0, 2100, none, 0, 3000).
possibleVFTableEntry(3000, 0, 3100).
possibleVFTableEntry(3000, 4, 2200).
returnsSelf(2100).
noCallsBefore(2100).
noCallsAfter(2200).
insnCallsDelete(0, 2210, none).
callTarget(0, 2210, 2200).
noCallsAfter(2210).

possibleVFTableWrite(0, 2300, none, 0, 4000).
possibleVFTableOverwrite(0, 0, 2300, 0, 3000, 4000).
possibleVFTableEntry(4000, 0, 3200).
possibleVFTableEntry(4000, 4, 3300).
returnsSelf(2300).
noCallsBefore(2300).
methodCallAtOffset(0, 2300, 2100, 0).

% ----------------------------------------------------------------
% RTTI facts. The CHD lists are already expanded into one fact per BCD,
% matching scripts/facts2clingo.py output.
% ----------------------------------------------------------------
fileInfo("dummy", "dummy", "MSVC_32", 4).

rTTITypeDescriptor(5000, 0, "?AVBase@@", "?AVBase@@").
rTTITypeDescriptor(5100, 0, "?AVDerived@@", "?AVDerived@@").
rTTICompleteObjectLocator(2996, 6000, 5000, 7000, 0, 0).   % vt_base -> Base
rTTICompleteObjectLocator(3996, 6100, 5100, 7100, 0, 0).   % vt_derived -> Derived

% Base self-reference.
rTTIClassHierarchyDescriptor(7000, 0, 8000).
rTTIBaseClassDescriptor(8000, 5000, 0, 0, 0xffffffff, 0, 0x40, 7000).

% Derived self-reference plus direct Base entry at offset 0.
rTTIClassHierarchyDescriptor(7100, 0, 8100).
rTTIClassHierarchyDescriptor(7100, 0, 8200).
rTTIBaseClassDescriptor(8100, 5100, 1, 0, 0xffffffff, 0, 0x40, 7100).
rTTIBaseClassDescriptor(8200, 5000, 0, 0, 0xffffffff, 0, 0x40, 7000).
