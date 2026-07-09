//! Native port of `propagator/introspect.py`.
//!
//! The inspector owns the JSONL sink. It samples every watched symbolic
//! assignment, classifying each as a direct branch decision or a
//! propagation-implied assignment; the driver forwards model/lower-bound/final
//! records through `write_json`.

use crate::ffi::{
    ClingoLiteral, ClingoPropagateControl, ClingoPropagateInit, Ffi, CHECK_MODE_FIXPOINT,
};
use std::collections::{BTreeMap, HashMap};
use std::ffi::c_void;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::Mutex;
use std::time::Instant;

const HB: u32 = 512;

#[derive(Default)]
struct Slice {
    /// Direct symbolic literals selected by the solver during this sample.
    decided: BTreeMap<String, u64>,
    /// Symbolic literals forced by propagation during this sample.
    implied: BTreeMap<String, u64>,
    backtracks: BTreeMap<String, u64>,
    root_returns: u64,
    depth_n: u64,
    depth_sum: u64,
    depth_min: Option<u32>,
    depth_max: Option<u32>,
}

struct ThreadSample {
    active: bool,
    hb: u32,
    last_sample: f64,
    root: Option<u32>,
    undo_prev: u32,
    watched: bool,
    slice: Slice,
}

impl Default for ThreadSample {
    fn default() -> Self {
        ThreadSample {
            active: false,
            hb: HB,
            last_sample: 0.0,
            root: None,
            undo_prev: 0,
            watched: false,
            slice: Slice::default(),
        }
    }
}

pub struct InspectorData {
    pub period: f64,
    pub window: f64,
    pub after: f64,
    pub start: Instant,
    pub init_lock: Mutex<()>,
    pub lit_pred: Mutex<HashMap<i32, String>>,
    /// Every signed symbolic solver literal. These are watched only during a
    /// duty-cycle window so each sample covers every program predicate.
    pub watched_lits: Mutex<Vec<i32>>,
    pub reward_lits: Mutex<Vec<(i32, String)>>,
    threads: Mutex<HashMap<usize, ThreadSample>>,
    pub file: Mutex<BufWriter<File>>,
}

pub fn new(path: &str, period: f64, window: f64, after: f64) -> Result<Box<InspectorData>, String> {
    OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .map_err(|e| format!("cannot initialize introspection trace: {e}"))?;
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("cannot open introspection trace: {e}"))?;
    Ok(Box::new(InspectorData {
        period,
        window,
        after,
        start: Instant::now(),
        init_lock: Mutex::new(()),
        lit_pred: Mutex::new(HashMap::new()),
        watched_lits: Mutex::new(Vec::new()),
        reward_lits: Mutex::new(Vec::new()),
        threads: Mutex::new(HashMap::new()),
        file: Mutex::new(BufWriter::new(file)),
    }))
}

fn reward_family(name: &str) -> Option<&'static str> {
    match name {
        "vfTable" | "vfTableSize" => Some("vftable"),
        "guessMethodReward" => Some("method"),
        "guessConstructor1Reward"
        | "guessConstructor2Reward"
        | "guessConstructor3Reward"
        | "guessConstructor4Reward" => Some("ctor"),
        "strongMergeReward" => Some("strong_merge"),
        "weakMergeReward" => Some("weak_merge"),
        "weakG1Bonus" => Some("weak_g1"),
        "lateF2Reward" => Some("late_f2"),
        "guessDerivedClassReward" | "purecallNotMostDerivedReward" | "embedsKnownBasePenalty" => {
            Some("composition")
        }
        _ => None,
    }
}

