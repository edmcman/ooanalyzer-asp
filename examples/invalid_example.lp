% invalid_example.lp: two real destructors forced into the same class via symbols
% Expected: UNSATISFIABLE
symbolProperty(1300, realDestructor).   % definitely a real destructor
symbolProperty(1400, realDestructor).   % also a real destructor
symbolClass(1300, none, classA, none).   % both in classA (forces a merge)
symbolClass(1400, none, classA, none).
