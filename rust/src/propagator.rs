//! Core propagator logic: `init`, `propagate`, `undo`, `check`, the `assert_*`
//! reason-clause builders, foundedness, and the observer callbacks. Port of
//! `sameclass.py:SameClassPropagator` (lines 246–1109).
//!
//! Every entry point recovers `&Shared` (read-only, behind `Arc`) and locks the
//! calling thread's `ThreadState`. No GIL/Python is touched.

use crate::entkey::EntKey;
use crate::ffi::{
    ClingoAssignment, ClingoAtom, ClingoExternalType, ClingoId, ClingoLiteral,
    ClingoPropagateControl, ClingoPropagateInit, ClingoSymbol, ClingoSymbolicAtoms, Ffi,
    CHECK_MODE_TOTAL, EXTERNAL_TYPE_FALSE,
};
use crate::potential_uf;
use crate::shared::{CrAtom, MergeScFacts, ObsRule, PropData, Shared};
use crate::threadstate::ThreadState;
use crate::uf::Uf;
use rustc_hash::{FxHashMap, FxHashSet};
use std::collections::VecDeque;

/// Add a learnt clause via the control; yields its consistency bool, or returns
/// the clingo error message up the stack on API failure.
macro_rules! clause {
    ($ffi:expr, $ctrl:expr, $c:expr) => {
        match $ffi.add_clause($ctrl, $c) {
            Ok(ok) => ok,
            Err(e) => return Err(e.message),
        }
    };
}

type Result_ = std::result::Result<(), String>;

// ── observer callbacks (run during ctl.ground(), single-threaded) ────────────

pub fn obs_rule(
    pd: &PropData,
    choice: bool,
    head: &[ClingoAtom],
    body: &[ClingoLiteral],
) -> Result_ {
    let pos_body: Vec<i32> = body.iter().filter(|&&l| l > 0).copied().collect();
    let mut obs = pd.obs.lock().unwrap();
    if pos_body.is_empty() {
        for &a in head {
            obs.unconditional.insert(a as i32);
        }
    } else {
        let heads: Vec<i32> = head.iter().map(|&a| a as i32).collect();
        let rule_idx = obs.rules.len();
        obs.rules.push(ObsRule {
            choice,
            heads: heads.clone(),
            pos_body,
        });
        for h in heads {
            obs.head_to_rules.entry(h).or_default().push(rule_idx);
        }
    }
    Ok(())
}

pub fn obs_unconditional(pd: &PropData, heads: &[i32]) -> Result_ {
    let mut obs = pd.obs.lock().unwrap();
    obs.unconditional.extend(heads.iter().copied());
    Ok(())
}

pub fn obs_external(pd: &PropData, atom: i32, value: ClingoExternalType) -> Result_ {
    if value != EXTERNAL_TYPE_FALSE {
        pd.obs.lock().unwrap().unconditional.insert(atom);
    }
    Ok(())
}

// ── init ─────────────────────────────────────────────────────────────────────

pub fn init(ffi: &Ffi, pd: &PropData, init_ptr: *mut ClingoPropagateInit) -> Result_ {
    ffi.set_check_mode(init_ptr, CHECK_MODE_TOTAL);

    // Serialize first-build; later threads see the frozen Shared and return.
    let _guard = pd.init_lock.lock().unwrap();
    if pd.shared.get().is_some() {
        return Ok(());
    }
    let shared = build_shared(ffi, pd, init_ptr)?;
    let _ = pd.shared.set(std::sync::Arc::new(shared));
    Ok(())
}

