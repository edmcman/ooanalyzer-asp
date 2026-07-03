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
use crate::shared::{MergeScFacts, ObsRule, PropData, Shared};
use crate::threadstate::ThreadState;
use crate::uf::Uf;
use rustc_hash::{FxHashMap, FxHashSet};

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

    // &sameClass/2 and &allWritersInClass/2 theory atoms.
    let mut now_slit_to_key: FxHashMap<i32, (EntKey, EntKey)> = FxHashMap::default();
    let mut now_writers_by_vft: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> = FxHashMap::default();
    let mut awc_to_slit: FxHashMap<(EntKey, EntKey), i32> = FxHashMap::default();
    let mut awc_slit_to_pair: FxHashMap<i32, (EntKey, EntKey)> = FxHashMap::default();
    let mut awc_by_vft: FxHashMap<EntKey, FxHashSet<(EntKey, i32)>> = FxHashMap::default();

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
            _ => {}
        }
    }

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

    // Freeze deterministic, interpreter-independent iteration order.
    let now_writers_by_vft = freeze_sorted(now_writers_by_vft);
    let awc_by_vft = freeze_sorted(awc_by_vft);

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

    for &lit in changes {
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
            }
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
    if state.merge_trail.is_empty() {
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

    if shared.foundedness_check && ffi.is_total(asgn) {
        check_foundedness(ffi, &shared, ctrl, asgn)?;
    }
    Ok(())
}

// ── decision heuristic (--decide-outputs / --decide-inputs) ──────────────────

/// Combined decision heuristic. When `--decide-outputs` is set and the fallback
/// is a `mergeClasses` literal, redirects to a free `&sameClass` atom incident to
/// either entity. When `--decide-inputs` is set and the fallback is a `&sameClass`
/// literal, redirects to a free `mergeClasses` literal incident to either entity.
/// Returns `fallback` unchanged when neither condition fires.
pub fn decide(
    ffi: &Ffi,
    pd: &PropData,
    _thread_id: ClingoId,
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
        let pair = shared
            .sc_lit_to_pair
            .get(&fa)
            .or_else(|| shared.sc_lit_to_pair.get(&-fa));
        if let Some((x, y)) = pair {
            if let Some(lit) = free_direct_merge(ffi, shared, asgn, x, y)
                .or_else(|| free_incident_merge(ffi, shared, asgn, x))
                .or_else(|| free_incident_merge(ffi, shared, asgn, y))
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

/// Smallest (deterministic) free `mergeClasses` solver literal incident to `e`.
fn free_incident_merge(
    ffi: &Ffi,
    shared: &Shared,
    asgn: *const ClingoAssignment,
    e: &EntKey,
) -> Option<ClingoLiteral> {
    shared
        .merge_by_entity
        .get(e)?
        .iter()
        .map(|(_, mlit)| *mlit)
        .filter(|&mlit| !ffi.is_true(asgn, mlit) && !ffi.is_false(asgn, mlit))
        .min()
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
