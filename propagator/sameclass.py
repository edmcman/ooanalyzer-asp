"""
SameClassPropagator: clingo theory propagator for &sameClass/2.

Maintains a union-find over true mergeClasses(A,B) atoms and decides
&sameClass(X,Y) theory atoms during solving — no N² closure.

True decisions use permanent reason clauses (tag=False):
  ¬merge_1 ∨ ¬merge_2 ∨ … ∨ sameClass(X,Y)
so CDCL retains them across backtracks.

False decisions distinguish two cases:
  - Cross-component (no mergeClasses path possible): permanent unit.
  - Within-component but not currently merged: permanent reason clause over the
    current component cut.

Reflexive atoms &sameClass(X,X): forced true at level 0 in init().
Undo strategy: rebuild from scratch on backtrack (correct; PoC).
"""

import clingo

DEBUG = False


def _dprint(*args):
    if DEBUG:
        print(*args)


def _sym_key(sym):
    if sym.type == clingo.SymbolType.Number:
        return sym.number
    return str(sym)


def _theory_key(theory_term):
    try:
        return theory_term.number
    except RuntimeError:
        return str(theory_term)


class _UF:
    """Union-find without path compression so reason paths are extractable."""
    def __init__(self):
        self._parent = {}
        self._reason = {}  # child → solver_lit that caused this tree edge
        self._rank = {}

    def _root(self, x):
        self._parent.setdefault(x, x)
        curr = x
        while self._parent[curr] != curr:
            curr = self._parent[curr]
        return curr

    def _path_to_root(self, x):
        self._parent.setdefault(x, x)
        lits = []
        curr = x
        while self._parent[curr] != curr:
            lits.append(self._reason[curr])
            curr = self._parent[curr]
        return lits

    def union(self, a, b, slit):
        ra, rb = self._root(a), self._root(b)
        if ra == rb:
            return False
        if self._rank.get(ra, 0) < self._rank.get(rb, 0):
            ra, rb = rb, ra
        self._parent[rb] = ra
        self._reason[rb] = slit
        if self._rank.get(ra, 0) == self._rank.get(rb, 0):
            self._rank[ra] = self._rank.get(ra, 0) + 1
        return True

    def same_with_reason(self, a, b):
        if a not in self._parent and b not in self._parent:
            return a == b, []
        ra, rb = self._root(a), self._root(b)
        if ra != rb:
            return False, []
        return True, self._path_to_root(a) + self._path_to_root(b)

    def same(self, a, b):
        return self.same_with_reason(a, b)[0]

    def component(self, x, universe):
        rx = self._root(x)
        return {n for n in universe if self._root(n) == rx}

    def component_reasons(self, members):
        reasons = set()
        for n in members:
            reasons.update(self._path_to_root(n))
        return reasons

    def groups(self):
        from collections import defaultdict
        out = defaultdict(set)
        for x in self._parent:
            out[self._root(x)].add(x)
        return dict(out)


