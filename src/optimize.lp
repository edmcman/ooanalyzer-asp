% ============================================================
% OPTIMIZATION
% ============================================================


% Priority 2: confirm as many vftables as possible
#maximize { 1@2, V : factVFTable(V); 1@2, V : factVBTable(V) }.        % Counterpart: guessVFTable / guessVBTable / guessDerivedClass / guessClassHasNoBase / guessMergeClasses priorities (Prolog uses binary-search guess ordering)

% Priority 1: maximize class merges (minimize class count)
#maximize { 1@1, M1, M2 : mergeClasses(M1, M2) }.                        % Counterpart: guessMergeClasses priority

% Priority 0: prefer Derived > Embedded > hasNoBase (weighted within same level)
#maximize { 100@0, Outer, Inner : factDerivedClass(Outer, Inner, _) }.   % Counterpart: guessDerivedClass priority
#maximize { 10@0, Outer, Inner : factEmbeddedObject(Outer, Inner, _) }.  % Counterpart: tryEmbeddedObject / guessDerivedClass negative preference
%#maximize { 1@0, C : factClassHasNoBase(C) }.                            % Counterpart: guessClassHasNoBase priority