fn build_shared(
    ffi: &Ffi,
    pd: &PropData,
    init_ptr: *mut ClingoPropagateInit,
) -> Result<Shared, String> {
    let sym_atoms = ffi.init_symbolic_atoms(init_ptr).map_err(|e| e.message)?;
    let theory_atoms = ffi.init_theory_atoms(init_ptr).map_err(|e| e.message)?;

    let mut facts = MergeScFacts::default();
    let mut sc_to_lit: FxHashMap<(EntKey, EntKey), i32> = FxHashMap::default();
    let mut sc_lit_to_pair: FxHashMap<i32, (EntKey, EntKey)> = FxHashMap::default();
    let mut sc_by_entity: FxHashMap<EntKey, Vec<(EntKey, i32)>> = FxHashMap::default();
    let mut merge_by_entity: FxHashMap<EntKey, Vec<(EntKey, i32)>> = FxHashMap::default();
    let mut entities: FxHashSet<EntKey> = FxHashSet::default();

    // mergeEntity/1
    each_sym_atom(ffi, sym_atoms, "mergeEntity", 1, |sym, _| {
        if let Some(args) = ffi.symbol_arguments(sym).ok() {
            if let Some(&a) = args.get(0) {
                entities.insert(EntKey::from_symbol(ffi, a));
            }
        }
    });

    // mergeClasses/2
    each_sym_atom(ffi, sym_atoms, "mergeClasses", 2, |sym, prog_lit| {
        let args = match ffi.symbol_arguments(sym).ok() {
            Some(a) => a,
            None => return,
        };
        if args.len() < 2 {
            return;
        }
        let a = EntKey::from_symbol(ffi, args[0]);
        let b = EntKey::from_symbol(ffi, args[1]);
        let slit = match ffi.solver_literal(init_ptr, prog_lit).ok() {
            Some(s) => s,
            None => return,
        };
        facts
            .merge_lit_to_pairs
            .entry(slit)
            .or_default()
            .push((a.clone(), b.clone()));
        facts
            .merge_proglit_to_pair
            .insert(prog_lit, (a.clone(), b.clone()));
        facts.merge_proglit_to_slit.insert(prog_lit, slit);
        merge_by_entity
            .entry(a.clone())
            .or_default()
            .push((b.clone(), slit));
        merge_by_entity
            .entry(b.clone())
            .or_default()
            .push((a.clone(), slit));
        entities.insert(a);
        entities.insert(b);
        if slit.abs() != 1 {
            ffi.add_watch(init_ptr, slit);
        }
    });

    // &sameClass/2, &allWritersInClass/2, &classRelationship{,Via}/2 theory atoms.
    let mut now_slit_to_key: FxHashMap<i32, (EntKey, EntKey)> = FxHashMap::default();
    let mut now_writers_by_vft: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> = FxHashMap::default();
    let mut awc_to_slit: FxHashMap<(EntKey, EntKey), i32> = FxHashMap::default();
    let mut awc_slit_to_pair: FxHashMap<i32, (EntKey, EntKey)> = FxHashMap::default();
    let mut awc_by_vft: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> = FxHashMap::default();
    let mut cr_atoms: Vec<CrAtom> = Vec::new();
    let mut chw_atoms: Vec<(EntKey, EntKey, i32)> = Vec::new();

    for atom in 0..ffi.theory_atoms_size(theory_atoms) as u32 {
        let term = ffi.theory_atom_term(theory_atoms, atom);
        let prog_lit = match ffi.theory_atom_literal(theory_atoms, atom).ok() {
            Some(l) => l,
            None => continue,
        };
        let name = ffi.theory_term_name(theory_atoms, term).unwrap_or_default();
        let args = ffi
            .theory_term_arguments(theory_atoms, term)
            .unwrap_or_default();
        let slit = match ffi.solver_literal(init_ptr, prog_lit).ok() {
            Some(s) => s,
            None => continue,
        };
        match name.as_str() {
            "sameClass" if args.len() == 2 => {
                let x = EntKey::from_theory_term(ffi, theory_atoms, args[0]);
                let y = EntKey::from_theory_term(ffi, theory_atoms, args[1]);
                facts
                    .sc_proglit_to_pair
                    .insert(prog_lit, (x.clone(), y.clone()));
                sc_to_lit.insert((x.clone(), y.clone()), slit);
                sc_lit_to_pair.insert(slit, (x.clone(), y.clone()));
                sc_by_entity
                    .entry(x.clone())
                    .or_default()
                    .push((y.clone(), slit));
                if x != y {
                    sc_by_entity
                        .entry(y.clone())
                        .or_default()
                        .push((x.clone(), slit));
                }
                entities.insert(x);
                entities.insert(y);
                ffi.add_watch(init_ptr, slit);
            }
            "allWritersInClass" if args.len() == 2 => {
                let vft = EntKey::from_theory_term(ffi, theory_atoms, args[0]);
                let class_ = EntKey::from_theory_term(ffi, theory_atoms, args[1]);
                awc_to_slit.insert((vft.clone(), class_.clone()), slit);
                awc_slit_to_pair.insert(slit.abs(), (vft.clone(), class_.clone()));
                awc_by_vft
                    .entry(vft.clone())
                    .or_default()
                    .insert((class_, slit));
                ffi.add_watch(init_ptr, slit);
            }
            "classRelationship" | "classRelationshipVia" if args.len() == 2 => {
                let a = EntKey::from_theory_term(ffi, theory_atoms, args[0]);
                let b = EntKey::from_theory_term(ffi, theory_atoms, args[1]);
                cr_atoms.push(CrAtom {
                    a,
                    b,
                    slit,
                    via: name == "classRelationshipVia",
                });
                ffi.add_watch(init_ptr, slit);
            }
            "classHasWitness" if args.len() == 2 => {
                let group = EntKey::from_theory_term(ffi, theory_atoms, args[0]);
                let class_ = EntKey::from_theory_term(ffi, theory_atoms, args[1]);
                chw_atoms.push((group, class_, slit));
                ffi.add_watch(init_ptr, slit);
            }
            _ => {}
        }
    }

    // objectInObject/3 — containment edges for &classRelationship* reachability.
    let mut oio_lit_to_edges: FxHashMap<i32, Vec<(EntKey, EntKey)>> = FxHashMap::default();
    each_sym_atom(ffi, sym_atoms, "objectInObject", 3, |sym, prog_lit| {
        let args = match ffi.symbol_arguments(sym).ok() {
            Some(a) => a,
            None => return,
        };
        if args.len() < 3 {
            return;
        }
        let outer = EntKey::from_symbol(ffi, args[0]);
        let inner = EntKey::from_symbol(ffi, args[1]);
        let lit = match ffi.solver_literal(init_ptr, prog_lit).ok() {
            Some(s) => s,
            None => return,
        };
        let is_new = !oio_lit_to_edges.contains_key(&lit);
        oio_lit_to_edges
            .entry(lit)
            .or_default()
            .push((outer, inner));
        if is_new && lit.abs() != 1 {
            ffi.add_watch(init_ptr, lit);
        }
    });

    // witnessGroup/2 — existential witness membership for &classHasWitness.
    // ASP-side sites tag the group term so unrelated witness pools never
    // collide (e.g. sizeGroup(S), methodGroup(M), zeroGroup).
    let mut witness_slit_to_group: FxHashMap<i32, EntKey> = FxHashMap::default();
    let mut witness_by_group_set: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> =
        FxHashMap::default();
    each_sym_atom(ffi, sym_atoms, "witnessGroup", 2, |sym, prog_lit| {
        let args = match ffi.symbol_arguments(sym).ok() {
            Some(a) => a,
            None => return,
        };
        if args.len() < 2 {
            return;
        }
        let group = EntKey::from_symbol(ffi, args[0]);
        let witness = EntKey::from_symbol(ffi, args[1]);
        let lit = match ffi.solver_literal(init_ptr, prog_lit).ok() {
            Some(s) => s,
            None => return,
        };
        let alit = lit.abs();
        witness_slit_to_group.insert(alit, group.clone());
        witness_by_group_set
            .entry(group)
            .or_default()
            .insert((witness, alit));
        ffi.add_watch(init_ptr, lit);
    });

    // nonOverwritingWrite/3
    each_sym_atom(ffi, sym_atoms, "nonOverwritingWrite", 3, |sym, prog_lit| {
        let args = match ffi.symbol_arguments(sym).ok() {
            Some(a) => a,
            None => return,
        };
        if args.len() < 3 {
            return;
        }
        let method = EntKey::from_symbol(ffi, args[0]);
        let vftable = EntKey::from_symbol(ffi, args[2]);
        let lit = match ffi.solver_literal(init_ptr, prog_lit).ok() {
            Some(s) => s,
            None => return,
        };
        let alit = lit.abs();
        now_slit_to_key.insert(alit, (method.clone(), vftable.clone()));
        now_writers_by_vft
            .entry(vftable)
            .or_default()
            .insert((method, alit));
        ffi.add_watch(init_ptr, lit);
    });

    // Potential connectivity (least fixpoint over observed rules).
    let mut potential_uf = Uf::new();
    let obs = pd.obs.lock().unwrap();
    potential_uf::build_potential_uf(&mut potential_uf, &obs, &facts);
    let observed_proglits: FxHashSet<i32> = {
        let mut s = obs.unconditional.clone();
        for r in &obs.rules {
            for &h in &r.heads {
                s.insert(h);
            }
            for &l in &r.pos_body {
                s.insert(l);
            }
        }
        s
    };
    let unconditional_proglits = obs.unconditional.clone();
    let mut head_to_bodies: FxHashMap<i32, Vec<Vec<i32>>> = FxHashMap::default();
    if pd.foundedness_check {
        for r in &obs.rules {
            for &h in &r.heads {
                head_to_bodies
                    .entry(h)
                    .or_default()
                    .push(r.pos_body.clone());
            }
        }
    }
    drop(obs); // release observer data

    let mut proglit_to_slit: FxHashMap<i32, i32> = FxHashMap::default();
    for pl in &observed_proglits {
        if let Ok(slit) = ffi.solver_literal(init_ptr, *pl) {
            proglit_to_slit.insert(*pl, slit);
        }
    }

    // check_atoms: non-reflexive sameClass atoms that are potentially same.
    let check_atoms: Vec<(EntKey, EntKey, i32)> = sc_to_lit
        .iter()
        .filter(|((x, y), _)| x != y && potential_uf.same(x, y))
        .map(|((x, y), &slit)| (x.clone(), y.clone(), slit))
        .collect();

    // Level-0 clauses: reflexive → true, cross-component → false.
    for ((x, y), &slit) in &sc_to_lit {
        if x == y {
            init_add(ffi, init_ptr, &[slit]);
        } else if !potential_uf.same(x, y) {
            init_add(ffi, init_ptr, &[-slit]);
        }
    }

    // Direct wiring mergeClasses(A,B) ↔ sameClass(A,B) (reverse only if bridge-safe).
    let mut reverse_safe_cache: FxHashMap<(EntKey, EntKey, i32), bool> = FxHashMap::default();
    for (&merge_slit, pairs) in &facts.merge_lit_to_pairs {
        for (a, b) in pairs {
            let key = (a.clone(), b.clone(), merge_slit);
            let reverse_is_safe = match reverse_safe_cache.get(&key) {
                Some(&v) => v,
                None => {
                    let v = !potential_uf.connected_without_lit(a, b, merge_slit);
                    reverse_safe_cache.insert(key, v);
                    reverse_safe_cache.insert((b.clone(), a.clone(), merge_slit), v);
                    v
                }
            };
            for (x, y) in [(a.clone(), b.clone()), (b.clone(), a.clone())] {
                if let Some(&sc_slit) = sc_to_lit.get(&(x, y)) {
                    init_add(ffi, init_ptr, &[-merge_slit, sc_slit]);
                    if reverse_is_safe {
                        init_add(ffi, init_ptr, &[merge_slit, -sc_slit]);
                    }
                }
            }
        }
    }

    // Level-0 pruning for &classRelationship*: a target unreachable from the
    // source even with ALL candidate edges present and potential merge
    // connectivity is false forever. (Applied to the Via variant too — its
    // semantics are strictly stronger, so plain-unreachable implies Via-false.)
    {
        let mut padj: FxHashMap<EntKey, FxHashSet<EntKey>> = FxHashMap::default();
        for edges in oio_lit_to_edges.values() {
            for (o, i) in edges {
                let ro = potential_uf.root(o);
                let ri = potential_uf.root(i);
                padj.entry(ro).or_default().insert(ri);
            }
        }
        let mut reach_cache: FxHashMap<EntKey, FxHashSet<EntKey>> = FxHashMap::default();
        let mut live: Vec<CrAtom> = Vec::with_capacity(cr_atoms.len());
        for cr in cr_atoms.drain(..) {
            let ra = potential_uf.root(&cr.a);
            let rb = potential_uf.root(&cr.b);
            if !reach_cache.contains_key(&ra) {
                reach_cache.insert(ra.clone(), potential_reach(&padj, &ra));
            }
            if reach_cache[&ra].contains(&rb) {
                live.push(cr);
            } else {
                // Statically unreachable: fixed false forever, drop from the
                // runtime sweep entirely.
                init_add(ffi, init_ptr, &[-cr.slit]);
            }
        }
        cr_atoms = live;
    }
    cr_atoms.sort_by(|x, y| x.a.cmp(&y.a).then(x.b.cmp(&y.b)).then(x.slit.cmp(&y.slit)));
    let cr_slit_to_atom: FxHashMap<i32, CrAtom> =
        cr_atoms.iter().map(|c| (c.slit.abs(), c.clone())).collect();

    // Level-0 pruning for &classHasWitness: a (group, class) pair can only ever
    // be true if some witness of the group is potentially same-class as class.
    {
        let mut live: Vec<(EntKey, EntKey, i32)> = Vec::with_capacity(chw_atoms.len());
        for (group, class_, slit) in chw_atoms.drain(..) {
            let possible = witness_by_group_set
                .get(&group)
                .map(|ws| ws.iter().any(|(w, _)| potential_uf.same(w, &class_)))
                .unwrap_or(false);
            if possible {
                live.push((group, class_, slit));
            } else {
                init_add(ffi, init_ptr, &[-slit]);
            }
        }
        chw_atoms = live;
    }
    chw_atoms.sort_by(|x, y| x.0.cmp(&y.0).then(x.1.cmp(&y.1)).then(x.2.cmp(&y.2)));

    // Freeze deterministic, interpreter-independent iteration order.
    let now_writers_by_vft = freeze_sorted(now_writers_by_vft);
    let awc_by_vft = freeze_sorted(awc_by_vft);
    let witness_by_group = freeze_sorted(witness_by_group_set);

    // Reverse indices for &classHasWitness so propagate()/check() only ever
    // touch the atoms a given change could actually affect, instead of
    // sweeping the (potentially tens-of-thousands-large) full chw_atoms list.
    let mut witness_entity_to_groups: FxHashMap<EntKey, Vec<EntKey>> = FxHashMap::default();
    {
        let mut groups_sorted: Vec<&EntKey> = witness_by_group.keys().collect();
        groups_sorted.sort();
        for g in groups_sorted {
            for (w, _) in &witness_by_group[g] {
                witness_entity_to_groups
                    .entry(w.clone())
                    .or_default()
                    .push(g.clone());
            }
        }
    }
    let mut chw_by_group: FxHashMap<EntKey, Vec<(EntKey, i32)>> = FxHashMap::default();
    let mut chw_by_class: FxHashMap<EntKey, Vec<(EntKey, i32)>> = FxHashMap::default();
    let mut chw_slit_to_pair: FxHashMap<i32, (EntKey, EntKey, i32)> = FxHashMap::default();
    for (group, class_, slit) in &chw_atoms {
        chw_by_group
            .entry(group.clone())
            .or_default()
            .push((class_.clone(), *slit));
        chw_by_class
            .entry(class_.clone())
            .or_default()
            .push((group.clone(), *slit));
        chw_slit_to_pair.insert(slit.abs(), (group.clone(), class_.clone(), *slit));
    }
    let oio_by_src: FxHashMap<EntKey, Vec<(EntKey, i32)>> = freeze_sorted({
        let mut m: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> = FxHashMap::default();
        for (&lit, edges) in &oio_lit_to_edges {
            for (o, i) in edges {
                m.entry(o.clone()).or_default().insert((i.clone(), lit));
            }
        }
        m
    });
    let reach_entities: FxHashSet<EntKey> = oio_lit_to_edges
        .values()
        .flatten()
        .flat_map(|(o, i)| [o.clone(), i.clone()])
        .chain(cr_atoms.iter().flat_map(|c| [c.a.clone(), c.b.clone()]))
        .collect();

    let num_threads = ffi.number_of_threads(init_ptr) as usize;
    let states = (0..num_threads)
        .map(|_| std::sync::Mutex::new(ThreadState::new()))
        .collect();

    Ok(Shared {
        facts,
        sc_to_lit,
        sc_lit_to_pair,
        sc_by_entity,
        merge_by_entity,
        entities,
        potential_uf,
        check_atoms,
        now_slit_to_key,
        now_writers_by_vft,
        awc_to_slit,
        awc_slit_to_pair,
        awc_by_vft,
        oio_lit_to_edges,
        oio_by_src,
        reach_entities,
        cr_atoms,
        cr_slit_to_atom,
        witness_slit_to_group,
        witness_by_group,
        witness_entity_to_groups,
        chw_atoms,
        chw_by_group,
        chw_by_class,
        chw_slit_to_pair,
        observed_proglits,
        unconditional_proglits,
        proglit_to_slit,
        head_to_bodies,
        foundedness_check: pd.foundedness_check,
        dump_lemmas: pd.dump_lemmas,
        decide_outputs: pd.decide_outputs,
        decide_inputs: pd.decide_inputs,
        states,
    })
}