fn init_impl(
    ffi: &Ffi,
    data: &InspectorData,
    init: *mut ClingoPropagateInit,
) -> Result<(), String> {
    ffi.set_check_mode(init, CHECK_MODE_FIXPOINT);
    let _guard = data.init_lock.lock().unwrap();
    if !data.lit_pred.lock().unwrap().is_empty() {
        return Ok(());
    }
    let atoms = ffi.init_symbolic_atoms(init).map_err(|e| e.message)?;
    let mut preds = data.lit_pred.lock().unwrap();
    let mut watched = data.watched_lits.lock().unwrap();
    let mut rewards = data.reward_lits.lock().unwrap();
    let mut it = ffi.sym_atoms_begin(atoms, None).map_err(|e| e.message)?;
    let end = ffi.sym_atoms_end(atoms);
    while !ffi.sym_atoms_equal(atoms, it, end) {
        let sym = ffi.sym_atoms_symbol(atoms, it);
        let plit = ffi.sym_atoms_literal(atoms, it);
        let lit = ffi.solver_literal(init, plit).map_err(|e| e.message)?;
        let atom = ffi.symbol_to_string(sym).unwrap_or_default();
        let name = atom.split('(').next().unwrap_or(&atom).to_string();
        preds.insert(lit.abs(), name.clone());
        watched.push(lit);
        watched.push(-lit);
        if let Some(reward) = reward_family(&name) {
            rewards.push((lit, reward.to_string()));
        }
        it = ffi.sym_atoms_next(atoms, it);
    }
    Ok(())
}

fn now(data: &InspectorData) -> f64 {
    data.start.elapsed().as_secs_f64()
}
fn in_window(data: &InspectorData, t: f64) -> bool {
    let e = t - data.after;
    e >= 0.0 && (e % data.period) < data.window
}
fn r3(v: f64) -> String {
    format!("{:.3}", v)
}
fn r4(v: f64) -> String {
    format!("{:.4}", v)
}
fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn flush(
    ffi: &Ffi,
    data: &InspectorData,
    ctrl: *mut ClingoPropagateControl,
    state: &mut ThreadSample,
    t: f64,
) {
    let dt = (t - state.last_sample).max(1e-6);
    let s = &state.slice;
    let depth_min = s.depth_min.unwrap_or(0);
    let depth_max = s.depth_max.unwrap_or(0);
    let mean = if s.depth_n == 0 {
        0.0
    } else {
        s.depth_sum as f64 / s.depth_n as f64
    };
    let mut back = String::from("{");
    for (i, (k, v)) in s.backtracks.iter().enumerate() {
        if i != 0 {
            back.push(',');
        }
        back.push_str(&format!("{}:{}", json_str(k), v));
    }
    back.push('}');
    let asgn = ffi.control_assignment(ctrl);
    let mut true_now: BTreeMap<String, u64> = BTreeMap::new();
    for (lit, family) in data.reward_lits.lock().unwrap().iter() {
        if ffi.is_true(asgn, *lit) {
            *true_now.entry(family.clone()).or_default() += 1;
        }
    }
    let truth = true_now
        .iter()
        .map(|(k, v)| format!("{}:{}", json_str(k), v))
        .collect::<Vec<_>>()
        .join(",");
    let decided = s
        .decided
        .iter()
        .map(|(k, v)| format!("{}:{}", json_str(k), v))
        .collect::<Vec<_>>()
        .join(",");
    let implied = s
        .implied
        .iter()
        .map(|(k, v)| format!("{}:{}", json_str(k), v))
        .collect::<Vec<_>>()
        .join(",");
    let mut line = format!("{{\"kind\":\"sample\",\"t\":{},\"dt\":{},\"depth\":{{\"min\":{},\"mean\":{:.1},\"max\":{}}},\"backtracks\":{},\"root_returns\":{},\"true_now\":{{{}}},\"decided\":{{{}}},\"implied\":{{{}}}}}",
                       r3(t), r4(dt), depth_min, mean, depth_max, back, s.root_returns, truth, decided, implied);
    line.push('\n');
    let mut file = data.file.lock().unwrap();
    let _ = file.write_all(line.as_bytes());
    let _ = file.flush();
    state.slice = Slice::default();
    state.last_sample = t;
}

