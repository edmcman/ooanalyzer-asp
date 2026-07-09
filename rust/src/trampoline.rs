//! `extern "C"` trampolines bridging clingo's C callback contract to the Rust
//! propagator/observer. Each recovers `PropData` from the raw `data` pointer,
//! slices the C arrays into Rust slices, dispatches into `propagator.rs`, and
//! converts any panic into a clingo runtime error (a panic crossing FFI is UB).
//!
//! No GIL/Python is touched here — solving runs entirely in Rust.

use crate::ffi::{
    self, ClingoAtom, ClingoExternalType, ClingoGroundProgramObserver, ClingoLiteral,
    ClingoPropagateControl, ClingoPropagateInit, ClingoPropagator, ClingoWeight,
    ClingoWeightedLiteral,
};
use crate::inspector;
use crate::propagator;
use crate::shared::PropData;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

fn pd(data: *mut std::ffi::c_void) -> &'static PropData {
    unsafe { &*(data as *const PropData) }
}

fn flatten(res: std::thread::Result<Result_>) -> bool {
    let ffi = ffi::Ffi::get();
    match res {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust observer panicked");
            false
        }
    }
}

type Result_ = std::result::Result<(), String>;

// ── propagator ──────────────────────────────────────────────────────────────

pub extern "C" fn init(init_ptr: *mut ClingoPropagateInit, data: *mut std::ffi::c_void) -> bool {
    let pd = pd(data);
    let ffi = ffi::Ffi::get();
    let res = catch_unwind(AssertUnwindSafe(|| propagator::init(ffi, pd, init_ptr)));
    match res {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust propagator init panicked");
            false
        }
    }
}

pub extern "C" fn propagate(
    ctrl: *mut ClingoPropagateControl,
    changes: *const ClingoLiteral,
    size: usize,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = pd(data);
    let ffi = ffi::Ffi::get();
    let changes = if changes.is_null() || size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(changes, size) }
    };
    let res = catch_unwind(AssertUnwindSafe(|| {
        propagator::propagate(ffi, pd, ctrl, changes)
    }));
    match res {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust propagator propagate panicked");
            false
        }
    }
}

pub extern "C" fn undo(
    ctrl: *const ClingoPropagateControl,
    changes: *const ClingoLiteral,
    size: usize,
    data: *mut std::ffi::c_void,
) {
    let pd = pd(data);
    let ffi = ffi::Ffi::get();
    let changes = if changes.is_null() || size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(changes, size) }
    };
    let _ = catch_unwind(AssertUnwindSafe(|| {
        propagator::undo(ffi, pd, ctrl, changes)
    }));
}

pub extern "C" fn check(ctrl: *mut ClingoPropagateControl, data: *mut std::ffi::c_void) -> bool {
    let pd = pd(data);
    let ffi = ffi::Ffi::get();
    let res = catch_unwind(AssertUnwindSafe(|| propagator::check(ffi, pd, ctrl)));
    match res {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust propagator check panicked");
            false
        }
    }
}

pub extern "C" fn decide(
    thread_id: ffi::ClingoId,
    assignment: *const ffi::ClingoAssignment,
    fallback: ClingoLiteral,
    data: *mut std::ffi::c_void,
    decision: *mut ClingoLiteral,
) -> bool {
    let pd = pd(data);
    let ffi_ = ffi::Ffi::get();
    let res = catch_unwind(AssertUnwindSafe(|| {
        propagator::decide(ffi_, pd, thread_id, assignment, fallback)
    }));
    match res {
        Ok(lit) => {
            unsafe { *decision = lit };
            true
        }
        Err(_) => {
            ffi::set_runtime_error(ffi_, "rust propagator decide panicked");
            false
        }
    }
}

// ── observer ────────────────────────────────────────────────────────────────

pub extern "C" fn rule(
    choice: bool,
    head: *const ClingoAtom,
    head_size: usize,
    body: *const ClingoLiteral,
    body_size: usize,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = pd(data);
    let head = if head.is_null() || head_size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(head, head_size) }
    };
    let body = if body.is_null() || body_size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(body, body_size) }
    };
    let res = catch_unwind(AssertUnwindSafe(|| {
        propagator::obs_rule(pd, choice, head, body)
    }));
    flatten(res)
}

