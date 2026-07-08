//! Read-only data shared across solver threads, plus the registration-time
//! `PropData` that holds it. Port of the `init`-built state of
//! `sameclass.py:SameClassPropagator`.
//!
//! Two sources, both populated once:
//! - [`ObsData`]: collected by the clingo ground-program observer (`rule`/
//!   `weight_rule`/`external`) during `ctl.ground()` (single-threaded). Feeds
//!   the least-fixpoint in `potential_uf` and the foundedness `head_to_bodies`.
//! - [`Shared`]: built once in the first `init` from symbolic/theory atoms and
//!   the consumed observer data, then frozen behind an `Arc` for every thread.

use crate::entkey::EntKey;
use crate::threadstate::ThreadState;
use crate::uf::Uf;
use rustc_hash::{FxHashMap, FxHashSet};
use std::sync::{Arc, Mutex, OnceLock};

/// One observed ground rule. `pos_body` holds only positive program literals.
#[derive(Default)]
#[allow(dead_code)]
pub struct ObsRule {
    pub choice: bool,
    pub heads: Vec<i32>,
    pub pos_body: Vec<i32>,
}

#[derive(Default)]
pub struct ObsData {
    pub rules: Vec<ObsRule>,
    /// head program-literal → indices into `rules`.
    pub head_to_rules: FxHashMap<i32, Vec<usize>>,
    /// program-literals derivable with no positive-body conditions.
    pub unconditional: FxHashSet<i32>,
}

/// `mergeClasses`/`&sameClass` program-literal → entity-key mappings, plus the
/// solver-literal fallback index. Built in `init`; consumed by `potential_uf`.
#[derive(Default)]
pub struct MergeScFacts {
    /// `mergeClasses` program-literal → (a, b).
    pub merge_proglit_to_pair: FxHashMap<i32, (EntKey, EntKey)>,
    /// `mergeClasses` program-literal → solver literal.
    pub merge_proglit_to_slit: FxHashMap<i32, i32>,
    /// `&sameClass` program-literal → (x, y).
    pub sc_proglit_to_pair: FxHashMap<i32, (EntKey, EntKey)>,
    /// solver literal → list of (a, b) pairs (union-all fallback path).
    pub merge_lit_to_pairs: FxHashMap<i32, Vec<(EntKey, EntKey)>>,
}

impl MergeScFacts {
    #[allow(dead_code)]
    pub fn merge_proglits(&self) -> impl Iterator<Item = i32> + '_ {
        self.merge_proglit_to_pair.keys().copied()
    }

    #[allow(dead_code)]
    pub fn sc_proglits(&self) -> impl Iterator<Item = i32> + '_ {
        self.sc_proglit_to_pair.keys().copied()
    }

    pub fn is_merge_proglit(&self, pl: i32) -> bool {
        self.merge_proglit_to_pair.contains_key(&pl)
    }
}

/// One `&classRelationship`/`&classRelationshipVia` theory atom. `via` selects
/// the "first intermediate class differs from class(b)" path semantics used by
/// reasonObjectInObject_D's grand-ancestor guard.
#[derive(Clone)]
pub struct CrAtom {
    pub a: EntKey,
    pub b: EntKey,
    pub slit: i32,
    pub via: bool,
}

