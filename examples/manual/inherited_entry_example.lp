% inherited_entry_example.lp — Single inheritance where Derived overrides one
% virtual method but inherits another (same function pointer in both vftables).
%
% Binary layout:
%
%   Class Base (vftable: 3000)
%     1100  constructor:  installs vt_base at offset 0, returns self
%     1200  virtual foo:  vt_base[0]
%     1300  virtual bar:  vt_base[4]   (NOT overridden by Derived)
%
%   Class Derived : Base (vftable: 4000)
%     2100  constructor:  overwrites vt_base with vt_derived, returns self
%     2200  override:     vt_derived[0]  (overrides Base::foo)
%     1300  inherited:    vt_derived[4]  (same pointer as vt_base[4] — bar)
%     1500  new virtual:  vt_derived[8]
%
% Expected output:
%   classRep(1100)  {1100, 1200, 1300}   constructor(1100)
%   classRep(1500)  {1500, 2100, 2200}   constructor(2100)
%   1300 stays in Base's class (not merged into Derived)
%   derivedClass(2100, 1100, 0)

fileInfo("dummy", "dummy", "MSVC_32", 4).

% ----------------------------------------------------------------
% Class Base
% ----------------------------------------------------------------
possibleVFTableWrite(0, 1100, none, 0, 3000).
possibleVFTableEntry(3000, 0, 1200).
possibleVFTableEntry(3000, 4, 1300).
returnsSelf(1100).
noCallsBefore(1100).

% ----------------------------------------------------------------
% Class Derived
% ----------------------------------------------------------------
possibleVFTableWrite(0, 2100, none, 0, 4000).
possibleVFTableOverwrite(0, 0, 2100, 0, 3000, 4000).
possibleVFTableEntry(4000, 0, 2200).
possibleVFTableEntry(4000, 4, 1300).   % inherited from Base — same function pointer
possibleVFTableEntry(4000, 8, 1500).
returnsSelf(2100).
noCallsBefore(2100).