pub extern "C" fn weight_rule(
    _choice: bool,
    head: *const ClingoAtom,
    head_size: usize,
    _lower: ClingoWeight,
    _body: *const ClingoWeightedLiteral,
    _body_size: usize,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = pd(data);
    // Conservatively treat all heads as unconditionally derivable.
    let head: Vec<i32> = if head.is_null() || head_size == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(head, head_size) }
            .iter()
            .map(|&a| a as i32)
            .collect()
    };
    let res = catch_unwind(AssertUnwindSafe(|| {
        propagator::obs_unconditional(pd, &head)
    }));
    flatten(res)
}

pub extern "C" fn external(
    atom: ClingoAtom,
    value: ClingoExternalType,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = pd(data);
    let res = catch_unwind(AssertUnwindSafe(|| {
        propagator::obs_external(pd, atom as i32, value)
    }));
    flatten(res)
}

/// Build the clingo propagator struct wired to the Rust trampolines. `decide` is
/// registered only when `--decide-outputs` or `--decide-inputs` is on.
pub fn propagator_struct(decide_outputs: bool, decide_inputs: bool) -> ClingoPropagator {
    ClingoPropagator {
        init: Some(init),
        propagate: Some(propagate),
        undo: Some(undo),
        check: Some(check),
        decide: if decide_outputs || decide_inputs {
            Some(decide)
        } else {
            None
        },
    }
}

/// Build the clingo observer struct wired to the Rust trampolines (only the
/// three callbacks we need; rest `None`).
pub fn observer_struct() -> ClingoGroundProgramObserver {
    ClingoGroundProgramObserver {
        init_program: None,
        begin_step: None,
        end_step: None,
        rule: Some(rule),
        weight_rule: Some(weight_rule),
        minimize: None,
        project: None,
        output_atom: None,
        output_term: None,
        external: Some(external),
        assume: None,
        heuristic: None,
        acyc_edge: None,
        theory_term_number: None,
        theory_term_string: None,
        theory_term_compound: None,
        theory_element: None,
        theory_atom: None,
        theory_atom_with_guard: None,
    }
}

// ── inspector propagator ───────────────────────────────────────────────────

pub extern "C" fn inspector_init(
    init: *mut ClingoPropagateInit,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = inspector::data_ptr(data);
    let ffi = ffi::Ffi::get();
    match catch_unwind(AssertUnwindSafe(|| inspector::init(ffi, pd, init))) {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust inspector init panicked");
            false
        }
    }
}

pub extern "C" fn inspector_propagate(
    ctrl: *mut ClingoPropagateControl,
    changes: *const ClingoLiteral,
    size: usize,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = inspector::data_ptr(data);
    let ffi = ffi::Ffi::get();
    let changes = if changes.is_null() || size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(changes, size) }
    };
    match catch_unwind(AssertUnwindSafe(|| {
        inspector::propagate(ffi, pd, ctrl, changes)
    })) {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust inspector propagate panicked");
            false
        }
    }
}

pub extern "C" fn inspector_undo(
    ctrl: *const ClingoPropagateControl,
    changes: *const ClingoLiteral,
    size: usize,
    data: *mut std::ffi::c_void,
) {
    let pd = inspector::data_ptr(data);
    let ffi = ffi::Ffi::get();
    let changes = if changes.is_null() || size == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(changes, size) }
    };
    let _ = catch_unwind(AssertUnwindSafe(|| inspector::undo(ffi, pd, ctrl, changes)));
}

pub extern "C" fn inspector_check(
    ctrl: *mut ClingoPropagateControl,
    data: *mut std::ffi::c_void,
) -> bool {
    let pd = inspector::data_ptr(data);
    let ffi = ffi::Ffi::get();
    match catch_unwind(AssertUnwindSafe(|| inspector::check(ffi, pd, ctrl))) {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            ffi::set_runtime_error(ffi, &msg);
            false
        }
        Err(_) => {
            ffi::set_runtime_error(ffi, "rust inspector check panicked");
            false
        }
    }
}

pub fn inspector_struct() -> ClingoPropagator {
    ClingoPropagator {
        init: Some(inspector_init),
        propagate: Some(inspector_propagate),
        undo: Some(inspector_undo),
        check: Some(inspector_check),
        decide: None,
    }
}

// Silence unused-warning for the pointer helper until lib.rs wires registration.
#[allow(dead_code)]
fn _unused(p: *mut std::ffi::c_void) {
    let _ = ptr::addr_of!(p);
}
