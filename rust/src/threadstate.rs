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

pub struct ThreadState {
    pub uf: Uf,
    /// `(merge_solver_lit, snapshot)` in assignment order; the suffix being
    /// undone is restored in `undo`.
    pub merge_trail: Vec<(i32, Snap)>,
    pub initialized: bool,
    /// Solver-assigned-true `&sameClass` solver literals, so `check()` only
    /// re-examines those. Maintained by propagate (add) and undo (drop).
    pub true_sc: FxHashSet<i32>,
    pub did_initial_sc_sweep: bool,
    /// True `objectInObject` edges `(outer, inner, offset, watched_lit)` in
    /// assignment order. Reachability ignores the retained offset;
    /// `&occupiedByOther` uses it to isolate candidate occupants.
    pub oio_true: Vec<(EntKey, EntKey, EntKey, i32)>,
    /// `(watched_lit, oio_true.len() before)` — suffix popped in `undo`.
    pub oio_trail: Vec<(i32, usize)>,
    /// `--decide-inputs` rotating scan position per entity into
    /// `merge_by_entity`. Pure decision-heuristic state: never undone, so
    /// re-dives after a backjump explore different merge prefixes instead of
    /// deterministically rebuilding the same one.
    pub decide_cursor: FxHashMap<EntKey, usize>,
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
            decide_cursor: FxHashMap::default(),
        }
    }
}

impl Default for ThreadState {
    fn default() -> Self {
        Self::new()
    }
}