fn init_add(ffi: &Ffi, init_ptr: *mut ClingoPropagateInit, clause: &[i32]) {
    let _ = ffi.init_add_clause(init_ptr, clause);
}

/// Iterate symbolic atoms matching a given name/arity, calling `f(symbol, program_literal)`.
///
/// clingo_symbolic_atoms_begin with a specific signature uses domain-level iteration
/// that may return an empty range during propagator init even when the atoms exist.
/// We iterate all atoms and filter by signature match instead.
fn each_sym_atom(
    ffi: &Ffi,
    atoms: *const ClingoSymbolicAtoms,
    name: &str,
    arity: u32,
    mut f: impl FnMut(ClingoSymbol, i32),
) {
    let begin = match ffi.sym_atoms_begin(atoms, None).ok() {
        Some(b) => b,
        None => return,
    };
    let end = ffi.sym_atoms_end(atoms);
    let mut it = begin;
    while !ffi.sym_atoms_equal(atoms, it, end) {
        let sym = ffi.sym_atoms_symbol(atoms, it);
        let lit = ffi.sym_atoms_literal(atoms, it);
        if ffi.symbol_matches(sym, name, arity) {
            f(sym, lit);
        }
        it = ffi.sym_atoms_next(atoms, it);
    }
}

/// Freeze a `vft → set` into a `vft → Vec` sorted by `(EntKey, i32)` (matches
/// `_okey` ordering), for deterministic, interpreter-independent iteration.
fn freeze_sorted(
    src: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>>,
) -> FxHashMap<EntKey, Vec<(EntKey, i32)>> {
    src.into_iter()
        .map(|(k, set)| {
            let mut v: Vec<(EntKey, i32)> = set.into_iter().collect();
            v.sort_unstable_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
            (k, v)
        })
        .collect()
}

// ── propagate / undo / check ────────────────────────────────────────────────

fn shared(pd: &PropData) -> Result<&std::sync::Arc<Shared>, String> {
    pd.shared
        .get()
        .ok_or_else(|| "shared not built before solve".to_string())
}

fn ensure_initialized(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    asgn: *const ClingoAssignment,
) {
    if !state.initialized {
        rebuild(ffi, shared, state, asgn);
        state.merge_trail.clear();
        state.true_sc.clear();
        state.did_initial_sc_sweep = false;
        state.true_chw.clear();
        state.did_initial_chw_sweep = false;
        state.initialized = true;
    }
}

fn rebuild(ffi: &Ffi, shared: &Shared, state: &mut ThreadState, asgn: *const ClingoAssignment) {
    state.uf = Uf::new();
    for (&slit, pairs) in &shared.facts.merge_lit_to_pairs {
        if ffi.is_true(asgn, slit) && ffi.is_fixed(asgn, slit) {
            for (a, b) in pairs {
                state.uf.union(a, b, slit, None, None);
            }
        }
    }
    // Seed level-0 containment edges in sorted-lit order (deterministic).
    state.oio_true.clear();
    state.oio_trail.clear();
    let mut fixed_lits: Vec<i32> = shared
        .oio_lit_to_edges
        .keys()
        .copied()
        .filter(|&lit| ffi.is_true(asgn, lit) && ffi.is_fixed(asgn, lit))
        .collect();
    fixed_lits.sort_unstable();
    for lit in fixed_lits {
        for (o, i) in &shared.oio_lit_to_edges[&lit] {
            state.oio_true.push((o.clone(), i.clone(), lit));
        }
    }
}

/// Eager mid-descent refutation of true-but-unsupported `&sameClass` /
/// `&classHasWitness` atoms (kill switch: `OOA_NO_EAGER=1` reverts to
/// check()-only refutation).
fn eager_refute() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var_os("OOA_NO_EAGER").is_none())
}

