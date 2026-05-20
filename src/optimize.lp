% ============================================================
% OPTIMIZATION
% ============================================================

% Priority 2: confirm as many vftables as possible
% Priority 1: maximize class merges (minimize class count)
% Priority 0: prefer factDerivedClass at offset 0; prefer more factClassHasNoBase
#maximize { 1@2, V : factVFTable(V); 1@2, V : factVBTable(V) }.        % Counterpart: guessVFTable / guessVBTable / guessDerivedClass / guessClassHasNoBase / guessMergeClasses priorities (Prolog uses binary-search guess ordering)
#maximize { 1@1, M1, M2 : mergeClasses(M1, M2) }.                        % Counterpart: guessMergeClasses priority
#maximize { 1@0, Outer, Inner : factDerivedClass(Outer, Inner, 0) }.      % Counterpart: guessDerivedClass priority
#maximize { 1@0, C : factClassHasNoBase(C) }.                            % Counterpart: guessClassHasNoBase priority
