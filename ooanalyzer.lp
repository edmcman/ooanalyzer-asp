% OOAnalyzer prototype in Clingo
% Recovers C++ class structure from binary analysis facts.
% See AGENTS.md for architecture details.

#include "src/util/facts.lp".
#include "src/util/initial.lp".
#include "src/modules/methods.lp".
#include "src/modules/ctorsdtors.lp".
#include "src/modules/vftables.lp".
#include "src/modules/merges.lp".
#include "src/modules/classes.lp".
#include "src/modules/composition.lp".
#include "src/util/sanity.lp".
