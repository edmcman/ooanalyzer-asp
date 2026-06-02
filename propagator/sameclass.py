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
from dataclasses import dataclass, field

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
    """Union-find augmented with a true-mc adjacency graph.

    UF is used for fast same-component checks. The adjacency graph stores the
    actual mc edges (a, b, slit) added via union(); reason paths come from BFS
    over the adjacency, NOT from walking the UF tree (which is rank-balanced
    and whose parent slits do not in general witness child↔parent connectivity).
    """
    def __init__(self):
        self._parent = {}
        self._rank = {}
        self._trail = []         # UF tree edits, for restore
        self._adj = {}           # node → list of (other, slit)  (true mc edges)
        self._adj_trail = []     # list of (a, b, slit), for restore

    def _root(self, x):
        self._parent.setdefault(x, x)
        curr = x
        while self._parent[curr] != curr:
            curr = self._parent[curr]
        return curr

    def union(self, a, b, slit):
        # Always record the actual mc edge, even if a and b are already
        # in the same UF component (redundant edge in the mc graph).
        self._adj.setdefault(a, []).append((b, slit))
        self._adj.setdefault(b, []).append((a, slit))
        self._adj_trail.append((a, b, slit))

        ra, rb = self._root(a), self._root(b)
        if ra == rb:
            return False
        if self._rank.get(ra, 0) < self._rank.get(rb, 0):
            ra, rb = rb, ra
        old_rank = self._rank.get(ra)
        self._trail.append((rb, self._parent[rb], ra, ra in self._rank, old_rank))
        self._parent[rb] = ra
        if self._rank.get(ra, 0) == self._rank.get(rb, 0):
            self._rank[ra] = self._rank.get(ra, 0) + 1
        return True

    def snapshot(self):
        return (len(self._trail), len(self._adj_trail))

    def restore(self, snapshot):
        trail_size, adj_size = snapshot
        while len(self._trail) > trail_size:
            rb, old_parent, ra, had_rank, old_rank = self._trail.pop()
            self._parent[rb] = old_parent
            if had_rank:
                self._rank[ra] = old_rank
            else:
                self._rank.pop(ra, None)
        while len(self._adj_trail) > adj_size:
            a, b, slit = self._adj_trail.pop()
            # Pop the LAST matching entry (LIFO order matches addition).
            for i in range(len(self._adj[a]) - 1, -1, -1):
                if self._adj[a][i] == (b, slit):
                    del self._adj[a][i]
                    break
            for i in range(len(self._adj[b]) - 1, -1, -1):
                if self._adj[b][i] == (a, slit):
                    del self._adj[b][i]
                    break

    def _path_between(self, x, y):
        """BFS through true mc edges; returns list of slits along an x→y path,
        or None if no path exists."""
        if x == y:
            return []
        if x not in self._adj:
            return None
        visited = {x}
        # Each queue entry: (node, list_of_slits_so_far)
        queue = [(x, [])]
        while queue:
            node, path = queue.pop(0)
            for other, slit in self._adj.get(node, ()):
                if other == y:
                    return path + [slit]
                if other not in visited:
                    visited.add(other)
                    queue.append((other, path + [slit]))
        return None

    def same_with_reason(self, a, b):
        if a == b:
            return True, []
        if a not in self._parent and b not in self._parent:
            return False, []
        ra, rb = self._root(a), self._root(b)
        if ra != rb:
            return False, []
        path = self._path_between(a, b)
        if path is None:
            # Defensive: UF and adj graph disagree (shouldn't happen).
            return False, []
        return True, path

    def same(self, a, b):
        return self.same_with_reason(a, b)[0]

    def component(self, x, universe):
        rx = self._root(x)
        return {n for n in universe if self._root(n) == rx}

    def component_reasons(self, members):
        """All true mc edges with both endpoints inside `members`."""
        members_set = set(members)
        reasons = set()
        for n in members_set:
            for other, slit in self._adj.get(n, ()):
                if other in members_set:
                    reasons.add(slit)
        return reasons

    def groups(self, universe=None):
        from collections import defaultdict
        out = defaultdict(set)
        for x in self._parent if universe is None else universe:
            out[self._root(x)].add(x)
        return dict(out)


