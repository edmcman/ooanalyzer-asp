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
%   class_rep(1100)  members: {1100, 1200, 1300}   constructor(1100) real_destructor(1300)
%   class_rep(1600)  members: {1600, 1700, 1800}   constructor(1600) real_destructor(1800)
%   class_rep(1900)  members: {1900, 1950, 1960}   constructor(1900) real_destructor(1960)

% ----------------------------------------------------------------
% Class A
% ----------------------------------------------------------------
poss_vftable_write(1100, 0, 2000).
poss_vftable_entry(2000, 0, 1200).
poss_vftable_entry(2000, 4, 1300).
returns_self(1100).
no_calls_before(1100).
no_calls_after(1300).

% ----------------------------------------------------------------
% Class B
% ----------------------------------------------------------------
poss_vftable_write(1600, 0, 2100).
poss_vftable_entry(2100, 0, 1700).
poss_vftable_entry(2100, 4, 1800).
returns_self(1600).
no_calls_before(1600).
no_calls_after(1800).

% ----------------------------------------------------------------
% Class C
% ----------------------------------------------------------------
poss_vftable_write(1900, 0, 2200).
poss_vftable_entry(2200, 0, 1950).
poss_vftable_entry(2200, 4, 1960).
returns_self(1900).
no_calls_before(1900).
no_calls_after(1960).
