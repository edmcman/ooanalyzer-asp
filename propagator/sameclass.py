"""
Pure-Python &sameClass/2 support utilities.

The live &sameClass propagator is the Rust cdylib `ooanalyzer_sameclass` (see
`rust/`). This module retains only the pure-Python pieces with no Rust
equivalent:

  - `_UF`: union-find with a true-mc adjacency graph, used by the diagnostic
    propagator and the post-solve partition helpers.
  - `LazySameClassConsistencyPropagator`: a deliberately weak check-time
    consistency checker for `--sameclass-mode=lazy-check` diagnostics.
  - `sc_pairs_from_merges`: expand mergeClasses pairs into all same-class pairs.
"""

from collections import deque

import clingo


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
        self._size = {}          # root → component size
        self._members = {}       # root → set of member nodes
        self._trail = []         # UF tree edits, for restore
        self._adj = {}           # node → list of (other, slit)  (true mc edges)
        self._adj_trail = []     # list of (a, b, slit), for restore

    def _root(self, x):
        parent = self._parent
        if x not in parent:
            parent[x] = x
            self._size[x] = 1
            self._members[x] = {x}
            return x
        while parent[x] != x:
            x = parent[x]
        return x

    def union(self, a, b, slit, ra=None, rb=None):
        # Always record the actual mc edge, even if a and b are already
        # in the same UF component (redundant edge in the mc graph).
        self._adj.setdefault(a, []).append((b, slit))
        self._adj.setdefault(b, []).append((a, slit))
        self._adj_trail.append((a, b, slit))

        # Callers in the hot path pass precomputed roots to avoid recomputing
        # them here (they already needed the roots for the redundancy check).
        if ra is None:
            ra = self._root(a)
        if rb is None:
            rb = self._root(b)
        if ra == rb:
            return None
        # Union by size: ra absorbs rb. rb is then the smaller side, and its
        # member set is left untouched — only the absorbing root's set grows.
        # The returned `absorbed` set object is therefore stable across this
        # mutation, which propagate() relies on. `merged` is the live absorbing
        # set, returned so callers need not re-walk to the new root.
        if self._size[ra] < self._size[rb]:
            ra, rb = rb, ra
        absorbed = self._members[rb]
        self._trail.append((rb, ra, self._size[ra]))
        self._parent[rb] = ra
        self._size[ra] += self._size[rb]
        merged = self._members[ra]
        merged |= absorbed
        return absorbed, merged

    def snapshot(self):
        return (len(self._trail), len(self._adj_trail))

    def restore(self, snapshot):
        trail_size, adj_size = snapshot
        while len(self._trail) > trail_size:
            rb, ra, old_size_ra = self._trail.pop()
            # rb was a root before the union (so its parent was itself) and its
            # member set was never mutated, so it is the exact set absorbed into
            # ra; subtract it back out and restore rb as its own root.
            self._members[ra] -= self._members[rb]
            self._size[ra] = old_size_ra
            self._parent[rb] = rb
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
        parent = {x: None}       # node → (prev_node, slit_from_prev)
        queue = deque([x])
        while queue:
            node = queue.popleft()
            for other, slit in self._adj.get(node, ()):
                if other in parent:
                    continue
                parent[other] = (node, slit)
                if other == y:
                    path = []
                    cur = y
                    while parent[cur] is not None:
                        prev, s = parent[cur]
                        path.append(s)
                        cur = prev
                    path.reverse()
                    return path
                queue.append(other)
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
        # Connectivity is a pure root comparison; the BFS reason path in
        # same_with_reason is only needed when building a clause. Avoid touching
        # _parent (no setdefault) for absent nodes so this stays side-effect free.
        if a == b:
            return True
        if a not in self._parent or b not in self._parent:
            return False
        return self._root(a) == self._root(b)

    def component(self, x, universe=None):
        # O(1) lookup of the maintained per-root member set, returned as a fresh
        # copy so callers may iterate or mutate it without disturbing UF state.
        if x not in self._parent:
            return {x}
        return set(self._members[self._root(x)])

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



