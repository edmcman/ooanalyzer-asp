% virtual_base_example.lp — Virtual inheritance: Derived virtually inherits Base
%
% Binary layout (MSVC-style):
%
%   Class Base (vftable: 3000)
%     1100  constructor:  installs vt_base at offset 0, returns self
%     1200  virtual foo:  vt_base[0]
%
%   Class Derived : virtual Base (vftable: 4000, VBTable: 5000)
%     2100  constructor:  installs vt_derived at offset 0,
%                         installs VBTable pointer at offset 4,
%                         calls Base::ctor at offset 8
%     2200  override foo: vt_derived[0]
%
%   VBTable (5000):
%     offset 0: -4  (offset from vbptr to object start)
%     offset 4:  4  (offset from vbptr to Base subobject: 4+4=8)
%
% The vftable overwrite rule does NOT fire (virtual inheritance, no overwrite).
% The VBTable confirms virtual inheritance:
%   derivedClass(2100, 1100, 8) from VBTable entry + objectInObject match.
%
% Expected output:
%   classRep(1100)  {1100, 1200}   constructor(1100)
%   classRep(2100)  {2100, 2200}   constructor(2100)
%   derivedClass(2100, 1100, 8)

fileInfo("dummy", "dummy", "MSVC_32", 4).

% ----------------------------------------------------------------
% Class Base
% ----------------------------------------------------------------
possibleVFTableWrite(0, 1100, none, 0, 3000).
possibleVFTableEntry(3000, 0, 1200).
returnsSelf(1100).
noCallsBefore(1100).

% ----------------------------------------------------------------
% Class Derived : virtual Base
% ----------------------------------------------------------------
possibleVFTableWrite(0, 2100, none, 0, 4000).
possibleVFTableEntry(4000, 0, 2200).
returnsSelf(2100).
noCallsBefore(2100).
methodCallAtOffset(0, 2100, 1100, 8).   % derived ctor calls base ctor at this+8

% VBTable: installed by Derived at object offset 4
possibleVBTableWrite(0, 2100, none, 4, 5000).
possibleVBTableEntry(5000, 0, -4).   % self-offset
possibleVBTableEntry(5000, 4, 4).    % offset to Base: vbptr_off(4) + entry(4) = 8
