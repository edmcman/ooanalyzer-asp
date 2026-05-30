% Configuration constants for the prototype.
%
% Override on the clingo command line with --const, e.g.:
%   clingo --const max_class_size=512 --const max_offset_depth=6 ooanalyzer.lp ...
%
% Both bounds are intersected when constructing the relevantOffset domain that
% bounds the derivedClassRelationship/3 recursion (composition.lp). Off must
% satisfy depth <= max_offset_depth AND Off <= max_class_size.

% Cap on the number of derivedClass edges that may be summed when building
% relevantOffset. Higher = deeper transitive chains; the domain size scales
% roughly Pᴰ where P is the number of distinct primitive offsets in the input.
#const max_offset_depth = 4.

% Byte ceiling on accumulated offsets. No transitive ancestor sub-object can
% sit beyond this offset within any object. Lower values prune more aggressively
% when the primitive-offset GCD is small.
#const max_class_size = 256.

maxOffsetDepth(max_offset_depth).
maxClassSize(max_class_size).
