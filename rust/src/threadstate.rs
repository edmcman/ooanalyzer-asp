//! Per-solver-thread mutable state. Port of `sameclass.py:_ThreadState`.
//!
//! Each clingo solver thread owns one `ThreadState`, indexed by `thread_id`.
//! Only that thread touches its state, but we guard it with a `Mutex` (held only
//! for the duration of one callback) so the raw-pointer trampolines stay sound
//! without reasoning about clingo's thread-affinity guarantees.

use crate::uf::Uf;
use rustc_hash::FxHashSet;

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
}

impl ThreadState {
    pub fn new() -> Self {
        ThreadState {
            uf: Uf::new(),
            merge_trail: Vec::new(),
            initialized: false,
            true_sc: FxHashSet::default(),
            did_initial_sc_sweep: false,
        }
    }
}

impl Default for ThreadState {
    fn default() -> Self {
        Self::new()
    }
}