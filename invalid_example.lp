% invalid_example.lp: two real destructors forced into the same class via symbols
% Expected: UNSATISFIABLE
symbol_property(1300, realDestructor).   % definitely a real destructor
symbol_property(1400, realDestructor).   % also a real destructor
symbol_class(1300, classA).              % both in classA (forces a merge)
symbol_class(1400, classA).
