% inherit_example.lp — Single inheritance: Base + Derived
%
% Binary layout:
%
%   Class Base (vftable: 3000)
%     2100  constructor:      installs vt_base at offset 0, returns self
%     3100  virtual method:   vt_base[0]
%     2200  real destructor:  vt_base[4], no calls after
%
%   Class Derived : Base (vftable: 4000)
%     2300  constructor:      calls Base::ctor at this+0, overwrites vt_base with
%                             vt_derived, returns self
%     3200  virtual method:   vt_derived[0]  (overrides Base::3100)
%     3300  new virtual:      vt_derived[4]
%
% Expected output (optimal model):
%   class_rep(2100)  methods: {2100, 2200, 3100}   constructor(2100)  real_destructor(2200)
%   class_rep(2300)  methods: {2300, 3200, 3300}   constructor(2300)
%   derived_class(2300, 2100, 0)

% ----------------------------------------------------------------
% Class Base
% ----------------------------------------------------------------
poss_vftable_write(2100, 0, 3000).
poss_vftable_entry(3000, 0, 3100).
poss_vftable_entry(3000, 4, 2200).
returns_self(2100).
no_calls_before(2100).
no_calls_after(2200).

% ----------------------------------------------------------------
% Class Derived
% ----------------------------------------------------------------
poss_vftable_write(2300, 0, 4000).
poss_vftable_overwrite(2300, 0, 3000, 4000).   % ctor sequence: install base, then overwrite
poss_vftable_entry(4000, 0, 3200).
poss_vftable_entry(4000, 4, 3300).
returns_self(2300).
no_calls_before(2300).
call_at_offset(2300, 2100, 0).                  % derived ctor calls base ctor at this+0
