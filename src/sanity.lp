#const diagnose = 0.
diagnosing :- diagnose != 0.

:- not diagnosing, insanity(_, _).
violate(Tag, Witness) :- diagnosing, insanity(Tag, Witness).
#show violate/2.