class SameClassPropagator:
    def init(self, init):
        # solver_lit → (a_key, b_key)
        self._merge_to_pair = {}
        # (x_key, y_key) → solver_lit
        self._sc_to_lit = {}
        # solver_lit → (x_key, y_key) — for watching positive theory atoms
        self._sc_lit_to_pair = {}
        self._entities = set()

        for sym_atom in init.symbolic_atoms.by_signature("mergeClasses", 2):
            args = sym_atom.symbol.arguments
            a, b = _sym_key(args[0]), _sym_key(args[1])
            slit = init.solver_literal(sym_atom.literal)
            self._merge_to_pair[slit] = (a, b)
            self._entities.update((a, b))
            init.add_watch(slit)

        for tatom in init.theory_atoms:
            if tatom.term.name == "sameClass" and len(tatom.term.arguments) == 2:
                x = _theory_key(tatom.term.arguments[0])
                y = _theory_key(tatom.term.arguments[1])
                slit = init.solver_literal(tatom.literal)
                self._sc_to_lit[(x, y)] = slit
                self._sc_lit_to_pair[slit] = (x, y)
                self._entities.update((x, y))
                # Watch positive polarity: catch solver guessing sameClass=true
                # eagerly so we can add permanent-false for cross-component pairs.
                init.add_watch(slit)

        # Potential connectivity: which pairs could EVER be same class,
        # considering all mergeClasses atoms as potentially true.
        # Cross-component pairs are permanently false.
        self._potential_uf = _UF()
        for slit, (a, b) in self._merge_to_pair.items():
            self._potential_uf.union(a, b, slit)

        # At level 0: force reflexive atoms true and cross-component atoms false.
        # The mergeClasses graph is static (fully ground before solving), so
        # any pair with no mergeClasses path is unconditionally false.
        for (x, y), slit in self._sc_to_lit.items():
            if x == y:
                init.add_clause([slit])
            elif not self._potential_uf.same(x, y):
                init.add_clause([-slit])

        # Biconditional wiring for DIRECT pairs: sameClass(A,B) ↔ mergeClasses(A,B).
        # Both directions as permanent clauses so BCP fires in either direction.
        # Transitive pairs are handled lazily during propagation.
        for merge_slit, (a, b) in self._merge_to_pair.items():
            for pair in [(a, b), (b, a)]:
                if pair in self._sc_to_lit:
                    sc_slit = self._sc_to_lit[pair]
                    init.add_clause([-merge_slit, sc_slit])   # merge → same
                    init.add_clause([merge_slit, -sc_slit])   # ¬merge → ¬same

        self._uf = _UF()
        _dprint(f"[init] {len(self._merge_to_pair)} mergeClasses, "
                f"{len(self._sc_to_lit)} &sameClass atoms")

    def _rebuild(self, assignment):
        self._uf = _UF()
        for slit, (a, b) in self._merge_to_pair.items():
            if assignment.is_true(slit):
                self._uf.union(a, b, slit)

    def _assert_same(self, ctl, x, y, slit):
        """Add permanent reason clause: reason_lits → sameClass(x,y)."""
        _, reason = self._uf.same_with_reason(x, y)
        clause = [-r for r in reason] + [slit]
        _dprint(f"[assert-true] &sameClass({x},{y}) via {reason}")
        return ctl.add_clause(clause, tag=False)

    def _assert_not_same(self, ctl, x, y, slit):
        """Assert sameClass(x,y)=false with a sound explanation."""
        if not self._potential_uf.same(x, y):
            _dprint(f"[assert-false/perm] &sameClass({x},{y})")
            return ctl.add_clause([-slit], tag=False)

        component = self._uf.component(x, self._entities)
        reason = self._uf.component_reasons(component)
        cut = [
            merge_slit
            for merge_slit, (a, b) in self._merge_to_pair.items()
            if (a in component) != (b in component)
        ]
        clause = [-r for r in reason] + cut + [-slit]
        _dprint(
            f"[assert-false/cut] &sameClass({x},{y}) "
            f"via reason={sorted(reason)} cut={sorted(cut)}"
        )
        return ctl.add_clause(clause, tag=False)

    def propagate(self, ctl, changes):
        uf_changed = False
        for lit in changes:
            if lit in self._merge_to_pair:
                a, b = self._merge_to_pair[lit]
                if self._uf.union(a, b, lit):
                    _dprint(f"[propagate] union({a},{b})")
                    uf_changed = True
            elif lit in self._sc_lit_to_pair:
                # Solver guessed this theory atom true — validate immediately.
                x, y = self._sc_lit_to_pair[lit]
                if x == y:
                    continue  # reflexive, always fine
                if not self._potential_uf.same(x, y):
                    # Permanently impossible — add permanent false.
                    _dprint(f"[propagate] solver guessed &sameClass({x},{y})=true but cross-component")
                    if not ctl.add_clause([-lit], tag=False):
                        return

        if uf_changed:
            asgn = ctl.assignment
            for (x, y), slit in self._sc_to_lit.items():
                if x == y:
                    continue
                if asgn.is_fixed(slit):
                    continue
                is_same, _ = self._uf.same_with_reason(x, y)
                if is_same:
                    if not self._assert_same(ctl, x, y, slit):
                        return

    def undo(self, thread_id, assignment, changes):
        _dprint(f"[undo] rebuild at level {assignment.decision_level}")
        self._rebuild(assignment)

    def check(self, ctl):
        """Complete assignment: decide all remaining undecided &sameClass atoms."""
        asgn = ctl.assignment
        for (x, y), slit in self._sc_to_lit.items():
            if x == y:
                continue
            if asgn.is_fixed(slit):
                continue
            is_same, _ = self._uf.same_with_reason(x, y)
            if is_same:
                if not self._assert_same(ctl, x, y, slit):
                    return
            else:
                _dprint(f"[check] &sameClass({x},{y}) → false")
                if not self._assert_not_same(ctl, x, y, slit):
                    return

    def partition(self):
        return self._uf.groups()