pub fn propagate(
    ffi: &Ffi,
    pd: &PropData,
    ctrl: *mut ClingoPropagateControl,
    changes: &[i32],
) -> Result_ {
    let shared = shared(pd)?.clone();
    let tid = ffi.thread_id(ctrl) as usize;
    let mut guard = shared.states[tid].lock().unwrap();
    let state = &mut *guard;
    let asgn = ffi.control_assignment(ctrl);
    ensure_initialized(ffi, &shared, state, asgn);

    let mut graph_touched = false;
    for &lit in changes {
        let alit = lit.abs();
        if let Some(cr) = shared.cr_slit_to_atom.get(&alit) {
            if ffi.is_true(asgn, cr.slit) {
                graph_touched = true;
            }
        }
        if let Some(group) = shared.witness_slit_to_group.get(&alit).cloned() {
            if !check_group_atoms(ffi, &shared, state, ctrl, asgn, &group)? {
                return Ok(());
            }
        }
        if let Some((group, class_, chw_slit)) = shared.chw_slit_to_pair.get(&alit).cloned() {
            if ffi.is_true(asgn, chw_slit) {
                state.true_chw.insert(alit);
                // Eager refutation: teach clasp the support structure now
                // ("chw → grow the class's component or make an in-class
                // witness true") instead of waiting for check(). The clause is
                // sound at any time — free cut merges and free witnesses are
                // positive literals — so mid-descent it unit-propagates merge
                // obligations and conflicts as cuts die, restoring the
                // conflict-driven-learning pressure the grounded witness-join
                // rules used to provide.
                if eager_refute() && !witness_supports(ffi, asgn, state, &shared, &group, &class_) {
                    let mut cache = FxHashMap::default();
                    if !assert_witness_false(
                        ffi, &shared, state, ctrl, asgn, &group, &class_, chw_slit, &mut cache,
                    )? {
                        return Ok(());
                    }
                }
            }
        }
        if let Some(pairs) = shared.facts.merge_lit_to_pairs.get(&lit).cloned() {
            for (a, b) in &pairs {
                let ra = state.uf.root(a);
                let rb = state.uf.root(b);
                if ra == rb {
                    continue;
                }
                let snap = state.uf.snapshot();
                if let Some((absorbed, merged_root)) = state.uf.union(a, b, lit, Some(ra), Some(rb))
                {
                    state.merge_trail.push((lit, snap));
                    graph_touched |= absorbed.iter().any(|e| shared.reach_entities.contains(e));
                    for e in &absorbed {
                        if !check_class_atoms(ffi, &shared, state, ctrl, asgn, e)? {
                            return Ok(());
                        }
                        if let Some(groups) = shared.witness_entity_to_groups.get(e).cloned() {
                            for g in &groups {
                                if !check_group_atoms(ffi, &shared, state, ctrl, asgn, g)? {
                                    return Ok(());
                                }
                            }
                        }
                    }
                    let absorbed_set: FxHashSet<EntKey> = absorbed.iter().cloned().collect();
                    let merged = state.uf.members_of(&merged_root).clone();
                    let mut sorted = absorbed;
                    sorted.sort();
                    // Collect first to avoid holding an immutable `sc_by_entity`
                    // borrow across the mutable `assert_same` calls.
                    let to_assert: Vec<(EntKey, EntKey, i32)> = sorted
                        .iter()
                        .flat_map(|x| {
                            let x = x.clone();
                            shared
                                .sc_by_entity
                                .get(&x)
                                .into_iter()
                                .flatten()
                                .map(move |(y, sc_lit)| (x.clone(), y.clone(), *sc_lit))
                        })
                        .filter(|(_, y, _)| merged.contains(y) && !absorbed_set.contains(y))
                        .filter(|(_, _, sc_lit)| !ffi.is_true(asgn, *sc_lit))
                        .collect();
                    for (x, y, sc_lit) in to_assert {
                        if !assert_same(ffi, &shared, state, ctrl, &x, &y, sc_lit)? {
                            return Ok(());
                        }
                    }
                }
            }
        } else if let Some((x, y)) = shared.sc_lit_to_pair.get(&lit).cloned() {
            if x == y {
                continue;
            }
            if !shared.potential_uf.same(&x, &y) {
                if !clause!(ffi, ctrl, &[-lit]) {
                    return Ok(());
                }
            } else {
                state.true_sc.insert(lit);
                // Eager refutation (see the &classHasWitness case above):
                // "sc(x,y) → some cut merge of x's component must be true".
                if eager_refute() && !state.uf.same(&x, &y) {
                    let mut cache = FxHashMap::default();
                    if !assert_not_same(ffi, &shared, state, ctrl, &x, &y, lit, &mut cache)? {
                        return Ok(());
                    }
                }
            }
        } else if let Some(edges) = shared.oio_lit_to_edges.get(&lit) {
            state.oio_trail.push((lit, state.oio_true.len()));
            for (o, i) in edges {
                state.oio_true.push((o.clone(), i.clone(), lit));
            }
            graph_touched = true;
        }
    }

    // &allWritersInClass: handle nonOverwritingWrite and awc literal changes.
    for &lit in changes {
        let alit = lit.abs();
        if let Some((method, vftable)) = shared.now_slit_to_key.get(&alit).cloned() {
            if let Some(classes) = shared.awc_by_vft.get(&vftable) {
                let mut cache = FxHashMap::default();
                let offenders: Vec<(i32, &EntKey)> = classes
                    .iter()
                    .filter(|(_, awc_slit)| ffi.is_true(asgn, *awc_slit))
                    .filter(|(class_, _)| !state.uf.same(&method, class_))
                    .map(|(class_, awc_slit)| (*awc_slit, class_))
                    .collect();
                for (awc_slit, class_) in offenders {
                    if !assert_not_all_writers(
                        ffi, &shared, state, ctrl, alit, class_, awc_slit, &mut cache,
                    )? {
                        return Ok(());
                    }
                }
            }
        } else if let Some((vftable, class_)) = shared.awc_slit_to_pair.get(&alit).cloned() {
            if let Some(writers) = shared.now_writers_by_vft.get(&vftable) {
                let offenders: Vec<i32> = writers
                    .iter()
                    .filter(|(_, now_alit)| ffi.is_true(asgn, *now_alit))
                    .filter(|(method, _)| !state.uf.same(method, &class_))
                    .map(|(_, now_alit)| *now_alit)
                    .collect();
                let mut cache = FxHashMap::default();
                for now_alit in offenders {
                    if !assert_not_all_writers(
                        ffi, &shared, state, ctrl, now_alit, &class_, lit, &mut cache,
                    )? {
                        return Ok(());
                    }
                }
            }
        }
    }

    if graph_touched {
        if !reconcile_reach(ffi, &shared, state, ctrl, asgn, true)? {
            return Ok(());
        }
    }
    Ok(())
}

pub fn undo(ffi: &Ffi, pd: &PropData, ctrl: *const ClingoPropagateControl, changes: &[i32]) {
    let shared = match shared(pd) {
        Ok(s) => s.clone(),
        Err(_) => return,
    };
    let tid = ffi.thread_id(ctrl) as usize;
    let mut guard = shared.states[tid].lock().unwrap();
    let state = &mut *guard;
    if !state.true_sc.is_empty() {
        for &lit in changes {
            state.true_sc.remove(&lit);
        }
    }
    if !state.true_chw.is_empty() {
        for &lit in changes {
            state.true_chw.remove(&lit.abs());
        }
    }
    if state.merge_trail.is_empty() && state.oio_trail.is_empty() {
        return;
    }
    let changes_set: FxHashSet<i32> = changes.iter().copied().collect();
    while let Some(&(lit, _)) = state.merge_trail.last() {
        if !changes_set.contains(&lit) {
            break;
        }
        let (_, snap) = state.merge_trail.pop().unwrap();
        state.uf.restore(snap);
    }
    while let Some(&(lit, len)) = state.oio_trail.last() {
        if !changes_set.contains(&lit) {
            break;
        }
        state.oio_trail.pop();
        state.oio_true.truncate(len);
    }
}

