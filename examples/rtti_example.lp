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
% RTTI facts
% ----------------------------------------------------------------
fileInfo('dummy', 'dummy', 'MSVC_32', 4).

rTTITypeDescriptor(0, 0, "?AVBase@@", "?AVBase@@").
rTTITypeDescriptor(0, 0, "?AVDerived@@", "?AVDerived@@").
rTTICompleteObjectLocator(2996, 0, 5000, 0, 0, 0).   % vt_base  → Base
rTTICompleteObjectLocator(3996, 0, 5100, 0, 0, 0).   % vt_derived → Derived
rTTIInheritsFrom(5100, 5000, 0, 0, 0xffffffff, 0).   % Derived inherits Base at offset 0
