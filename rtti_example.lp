% rtti_example.lp — inherit_example.lp augmented with RTTI facts
%
% Same binary layout as inherit_example.lp (Base + Derived), but RTTI is present.
% RTTI confirms vftables directly and provides authoritative inheritance structure.
%
% With RTTI:
%   - vftable(3000) is confirmed by rtti_complete_object_locator, not just guessed
%   - derived_class(2300, 2100, 0) comes from rtti_inherits_from (hard derivation)
%   - class_has_no_base(2100's class) from RTTI (Base has no base)
%
% Expected output: same 2-class result as inherit_example.lp

% ----------------------------------------------------------------
% Structural facts (same as inherit_example.lp)
% ----------------------------------------------------------------
poss_vftable_write(2100, 0, 3000).
poss_vftable_entry(3000, 0, 3100).
poss_vftable_entry(3000, 4, 2200).
returns_self(2100).
no_calls_before(2100).
no_calls_after(2200).

poss_vftable_write(2300, 0, 4000).
poss_vftable_overwrite(2300, 0, 3000, 4000).
poss_vftable_entry(4000, 0, 3200).
poss_vftable_entry(4000, 4, 3300).
returns_self(2300).
no_calls_before(2300).
call_at_offset(2300, 2100, 0).

% ----------------------------------------------------------------
% RTTI facts
% ----------------------------------------------------------------
rtti_type_descriptor(5000, "?AVBase@@").
rtti_type_descriptor(5100, "?AVDerived@@").
rtti_complete_object_locator(3000, 5000).   % vt_base  → Base
rtti_complete_object_locator(4000, 5100).   % vt_derived → Derived
rtti_inherits_from(5100, 5000, 0).          % Derived inherits Base at offset 0
