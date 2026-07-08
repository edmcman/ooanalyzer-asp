//! Per-solver-thread mutable state. Port of `sameclass.py:_ThreadState`.
//!
//! Each clingo solver thread owns one `ThreadState`, indexed by `thread_id`.
//! Only that thread touches its state, but we guard it with a `Mutex` (held only
//! for the duration of one callback) so the raw-pointer trampolines stay sound
//! without reasoning about clingo's thread-affinity guarantees.

use crate::entkey::EntKey;
use crate::uf::Uf;
use rustc_hash::{FxHashMap, FxHashSet};

/// A UF snapshot, restored on undo.
pub type Snap = (usize, usize);

/// Per-union undo record for the incremental `&classHasWitness` support maps:
/// the absorbed root's support counts (moved wholesale into the winner) and the
/// per-group lengths of the chw-atom blocks appended to the winner's lists.
/// Reversed in LIFO order with the UF snapshots, so the appended blocks are
/// always exactly the winners' list tails when popped.
pub struct UnionUndo {
    pub winner: EntKey,
    pub absorbed: EntKey,
    pub moved_support: Option<FxHashMap<EntKey, u32>>,
    pub moved_chw: Vec<(EntKey, usize)>,
}

pub struct ThreadState {
    pub uf: Uf,
    /// `(merge_solver_lit, snapshot, support-undo)` in assignment order; the
    /// suffix being undone is restored in `undo`.
    pub merge_trail: Vec<(i32, Snap, UnionUndo)>,
    pub initialized: bool,
    /// Solver-assigned-true `&sameClass` solver literals, so `check()` only
    /// re-examines those. Maintained by propagate (add) and undo (drop).
    pub true_sc: FxHashSet<i32>,
    pub did_initial_sc_sweep: bool,
    /// True `objectInObject` edges `(outer, inner, watched_lit)` in assignment
    /// order — the containment graph for `&classRelationship*` reachability.
    pub oio_true: Vec<(EntKey, EntKey, i32)>,
    /// `(watched_lit, oio_true.len() before)` — suffix popped in `undo`.
    pub oio_trail: Vec<(i32, usize)>,
    /// Solver-assigned-true `&classHasWitness` solver literals, so `check()`
    /// only re-examines those after the initial full sweep. Maintained by
    /// propagate (add) and undo (drop) — mirrors `true_sc`.
    pub true_chw: FxHashSet<i32>,
    pub did_initial_chw_sweep: bool,
    /// `--decide-inputs` rotating scan position per entity into
    /// `merge_by_entity`. Pure decision-heuristic state: never undone, so
    /// re-dives after a backjump explore different merge prefixes instead of
    /// deterministically rebuilding the same one.
    pub decide_cursor: FxHashMap<EntKey, usize>,
    /// root → group → count of true `witnessGroup` atoms whose witness lives
    /// in the root's component. The O(1) answer to `&classHasWitness` support.
    pub support: FxHashMap<EntKey, FxHashMap<EntKey, u32>>,
    /// root → group → `&classHasWitness` atoms `(class, slit)` whose class
    /// lives in the root's component — the atoms to force when the component
    /// gains its first witness of the group.
    pub chw_in: FxHashMap<EntKey, FxHashMap<EntKey, Vec<(EntKey, i32)>>>,
    /// `(witness alit, root at increment time, group)` — decremented at the
    /// recorded root on undo (union moves are always reversed first, so the
    /// recorded root's map is live again by then).
    pub witness_trail: Vec<(i32, EntKey, EntKey)>,
    /// Witness alits currently counted into `support` (idempotence guard).
    pub counted_witness: FxHashSet<i32>,
    /// `(entity, group)` hints whose support may have dropped to zero during
    /// undo; re-verified and eagerly refuted at the next propagate() entry.
    pub pending_unsupported: Vec<(EntKey, EntKey)>,
}

impl ThreadState {
    pub fn new() -> Self {
        ThreadState {
            uf: Uf::new(),
            merge_trail: Vec::new(),
            initialized: false,
            true_sc: FxHashSet::default(),
            did_initial_sc_sweep: false,
            oio_true: Vec::new(),
            oio_trail: Vec::new(),
            true_chw: FxHashSet::default(),
            did_initial_chw_sweep: false,
            decide_cursor: FxHashMap::default(),
            support: FxHashMap::default(),
            chw_in: FxHashMap::default(),
            witness_trail: Vec::new(),
            counted_witness: FxHashSet::default(),
            pending_unsupported: Vec::new(),
        }
    }
}

impl Default for ThreadState {
    fn default() -> Self {
        Self::new()
    }
}