/// Frozen, read-only-for-solving state built once in the first `init`.
pub struct Shared {
    pub facts: MergeScFacts,
    /// `(x, y)` → solver literal.
    pub sc_to_lit: FxHashMap<(EntKey, EntKey), i32>,
    /// solver literal → `(x, y)` (for watching positive theory atoms).
    pub sc_lit_to_pair: FxHashMap<i32, (EntKey, EntKey)>,
    /// `x` → `[(y, sameClass solver_lit)]`.
    pub sc_by_entity: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    /// `member` → `[(other, mergeClasses solver_lit)]` (cut-edge lookup).
    pub merge_by_entity: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    pub entities: FxHashSet<EntKey>,
    /// Potential same-class connectivity over the merge graph (read-only).
    pub potential_uf: Uf,
    /// `(x, y, slit)` for non-reflexive sameClass atoms potentially same.
    pub check_atoms: Vec<(EntKey, EntKey, i32)>,
    /// `abs(slit)` → `(method, vftable)` for nonOverwritingWrite atoms.
    pub now_slit_to_key: FxHashMap<i32, (EntKey, EntKey)>,
    /// `vftable` → sorted `[(method, abs_slit)]` (frozen order).
    pub now_writers_by_vft: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    /// `(vftable, class)` → solver literal for &allWritersInClass.
    pub awc_to_slit: FxHashMap<(EntKey, EntKey), i32>,
    /// `abs(slit)` → `(vftable, class)`.
    pub awc_slit_to_pair: FxHashMap<i32, (EntKey, EntKey)>,
    /// `vftable` → sorted `[(class, slit)]` (frozen order).
    pub awc_by_vft: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    /// watched `objectInObject` solver literal → `[(outer, inner)]` edges
    /// (object offsets dropped — reachability only).
    pub oio_lit_to_edges: FxHashMap<i32, Vec<(EntKey, EntKey)>>,
    /// `outer` → sorted `[(inner, watched_lit)]` — every candidate containment
    /// edge, for unreachability-cut enumeration.
    pub oio_by_src: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    /// Entities incident to any containment edge or `&classRelationship*` atom;
    /// merges touching none of these cannot change reachability.
    pub reach_entities: FxHashSet<EntKey>,
    /// `&classRelationship`/`&classRelationshipVia` atoms, sorted `(a, b, slit)`.
    pub cr_atoms: Vec<CrAtom>,
    /// `abs(slit)` → full relationship atom for watched-literal lookup.
    pub cr_slit_to_atom: FxHashMap<i32, CrAtom>,
    /// `abs(slit)` → sorted `[(group, witness_entity)]` for `witnessGroup/2`
    /// atoms sharing that solver literal (existential witness membership,
    /// decided by `&classHasWitness/2`).
    pub witness_lit_entries: FxHashMap<i32, Vec<(EntKey, EntKey)>>,
    /// `group` → sorted `[(witness_entity, abs_slit)]` (frozen order).
    pub witness_by_group: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
    /// `&classHasWitness` atoms, sorted `(group, class, slit)`. Only swept in
    /// full once (the initial `check()` sweep); routine updates use each
    /// thread's component-local `chw_in` index. This list can be tens of
    /// thousands of entries once the value/method domains are large, so an
    /// unconditional per-`check()` sweep does not scale.
    pub chw_atoms: Vec<(EntKey, EntKey, i32)>,
    /// `abs(slit)` → `(group, class, slit)`, for watching a `&classHasWitness`
    /// atom's own literal (mirrors `awc_slit_to_pair`; keeps the signed `slit`
    /// alongside so truth is re-queried against it, not the raw abs literal).
    pub chw_slit_to_pair: FxHashMap<i32, (EntKey, EntKey, i32)>,
    pub observed_proglits: FxHashSet<i32>,
    pub unconditional_proglits: FxHashSet<i32>,
    /// observed program-literal → solver literal (best-effort).
    pub proglit_to_slit: FxHashMap<i32, i32>,
    /// head program-literal → positive bodies (foundedness; empty if disabled).
    pub head_to_bodies: FxHashMap<i32, Vec<Vec<i32>>>,
    pub foundedness_check: bool,
    /// Print every learnt reason clause to stderr (debug; `--dump-lemmas`).
    pub dump_lemmas: bool,
    /// Redirect from `mergeClasses` decisions to `&sameClass` outputs (`--decide-outputs`).
    pub decide_outputs: bool,
    /// Redirect from `&sameClass` decisions to `mergeClasses` inputs (`--decide-inputs`).
    pub decide_inputs: bool,
    /// Per-thread mutable state, indexed by clingo `thread_id`.
    pub states: Vec<Mutex<ThreadState>>,
}

/// Lives for the whole solve, shared between the observer (during ground) and
/// the propagator (during solve). `data` pointer passed to clingo is
/// `Box::into_raw(Box<PropData>)`.
pub struct PropData {
    /// Observer-collected rules; drained by the first `init`.
    pub obs: Mutex<ObsData>,
    pub shared: OnceLock<Arc<Shared>>,
    /// Serializes the first-thread `Shared` build so later threads reuse it.
    pub init_lock: Mutex<()>,
    pub foundedness_check: bool,
    pub dump_lemmas: bool,
    pub decide_outputs: bool,
    pub decide_inputs: bool,
}

impl PropData {
    pub fn new(
        foundedness_check: bool,
        dump_lemmas: bool,
        decide_outputs: bool,
        decide_inputs: bool,
    ) -> Box<PropData> {
        Box::new(PropData {
            obs: Mutex::new(ObsData::default()),
            shared: OnceLock::new(),
            init_lock: Mutex::new(()),
            foundedness_check,
            dump_lemmas,
            decide_outputs,
            decide_inputs,
        })
    }
}