pub fn check(ffi: &Ffi, pd: &PropData, ctrl: *mut ClingoPropagateControl) -> Result_ {
    let shared = shared(pd)?.clone();
    let tid = ffi.thread_id(ctrl) as usize;
    let mut guard = shared.states[tid].lock().unwrap();
    let state = &mut *guard;
    let asgn = ffi.control_assignment(ctrl);
    ensure_initialized(ffi, &shared, state, asgn);

    if !state.did_initial_sc_sweep {
        let atoms = shared.check_atoms.clone();
        let mut cache = FxHashMap::default();
        for (x, y, slit) in &atoms {
            if state.uf.same(x, y) {
                if !ffi.is_true(asgn, *slit)
                    && !assert_same(ffi, &shared, state, ctrl, x, y, *slit)?
                {
                    return Ok(());
                }
            } else if ffi.is_true(asgn, *slit)
                && !assert_not_same(ffi, &shared, state, ctrl, x, y, *slit, &mut cache)?
            {
                return Ok(());
            }
        }
        state.did_initial_sc_sweep = true;
    } else {
        let sorted: Vec<i32> = {
            let mut v: Vec<i32> = state.true_sc.iter().copied().collect();
            v.sort_unstable();
            v
        };
        let mut cache = FxHashMap::default();
        for slit in sorted {
            if !ffi.is_true(asgn, slit) {
                state.true_sc.remove(&slit);
                continue;
            }
            let (x, y) = match shared.sc_lit_to_pair.get(&slit) {
                Some(p) => p.clone(),
                None => continue,
            };
            if !state.uf.same(&x, &y)
                && !assert_not_same(ffi, &shared, state, ctrl, &x, &y, slit, &mut cache)?
            {
                return Ok(());
            }
        }
    }

    // Verify &allWritersInClass atoms at stable search states.
    let mut cache = FxHashMap::default();
    let awc: Vec<((EntKey, EntKey), i32)> = shared
        .awc_to_slit
        .iter()
        .map(|(k, &v)| (k.clone(), v))
        .collect();
    for ((vftable, class_), awc_slit) in &awc {
        let out_of_class = shared
            .now_writers_by_vft
            .get(vftable)
            .into_iter()
            .flatten()
            .find(|(method, now_alit)| {
                ffi.is_true(asgn, *now_alit) && !state.uf.same(method, class_)
            })
            .map(|(_, now_alit)| *now_alit);
        if let Some(now_alit) = out_of_class {
            if ffi.is_true(asgn, *awc_slit)
                && !assert_not_all_writers(
                    ffi, &shared, state, ctrl, now_alit, class_, *awc_slit, &mut cache,
                )?
            {
                return Ok(());
            }
        }
    }

    // Reconcile &classRelationship* against the containment graph: force
    // supported atoms true and refute unsupported true-assigned ones.
    if !reconcile_reach(ffi, &shared, state, ctrl, asgn, true)? {
        return Ok(());
    }

    // Reconcile &classHasWitness against the live &sameClass classes. First
    // call: one full sweep (mirrors the &sameClass check_atoms sweep above).
    // After that: only true_chw (atoms the solver has actually assigned true)
    // need re-verifying — propagate()'s check_group_atoms/check_class_atoms
    // already force-true anything newly supported, so only refutation of a
    // solver-decided guess with no propagate()-visible trigger remains here.
    if !state.did_initial_chw_sweep {
        if !initial_chw_sweep(ffi, &shared, state, ctrl, asgn)? {
            return Ok(());
        }
        state.did_initial_chw_sweep = true;
    } else {
        let sorted: Vec<i32> = {
            let mut v: Vec<i32> = state.true_chw.iter().copied().collect();
            v.sort_unstable();
            v
        };
        let mut cache = FxHashMap::default();
        for alit in sorted {
            let (group, class_, slit) = match shared.chw_slit_to_pair.get(&alit) {
                Some(p) => p.clone(),
                None => continue,
            };
            if !ffi.is_true(asgn, slit) {
                state.true_chw.remove(&alit);
                continue;
            }
            if !witness_supports(ffi, asgn, state, &shared, &group, &class_)
                && !assert_witness_false(
                    ffi, &shared, state, ctrl, asgn, &group, &class_, slit, &mut cache,
                )?
            {
                return Ok(());
            }
        }
    }

    if shared.foundedness_check && ffi.is_total(asgn) {
        check_foundedness(ffi, &shared, ctrl, asgn)?;
    }
    Ok(())
}

// ── decision heuristic (--decide-outputs / --decide-inputs) ──────────────────

/// `OOA_DECIDE_SKIP_NEG=1`: don't redirect when the solver's fallback phase is
/// negative — let it assign the theory atom false itself (A/B experiment knob).
fn decide_skip_neg() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var_os("OOA_DECIDE_SKIP_NEG").is_some())
}

/// Combined decision heuristic. When `--decide-outputs` is set and the fallback
/// is a `mergeClasses` literal, redirects to a free `&sameClass` atom incident to
/// either entity. When `--decide-inputs` is set and the fallback is a
/// `&sameClass` literal, redirects to a free `mergeClasses` literal incident to
/// either entity, chosen by a per-entity rotating cursor. Relationship and
/// witness theory atoms pass through because merges alone do not define their
/// truth. Returns `fallback` when nothing fires.
pub fn decide(
    ffi: &Ffi,
    pd: &PropData,
    thread_id: ClingoId,
    asgn: *const ClingoAssignment,
    fallback: ClingoLiteral,
) -> ClingoLiteral {
    let shared = match shared(pd) {
        Ok(s) => &**s,
        Err(_) => return fallback,
    };
    let fa = fallback.abs();

    if shared.decide_outputs {
        let pairs = shared
            .facts
            .merge_lit_to_pairs
            .get(&fa)
            .or_else(|| shared.facts.merge_lit_to_pairs.get(&-fa));
        if let Some(pairs) = pairs {
            if let Some(lit) = pairs.iter().find_map(|(a, b)| {
                free_incident_sameclass(ffi, shared, asgn, a)
                    .or_else(|| free_incident_sameclass(ffi, shared, asgn, b))
            }) {
                return lit;
            }
        }
    }

    if shared.decide_inputs {
        let is_sc_fallback =
            shared.sc_lit_to_pair.contains_key(&fa) || shared.sc_lit_to_pair.contains_key(&-fa);
        if !is_sc_fallback || (decide_skip_neg() && fallback < 0) {
            return fallback;
        }
        let mut state = match shared.states.get(thread_id as usize).map(|m| m.lock()) {
            Some(Ok(s)) => s,
            _ => return fallback,
        };
        let state = &mut *state;

        let pair = shared
            .sc_lit_to_pair
            .get(&fa)
            .or_else(|| shared.sc_lit_to_pair.get(&-fa));
        if let Some((x, y)) = pair {
            let (x, y) = (x.clone(), y.clone());
            if let Some(lit) = free_direct_merge(ffi, shared, asgn, &x, &y)
                .or_else(|| cursor_incident_merge(ffi, shared, state, asgn, &x))
                .or_else(|| cursor_incident_merge(ffi, shared, state, asgn, &y))
            {
                return lit;
            }
        }
    }

    fallback
}

/// Smallest (deterministic) free `&sameClass` solver literal incident to `e`,
/// returned in its atom-true phase so the chosen decision asserts same-class.
fn free_incident_sameclass(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
    e: &EntKey,
) -> Option<ClingoLiteral> {
    shared
        .sc_by_entity
        .get(e)?
        .iter()
        .map(|(_, slit)| *slit)
        .filter(|&slit| !ffi.is_true(asgn, slit) && !ffi.is_false(asgn, slit))
        .min()
}

/// Smallest free `mergeClasses` solver literal on the edge `(x, y)` itself —
/// the merge decision most aligned with the `&sameClass(x, y)` fallback.
fn free_direct_merge(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
    x: &EntKey,
    y: &EntKey,
) -> Option<ClingoLiteral> {
    shared
        .merge_by_entity
        .get(x)?
        .iter()
        .filter(|(other, _)| other == y)
        .map(|(_, mlit)| *mlit)
        .filter(|&mlit| !ffi.is_true(asgn, mlit) && !ffi.is_false(asgn, mlit))
        .min()
}

/// Free `mergeClasses` solver literal incident to `e`, scanned from a
/// per-entity rotating cursor. During a dive the cursor skips the
/// already-assigned prefix (amortized O(1) instead of a full rescan with an
/// FFI truth query per candidate), and because it is never undone, re-dives
/// after a backjump start from a different merge instead of deterministically
/// rebuilding the same prefix.
fn cursor_incident_merge(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    asgn: *const ClingoAssignment,
    e: &EntKey,
) -> Option<ClingoLiteral> {
    let lst = shared.merge_by_entity.get(e)?;
    let len = lst.len();
    let cur = state.decide_cursor.get(e).copied().unwrap_or(0) % len;
    for i in 0..len {
        let idx = (cur + i) % len;
        let mlit = lst[idx].1;
        if !ffi.is_true(asgn, mlit) && !ffi.is_false(asgn, mlit) {
            state.decide_cursor.insert(e.clone(), (idx + 1) % len);
            return Some(mlit);
        }
    }
    None
}

// ── assert_* reason-clause builders ──────────────────────────────────────────

fn ek_str(e: &EntKey) -> String {
    match e {
        EntKey::Num(n) => n.to_string(),
        EntKey::Str(s) => s.clone(),
    }
}