class LazySameClassConsistencyPropagator:
    """Simple diagnostic checker for &sameClass/2 and &allWritersInClass/2.

    This mode deliberately avoids the eager propagation and potential-UF logic in
    the native Rust propagator.  At check points it rebuilds a union-find from the
    currently true mergeClasses/2 atoms, compares assigned theory atoms against
    that graph, and blocks the inconsistent current merge assignment.

    The clauses are intentionally broad and weak.  This is for debugging theory
    consistency and search behavior, not for normal performance.
    """

    def init(self, init):
        init.check_mode = clingo.PropagatorCheckMode.Total
        self._merge_lit_to_pairs = {}
        self._merge_lits = set()
        self._entities = set()

        for sym_atom in init.symbolic_atoms.by_signature("mergeEntity", 1):
            self._entities.add(_sym_key(sym_atom.symbol.arguments[0]))

        for sym_atom in init.symbolic_atoms.by_signature("mergeClasses", 2):
            args = sym_atom.symbol.arguments
            a, b = _sym_key(args[0]), _sym_key(args[1])
            slit = init.solver_literal(sym_atom.literal)
            self._merge_lit_to_pairs.setdefault(slit, []).append((a, b))
            self._merge_lits.add(slit)
            self._entities.update((a, b))

        self._sameclass_atoms = []
        self._awc_atoms = []
        for tatom in init.theory_atoms:
            if tatom.term.name == "sameClass" and len(tatom.term.arguments) == 2:
                x = _theory_key(tatom.term.arguments[0])
                y = _theory_key(tatom.term.arguments[1])
                slit = init.solver_literal(tatom.literal)
                self._sameclass_atoms.append((x, y, slit))
                self._entities.update((x, y))
                init.add_watch(slit)
                init.add_watch(-slit)
            elif tatom.term.name == "allWritersInClass" and len(tatom.term.arguments) == 2:
                vftable = _theory_key(tatom.term.arguments[0])
                class_ = _theory_key(tatom.term.arguments[1])
                slit = init.solver_literal(tatom.literal)
                self._awc_atoms.append((vftable, class_, slit))
                self._entities.add(class_)
                init.add_watch(slit)
                init.add_watch(-slit)

        self._writers_by_vft = {}
        for sym_atom in init.symbolic_atoms.by_signature("nonOverwritingWrite", 3):
            args = sym_atom.symbol.arguments
            method = _sym_key(args[0])
            vftable = _sym_key(args[2])
            slit = init.solver_literal(sym_atom.literal)
            self._writers_by_vft.setdefault(vftable, []).append((method, slit))
            self._entities.add(method)
            init.add_watch(slit)
            init.add_watch(-slit)

    def propagate(self, ctl, changes):
        pass

    def _current_uf(self, assignment):
        uf = _UF()
        for slit, pairs in self._merge_lit_to_pairs.items():
            if assignment.is_true(slit):
                for a, b in pairs:
                    uf.union(a, b, slit)
        return uf

    def _merge_assignment_clause(self, assignment):
        clause = []
        for slit in self._merge_lits:
            if assignment.is_true(slit):
                clause.append(-slit)
            elif assignment.is_false(slit):
                clause.append(slit)
        return clause

    def check(self, ctl):
        assignment = ctl.assignment
        uf = self._current_uf(assignment)
        merge_clause = None
        merges_total = all(
            assignment.is_true(slit) or assignment.is_false(slit)
            for slit in self._merge_lits
        )

        def get_merge_clause():
            nonlocal merge_clause
            if merge_clause is None:
                merge_clause = self._merge_assignment_clause(assignment)
            return list(merge_clause)

        for x, y, slit in self._sameclass_atoms:
            is_same = uf.same(x, y)
            if is_same and not assignment.is_true(slit):
                same, reason = uf.same_with_reason(x, y)
                assert same
                clause = [-r for r in reason] + [slit]
                if not ctl.add_clause(clause):
                    return
            elif merges_total and not is_same and assignment.is_true(slit):
                clause = get_merge_clause() + [-slit]
                if not ctl.add_clause(clause):
                    return

        for vftable, class_, awc_slit in self._awc_atoms:
            if not merges_total or not assignment.is_true(awc_slit):
                continue
            for method, now_slit in self._writers_by_vft.get(vftable, ()):
                if assignment.is_true(now_slit) and not uf.same(method, class_):
                    clause = get_merge_clause() + [-now_slit, -awc_slit]
                    if not ctl.add_clause(clause):
                        return
                    break

    def partition(self, merge_pairs=None):
        if merge_pairs is None:
            return {}

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
