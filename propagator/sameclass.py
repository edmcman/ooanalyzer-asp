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
        self._trail = []

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
        old_reason = self._reason.get(rb)
        old_rank = self._rank.get(ra)
        self._trail.append((rb, self._parent[rb], rb in self._reason,
                            old_reason, ra, ra in self._rank, old_rank))
        self._parent[rb] = ra
        self._reason[rb] = slit
        if self._rank.get(ra, 0) == self._rank.get(rb, 0):
            self._rank[ra] = self._rank.get(ra, 0) + 1
        return True

    def snapshot(self):
        return len(self._trail)

    def restore(self, snapshot):
        while len(self._trail) > snapshot:
            rb, old_parent, had_reason, old_reason, ra, had_rank, old_rank = self._trail.pop()
            self._parent[rb] = old_parent
            if had_reason:
                self._reason[rb] = old_reason
            else:
                self._reason.pop(rb, None)
            if had_rank:
                self._rank[ra] = old_rank
            else:
                self._rank.pop(ra, None)

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
        # entity_key → [(other_key, sameClass solver_lit)]
        self._sc_by_entity = {}
        # entity_key → [(other_key, mergeClasses solver_lit)]
        self._merge_by_entity = {}
        self._entities = set()

        for sym_atom in init.symbolic_atoms.by_signature("mergeClasses", 2):
            args = sym_atom.symbol.arguments
            a, b = _sym_key(args[0]), _sym_key(args[1])
            slit = init.solver_literal(sym_atom.literal)
            self._merge_to_pair[slit] = (a, b)
            self._merge_by_entity.setdefault(a, []).append((b, slit))
            self._merge_by_entity.setdefault(b, []).append((a, slit))
            self._entities.update((a, b))
            init.add_watch(slit)

        for tatom in init.theory_atoms:
            if tatom.term.name == "sameClass" and len(tatom.term.arguments) == 2:
                x = _theory_key(tatom.term.arguments[0])
                y = _theory_key(tatom.term.arguments[1])
                slit = init.solver_literal(tatom.literal)
                self._sc_to_lit[(x, y)] = slit
                self._sc_lit_to_pair[slit] = (x, y)
                self._sc_by_entity.setdefault(x, []).append((y, slit))
                if x != y:
                    self._sc_by_entity.setdefault(y, []).append((x, slit))
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

        self._check_atoms = [
            (x, y, slit)
            for (x, y), slit in self._sc_to_lit.items()
            if x != y and self._potential_uf.same(x, y)
        ]

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
        self._merge_trail = []
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

    def _component_cut_and_reasons(self, x, cache):
        root = self._uf._root(x)
        if root in cache:
            return cache[root]
        component = self._uf.component(x, self._entities)
        reason = self._uf.component_reasons(component)
        cut = set()
        for member in component:
            for other, merge_slit in self._merge_by_entity.get(member, ()):
                if other not in component:
                    cut.add(merge_slit)
        cache[root] = (reason, cut)
        return reason, cut

    def _assert_not_same(self, ctl, x, y, slit, cache=None):
        """Assert sameClass(x,y)=false with a sound explanation."""
        if not self._potential_uf.same(x, y):
            _dprint(f"[assert-false/perm] &sameClass({x},{y})")
            return ctl.add_clause([-slit], tag=False)

        if cache is None:
            cache = {}
        reason, cut = self._component_cut_and_reasons(x, cache)
        clause = [-r for r in reason] + list(cut) + [-slit]
        _dprint(
            f"[assert-false/cut] &sameClass({x},{y}) "
            f"via reason={sorted(reason)} cut={sorted(cut)}"
        )
        return ctl.add_clause(clause, tag=False)

    def propagate(self, ctl, changes):
        asgn = ctl.assignment
        for lit in changes:
            if lit in self._merge_to_pair:
                a, b = self._merge_to_pair[lit]
                if self._uf.same(a, b):
                    continue
                comp_a = self._uf.component(a, self._entities)
                comp_b = self._uf.component(b, self._entities)
                snapshot = self._uf.snapshot()
                if self._uf.union(a, b, lit):
                    self._merge_trail.append((lit, snapshot))
                    _dprint(f"[propagate] union({a},{b})")
                    if len(comp_a) > len(comp_b):
                        comp_a, comp_b = comp_b, comp_a
                    for x in comp_a:
                        for y, sc_lit in self._sc_by_entity.get(x, ()):
                            if y in comp_b and not asgn.is_fixed(sc_lit):
                                if not self._assert_same(ctl, x, y, sc_lit):
                                    return
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

    def undo(self, thread_id, assignment, changes):
        _dprint(f"[undo] restore at level {assignment.decision_level}")
        for lit in changes:
            if lit not in self._merge_to_pair:
                continue
            if self._merge_trail and self._merge_trail[-1][0] == lit:
                _lit, snapshot = self._merge_trail.pop()
                self._uf.restore(snapshot)
            else:
                # Fallback for any non-LIFO undo ordering from clingo.
                self._rebuild(assignment)
                self._merge_trail = []
                return

    def check(self, ctl):
        """Validate assigned &sameClass atoms without eagerly deciding negatives."""
        asgn = ctl.assignment
        for x, y, slit in self._check_atoms:
            is_same, _ = self._uf.same_with_reason(x, y)
            if is_same:
                if not asgn.is_fixed(slit):
                    if not self._assert_same(ctl, x, y, slit):
                        return
                continue

            if asgn.is_true(slit):
                _dprint(f"[check] &sameClass({x},{y}) → false")
                if not self._assert_not_same(ctl, x, y, slit):
                    return

    def partition(self):
        return self._uf.groups()
