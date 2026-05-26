% constructor_vftable_entry_example.lp
% Purpose: a possible vftable entry that dethunks to a constructor is rejected.
% Expected:
%   - SATISFIABLE / OPTIMUM FOUND
%   - -vfTableEntry(2000,0,1000)

possibleVFTableEntry(2000, 0, 1000).
symbolProperty(1000, constructor).

#show -vfTableEntry/3.
