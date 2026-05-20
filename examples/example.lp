% example.lp — Three vftable-based classes for the OOAnalyzer Clingo prototype
%
% Binary layout (hypothetical):
%
%   Class A  (vftable: 2000)
%     1100  constructor:      installs vt_a at offset 0, returns self
%     1200  virtual method:   vt_a[0]
%     1300  real destructor:  vt_a[4], no calls after
%
%   Class B  (vftable: 2100)
%     1600  constructor:      installs vt_b at offset 0, returns self
%     1700  virtual method:   vt_b[0]
%     1800  real destructor:  vt_b[4], no calls after
%
%   Class C  (vftable: 2200)
%     1900  constructor:      installs vt_c at offset 0, returns self
%     1950  virtual method:   vt_c[0]
%     1960  real destructor:  vt_c[4], no calls after
%
% All three classes are separated by the "different vftables at same offset" constraint.
%
% Expected output (optimal model):
%   classRep(1100)  members: {1100, 1200, 1300}   factConstructor(1100) factRealDestructor(1300)
%   classRep(1600)  members: {1600, 1700, 1800}   factConstructor(1600) factRealDestructor(1800)
%   classRep(1900)  members: {1900, 1950, 1960}   factConstructor(1900) factRealDestructor(1960)

% ----------------------------------------------------------------
% Class A
% ----------------------------------------------------------------
possibleVFTableWrite(1100, 0, 2000).
possibleVFTableEntry(2000, 0, 1200).
possibleVFTableEntry(2000, 4, 1300).
returnsSelf(1100).
noCallsBefore(1100).
noCallsAfter(1300).

% ----------------------------------------------------------------
% Class B
% ----------------------------------------------------------------
possibleVFTableWrite(1600, 0, 2100).
possibleVFTableEntry(2100, 0, 1700).
possibleVFTableEntry(2100, 4, 1800).
returnsSelf(1600).
noCallsBefore(1600).
noCallsAfter(1800).

% ----------------------------------------------------------------
% Class C
% ----------------------------------------------------------------
possibleVFTableWrite(1900, 0, 2200).
possibleVFTableEntry(2200, 0, 1950).
possibleVFTableEntry(2200, 4, 1960).
returnsSelf(1900).
noCallsBefore(1900).
noCallsAfter(1960).
