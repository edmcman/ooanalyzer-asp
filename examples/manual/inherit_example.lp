% inherit_example.lp — Single inheritance: Base + Derived
%
% Binary layout:
%
%   Class Base (vftable: 3000)
%     2100  constructor:      installs vt_base at offset 0, returns self
%     3100  virtual method:   vt_base[0]
%     2200  real destructor:  vt_base[4], no calls after
%     2210  deleting destructor: calls 2200, calls delete
%
%   Class Derived : Base (vftable: 4000)
%     2300  constructor:      calls Base::ctor at this+0, overwrites vt_base with
%                             vt_derived, returns self
%     3200  virtual method:   vt_derived[0]  (overrides Base::3100)
%     3300  new virtual:      vt_derived[4]
%
% Expected output (optimal model):
%   classRep(2100)  methods: {2100, 2200, 2210, 3100}   constructor(2100) deletingDestructor(2210)
%   classRep(2300)  methods: {2300, 3200, 3300}   constructor(2300)
%   derivedClass(2300, 2100, 0)

fileInfo("dummy", "dummy", "MSVC_32", 4).

% ----------------------------------------------------------------
% Class Base
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

% ----------------------------------------------------------------
% Class Derived
% ----------------------------------------------------------------
possibleVFTableWrite(0, 2300, none, 0, 4000).
possibleVFTableOverwrite(0, 0, 2300, 0, 3000, 4000).   % ctor sequence: install base, then overwrite
possibleVFTableEntry(4000, 0, 3200).
possibleVFTableEntry(4000, 4, 3300).
returnsSelf(2300).
noCallsBefore(2300).
methodCallAtOffset(0, 2300, 2100, 0).                      % derived ctor calls base ctor at this+0