@dataclass
class _ThreadState:
    uf: _UF = field(default_factory=_UF)
    merge_trail: list = field(default_factory=list)


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

        for sym_atom in init.symbolic_atoms.by_signature("mergeEntity", 1):
            self._entities.add(_sym_key(sym_atom.symbol.arguments[0]))

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

        self._states = [_ThreadState() for _ in range(init.number_of_threads)]
        _dprint(f"[init] {len(self._merge_to_pair)} mergeClasses, "
                f"{len(self._sc_to_lit)} &sameClass atoms")

    def _state(self, thread_id):
        return self._states[thread_id]

    def _rebuild(self, state, assignment):
        state.uf = _UF()
        for slit, (a, b) in self._merge_to_pair.items():
            if assignment.is_true(slit):
                state.uf.union(a, b, slit)

    def _assert_same(self, state, ctl, x, y, slit):
        """Add permanent reason clause: reason_lits → sameClass(x,y)."""
        _, reason = state.uf.same_with_reason(x, y)
        clause = [-r for r in reason] + [slit]
        _dprint(f"[assert-true] &sameClass({x},{y}) via {reason}")
        return ctl.add_clause(clause, tag=False)

    def _component_cut_and_reasons(self, state, x, cache):
        root = state.uf._root(x)
        if root in cache:
            return cache[root]
        component = state.uf.component(x, self._entities)
        reason = state.uf.component_reasons(component)
        cut = set()
        for member in component:
            for other, merge_slit in self._merge_by_entity.get(member, ()):
                if other not in component:
                    cut.add(merge_slit)
        cache[root] = (reason, cut)
        return reason, cut

    def _assert_not_same(self, state, ctl, x, y, slit, cache=None):
        """Assert sameClass(x,y)=false with a sound explanation."""
        if not self._potential_uf.same(x, y):
            _dprint(f"[assert-false/perm] &sameClass({x},{y})")
            return ctl.add_clause([-slit], tag=False)

        if cache is None:
            cache = {}
        reason, cut = self._component_cut_and_reasons(state, x, cache)
        clause = [-r for r in reason] + list(cut) + [-slit]
        _dprint(
            f"[assert-false/cut] &sameClass({x},{y}) "
            f"via reason={sorted(reason)} cut={sorted(cut)}"
        )
        return ctl.add_clause(clause, tag=False)

    def propagate(self, ctl, changes):
        asgn = ctl.assignment
        state = self._state(ctl.thread_id)
        for lit in changes:
            if lit in self._merge_to_pair:
                a, b = self._merge_to_pair[lit]
                if state.uf.same(a, b):
                    continue
                comp_a = state.uf.component(a, self._entities)
                comp_b = state.uf.component(b, self._entities)
                snapshot = state.uf.snapshot()
                if state.uf.union(a, b, lit):
                    state.merge_trail.append((lit, snapshot))
                    _dprint(f"[propagate] union({a},{b})")
                    if len(comp_a) > len(comp_b):
                        comp_a, comp_b = comp_b, comp_a
                    for x in comp_a:
                        for y, sc_lit in self._sc_by_entity.get(x, ()):
                            if y in comp_b and not asgn.is_fixed(sc_lit):
                                if not self._assert_same(state, ctl, x, y, sc_lit):
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
        state = self._state(thread_id)
        for lit in changes:
            if lit not in self._merge_to_pair:
                continue
            if state.merge_trail and state.merge_trail[-1][0] == lit:
                _lit, snapshot = state.merge_trail.pop()
                state.uf.restore(snapshot)
            else:
                # Fallback for any non-LIFO undo ordering from clingo.
                self._rebuild(state, assignment)
                state.merge_trail = []
                return

    def check(self, ctl):
        """Validate assigned &sameClass atoms without eagerly deciding negatives."""
        asgn = ctl.assignment
        state = self._state(ctl.thread_id)
        for x, y, slit in self._check_atoms:
            is_same, _ = state.uf.same_with_reason(x, y)
            if is_same:
                if not asgn.is_fixed(slit):
                    if not self._assert_same(state, ctl, x, y, slit):
                        return
                continue

            if asgn.is_true(slit):
                _dprint(f"[check] &sameClass({x},{y}) → false")
                if not self._assert_not_same(state, ctl, x, y, slit):
                    return

    def partition(self, merge_pairs=None):
        """Return class groups.

        Prefer passing model mergeClasses/2 pairs after solving. Without
        merge_pairs this exposes thread 0's live groups for compatibility with
        older direct callers.
        """
        if merge_pairs is None:
            return self._state(0).uf.groups(self._entities)

        uf = _UF()
        for a, b in merge_pairs:
            uf.union(_sym_key(a), _sym_key(b), 0)
        return uf.groups(self._entities)


def sc_pairs_from_merges(merge_pairs):
    """Given [(Symbol, Symbol)] mergeClasses pairs, yield all (a, b) same-class pairs."""
    uf = _UF()
    sym_map = {}
    for a, b in merge_pairs:
        ka, kb = _sym_key(a), _sym_key(b)
        sym_map.setdefault(ka, a)
        sym_map.setdefault(kb, b)
        uf.union(ka, kb, 0)
    entities = set(sym_map)
    for ka in entities:
        for kb in entities:
            if uf.same(ka, kb):
                yield sym_map[ka], sym_map[kb]
