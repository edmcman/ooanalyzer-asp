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

Observer integration (optional but recommended):
  Register the propagator as both propagator and observer before grounding:
    ctl.register_observer(prop)
    ctl.register_propagator(prop)
  This enables the least-fixpoint potential-UF seeding that eliminates the
  circular &sameClass bootstrap (see PROP.md).  Without observer data the
  propagator falls back to the original union-all seeding.

Foundedness check (optional, gated by foundedness_check=True):
  At each total assignment, verifies that every true mergeClasses atom has a
  justification that does not circularly depend on &sameClass atoms it supports.
  Unfounded atoms are rejected via add_clause.  Enable with --foundedness-check.
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
    def __init__(self, foundedness_check=False):
        self._foundedness_check = foundedness_check
        # Collected by observer callbacks during grounding (before init()).
        # _obs_rules: (choice, heads_tuple, pos_body_tuple) — positive body lits only.
        # _obs_unconditional: prog_lits derivable with no positive-body conditions.
        self._obs_rules = []
        self._obs_unconditional = set()

    # ── Observer callbacks ───────────────────────────────────────────────────
    # Called during ctl.ground(); program literals here are the same integers
    # as symbolic_atoms[...].literal and theory_atoms[...].literal in init().

    def rule(self, choice, head, body):
        pos_body = tuple(l for l in body if l > 0)
        if not pos_body:
            self._obs_unconditional.update(head)
        else:
            self._obs_rules.append((choice, tuple(head), pos_body))

    def weight_rule(self, choice, head, lower_bound, body):
        # Weight-rule semantics are complex; conservatively treat all heads as
        # potentially derivable regardless of the cardinality bound.
        self._obs_unconditional.update(head)

    def external(self, atom, value):
        if value != clingo.TruthValue.False_:
            self._obs_unconditional.add(atom)

    def begin_step(self): pass
    def end_step(self): pass
    def init_program(self, incremental): pass
    def output_atom(self, symbol, atom): pass
    def output_term(self, symbol, condition): pass
    def theory_term_number(self, tid, number): pass
    def theory_term_string(self, tid, name): pass
    def theory_term_compound(self, tid, ctype, args): pass
    def theory_element(self, eid, terms, condition): pass
    def theory_atom(self, atom, term, elements): pass
    def theory_atom_with_guard(self, atom, term, elements, op, right): pass
    def assume(self, lits): pass
    def minimize(self, priority, lits): pass
    def project(self, atoms): pass
    def heuristic(self, atom, b, bias, priority, condition): pass
    def acyc_edge(self, node_u, node_v, condition): pass

    # ── PropagateInit ────────────────────────────────────────────────────────

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

        # Program-literal maps for potential-UF fixpoint and foundedness check.
        # prog_lit values match sym_atom.literal / tatom.literal from PropagateInit.
        self._merge_proglit_to_pair = {}  # prog_lit → (a_key, b_key)
        self._merge_proglit_to_slit = {}  # prog_lit → solver_lit
        self._sc_proglit_to_pair = {}     # prog_lit → (x_key, y_key)

        for sym_atom in init.symbolic_atoms.by_signature("mergeEntity", 1):
            self._entities.add(_sym_key(sym_atom.symbol.arguments[0]))

        for sym_atom in init.symbolic_atoms.by_signature("mergeClasses", 2):
            args = sym_atom.symbol.arguments
            a, b = _sym_key(args[0]), _sym_key(args[1])
            prog_lit = sym_atom.literal
            slit = init.solver_literal(prog_lit)
            self._merge_to_pair[slit] = (a, b)
            self._merge_proglit_to_pair[prog_lit] = (a, b)
            self._merge_proglit_to_slit[prog_lit] = slit
            self._merge_by_entity.setdefault(a, []).append((b, slit))
            self._merge_by_entity.setdefault(b, []).append((a, slit))
            self._entities.update((a, b))
            init.add_watch(slit)

        for tatom in init.theory_atoms:
            if tatom.term.name == "sameClass" and len(tatom.term.arguments) == 2:
                x = _theory_key(tatom.term.arguments[0])
                y = _theory_key(tatom.term.arguments[1])
                prog_lit = tatom.literal
                slit = init.solver_literal(prog_lit)
                self._sc_proglit_to_pair[prog_lit] = (x, y)
                self._sc_to_lit[(x, y)] = slit
                self._sc_lit_to_pair[slit] = (x, y)
                self._sc_by_entity.setdefault(x, []).append((y, slit))
                if x != y:
                    self._sc_by_entity.setdefault(y, []).append((x, slit))
                self._entities.update((x, y))
                # Watch positive polarity: catch solver guessing sameClass=true
                # eagerly so we can add permanent-false for cross-component pairs.
                init.add_watch(slit)

        # Potential connectivity: which pairs could EVER be same class?
        # Uses a least fixpoint over the observed ground rules so that K-rule
        # heads (which need &sameClass in their body) cannot circularly bootstrap.
        # Falls back to union-all if no observer data was registered.
        self._potential_uf = _UF()
        self._build_potential_uf()

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

        # nonOverwritingWrite(Method, Offset, VFTable) ground atoms.
        # abs(slit) → (method_key, vftable_key); vftable_key → {(method_key, abs_slit)}
        self._now_slit_to_key     = {}
        self._now_writers_by_vft  = {}

        for sym_atom in init.symbolic_atoms.by_signature("nonOverwritingWrite", 3):
            args = sym_atom.symbol.arguments
            method  = _sym_key(args[0])
            vftable = _sym_key(args[2])
            lit  = init.solver_literal(sym_atom.literal)
            alit = abs(lit)
            self._now_slit_to_key[alit] = (method, vftable)
            self._now_writers_by_vft.setdefault(vftable, set()).add((method, alit))
            init.add_watch(lit)

        # &allWritersInClass(VFTable, Class) theory atoms.
        # (vftable_key, class_key) → slit; abs(slit) → (vftable_key, class_key)
        # vftable_key → {(class_key, slit)}
        self._awc_to_slit      = {}
        self._awc_slit_to_pair = {}
        self._awc_by_vft       = {}

        for tatom in init.theory_atoms:
            if tatom.term.name != "allWritersInClass" or len(tatom.term.arguments) != 2:
                continue
            vftable = _theory_key(tatom.term.arguments[0])
            class_  = _theory_key(tatom.term.arguments[1])
            slit = init.solver_literal(tatom.literal)
            self._awc_to_slit[(vftable, class_)] = slit
            self._awc_slit_to_pair[abs(slit)] = (vftable, class_)
            self._awc_by_vft.setdefault(vftable, set()).add((class_, slit))
            init.add_watch(slit)

        # Pre-compute rule index for foundedness check (merge heads only).
        if self._foundedness_check:
            merge_proglits = set(self._merge_proglit_to_pair.keys())
            self._head_to_bodies = {}
            for _choice, heads, pos_body in self._obs_rules:
                for h in heads:
                    if h in merge_proglits:
                        self._head_to_bodies.setdefault(h, []).append(pos_body)
            self._unconditional_merge_proglits = merge_proglits & self._obs_unconditional

        # Release raw observer data — no longer needed.
        self._obs_rules = []
        self._obs_unconditional = set()

        self._states = [_ThreadState() for _ in range(init.number_of_threads)]
        _dprint(f"[init] {len(self._merge_to_pair)} mergeClasses, "
                f"{len(self._sc_to_lit)} &sameClass atoms, "
                f"{len(self._now_slit_to_key)} nonOverwritingWrite atoms, "
                f"{len(self._awc_to_slit)} &allWritersInClass atoms")

    def _build_potential_uf(self):
        """Least fixpoint over observed ground rules to populate _potential_uf.

        A mergeClasses(a,b) atom is potentially derivable only when some rule
        deriving it has all positive body atoms potentially derivable, where
        &sameClass(x,y) is derivable iff (x,y) are already same-component in
        the potential UF being built.  Non-tracked (structural) atoms are
        treated as unconditionally derivable.

        This kills the circular K-rule bootstrap: mergeClasses(CM,TI) that has
        only a K-rule support requiring &sameClass(CM,TI) never enters the UF
        because that sc atom is cross-component until the merge edge exists.

        Falls back to union-all when no observer data is available.
        """
        merge_proglits = set(self._merge_proglit_to_pair.keys())
        sc_proglits = set(self._sc_proglit_to_pair.keys())

        if not self._obs_rules and not self._obs_unconditional:
            # Observer not registered: use old behavior (union all merge atoms).
            for slit, (a, b) in self._merge_to_pair.items():
                self._potential_uf.union(a, b, slit)
            return

        derivable = set(self._obs_unconditional)

        # Seed UF with merge atoms that are unconditionally derivable.
        for pl in merge_proglits & derivable:
            a, b = self._merge_proglit_to_pair[pl]
            self._potential_uf.union(a, b, self._merge_proglit_to_slit[pl])

        # Rule index: merge head prog_lit → list of positive-body tuples.
        head_to_bodies = {}
        for _choice, heads, pos_body in self._obs_rules:
            for h in heads:
                if h in merge_proglits:
                    head_to_bodies.setdefault(h, []).append(pos_body)

        def body_ok(pos_body):
            for lit in pos_body:
                if lit in sc_proglits:
                    x, y = self._sc_proglit_to_pair[lit]
                    if not self._potential_uf.same(x, y):
                        return False
                elif lit in merge_proglits and lit not in derivable:
                    return False
                # else: structural atom — treat as unconditionally derivable
            return True

        changed = True
        while changed:
            changed = False
            for pl in merge_proglits:
                if pl in derivable:
                    continue
                for body in head_to_bodies.get(pl, []):
                    if body_ok(body):
                        derivable.add(pl)
                        a, b = self._merge_proglit_to_pair[pl]
                        self._potential_uf.union(a, b, self._merge_proglit_to_slit[pl])
                        changed = True
                        break

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

    def _assert_not_all_writers(self, state, ctl, now_alit, class_, awc_slit, cache=None):
        """Assert &allWritersInClass=false: now_alit writer is outside Class's component.

        Clause: ¬nonOverwritingWrite ∨ ¬reason_1 ∨ … ∨ cut_1 ∨ … ∨ ¬awc
        Mirrors _assert_not_same: satisfied once any internal reason is unset
        (backtrack) or any cut edge (bridging mergeClasses) becomes true.
        """
        if cache is None:
            cache = {}
        reason_class, cut_class = self._component_cut_and_reasons(state, class_, cache)
        clause = [-now_alit] + [-r for r in reason_class] + list(cut_class) + [-awc_slit]
        _dprint(f"[awc-false] now_alit={now_alit} class={class_} awc={awc_slit} "
                f"reason={sorted(reason_class)} cut={sorted(cut_class)}")
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

        # &allWritersInClass: handle nonOverwritingWrite and awc literal changes.
        # We only watch the positive literal for each, so lit in changes always means
        # the atom became true (no polarity ambiguity).
        for lit in changes:
            alit = abs(lit)

            if alit in self._now_slit_to_key:
                # A non-overwriting write became confirmed — check awc atoms for its vftable.
                method, vftable = self._now_slit_to_key[alit]
                for class_, awc_slit in self._awc_by_vft.get(vftable, ()):
                    if not state.uf.same(method, class_):
                        if not self._assert_not_all_writers(state, ctl, alit, class_, awc_slit):
                            return

            elif alit in self._awc_slit_to_pair:
                # Solver guessed &allWritersInClass true — verify no out-of-class writer.
                vftable, class_ = self._awc_slit_to_pair[alit]
                awc_slit = lit  # positive literal (we only watch positive)
                for method, now_alit in self._now_writers_by_vft.get(vftable, ()):
                    if asgn.is_true(now_alit) and not state.uf.same(method, class_):
                        if not self._assert_not_all_writers(state, ctl, now_alit, class_, awc_slit):
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

        # Verify &allWritersInClass atoms at stable search states.
        cache = {}
        for (vftable, class_), awc_slit in self._awc_to_slit.items():
            out_of_class_now_alit = None
            for method, now_alit in self._now_writers_by_vft.get(vftable, ()):
                if asgn.is_true(now_alit) and not state.uf.same(method, class_):
                    out_of_class_now_alit = now_alit
                    break

            if out_of_class_now_alit is not None and asgn.is_true(awc_slit):
                _dprint(f"[check] &allWritersInClass({vftable},{class_}) → false (out-of-class writer)")
                if not self._assert_not_all_writers(state, ctl, out_of_class_now_alit,
                                                    class_, awc_slit, cache):
                    return

        if self._foundedness_check:
            self._check_foundedness(ctl)

    def _check_foundedness(self, ctl):
        """Reject total assignments where a true mergeClasses atom is only circularly supported.

        Builds a founded union-find from merge atoms with non-circular justification,
        then flags any true merge atom absent from it as unfounded and adds a clause
        forcing it false.
        """
        asgn = ctl.assignment
        sc_proglits = set(self._sc_proglit_to_pair.keys())
        merge_proglits = set(self._merge_proglit_to_pair.keys())

        true_merges = {}  # prog_lit → (a_key, b_key, solver_lit)
        for pl, (a, b) in self._merge_proglit_to_pair.items():
            slit = self._merge_proglit_to_slit[pl]
            if asgn.is_true(slit):
                true_merges[pl] = (a, b, slit)

        if not true_merges:
            return

        founded = set()   # prog_lits of founded merge atoms
        founded_uf = _UF()

        # Seed: merge atoms with no positive-body conditions (choice facts, etc.)
        for pl in self._unconditional_merge_proglits:
            if pl in true_merges:
                a, b, slit = true_merges[pl]
                founded_uf.union(a, b, slit)
                founded.add(pl)

        def body_active(pos_body):
            """True if all tracked atoms in this rule body are true at this assignment."""
            for lit in pos_body:
                if lit in sc_proglits:
                    x, y = self._sc_proglit_to_pair[lit]
                    sc_slit = self._sc_to_lit.get((x, y))
                    if sc_slit is None or not asgn.is_true(sc_slit):
                        return False
                elif lit in merge_proglits:
                    if not asgn.is_true(self._merge_proglit_to_slit[lit]):
                        return False
                # else: structural atom — treat as true (conservative)
            return True

        def body_founded(pos_body):
            """True if all sc/merge atoms in this rule body are founded."""
            for lit in pos_body:
                if lit in sc_proglits:
                    x, y = self._sc_proglit_to_pair[lit]
                    if not founded_uf.same(x, y):
                        return False
                elif lit in merge_proglits and lit not in founded:
                    return False
            return True

        changed = True
        while changed:
            changed = False
            for pl, (a, b, slit) in true_merges.items():
                if pl in founded:
                    continue
                for body in self._head_to_bodies.get(pl, []):
                    if body_active(body) and body_founded(body):
                        founded_uf.union(a, b, slit)
                        founded.add(pl)
                        changed = True
                        break

        for pl, (a, b, slit) in true_merges.items():
            if pl not in founded:
                _dprint(f"[foundedness] unfounded mergeClasses({a},{b})")
                # Build a permanent clause: ¬mc(a,b) ∨ ⋁{frontier edges from
                # a's founded component in potential_uf, excluding mc(a,b)'s own edge}.
                #
                # This is sound: if mc(a,b) is true and ALL frontier edges are
                # false, then a's founded component has no indirect path to b,
                # so mc(a,b) is circularly unfounded.  The clause fires only in
                # that specific context; once some frontier edge becomes true the
                # clause is satisfied and a later check() decides founding afresh.
                comp_a = _founded_component(founded_uf, a)
                frontier = _frontier_slits(self._potential_uf, comp_a, slit)
                clause = [-slit] + frontier
                if not ctl.add_clause(clause, tag=False):
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


def _founded_component(founded_uf, x):
    """BFS in founded_uf._adj; returns the set of entities reachable from x."""
    visited = {x}
    queue = [x]
    while queue:
        node = queue.pop()
        for other, _ in founded_uf._adj.get(node, ()):
            if other not in visited:
                visited.add(other)
                queue.append(other)
    return visited


def _frontier_slits(potential_uf, founded_comp, excl_slit):
    """Solver literals of potential_uf edges that cross from founded_comp to outside.

    Excludes the edge whose slit == excl_slit (the unfounded merge atom itself).
    Returns a deduplicated list.  An empty list means mc(X,Y) is the only potential
    connection — the caller should add a permanent unit clause ¬mc(X,Y).
    """
    seen = set()
    result = []
    for node in founded_comp:
        for other, slit in potential_uf._adj.get(node, ()):
            if other not in founded_comp and slit != excl_slit and slit not in seen:
                seen.add(slit)
                result.append(slit)
    return result


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