/// Best-effort human-readable rendering of one clause literal (debug only).
fn fmt_lit(shared: &Shared, c: i32) -> String {
    for (&s, pairs) in &shared.facts.merge_lit_to_pairs {
        if c == s || c == -s {
            let body = pairs
                .iter()
                .map(|(a, b)| format!("mergeClasses({},{})", ek_str(a), ek_str(b)))
                .collect::<Vec<_>>()
                .join("|");
            return if c == s { body } else { format!("-{}", body) };
        }
    }
    for (&s, (x, y)) in &shared.sc_lit_to_pair {
        if c == s || c == -s {
            let body = format!("sameClass({},{})", ek_str(x), ek_str(y));
            return if c == s {
                body
            } else {
                format!("not {}", body)
            };
        }
    }
    format!("lit({})", c)
}

/// Print a reason clause to stderr when `--dump-lemmas` is on. `label` names the
/// builder; `conflict` is true when this reason was the one that made the
/// assignment inconsistent (`add_clause` returned false), i.e. the nogood clasp
/// hands to 1-UIP. The leading `len=` lets post-processing compare the
/// propagator's reason size against clasp's final learned-clause length.
fn dump_lemma(shared: &Shared, label: &str, clause: &[i32], conflict: bool) {
    if !shared.dump_lemmas {
        return;
    }
    let tag = if conflict { " CONFLICT" } else { "" };
    let body = clause
        .iter()
        .map(|&c| fmt_lit(shared, c))
        .collect::<Vec<_>>()
        .join(" | ");
    eprintln!("[lemma {label}{tag} len={}] {{ {body} }}", clause.len());
}

fn assert_same(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    x: &EntKey,
    y: &EntKey,
    slit: i32,
) -> Result<bool, String> {
    let (_, reason) = state.uf.same_with_reason(x, y);
    let mut clause: Vec<i32> = reason.iter().map(|&r| -r).collect();
    clause.push(slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "same", &clause, !ok);
    Ok(ok)
}

fn component_cut_and_reasons(
    shared: &Shared,
    state: &mut ThreadState,
    x: &EntKey,
    cache: &mut FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)>,
) -> (FxHashSet<i32>, FxHashSet<i32>) {
    let root = state.uf.root(x);
    if let Some(v) = cache.get(&root) {
        return v.clone();
    }
    let component = state.uf.component(x);
    let reason = state.uf.component_reasons(&component);
    let mut cut: FxHashSet<i32> = FxHashSet::default();
    for member in &component {
        if let Some(edges) = shared.merge_by_entity.get(member) {
            for (other, merge_slit) in edges {
                if !component.contains(other) {
                    cut.insert(*merge_slit);
                }
            }
        }
    }
    cache.insert(root, (reason.clone(), cut.clone()));
    (reason, cut)
}

fn assert_not_same(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    x: &EntKey,
    y: &EntKey,
    slit: i32,
    cache: &mut FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)>,
) -> Result<bool, String> {
    if !shared.potential_uf.same(x, y) {
        let clause = [-slit];
        let ok = clause!(ffi, ctrl, &clause);
        dump_lemma(shared, "not_same/static", &clause, !ok);
        return Ok(ok);
    }
    let (reason, cut) = component_cut_and_reasons(shared, state, x, cache);
    let mut clause: Vec<i32> = Vec::with_capacity(reason.len() + cut.len() + 1);
    let mut rs: Vec<i32> = reason.iter().copied().collect();
    rs.sort_unstable();
    let mut cs: Vec<i32> = cut.iter().copied().collect();
    cs.sort_unstable();
    for r in &rs {
        clause.push(-r);
    }
    for c in &cs {
        clause.push(*c);
    }
    clause.push(-slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "not_same/cut", &clause, !ok);
    Ok(ok)
}

fn assert_not_all_writers(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    now_alit: i32,
    class_: &EntKey,
    awc_slit: i32,
    cache: &mut FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)>,
) -> Result<bool, String> {
    let (reason, cut) = component_cut_and_reasons(shared, state, class_, cache);
    let mut clause: Vec<i32> = vec![-now_alit];
    let mut rs: Vec<i32> = reason.iter().copied().collect();
    rs.sort_unstable();
    let mut cs: Vec<i32> = cut.iter().copied().collect();
    cs.sort_unstable();
    for r in &rs {
        clause.push(-r);
    }
    for c in &cs {
        clause.push(*c);
    }
    clause.push(-awc_slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "not_all_writers", &clause, !ok);
    Ok(ok)
}

// ── &classRelationship / &classRelationshipVia reachability ─────────────────
//
// Semantics: vertices are the &sameClass union-find classes; edges are true
// `objectInObject(Outer, Inner, _)` atoms. `&classRelationship(A, B)` holds iff
// a ≥1-edge path leads from class(A) to class(B); the `Via` variant restricts
// the first hop to land outside class(B) (reasonObjectInObject_D's
// grand-ancestor guard, odd-loop-free because theory atoms have no
// foundedness).

/// Init-time reachability (≥1 edge) over the potential quotient graph.
fn potential_reach(
    padj: &FxHashMap<EntKey, FxHashSet<EntKey>>,
    source: &EntKey,
) -> FxHashSet<EntKey> {
    let mut reached: FxHashSet<EntKey> = FxHashSet::default();
    let mut queue: VecDeque<EntKey> = VecDeque::new();
    if let Some(nbs) = padj.get(source) {
        for nb in nbs {
            if reached.insert(nb.clone()) {
                queue.push_back(nb.clone());
            }
        }
    }
    while let Some(node) = queue.pop_front() {
        if let Some(nbs) = padj.get(&node) {
            for nb in nbs {
                if reached.insert(nb.clone()) {
                    queue.push_back(nb.clone());
                }
            }
        }
    }
    reached
}

/// Reached class root → (previous root, edge outer entity, edge inner entity,
/// edge lit): the BFS tree used for path reconstruction. The source root is a
/// key only when a cycle reaches it back (self-containment).
type ReachParent = FxHashMap<EntKey, (EntKey, EntKey, EntKey, i32)>;

/// Quotient adjacency of the true containment edges, in assignment order:
/// class root of the outer entity → [(outer, inner, lit)].
fn build_reach_adj(state: &mut ThreadState) -> FxHashMap<EntKey, Vec<(EntKey, EntKey, i32)>> {
    let edges = state.oio_true.clone();
    let mut adj: FxHashMap<EntKey, Vec<(EntKey, EntKey, i32)>> = FxHashMap::default();
    for (o, i, lit) in edges {
        let r = state.uf.root(&o);
        adj.entry(r).or_default().push((o, i, lit));
    }
    adj
}

fn reach_bfs(
    state: &mut ThreadState,
    adj: &FxHashMap<EntKey, Vec<(EntKey, EntKey, i32)>>,
    source: &EntKey,
    forbid_first_dst: Option<&EntKey>,
) -> ReachParent {
    let mut parent: ReachParent = FxHashMap::default();
    let mut queue: VecDeque<EntKey> = VecDeque::new();
    if let Some(edges) = adj.get(source) {
        for (o, i, lit) in edges.clone() {
            let ri = state.uf.root(&i);
            if forbid_first_dst == Some(&ri) {
                continue;
            }
            if !parent.contains_key(&ri) {
                parent.insert(ri.clone(), (source.clone(), o, i, lit));
                queue.push_back(ri);
            }
        }
    }
    while let Some(node) = queue.pop_front() {
        if let Some(edges) = adj.get(&node) {
            for (o, i, lit) in edges.clone() {
                let ri = state.uf.root(&i);
                if !parent.contains_key(&ri) {
                    parent.insert(ri.clone(), (node.clone(), o, i, lit));
                    queue.push_back(ri);
                }
            }
        }
    }
    parent
}

/// Reason lits (merge slits + edge lits, to be negated) witnessing a path from
/// entity `a` to entity `b`, plus the first intermediate entity (for the Via
/// certificate). None if the BFS tree has no path (defensive).
fn cr_path_reason(
    state: &mut ThreadState,
    parent: &ReachParent,
    a: &EntKey,
    b: &EntKey,
    source: &EntKey,
    target: &EntKey,
) -> Option<(Vec<i32>, EntKey)> {
    parent.get(target)?;
    let mut hops: Vec<(EntKey, EntKey, i32)> = Vec::new();
    let mut cur = target.clone();
    loop {
        let (prev, o, i, lit) = parent.get(&cur)?.clone();
        hops.push((o, i, lit));
        if prev == *source {
            break;
        }
        cur = prev;
    }
    hops.reverse();
    let first_mid = hops[0].1.clone();
    let mut reason: Vec<i32> = Vec::new();
    let mut at = a.clone();
    for (o, i, lit) in hops {
        let (same, merges) = state.uf.same_with_reason(&at, &o);
        if !same {
            return None;
        }
        reason.extend(merges);
        reason.push(lit);
        at = i;
    }
    let (same, merges) = state.uf.same_with_reason(&at, b);
    if !same {
        return None;
    }
    reason.extend(merges);
    Some((reason, first_mid))
}