pub fn init(ffi: &Ffi, data: &InspectorData, init: *mut ClingoPropagateInit) -> Result<(), String> {
    init_impl(ffi, data, init)
}

pub fn propagate(
    ffi: &Ffi,
    data: &InspectorData,
    ctrl: *mut ClingoPropagateControl,
    changes: &[ClingoLiteral],
) -> Result<(), String> {
    let tid = ffi.thread_id(ctrl) as usize;
    let asgn = ffi.control_assignment(ctrl);
    let mut threads = data.threads.lock().unwrap();
    let state = threads.entry(tid).or_default();
    if !state.active {
        return Ok(());
    }
    let predicates = data.lit_pred.lock().unwrap();
    for &lit in changes {
        let Some(predicate) = predicates.get(&lit.abs()) else {
            continue;
        };
        let direct = ffi
            .level(asgn, lit)
            .and_then(|level| (level > 0).then(|| ffi.decision(asgn, level)))
            .flatten()
            == Some(lit);
        let target = if direct {
            &mut state.slice.decided
        } else {
            &mut state.slice.implied
        };
        *target.entry(predicate.clone()).or_default() += 1;
    }
    Ok(())
}

pub fn check(
    ffi: &Ffi,
    data: &InspectorData,
    ctrl: *mut ClingoPropagateControl,
) -> Result<(), String> {
    let tid = ffi.thread_id(ctrl) as usize;
    let t = now(data);
    let mut threads = data.threads.lock().unwrap();
    let state = threads.entry(tid).or_default();
    if state.active {
        let level = ffi.decision_level(ffi.control_assignment(ctrl));
        state.slice.depth_n += 1;
        state.slice.depth_sum += level as u64;
        state.slice.depth_min = Some(state.slice.depth_min.map_or(level, |x| x.min(level)));
        state.slice.depth_max = Some(state.slice.depth_max.map_or(level, |x| x.max(level)));
        if !in_window(data, t) {
            flush(ffi, data, ctrl, state, t);
            for &lit in data.watched_lits.lock().unwrap().iter() {
                ffi.control_remove_watch(ctrl, lit);
            }
            state.active = false;
            state.watched = false;
            state.hb = HB;
        }
    } else {
        state.hb -= 1;
        if state.hb == 0 {
            state.hb = HB;
            if in_window(data, t) {
                for &lit in data.watched_lits.lock().unwrap().iter() {
                    if !ffi.control_add_watch(ctrl, lit) {
                        return Err("failed to add inspector watch".into());
                    }
                }
                state.slice = Slice::default();
                state.last_sample = t;
                state.active = true;
                state.watched = true;
            }
        }
    }
    Ok(())
}

pub fn undo(
    ffi: &Ffi,
    data: &InspectorData,
    ctrl: *const ClingoPropagateControl,
    changes: &[ClingoLiteral],
) {
    let tid = ffi.thread_id(ctrl) as usize;
    let mut threads = data.threads.lock().unwrap();
    let state = threads.entry(tid).or_default();
    if !state.active {
        return;
    }
    for lit in changes {
        if let Some(name) = data.lit_pred.lock().unwrap().get(&lit.abs()) {
            *state.slice.backtracks.entry(name.clone()).or_default() += 1;
        }
    }
    let level = ffi.decision_level(ffi.control_assignment(ctrl));
    if state.root.is_none() || level < state.root.unwrap() {
        state.root = Some(level);
    }
    let root = state.root.unwrap();
    if level <= root && state.undo_prev > root {
        state.slice.root_returns += 1;
    }
    state.undo_prev = level;
}

pub fn close(data: &InspectorData) {
    let _ = data.file.lock().unwrap().flush();
}

pub fn data_ptr(data: *mut c_void) -> &'static InspectorData {
    unsafe { &*(data as *const InspectorData) }
}
