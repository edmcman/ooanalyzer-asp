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

from dataclasses import dataclass, field
from collections import deque
import time

import clingo

DEBUG = False
PROFILE = False


def _dprint(*args):
    if DEBUG:
        print(*args)


def _profile(*args):
    if PROFILE:
        print("sameclass-profile:", *args)


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
        # The mc-adjacency graph already captures every non-singleton component,
        # so BFS over it touches only the connected members instead of scanning
        # the whole universe. A node with no adjacency is its own singleton.
        if x not in self._adj:
            return {x}
        members = {x}
        queue = deque([x])
        while queue:
            node = queue.popleft()
            for other, _slit in self._adj.get(node, ()):
                if other not in members:
                    members.add(other)
                    queue.append(other)
        return members

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
    initialized: bool = False


class SameClassPropagator:
    def __init__(self, foundedness_check=False):
        self._foundedness_check = foundedness_check
        # Collected by observer callbacks during grounding (before init()).
        # _obs_rules: (choice, heads_tuple, pos_body_tuple) — positive body lits only.
        # _obs_unconditional: prog_lits derivable with no positive-body conditions.
        self._obs_rules = []
        self._obs_head_to_rules = {}
        self._obs_unconditional = set()

    # ── Observer callbacks ───────────────────────────────────────────────────
    # Called during ctl.ground(); program literals here are the same integers
    # as symbolic_atoms[...].literal and theory_atoms[...].literal in init().

    def rule(self, choice, head, body):
        pos_body = tuple(l for l in body if l > 0)
        if not pos_body:
            self._obs_unconditional.update(head)
        else:
            heads = tuple(head)
            rule_idx = len(self._obs_rules)
            self._obs_rules.append((choice, heads, pos_body))
            for h in heads:
                self._obs_head_to_rules.setdefault(h, []).append(rule_idx)

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
        init_profile_start = time.perf_counter() if PROFILE else None
        # check() is part of eager propagation: it asserts sameClass atoms that
        # become true through multi-edge paths once watched merge propagation has
        # reached a fixpoint.  Without Fixpoint checks, search can run for a long
        # time before a total assignment ever gives the propagator a chance to
        # add these path clauses.
        init.check_mode = clingo.PropagatorCheckMode.Both

        # solver_lit → [(a_key, b_key)]
        #
        # Multiple ground atoms can share one solver literal. In particular,
        # facts are mapped to solver literal 1. Do not collapse these pairs.
        self._merge_lit_to_pairs = {}
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
        if PROFILE:
            _profile("init mergeEntity", f"entities={len(self._entities)}")

        for sym_atom in init.symbolic_atoms.by_signature("mergeClasses", 2):
            args = sym_atom.symbol.arguments
            a, b = _sym_key(args[0]), _sym_key(args[1])
            prog_lit = sym_atom.literal
            slit = init.solver_literal(prog_lit)
            self._merge_lit_to_pairs.setdefault(slit, []).append((a, b))
            self._merge_proglit_to_pair[prog_lit] = (a, b)
            self._merge_proglit_to_slit[prog_lit] = slit
            self._merge_by_entity.setdefault(a, []).append((b, slit))
            self._merge_by_entity.setdefault(b, []).append((a, slit))
            self._entities.update((a, b))
            if abs(slit) != 1:
                init.add_watch(slit)
        if PROFILE:
            merge_count = sum(len(pairs) for pairs in self._merge_lit_to_pairs.values())
            _profile(
                "init mergeClasses",
                f"merge_atoms={merge_count}",
                f"merge_solver_lits={len(self._merge_lit_to_pairs)}",
            )

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
        if PROFILE:
            _profile(
                "init sameClass atoms",
                f"sameclass_atoms={len(self._sc_to_lit)}",
                f"entities={len(self._entities)}",
            )

        # Potential connectivity: which pairs could EVER be same class?
        # Uses a least fixpoint over the observed ground rules so that K-rule
        # heads (which need &sameClass in their body) cannot circularly bootstrap.
        # Falls back to union-all if no observer data was registered.
        self._potential_uf = _UF()
        self._build_potential_uf()
        if PROFILE:
            _profile(
                "init potential-uf done",
                f"elapsed={time.perf_counter() - init_profile_start:.3f}s",
            )

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
        if PROFILE:
            _profile("init level0 sameClass clauses")

        # Direct wiring: mergeClasses(A,B) → sameClass(A,B).
        #
        # The reverse implication is not globally sound: A and B can be in the
        # same class via a transitive path while the direct mergeClasses(A,B)
        # atom is false.  It is sound for bridge edges, though, and those clauses
        # recover important pruning without losing transitive sameClass models.
        reverse_safe_cache = {}
        for merge_slit, pairs in self._merge_lit_to_pairs.items():
            for a, b in pairs:
                cache_key = (a, b, merge_slit)
                reverse_is_safe = reverse_safe_cache.get(cache_key)
                if reverse_is_safe is None:
                    reverse_is_safe = not self._potential_connected_without_lit(a, b, merge_slit)
                    reverse_safe_cache[cache_key] = reverse_is_safe
                    reverse_safe_cache[(b, a, merge_slit)] = reverse_is_safe
                for pair in [(a, b), (b, a)]:
                    if pair in self._sc_to_lit:
                        sc_slit = self._sc_to_lit[pair]
                        init.add_clause([-merge_slit, sc_slit])   # merge → same
                        if reverse_is_safe:
                            init.add_clause([merge_slit, -sc_slit])   # same → merge

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
        if PROFILE:
            _profile(
                "init vftable writer theory",
                f"nonOverwritingWrite={len(self._now_slit_to_key)}",
                f"allWritersInClass={len(self._awc_to_slit)}",
            )

        self._observed_proglits = set(self._obs_unconditional)
        self._unconditional_proglits = set(self._obs_unconditional)
        for _choice, heads, pos_body in self._obs_rules:
            self._observed_proglits.update(heads)
            self._observed_proglits.update(pos_body)

        self._proglit_to_slit = {}
        for prog_lit in self._observed_proglits:
            try:
                self._proglit_to_slit[prog_lit] = init.solver_literal(prog_lit)
            except RuntimeError:
                pass
        if PROFILE:
            _profile(
                "init observed proglits",
                f"observed={len(self._observed_proglits)}",
                f"mapped={len(self._proglit_to_slit)}",
            )

        # Pre-compute rule index for foundedness check.
        if self._foundedness_check:
            self._head_to_bodies = {}
            for _choice, heads, pos_body in self._obs_rules:
                for h in heads:
                    self._head_to_bodies.setdefault(h, []).append(pos_body)

        # Release raw observer data — no longer needed.
        self._obs_rules = []
        self._obs_head_to_rules = {}
        self._obs_unconditional = set()

        self._states = [_ThreadState() for _ in range(init.number_of_threads)]
        merge_count = sum(len(pairs) for pairs in self._merge_lit_to_pairs.values())
        _dprint(f"[init] {merge_count} mergeClasses, "
                f"{len(self._sc_to_lit)} &sameClass atoms, "
                f"{len(self._now_slit_to_key)} nonOverwritingWrite atoms, "
                f"{len(self._awc_to_slit)} &allWritersInClass atoms")
        if PROFILE:
            _profile("init total", f"elapsed={time.perf_counter() - init_profile_start:.3f}s")

    def _build_potential_uf(self):
        """Least fixpoint over observed ground rules to populate _potential_uf.

        A mergeClasses(a,b) atom is potentially derivable only when some rule
        deriving it has all positive body atoms potentially derivable, where
        &sameClass(x,y) is derivable iff (x,y) are already same-component in
        the potential UF being built. Ordinary helper atoms are derived through
        the same positive-rule fixpoint so they cannot hide circular sc deps.

        This kills the circular K-rule bootstrap: mergeClasses(CM,TI) that has
        only a K-rule support requiring &sameClass(CM,TI) never enters the UF
        because that sc atom is cross-component until the merge edge exists.

        Falls back to union-all when no observer data is available.
        """
        profile_start = time.perf_counter() if PROFILE else None
        merge_proglits = set(self._merge_proglit_to_pair.keys())
        sc_proglits = set(self._sc_proglit_to_pair.keys())

        if not self._obs_rules and not self._obs_unconditional:
            # Observer not registered: use old behavior (union all merge atoms).
            union_count = 0
            for slit, pairs in self._merge_lit_to_pairs.items():
                for a, b in pairs:
                    union_count += 1
                    self._potential_uf.union(a, b, slit)
            if PROFILE:
                _profile(
                    "potential-uf fallback",
                    f"merge_unions={union_count}",
                    f"elapsed={time.perf_counter() - profile_start:.3f}s",
                )
            return

        derivable = set(self._obs_unconditional)
        sc_derivable = set()
        ready = deque()
        blocked_by_lit = {}
        slice_start = time.perf_counter() if PROFILE else None
        relevant_rules = set()
        pending_targets = deque(pl for pl in merge_proglits if pl not in derivable)
        seen_targets = set(pending_targets)
        while pending_targets:
            target = pending_targets.popleft()
            for rule_idx in self._obs_head_to_rules.get(target, ()):
                if rule_idx in relevant_rules:
                    continue
                relevant_rules.add(rule_idx)
                _choice, _heads, pos_body = self._obs_rules[rule_idx]
                for lit in pos_body:
                    if lit in sc_proglits or lit in derivable or lit in seen_targets:
                        continue
                    seen_targets.add(lit)
                    pending_targets.append(lit)

        rules_indexed = 0
        ready_initial = 0
        ready_pops = 0
        blocked_initial = 0
        reblocks = 0
        wake_calls = 0
        woke_rules = 0
        derivable_added = 0
        merge_added = 0
        redundant_merge_added = 0
        sc_added = 0
        max_ready = 0

        sc_by_entity = {}
        for pl, (x, y) in self._sc_proglit_to_pair.items():
            sc_by_entity.setdefault(x, []).append((y, pl))
            if x != y:
                sc_by_entity.setdefault(y, []).append((x, pl))

        # Seed UF with merge atoms that are unconditionally derivable.
        for pl in merge_proglits & derivable:
            a, b = self._merge_proglit_to_pair[pl]
            self._potential_uf.union(a, b, self._merge_proglit_to_slit[pl])

        # Reflexive and seed-connected sameClass atoms are available before any
        # rule indexing. Later ones are awakened incrementally as UF components
        # are connected by newly derivable mergeClasses atoms.
        for pl, (x, y) in self._sc_proglit_to_pair.items():
            if self._potential_uf.same(x, y):
                sc_derivable.add(pl)
        sc_seed_count = len(sc_derivable)

        def first_blocker(pos_body):
            for lit in pos_body:
                if lit in sc_proglits:
                    if lit not in sc_derivable:
                        return lit
                elif lit not in derivable:
                    return lit
            return None

        def block_or_ready(rule_idx):
            nonlocal reblocks, max_ready
            _choice, _heads, pos_body = self._obs_rules[rule_idx]
            blocker = first_blocker(pos_body)
            if blocker is None:
                ready.append(rule_idx)
                max_ready = max(max_ready, len(ready))
            else:
                reblocks += 1
                blocked_by_lit.setdefault(blocker, []).append(rule_idx)

        def wake(lit):
            nonlocal wake_calls, woke_rules
            waiting = blocked_by_lit.pop(lit, ())
            if not waiting:
                return
            wake_calls += 1
            woke_rules += len(waiting)
            for rule_idx in waiting:
                block_or_ready(rule_idx)

        def mark_sc_derivable(pl):
            nonlocal sc_added
            if pl in sc_derivable:
                return
            sc_derivable.add(pl)
            sc_added += 1
            wake(pl)

        def add_potential_merge(pl):
            nonlocal merge_added, redundant_merge_added
            a, b = self._merge_proglit_to_pair[pl]
            slit = self._merge_proglit_to_slit[pl]
            already_connected = self._potential_uf.same(a, b)
            if not already_connected:
                comp_a = self._potential_uf.component(a)
                comp_b = self._potential_uf.component(b)
            else:
                comp_a = comp_b = ()
                redundant_merge_added += 1
            merge_added += 1

            # Always record the edge, even if it is redundant; later bridge-edge
            # tests need the full potential merge graph, not just the UF forest.
            self._potential_uf.union(a, b, slit)

            if already_connected:
                return
            if len(comp_a) > len(comp_b):
                comp_a, comp_b = comp_b, comp_a
            comp_b = set(comp_b)
            for x in comp_a:
                for y, sc_pl in sc_by_entity.get(x, ()):
                    if y in comp_b:
                        mark_sc_derivable(sc_pl)

        def mark_derivable(pl):
            nonlocal derivable_added
            if pl in derivable:
                return
            derivable.add(pl)
            derivable_added += 1
            wake(pl)
            if pl in merge_proglits:
                add_potential_merge(pl)

        for idx in relevant_rules:
            _choice, _heads, pos_body = self._obs_rules[idx]
            rules_indexed += 1
            if pos_body:
                before_ready = len(ready)
                before_reblocks = reblocks
                block_or_ready(idx)
                if len(ready) > before_ready:
                    ready_initial += 1
                elif reblocks > before_reblocks:
                    blocked_initial += 1
            else:
                ready.append(idx)
                ready_initial += 1
                max_ready = max(max_ready, len(ready))

        while ready:
            rule_idx = ready.popleft()
            ready_pops += 1
            _choice, heads, _pos_body = self._obs_rules[rule_idx]
            for pl in heads:
                mark_derivable(pl)

        if PROFILE:
            _profile(
                "potential-uf worklist",
                f"obs_rules={len(self._obs_rules)}",
                f"sliced_rules={len(relevant_rules)}",
                f"slice_targets={len(seen_targets)}",
                f"slice_elapsed={time.perf_counter() - slice_start:.3f}s",
                f"unconditional={len(self._obs_unconditional)}",
                f"merge_proglits={len(merge_proglits)}",
                f"sc_proglits={len(sc_proglits)}",
                f"seeded_sc={sc_seed_count}",
                f"rules_indexed={rules_indexed}",
                f"ready_initial={ready_initial}",
                f"blocked_initial={blocked_initial}",
                f"reblocks={reblocks}",
                f"wake_calls={wake_calls}",
                f"woke_rules={woke_rules}",
                f"ready_pops={ready_pops}",
                f"max_ready={max_ready}",
                f"derivable_added={derivable_added}",
                f"merge_added={merge_added}",
                f"redundant_merge_added={redundant_merge_added}",
                f"sc_added={sc_added}",
                f"derivable_total={len(derivable)}",
                f"sc_total={len(sc_derivable)}",
                f"elapsed={time.perf_counter() - profile_start:.3f}s",
            )

    def _potential_connected_without_lit(self, a, b, excluded_slit):
        """Whether a and b have a potential path without `excluded_slit` edges."""
        if a == b:
            return True
        visited = {a}
        queue = deque([a])
        while queue:
            node = queue.popleft()
            for other, slit in self._potential_uf._adj.get(node, ()):
                if slit == excluded_slit:
                    continue
                if other == b:
                    return True
                if other not in visited:
                    visited.add(other)
                    queue.append(other)
        return False

    def _state(self, thread_id):
        return self._states[thread_id]

    def _rebuild(self, state, assignment):
        # Seed only level-0 fixed-true merges: these can never be undone, so they
        # need no trail entries. Non-fixed true merges are watched (abs(slit)!=1)
        # and arrive through propagate's `changes` with trail entries, which keeps
        # merge_trail level-monotone so the incremental undo can restore by suffix.
        # Seeding non-fixed merges here (in dict order) would break that order.
        state.uf = _UF()
        for slit, pairs in self._merge_lit_to_pairs.items():
            if assignment.is_true(slit) and assignment.is_fixed(slit):
                for a, b in pairs:
                    state.uf.union(a, b, slit)

    def _ensure_initialized(self, state, assignment):
        if not state.initialized:
            self._rebuild(state, assignment)
            state.merge_trail = []
            state.initialized = True

    @staticmethod
    def _assignment_is_total(assignment):
        is_total = getattr(assignment, "is_total", None)
        return is_total() if callable(is_total) else bool(is_total)

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
        component = state.uf.component(x)
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
        self._ensure_initialized(state, asgn)
        for lit in changes:
            if lit in self._merge_lit_to_pairs:
                for a, b in self._merge_lit_to_pairs[lit]:
                    if state.uf.same(a, b):
                        continue
                    comp_a = state.uf.component(a)
                    comp_b = state.uf.component(b)
                    snapshot = state.uf.snapshot()
                    if state.uf.union(a, b, lit):
                        state.merge_trail.append((lit, snapshot))
                        _dprint(f"[propagate] union({a},{b})")
                        if len(comp_a) > len(comp_b):
                            comp_a, comp_b = comp_b, comp_a
                        for x in comp_a:
                            for y, sc_lit in self._sc_by_entity.get(x, ()):
                                if y in comp_b and not asgn.is_true(sc_lit):
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
        if not state.merge_trail:
            return
        # The merge edges added at the level(s) being undone form a contiguous
        # suffix at the top of merge_trail: deeper levels were already restored,
        # and edges are appended in assignment order, so trail order matches
        # level order. `changes` lists the unassigned literals but NOT in trail
        # order, so match the trail top by membership in `changes`, not by
        # position. The old `== lit` check missed most edges and fell back to an
        # O(all-merges) _rebuild on ~72% of undos.
        changes_set = set(changes)
        while state.merge_trail and state.merge_trail[-1][0] in changes_set:
            _lit, snapshot = state.merge_trail.pop()
            state.uf.restore(snapshot)

    def check(self, ctl):
        """Validate assigned &sameClass atoms without eagerly deciding negatives."""
        asgn = ctl.assignment
        state = self._state(ctl.thread_id)
        self._ensure_initialized(state, asgn)
        for x, y, slit in self._check_atoms:
            is_same = state.uf.same(x, y)  # root-only; reason built lazily on assert
            if is_same:
                if not asgn.is_true(slit):
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

        if self._foundedness_check and self._assignment_is_total(asgn):
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

        founded = set()   # prog_lits of founded true atoms
        founded_uf = _UF()

        def lit_true(prog_lit):
            if prog_lit in sc_proglits:
                x, y = self._sc_proglit_to_pair[prog_lit]
                sc_slit = self._sc_to_lit.get((x, y))
                return sc_slit is not None and asgn.is_true(sc_slit)
            slit = self._proglit_to_slit.get(prog_lit)
            if slit is None:
                # Be conservative for any solver-internal literal we cannot map.
                return True
            return asgn.is_true(slit)

        def mark_founded(prog_lit):
            founded.add(prog_lit)
            if prog_lit in true_merges:
                a, b, slit = true_merges[prog_lit]
                founded_uf.union(a, b, slit)

        # Seed: true atoms with no positive-body conditions (facts, selected
        # choice atoms, conservative weight-rule heads, etc.).
        for pl in self._unconditional_proglits:
            if lit_true(pl):
                mark_founded(pl)

        def body_active(pos_body):
            """True if all tracked atoms in this rule body are true at this assignment."""
            for lit in pos_body:
                if not lit_true(lit):
                    return False
            return True

        def body_founded(pos_body):
            """True if all positive body atoms in this rule body are founded."""
            for lit in pos_body:
                if lit in sc_proglits:
                    x, y = self._sc_proglit_to_pair[lit]
                    if not founded_uf.same(x, y):
                        return False
                elif lit in self._observed_proglits and lit not in founded:
                    return False
            return True

        changed = True
        while changed:
            changed = False
            for pl in self._observed_proglits:
                if pl in founded or not lit_true(pl):
                    continue
                for body in self._head_to_bodies.get(pl, []):
                    if body_active(body) and body_founded(body):
                        mark_founded(pl)
                        changed = True
                        break

        unfounded_merges = [
            (pl, a, b, slit)
            for pl, (a, b, slit) in true_merges.items()
            if pl not in founded
        ]
        if not unfounded_merges:
            return

        for _pl, a, b, _slit in unfounded_merges:
            _dprint(f"[foundedness] unfounded mergeClasses({a},{b})")

        # The older per-edge "frontier" clause was too local:
        #
        #   ¬mc1 ∨ mc2
        #   ¬mc2 ∨ mc1
        #
        # lets two unfounded frontier edges justify each other forever.  Instead,
        # block the complete truth assignment observed by this foundedness pass.
        # If any relevant rule-body atom, merge edge, or sameClass atom changes,
        # this clause is satisfied and a later check recomputes founded support.
        clause = self._foundedness_assignment_blocker(asgn)
        if not ctl.add_clause(clause, tag=False):
            return

    def _foundedness_assignment_blocker(self, asgn):
        """Return a clause that blocks the current foundedness-observed assignment."""
        clause = []
        seen = set()

        def add_current_truth(slit):
            if slit is None or slit in seen:
                return
            seen.add(slit)
            if asgn.is_true(slit):
                clause.append(-slit)
            elif asgn.is_false(slit):
                clause.append(slit)

        for pl in self._observed_proglits:
            if pl in self._merge_proglit_to_slit:
                add_current_truth(self._merge_proglit_to_slit[pl])
            elif pl in self._sc_proglit_to_pair:
                add_current_truth(self._proglit_to_slit.get(pl))
            else:
                add_current_truth(self._proglit_to_slit.get(pl))

        for slit in self._merge_proglit_to_slit.values():
            add_current_truth(slit)
        for slit in self._sc_to_lit.values():
            add_current_truth(slit)

        return clause

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


class LazySameClassConsistencyPropagator:
    """Simple diagnostic checker for &sameClass/2 and &allWritersInClass/2.

    This mode deliberately avoids the eager propagation and potential-UF logic in
    SameClassPropagator.  At check points it rebuilds a union-find from the
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