fn assert_cr_reachable(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    path_reason: &[i32],
    via_mid: Option<&EntKey>,
    slit: i32,
    cut_cache: &mut FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)>,
) -> Result<bool, String> {
    let mut neg: FxHashSet<i32> = path_reason.iter().copied().collect();
    let mut pos: FxHashSet<i32> = FxHashSet::default();
    // Via: certify the first intermediate is currently outside class(b) — its
    // component is exactly its internal merges, closed off by its cut merges.
    if let Some(mid) = via_mid {
        let (reason, cut) = component_cut_and_reasons(shared, state, mid, cut_cache);
        neg.extend(reason);
        pos.extend(cut);
    }
    let mut clause: Vec<i32> = Vec::with_capacity(neg.len() + pos.len() + 1);
    let mut ns: Vec<i32> = neg.into_iter().collect();
    ns.sort_unstable();
    let mut ps: Vec<i32> = pos.into_iter().collect();
    ps.sort_unstable();
    for n in &ns {
        clause.push(-n);
    }
    for p in &ps {
        clause.push(*p);
    }
    clause.push(slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "cr_reach", &clause, !ok);
    Ok(ok)
}

fn assert_cr_unreachable(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    b: &EntKey,
    source: &EntKey,
    parent: &ReachParent,
    slit: i32,
) -> Result<bool, String> {
    let r_roots: FxHashSet<EntKey> = parent.keys().cloned().collect();
    let mut s_roots = r_roots.clone();
    s_roots.insert(source.clone());
    let mut neg: FxHashSet<i32> = FxHashSet::default();
    let mut pos: FxHashSet<i32> = FxHashSet::default();

    // Candidate containment edges out of S = {source} ∪ R.
    for (src_ent, edges) in &shared.oio_by_src {
        let rs = state.uf.root(src_ent);
        if !s_roots.contains(&rs) {
            continue;
        }
        for (dst_ent, lit) in edges {
            let rd = state.uf.root(dst_ent);
            if r_roots.contains(&rd) {
                if ffi.is_true(asgn, *lit) {
                    neg.insert(*lit);
                }
                // A false internal edge cannot extend R — skip.
            } else if ffi.is_true(asgn, *lit) {
                // Only reachable-but-excluded Via first hops land here: the
                // edge is true yet its target class was not entered, which
                // means class(dst) == class(b). Bind that equality.
                let (same, merges) = state.uf.same_with_reason(dst_ent, b);
                if same {
                    neg.extend(merges);
                } else {
                    // Defensive: unexpectedly unexplored true edge — include
                    // it so the clause stays sound (weaker, never wrong).
                    neg.insert(*lit);
                }
            } else {
                pos.insert(*lit);
            }
        }
    }

    // Merges: freeze each S component (internal reasons) and enumerate its
    // frontier (crossing merge candidates into classes outside R).
    for r in &s_roots {
        let members = state.uf.component(r);
        neg.extend(state.uf.component_reasons(&members));
        for member in &members {
            if let Some(mes) = shared.merge_by_entity.get(member) {
                for (other, mslit) in mes {
                    let ro = state.uf.root(other);
                    if !r_roots.contains(&ro) && ro != *r {
                        pos.insert(*mslit);
                    }
                }
            }
        }
    }

    let mut clause: Vec<i32> = Vec::with_capacity(neg.len() + pos.len() + 1);
    let mut ns: Vec<i32> = neg.into_iter().collect();
    ns.sort_unstable();
    let mut ps: Vec<i32> = pos.into_iter().collect();
    ps.sort_unstable();
    for n in &ns {
        clause.push(-n);
    }
    for p in &ps {
        clause.push(*p);
    }
    clause.push(-slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "cr_unreach", &clause, !ok);
    Ok(ok)
}

