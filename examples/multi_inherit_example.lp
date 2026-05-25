% multi_inherit_example.lp — Multiple inheritance: C : A (offset 0), B (offset 8)
%
% Binary layout:
%
%   Class A (vftable: 3000)
%     1100  constructor:     installs vt_a at offset 0, returns self
%     1200  virtual method:  vt_a[0]
%     1300  real destructor: noCallsAfter
%     1310  deleting destructor: calls 1300, calls delete
%
%   Class B (vftable: 3100)
%     2100  constructor:     installs vt_b at offset 0, returns self
%     2200  virtual method:  vt_b[0]
%     2300  real destructor: noCallsAfter
%     2310  deleting destructor: calls 2300, calls delete
%
%   Class C : A (offset 0), B (offset 8)
%     Two vftables: vt_c_0 (4000) at object offset 0, vt_c_8 (4100) at offset 8.
%     5100  constructor:  calls A::ctor at this+0, B::ctor at this+8;
%                         overwrites vt_a→vt_c_0 and vt_b→vt_c_8
%     5200  override of A::1200, vt_c_0[0]
%     5300  override of B::2200, vt_c_8[0]
%
% Expected output:
%   classRep(1100)  {1100, 1200, 1300, 1310}   constructor(1100) deletingDestructor(1310)
%   classRep(2100)  {2100, 2200, 2300, 2310}   constructor(2100) deletingDestructor(2310)
%   classRep(5100)  {5100, 5200, 5300}   constructor(5100)
%   derivedClass(5100, 1100, 0)
%   derivedClass(5100, 2100, 8)

% ----------------------------------------------------------------
% Class A
% ----------------------------------------------------------------
possibleVFTableWrite(1100, 0, 3000).
possibleVFTableEntry(3000, 0, 1200).
possibleVFTableEntry(3000, 4, 1300).
returnsSelf(1100).
noCallsBefore(1100).
noCallsAfter(1300).
callsDelete(1310).
callTarget(1310, 1300).
noCallsAfter(1310).

% ----------------------------------------------------------------
% Class B
% ----------------------------------------------------------------
possibleVFTableWrite(2100, 0, 3100).
possibleVFTableEntry(3100, 0, 2200).
possibleVFTableEntry(3100, 4, 2300).
returnsSelf(2100).
noCallsBefore(2100).
noCallsAfter(2300).
callsDelete(2310).
callTarget(2310, 2300).
noCallsAfter(2310).

% ----------------------------------------------------------------
% Class C : A, B
% ----------------------------------------------------------------
possibleVFTableWrite(5100, 0, 4000).
possibleVFTableWrite(5100, 8, 4100).
possibleVFTableOverwrite(5100, 0, 3000, 4000).   % overwrites A's vftable with C's primary
possibleVFTableOverwrite(5100, 8, 3100, 4100).   % overwrites B's vftable with C's secondary
possibleVFTableEntry(4000, 0, 5200).             % C overrides A::virtual
possibleVFTableEntry(4000, 4, 1300).             % inherited A destructor
possibleVFTableEntry(4100, 0, 5300).             % C overrides B::virtual
possibleVFTableEntry(4100, 4, 2300).             % inherited B destructor
returnsSelf(5100).
noCallsBefore(5100).
callAtOffset(5100, 1100, 0).   % C ctor calls A ctor at this+0
callAtOffset(5100, 2100, 8).   % C ctor calls B ctor at this+8
