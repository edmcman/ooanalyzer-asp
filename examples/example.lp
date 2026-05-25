% example.lp — Three vftable-based classes for the OOAnalyzer Clingo prototype
%
% Binary layout (hypothetical):
%
%   Class A  (vftable: 2000)
%     1100  constructor:      installs vt_a at offset 0, returns self
%     1200  virtual method:   vt_a[0]
%     1300  real destructor:  vt_a[4], no calls after
%     1310  deleting destructor: calls 1300, calls delete
%
%   Class B  (vftable: 2100)
%     1600  constructor:      installs vt_b at offset 0, returns self
%     1700  virtual method:   vt_b[0]
%     1800  real destructor:  vt_b[4], no calls after
%     1810  deleting destructor: calls 1800, calls delete
%
%   Class C  (vftable: 2200)
%     1900  constructor:      installs vt_c at offset 0, returns self
%     1950  virtual method:   vt_c[0]
%     1960  real destructor:  vt_c[4], no calls after
%     1970  deleting destructor: calls 1960, calls delete
%
% All three classes are separated by the "different vftables at same offset" constraint.
%
% Expected output (optimal model):
%   classRep(1100)  members: {1100, 1200, 1300, 1310}   constructor(1100) deletingDestructor(1310)
%   classRep(1600)  members: {1600, 1700, 1800, 1810}   constructor(1600) deletingDestructor(1810)
%   classRep(1900)  members: {1900, 1950, 1960, 1970}   constructor(1900) deletingDestructor(1970)

% ----------------------------------------------------------------
% Class A
% ----------------------------------------------------------------
possibleVFTableWrite(1100, 0, 2000).
possibleVFTableEntry(2000, 0, 1200).
possibleVFTableEntry(2000, 4, 1300).
returnsSelf(1100).
noCallsBefore(1100).
noCallsAfter(1300).
callsDelete(1310).
callTarget(1310, 1300).
noCallsAfter(1310).

% ----------------------------------------------------------------
% Class B
% ----------------------------------------------------------------
possibleVFTableWrite(1600, 0, 2100).
possibleVFTableEntry(2100, 0, 1700).
possibleVFTableEntry(2100, 4, 1800).
returnsSelf(1600).
noCallsBefore(1600).
noCallsAfter(1800).
callsDelete(1810).
callTarget(1810, 1800).
noCallsAfter(1810).

% ----------------------------------------------------------------
% Class C
% ----------------------------------------------------------------
possibleVFTableWrite(1900, 0, 2200).
possibleVFTableEntry(2200, 0, 1950).
possibleVFTableEntry(2200, 4, 1960).
returnsSelf(1900).
noCallsBefore(1900).
noCallsAfter(1960).
callsDelete(1970).
callTarget(1970, 1960).
noCallsAfter(1970).