/// Sweep all `&classRelationship*` atoms against the current containment graph.
/// Path-supported atoms not yet true are forced true (conflicting if assigned
/// false); with `refute`, true-assigned atoms without support are refuted via
/// an unreachability cut. Returns Ok(false) when a clause made the assignment
/// inconsistent (caller must return to clingo immediately).
fn reconcile_reach(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    refute: bool,
) -> Result<bool, String> {
    if shared.cr_atoms.is_empty() {
        return Ok(true);
    }
    let adj = build_reach_adj(state);
    let mut bfs_cache: FxHashMap<(EntKey, Option<EntKey>), ReachParent> = FxHashMap::default();
    let mut cut_cache: FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)> = FxHashMap::default();
    for cr in &shared.cr_atoms {
        let source = state.uf.root(&cr.a);
        let target = state.uf.root(&cr.b);
        let forbid = if cr.via { Some(target.clone()) } else { None };
        let key = (source.clone(), forbid.clone());
        if !bfs_cache.contains_key(&key) {
            let p = reach_bfs(state, &adj, &source, forbid.as_ref());
            bfs_cache.insert(key.clone(), p);
        }
        let parent = bfs_cache[&key].clone();
        let reached = parent.contains_key(&target);
        let is_true = ffi.is_true(asgn, cr.slit);
        if reached && !is_true {
            if let Some((reason, first_mid)) =
                cr_path_reason(state, &parent, &cr.a, &cr.b, &source, &target)
            {
                let via_mid = cr.via.then_some(&first_mid);
                if !assert_cr_reachable(
                    ffi,
                    shared,
                    state,
                    ctrl,
                    &reason,
                    via_mid,
                    cr.slit,
                    &mut cut_cache,
                )? {
                    return Ok(false);
                }
            }
        } else if refute && !reached && is_true {
            if !assert_cr_unreachable(
                ffi, shared, state, ctrl, asgn, &cr.b, &source, &parent, cr.slit,
            )? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

// ── &classHasWitness: existential witness-in-class membership ───────────────
//
// Semantics: `&classHasWitness(Group, Class)` holds iff some `witnessGroup(Group,
// W)` atom is true with `W` in `class(Class)`'s current &sameClass component.
// `Group` is an opaque tag chosen on the ASP side (e.g. `sizeGroup(S)`,
// `methodGroup(M)`, `zeroGroup`) so unrelated witness pools never collide.
// Generalizes the free-witness-join pattern (`&sameClass(A, W), P(W, ...)`
// with `W` unbound) that exploded classSizeGTE_F/classHasInnerAtZero/
// reasonNOTMergeClasses_C's grounding once objectInObject grew from 14 to 286
// facts: instead of grounding one instance per (A, W) pair, the ASP side
// grounds one instance per (A, Group) pair (Group ranges over a small static
// value domain) and the propagator answers the existence query directly
// against the live union-find, using a plain linear scan (no path search
// needed, unlike &classRelationship) since group membership is unordered.

/// One-time full sweep of all `&classHasWitness` atoms against the live
/// &sameClass classes — used only for the very first `check()` call (mirrors
/// the `check_atoms` initial sweep for `&sameClass`). Every subsequent update
/// goes through the targeted `check_group_atoms`/`check_class_atoms` (called
/// from `propagate()`) plus the `true_chw`-scoped incremental sweep in
/// `check()`; a full unconditional sweep does not scale once `chw_atoms` is
/// tens of thousands of entries (as it is once the value/method domains that
/// generate `&classHasWitness` instances are large).
fn initial_chw_sweep(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
) -> Result<bool, String> {
    if shared.chw_atoms.is_empty() {
        return Ok(true);
    }
    let mut cut_cache: FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)> = FxHashMap::default();
    for (group, class_, slit) in &shared.chw_atoms {
        if !try_force_witness_true(ffi, shared, state, ctrl, asgn, group, class_, *slit)? {
            return Ok(false);
        }
        if ffi.is_true(asgn, *slit)
            && !witness_supports(ffi, asgn, state, shared, group, class_)
            && !assert_witness_false(
                ffi,
                shared,
                state,
                ctrl,
                asgn,
                group,
                class_,
                *slit,
                &mut cut_cache,
            )?
        {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Whether some witness of `group` is currently true and same-class as `class_`.
fn witness_supports(
    ffi: &Ffi,
    asgn: *const ClingoAssignment,
    state: &mut ThreadState,
    shared: &Shared,
    group: &EntKey,
    class_: &EntKey,
) -> bool {
    shared
        .witness_by_group
        .get(group)
        .map(|ws| {
            ws.iter()
                .any(|(w, wlit)| ffi.is_true(asgn, *wlit) && state.uf.same(w, class_))
        })
        .unwrap_or(false)
}

/// If `(group, class_)`'s `&classHasWitness` atom (solver literal `slit`)
/// isn't already true and a live witness now supports it, force it true.
/// No-op if already true or still unsupported.
fn try_force_witness_true(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    group: &EntKey,
    class_: &EntKey,
    slit: i32,
) -> Result<bool, String> {
    if ffi.is_true(asgn, slit) {
        return Ok(true);
    }
    let support = shared.witness_by_group.get(group).and_then(|ws| {
        ws.iter()
            .find(|(w, wlit)| ffi.is_true(asgn, *wlit) && state.uf.same(w, class_))
    });
    match support {
        Some((w, wlit)) => assert_witness_true(ffi, shared, state, ctrl, w, class_, *wlit, slit),
        None => Ok(true),
    }
}

/// Recheck every `&classHasWitness(group, _)` atom — called when a witness of
/// this group just changed truth.
fn check_group_atoms(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    group: &EntKey,
) -> Result<bool, String> {
    if let Some(atoms) = shared.chw_by_group.get(group) {
        for (class_, slit) in atoms {
            if !try_force_witness_true(ffi, shared, state, ctrl, asgn, group, class_, *slit)? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// Recheck every `&classHasWitness(_, class_)` atom — called when `class_`
/// itself was just absorbed into a merge (its component gained new members).
fn check_class_atoms(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    class_: &EntKey,
) -> Result<bool, String> {
    if let Some(atoms) = shared.chw_by_class.get(class_) {
        for (group, slit) in atoms {
            if !try_force_witness_true(ffi, shared, state, ctrl, asgn, group, class_, *slit)? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn assert_witness_true(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    w: &EntKey,
    class_: &EntKey,
    wlit: i32,
    slit: i32,
) -> Result<bool, String> {
    let (_, reason) = state.uf.same_with_reason(w, class_);
    let mut clause: Vec<i32> = reason.iter().map(|&r| -r).collect();
    clause.push(-wlit);
    clause.push(slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "witness_true", &clause, !ok);
    Ok(ok)
}

fn assert_witness_false(
    ffi: &Ffi,
    shared: &Shared,
    state: &mut ThreadState,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
    group: &EntKey,
    class_: &EntKey,
    slit: i32,
    cache: &mut FxHashMap<EntKey, (FxHashSet<i32>, FxHashSet<i32>)>,
) -> Result<bool, String> {
    let (reason, cut) = component_cut_and_reasons(shared, state, class_, cache);
    let mut neg = reason;
    let mut pos = cut;
    if let Some(witnesses) = shared.witness_by_group.get(group) {
        for (w, wlit) in witnesses {
            if state.uf.same(w, class_) && !ffi.is_true(asgn, *wlit) {
                pos.insert(*wlit);
            }
        }
    }
    let mut clause: Vec<i32> = Vec::with_capacity(neg.len() + pos.len() + 1);
    let mut ns: Vec<i32> = neg.drain().collect();
    ns.sort_unstable();
    let mut ps: Vec<i32> = pos.drain().collect();
    ps.sort_unstable();
    for n in &ns {
        clause.push(-n);
    }
    for p in &ps {
        clause.push(*p);
    }
    clause.push(-slit);
    let ok = clause!(ffi, ctrl, &clause);
    dump_lemma(shared, "witness_false", &clause, !ok);
    Ok(ok)
}

// ── foundedness ──────────────────────────────────────────────────────────────

fn check_foundedness(
    ffi: &Ffi,
    shared: &Shared,
    ctrl: *mut ClingoPropagateControl,
    asgn: *const ClingoAssignment,
) -> Result_ {
    let sc_proglits: FxHashSet<i32> = shared.facts.sc_proglit_to_pair.keys().copied().collect();

    let true_merges: FxHashMap<i32, (EntKey, EntKey, i32)> = shared
        .facts
        .merge_proglit_to_pair
        .iter()
        .filter_map(|(pl, (a, b))| {
            let slit = *shared.facts.merge_proglit_to_slit.get(pl)?;
            ffi.is_true(asgn, slit)
                .then(|| (*pl, (a.clone(), b.clone(), slit)))
        })
        .collect();
    if true_merges.is_empty() {
        return Ok(());
    }

    let mut founded: FxHashSet<i32> = FxHashSet::default();
    let mut founded_uf = Uf::new();

    let mark_founded = |founded: &mut FxHashSet<i32>, founded_uf: &mut Uf, pl: i32| {
        founded.insert(pl);
        if let Some((a, b, slit)) = true_merges.get(&pl) {
            founded_uf.union(a, b, *slit, None, None);
        }
    };

    for pl in &shared.unconditional_proglits {
        if lit_true(ffi, shared, asgn, &sc_proglits, pl) {
            mark_founded(&mut founded, &mut founded_uf, *pl);
        }
    }

    let observed: Vec<i32> = shared.observed_proglits.iter().copied().collect();
    let mut changed = true;
    while changed {
        changed = false;
        for pl in &observed {
            if founded.contains(pl) || !lit_true(ffi, shared, asgn, &sc_proglits, pl) {
                continue;
            }
            if let Some(bodies) = shared.head_to_bodies.get(pl) {
                let made = bodies.iter().any(|body| {
                    body_active(ffi, shared, asgn, &sc_proglits, body)
                        && body_founded(shared, &founded, &founded_uf, &sc_proglits, body)
                });
                if made {
                    mark_founded(&mut founded, &mut founded_uf, *pl);
                    changed = true;
                }
            }
        }
    }

    let any_unfounded = true_merges.keys().any(|pl| !founded.contains(pl));
    if !any_unfounded {
        return Ok(());
    }
    let clause = foundedness_assignment_blocker(ffi, shared, asgn);
    if !clause!(ffi, ctrl, &clause) {
        return Ok(());
    }
    Ok(())
}

/// `lit_true`: truth of a program literal at the current assignment.
/// `&sameClass` lits resolve through `sc_to_lit`; unmappable lits are
/// conservatively treated as true (mirrors the Python `RuntimeError` fallback).
fn lit_true(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
    sc_proglits: &FxHashSet<i32>,
    pl: &i32,
) -> bool {
    if sc_proglits.contains(pl) {
        let (x, y) = &shared.facts.sc_proglit_to_pair[pl];
        match shared.sc_to_lit.get(&(x.clone(), y.clone())) {
            Some(&sc_slit) => ffi.is_true(asgn, sc_slit),
            None => false,
        }
    } else {
        match shared.proglit_to_slit.get(pl) {
            Some(&slit) => ffi.is_true(asgn, slit),
            None => true,
        }
    }
}

fn body_active(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
    sc_proglits: &FxHashSet<i32>,
    body: &[i32],
) -> bool {
    body.iter()
        .all(|lit| lit_true(ffi, shared, asgn, sc_proglits, lit))
}

fn body_founded(
    shared: &Shared,
    founded: &FxHashSet<i32>,
    founded_uf: &Uf,
    sc_proglits: &FxHashSet<i32>,
    body: &[i32],
) -> bool {
    body.iter().all(|lit| {
        if sc_proglits.contains(lit) {
            let (x, y) = &shared.facts.sc_proglit_to_pair[lit];
            founded_uf.same(x, y)
        } else {
            !(shared.observed_proglits.contains(lit) && !founded.contains(lit))
        }
    })
}

fn foundedness_assignment_blocker(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
) -> Vec<i32> {
    let mut clause: Vec<i32> = Vec::new();
    let mut seen: FxHashSet<i32> = FxHashSet::default();
    let mut add = |slit: Option<i32>| {
        let slit = match slit {
            Some(s) => s,
            None => return,
        };
        if !seen.insert(slit) {
            return;
        }
        if ffi.is_true(asgn, slit) {
            clause.push(-slit);
        } else if ffi.is_false(asgn, slit) {
            clause.push(slit);
        }
    };
    for pl in &shared.observed_proglits {
        if shared.facts.merge_proglit_to_slit.contains_key(pl) {
            add(Some(*shared.facts.merge_proglit_to_slit.get(pl).unwrap()));
        } else if shared.facts.sc_proglit_to_pair.contains_key(pl) {
            add(shared.proglit_to_slit.get(pl).copied());
        } else {
            add(shared.proglit_to_slit.get(pl).copied());
        }
    }
    for &slit in shared.facts.merge_proglit_to_slit.values() {
        add(Some(slit));
    }
    for &slit in shared.sc_to_lit.values() {
        add(Some(slit));
    }
    clause
}
