% rtti_example.lp — inherit_example.lp augmented with RTTI facts
%
% Same binary layout as inherit_example.lp (Base + Derived), but RTTI is present.
% RTTI confirms vftables directly and provides authoritative inheritance structure.
%
% With RTTI:
%   - factVFTable(3000) is confirmed by rTTICompleteObjectLocator, not just guessed
%   - factDerivedClass(2300, 2100, 0) comes from rTTIInheritsFrom (hard derivation)
%   - factClassHasNoBase(2100's class) from RTTI (Base has no base)
%
% Expected output:
%   classRep(2100)  methods: {2100, 2200, 2210, 3100}   factConstructor(2100) factDeletingDestructor(2210)
%   classRep(2300)  methods: {2300, 3200, 3300}   factConstructor(2300)
%   factDerivedClass(2300, 2100, 0)

% ----------------------------------------------------------------
% Structural facts (same as inherit_example.lp)
% ----------------------------------------------------------------
possibleVFTableWrite(2100, 0, 3000).
possibleVFTableEntry(3000, 0, 3100).
possibleVFTableEntry(3000, 4, 2200).
returnsSelf(2100).
noCallsBefore(2100).
noCallsAfter(2200).
callsDelete(2210).
callTarget(2210, 2200).
noCallsAfter(2210).

possibleVFTableWrite(2300, 0, 4000).
possibleVFTableOverwrite(2300, 0, 3000, 4000).
possibleVFTableEntry(4000, 0, 3200).
possibleVFTableEntry(4000, 4, 3300).
returnsSelf(2300).
noCallsBefore(2300).
callAtOffset(2300, 2100, 0).

% ----------------------------------------------------------------
% RTTI facts
% ----------------------------------------------------------------
rTTITypeDescriptor(5000, "?AVBase@@").
rTTITypeDescriptor(5100, "?AVDerived@@").
rTTICompleteObjectLocator(3000, 5000).   % vt_base  → Base
rTTICompleteObjectLocator(4000, 5100).   % vt_derived → Derived
rTTIInheritsFrom(5100, 5000, 0).         % Derived inherits Base at offset 0
