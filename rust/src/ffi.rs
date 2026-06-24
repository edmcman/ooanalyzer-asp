//! Hand-written FFI bindings for the subset of libclingo's C API used by the
//! propagator. libclingo is statically embedded in the Python `clingo` wheel
//! and loaded with `RTLD_GLOBAL`, so its symbols are resolvable at runtime via
//! `dlsym(RTLD_DEFAULT, ...)` (see `clingo/_internal.py`). We never link against
//! libclingo at build time; `Ffi::load()` resolves every needed function
//! pointer once at module import and stores them in a `static`.
//!
//! The propagator/observer callback structs are declared with `#[repr(C)]`
//! matching `clingo.h` exactly so their field layout matches what
//! `clingo_control_register_propagator`/`register_observer` expect.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::ptr;
use std::sync::OnceLock;

// ── scalar typedefs (clingo.h:121-330) ──────────────────────────────────────
pub type ClingoLiteral = i32;
pub type ClingoAtom = u32;
pub type ClingoId = u32;
pub type ClingoWeight = i32;
pub type ClingoSymbol = u64;
pub type ClingoSignature = u64;
pub type ClingoSymAtomIterator = u64;
pub type ClingoSymbolType = i32;
pub type ClingoTheoryTermType = i32;
pub type ClingoExternalType = i32;
pub type ClingoCheckMode = i32;
pub type ClingoClauseType = i32;

// ── opaque types (passed only by pointer) ───────────────────────────────────
#[repr(C)]
pub struct ClingoControl {
    _o: [u8; 0],
}
#[repr(C)]
pub struct ClingoPropagateInit {
    _o: [u8; 0],
}
#[repr(C)]
pub struct ClingoPropagateControl {
    _o: [u8; 0],
}
#[repr(C)]
pub struct ClingoAssignment {
    _o: [u8; 0],
}
#[repr(C)]
pub struct ClingoSymbolicAtoms {
    _o: [u8; 0],
}
#[repr(C)]
pub struct ClingoTheoryAtoms {
    _o: [u8; 0],
}

#[repr(C)]
pub struct ClingoWeightedLiteral {
    pub literal: ClingoLiteral,
    pub weight: ClingoWeight,
}

// ── enum constants ───────────────────────────────────────────────────────────
// The full clingo enum surface is bound for parity; only a subset is currently
// read by the propagator.
#[allow(dead_code)]
pub const CHECK_MODE_TOTAL: ClingoCheckMode = 1;
pub const CLAUSE_TYPE_LEARNT: ClingoClauseType = 0;
#[allow(dead_code)]
pub const CLAUSE_TYPE_STATIC: ClingoClauseType = 1;
#[allow(dead_code)]
pub const CLAUSE_TYPE_VOLATILE: ClingoClauseType = 2;

pub const SYMBOL_TYPE_NUMBER: ClingoSymbolType = 1;
pub const SYMBOL_TYPE_FUNCTION: ClingoSymbolType = 5;

#[allow(dead_code)]
pub const THEORY_TERM_TYPE_TUPLE: ClingoTheoryTermType = 0;
#[allow(dead_code)]
pub const THEORY_TERM_TYPE_FUNCTION: ClingoTheoryTermType = 3;
pub const THEORY_TERM_TYPE_NUMBER: ClingoTheoryTermType = 4;
#[allow(dead_code)]
pub const THEORY_TERM_TYPE_SYMBOL: ClingoTheoryTermType = 5;

pub const EXTERNAL_TYPE_FALSE: ClingoExternalType = 2;

pub const ERROR_RUNTIME: i32 = 1;

// ── callback typedefs for the registration structs ───────────────────────────
pub type PropInitCb = unsafe extern "C" fn(*mut ClingoPropagateInit, *mut c_void) -> bool;
pub type PropPropagateCb =
    unsafe extern "C" fn(*mut ClingoPropagateControl, *const ClingoLiteral, usize, *mut c_void) -> bool;
pub type PropUndoCb =
    unsafe extern "C" fn(*const ClingoPropagateControl, *const ClingoLiteral, usize, *mut c_void);
pub type PropCheckCb = unsafe extern "C" fn(*mut ClingoPropagateControl, *mut c_void) -> bool;
pub type PropDecideCb = unsafe extern "C" fn(
    ClingoId,
    *const ClingoAssignment,
    ClingoLiteral,
    *mut c_void,
    *mut ClingoLiteral,
) -> bool;

#[repr(C)]
pub struct ClingoPropagator {
    pub init: Option<PropInitCb>,
    pub propagate: Option<PropPropagateCb>,
    pub undo: Option<PropUndoCb>,
    pub check: Option<PropCheckCb>,
    pub decide: Option<PropDecideCb>,
}

// Observer callbacks (clingo.h:2667-2848). sameclass only implements
// rule/weight_rule/external; the rest are left None.
pub type ObsInitProgramCb = unsafe extern "C" fn(bool, *mut c_void) -> bool;
pub type ObsBeginStepCb = unsafe extern "C" fn(*mut c_void) -> bool;
pub type ObsEndStepCb = unsafe extern "C" fn(*mut c_void) -> bool;
pub type ObsRuleCb = unsafe extern "C" fn(
    bool,
    *const ClingoAtom,
    usize,
    *const ClingoLiteral,
    usize,
    *mut c_void,
) -> bool;
pub type ObsWeightRuleCb = unsafe extern "C" fn(
    bool,
    *const ClingoAtom,
    usize,
    ClingoWeight,
    *const ClingoWeightedLiteral,
    usize,
    *mut c_void,
) -> bool;
pub type ObsMinimizeCb =
    unsafe extern "C" fn(ClingoWeight, *const ClingoWeightedLiteral, usize, *mut c_void) -> bool;
pub type ObsProjectCb = unsafe extern "C" fn(*const ClingoAtom, usize, *mut c_void) -> bool;
pub type ObsOutputAtomCb =
    unsafe extern "C" fn(ClingoSymbol, ClingoAtom, *mut c_void) -> bool;
pub type ObsOutputTermCb =
    unsafe extern "C" fn(ClingoSymbol, *const ClingoLiteral, usize, *mut c_void) -> bool;
pub type ObsExternalCb =
    unsafe extern "C" fn(ClingoAtom, ClingoExternalType, *mut c_void) -> bool;
pub type ObsAssumeCb =
    unsafe extern "C" fn(*const ClingoLiteral, usize, *mut c_void) -> bool;
pub type ObsHeuristicCb = unsafe extern "C" fn(
    ClingoAtom,
    i32,
    i32,
    u32,
    *const ClingoLiteral,
    usize,
    *mut c_void,
) -> bool;
pub type ObsAcycEdgeCb =
    unsafe extern "C" fn(i32, i32, *const ClingoLiteral, usize, *mut c_void) -> bool;
pub type ObsTheoryTermNumberCb =
    unsafe extern "C" fn(ClingoId, i32, *mut c_void) -> bool;
pub type ObsTheoryTermStringCb =
    unsafe extern "C" fn(ClingoId, *const c_char, *mut c_void) -> bool;
pub type ObsTheoryTermCompoundCb = unsafe extern "C" fn(
    ClingoId,
    i32,
    *const ClingoId,
    usize,
    *mut c_void,
) -> bool;
pub type ObsTheoryElementCb = unsafe extern "C" fn(
    ClingoId,
    *const ClingoId,
    usize,
    *const ClingoLiteral,
    usize,
    *mut c_void,
) -> bool;
pub type ObsTheoryAtomCb =
    unsafe extern "C" fn(ClingoId, ClingoId, *const ClingoId, usize, *mut c_void) -> bool;
pub type ObsTheoryAtomWithGuardCb = unsafe extern "C" fn(
    ClingoId,
    ClingoId,
    *const ClingoId,
    usize,
    ClingoId,
    ClingoId,
    *mut c_void,
) -> bool;

#[repr(C)]
pub struct ClingoGroundProgramObserver {
    pub init_program: Option<ObsInitProgramCb>,
    pub begin_step: Option<ObsBeginStepCb>,
    pub end_step: Option<ObsEndStepCb>,
    pub rule: Option<ObsRuleCb>,
    pub weight_rule: Option<ObsWeightRuleCb>,
    pub minimize: Option<ObsMinimizeCb>,
    pub project: Option<ObsProjectCb>,
    pub output_atom: Option<ObsOutputAtomCb>,
    pub output_term: Option<ObsOutputTermCb>,
    pub external: Option<ObsExternalCb>,
    pub assume: Option<ObsAssumeCb>,
    pub heuristic: Option<ObsHeuristicCb>,
    pub acyc_edge: Option<ObsAcycEdgeCb>,
    pub theory_term_number: Option<ObsTheoryTermNumberCb>,
    pub theory_term_string: Option<ObsTheoryTermStringCb>,
    pub theory_term_compound: Option<ObsTheoryTermCompoundCb>,
    pub theory_element: Option<ObsTheoryElementCb>,
    pub theory_atom: Option<ObsTheoryAtomCb>,
    pub theory_atom_with_guard: Option<ObsTheoryAtomWithGuardCb>,
}

// ── typed function pointers for the API ─────────────────────────────────────
type FnControlRegisterPropagator =
    unsafe extern "C" fn(*mut ClingoControl, *const ClingoPropagator, *mut c_void, bool) -> bool;
type FnControlRegisterObserver =
    unsafe extern "C" fn(*mut ClingoControl, *const ClingoGroundProgramObserver, bool, *mut c_void) -> bool;

type FnErrorCode = unsafe extern "C" fn() -> i32;
type FnErrorMessage = unsafe extern "C" fn() -> *const c_char;
type FnSetError = unsafe extern "C" fn(i32, *const c_char);

type FnSignatureCreate =
    unsafe extern "C" fn(*const c_char, u32, bool, *mut ClingoSignature) -> bool;
type FnSignatureName = unsafe extern "C" fn(ClingoSignature) -> *const c_char;
type FnSignatureArity = unsafe extern "C" fn(ClingoSignature) -> u32;

type FnSymbolNumber = unsafe extern "C" fn(ClingoSymbol, *mut i32) -> bool;
type FnSymbolName = unsafe extern "C" fn(ClingoSymbol, *mut *const c_char) -> bool;
type FnSymbolIsPositive = unsafe extern "C" fn(ClingoSymbol, *mut bool) -> bool;
type FnSymbolArguments =
    unsafe extern "C" fn(ClingoSymbol, *mut *const ClingoSymbol, *mut usize) -> bool;
type FnSymbolType = unsafe extern "C" fn(ClingoSymbol) -> ClingoSymbolType;
type FnSymbolToStringSize = unsafe extern "C" fn(ClingoSymbol, *mut usize) -> bool;
type FnSymbolToString =
    unsafe extern "C" fn(ClingoSymbol, *mut c_char, usize) -> bool;

type FnSymAtomsBegin = unsafe extern "C" fn(
    *const ClingoSymbolicAtoms,
    *const ClingoSignature,
    *mut ClingoSymAtomIterator,
) -> bool;
type FnSymAtomsEnd =
    unsafe extern "C" fn(*const ClingoSymbolicAtoms, *mut ClingoSymAtomIterator) -> bool;
type FnSymAtomsNext = unsafe extern "C" fn(
    *const ClingoSymbolicAtoms,
    ClingoSymAtomIterator,
    *mut ClingoSymAtomIterator,
) -> bool;
type FnSymAtomsIterEqual = unsafe extern "C" fn(
    *const ClingoSymbolicAtoms,
    ClingoSymAtomIterator,
    ClingoSymAtomIterator,
    *mut bool,
) -> bool;
type FnSymAtomsSymbol = unsafe extern "C" fn(
    *const ClingoSymbolicAtoms,
    ClingoSymAtomIterator,
    *mut ClingoSymbol,
) -> bool;
type FnSymAtomsLiteral = unsafe extern "C" fn(
    *const ClingoSymbolicAtoms,
    ClingoSymAtomIterator,
    *mut ClingoLiteral,
) -> bool;

type FnTheoryAtomsSize = unsafe extern "C" fn(*const ClingoTheoryAtoms, *mut usize) -> bool;
type FnTheoryAtomsAtomTerm =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut ClingoId) -> bool;
type FnTheoryAtomsAtomLiteral =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut ClingoLiteral) -> bool;
type FnTheoryAtomsTermType =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut ClingoTheoryTermType) -> bool;
type FnTheoryAtomsTermNumber =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut i32) -> bool;
type FnTheoryAtomsTermName =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut *const c_char) -> bool;
type FnTheoryAtomsTermArguments = unsafe extern "C" fn(
    *const ClingoTheoryAtoms,
    ClingoId,
    *mut *const ClingoId,
    *mut usize,
) -> bool;
type FnTheoryAtomsTermToStringSize =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut usize) -> bool;
type FnTheoryAtomsTermToString =
    unsafe extern "C" fn(*const ClingoTheoryAtoms, ClingoId, *mut c_char, usize) -> bool;

type FnInitSolverLiteral =
    unsafe extern "C" fn(*const ClingoPropagateInit, ClingoLiteral, *mut ClingoLiteral) -> bool;
type FnInitAddWatch = unsafe extern "C" fn(*mut ClingoPropagateInit, ClingoLiteral) -> bool;
type FnInitAddClause =
    unsafe extern "C" fn(*mut ClingoPropagateInit, *const ClingoLiteral, usize, *mut bool) -> bool;
type FnInitSymbolicAtoms =
    unsafe extern "C" fn(*const ClingoPropagateInit, *mut *const ClingoSymbolicAtoms) -> bool;
type FnInitTheoryAtoms =
    unsafe extern "C" fn(*const ClingoPropagateInit, *mut *const ClingoTheoryAtoms) -> bool;
type FnInitNumberOfThreads = unsafe extern "C" fn(*const ClingoPropagateInit) -> i32;
type FnInitSetCheckMode = unsafe extern "C" fn(*mut ClingoPropagateInit, ClingoCheckMode);
type FnInitAssignment =
    unsafe extern "C" fn(*const ClingoPropagateInit) -> *const ClingoAssignment;

type FnControlThreadId = unsafe extern "C" fn(*const ClingoPropagateControl) -> ClingoId;
type FnControlAssignment =
    unsafe extern "C" fn(*const ClingoPropagateControl) -> *const ClingoAssignment;
type FnControlAddClause = unsafe extern "C" fn(
    *mut ClingoPropagateControl,
    *const ClingoLiteral,
    usize,
    ClingoClauseType,
    *mut bool,
) -> bool;

type FnAssignmentIsTrue =
    unsafe extern "C" fn(*const ClingoAssignment, ClingoLiteral, *mut bool) -> bool;
type FnAssignmentIsFalse =
    unsafe extern "C" fn(*const ClingoAssignment, ClingoLiteral, *mut bool) -> bool;
type FnAssignmentIsFixed =
    unsafe extern "C" fn(*const ClingoAssignment, ClingoLiteral, *mut bool) -> bool;
type FnAssignmentIsTotal = unsafe extern "C" fn(*const ClingoAssignment) -> bool;
type FnAssignmentDecisionLevel = unsafe extern "C" fn(*const ClingoAssignment) -> u32;

/// Resolved libclingo function pointers.
#[allow(non_snake_case, dead_code)]
pub struct Ffi {
    pub control_register_propagator: FnControlRegisterPropagator,
    pub control_register_observer: FnControlRegisterObserver,
    pub error_code: FnErrorCode,
    pub error_message: FnErrorMessage,
    pub set_error: FnSetError,
    pub signature_create: FnSignatureCreate,
    pub signature_name: FnSignatureName,
    pub signature_arity: FnSignatureArity,
    pub symbol_number: FnSymbolNumber,
    pub symbol_name: FnSymbolName,
    pub symbol_is_positive: FnSymbolIsPositive,
    pub symbol_arguments: FnSymbolArguments,
    pub symbol_type: FnSymbolType,
    pub symbol_to_string_size: FnSymbolToStringSize,
    pub symbol_to_string: FnSymbolToString,
    pub sym_atoms_begin: FnSymAtomsBegin,
    pub sym_atoms_end: FnSymAtomsEnd,
    pub sym_atoms_next: FnSymAtomsNext,
    pub sym_atoms_iter_equal: FnSymAtomsIterEqual,
    pub sym_atoms_symbol: FnSymAtomsSymbol,
    pub sym_atoms_literal: FnSymAtomsLiteral,
    pub theory_atoms_size: FnTheoryAtomsSize,
    pub theory_atoms_atom_term: FnTheoryAtomsAtomTerm,
    pub theory_atoms_atom_literal: FnTheoryAtomsAtomLiteral,
    pub theory_atoms_term_type: FnTheoryAtomsTermType,
    pub theory_atoms_term_number: FnTheoryAtomsTermNumber,
    pub theory_atoms_term_name: FnTheoryAtomsTermName,
    pub theory_atoms_term_arguments: FnTheoryAtomsTermArguments,
    pub theory_atoms_term_to_string_size: FnTheoryAtomsTermToStringSize,
    pub theory_atoms_term_to_string: FnTheoryAtomsTermToString,
    pub init_solver_literal: FnInitSolverLiteral,
    pub init_add_watch: FnInitAddWatch,
    pub init_add_clause: FnInitAddClause,
    pub init_symbolic_atoms: FnInitSymbolicAtoms,
    pub init_theory_atoms: FnInitTheoryAtoms,
    pub init_number_of_threads: FnInitNumberOfThreads,
    pub init_set_check_mode: FnInitSetCheckMode,
    pub init_assignment: FnInitAssignment,
    pub control_thread_id: FnControlThreadId,
    pub control_assignment: FnControlAssignment,
    pub control_add_clause: FnControlAddClause,
    pub assignment_is_true: FnAssignmentIsTrue,
    pub assignment_is_false: FnAssignmentIsFalse,
    pub assignment_is_fixed: FnAssignmentIsFixed,
    pub assignment_is_total: FnAssignmentIsTotal,
    pub assignment_decision_level: FnAssignmentDecisionLevel,
}

static FFI: OnceLock<Ffi> = OnceLock::new();

#[derive(Debug)]
#[allow(dead_code)]
pub struct ClingoError {
    pub code: i32,
    pub message: String,
}

unsafe fn dlsym_str(name: &str) -> *mut c_void {
    let c = CString::new(name).unwrap();
    libc::dlsym(libc::RTLD_DEFAULT, c.as_ptr())
}

/// Resolve a clingo C symbol by name and transmute it to a typed fn pointer.
/// Used via `make_ffi!` so the macro is invoked in expression position (macros
/// are not permitted directly in struct-field position).
unsafe fn load_fn_ptr<T>(name: &str) -> Result<T, String> {
    let p = dlsym_str(name);
    if p.is_null() {
        return Err(format!("dlsym failed for {name}"));
    }
    // *mut c_void and any fn pointer are each one word; transmute_copy is sound.
    Ok(unsafe { std::mem::transmute_copy::<*mut c_void, T>(&p) })
}

macro_rules! make_ffi {
    ( $( $field:ident : $name:literal ),* $(,)? ) => {
        Ffi {
            $( $field: unsafe { load_fn_ptr($name)? }, )*
        }
    };
}

impl Ffi {
    pub fn load() -> Result<&'static Ffi, String> {
        if let Some(f) = FFI.get() {
            return Ok(f);
        }
        let ffi = make_ffi! {
            control_register_propagator: "clingo_control_register_propagator",
            control_register_observer: "clingo_control_register_observer",
            error_code: "clingo_error_code",
            error_message: "clingo_error_message",
            set_error: "clingo_set_error",
            signature_create: "clingo_signature_create",
            signature_name: "clingo_signature_name",
            signature_arity: "clingo_signature_arity",
            symbol_number: "clingo_symbol_number",
            symbol_name: "clingo_symbol_name",
            symbol_is_positive: "clingo_symbol_is_positive",
            symbol_arguments: "clingo_symbol_arguments",
            symbol_type: "clingo_symbol_type",
            symbol_to_string_size: "clingo_symbol_to_string_size",
            symbol_to_string: "clingo_symbol_to_string",
            sym_atoms_begin: "clingo_symbolic_atoms_begin",
            sym_atoms_end: "clingo_symbolic_atoms_end",
            sym_atoms_next: "clingo_symbolic_atoms_next",
            sym_atoms_iter_equal: "clingo_symbolic_atoms_iterator_is_equal_to",
            sym_atoms_symbol: "clingo_symbolic_atoms_symbol",
            sym_atoms_literal: "clingo_symbolic_atoms_literal",
            theory_atoms_size: "clingo_theory_atoms_size",
            theory_atoms_atom_term: "clingo_theory_atoms_atom_term",
            theory_atoms_atom_literal: "clingo_theory_atoms_atom_literal",
            theory_atoms_term_type: "clingo_theory_atoms_term_type",
            theory_atoms_term_number: "clingo_theory_atoms_term_number",
            theory_atoms_term_name: "clingo_theory_atoms_term_name",
            theory_atoms_term_arguments: "clingo_theory_atoms_term_arguments",
            theory_atoms_term_to_string_size: "clingo_theory_atoms_term_to_string_size",
            theory_atoms_term_to_string: "clingo_theory_atoms_term_to_string",
            init_solver_literal: "clingo_propagate_init_solver_literal",
            init_add_watch: "clingo_propagate_init_add_watch",
            init_add_clause: "clingo_propagate_init_add_clause",
            init_symbolic_atoms: "clingo_propagate_init_symbolic_atoms",
            init_theory_atoms: "clingo_propagate_init_theory_atoms",
            init_number_of_threads: "clingo_propagate_init_number_of_threads",
            init_set_check_mode: "clingo_propagate_init_set_check_mode",
            init_assignment: "clingo_propagate_init_assignment",
            control_thread_id: "clingo_propagate_control_thread_id",
            control_assignment: "clingo_propagate_control_assignment",
            control_add_clause: "clingo_propagate_control_add_clause",
            assignment_is_true: "clingo_assignment_is_true",
            assignment_is_false: "clingo_assignment_is_false",
            assignment_is_fixed: "clingo_assignment_is_fixed",
            assignment_is_total: "clingo_assignment_is_total",
            assignment_decision_level: "clingo_assignment_decision_level",
        };
        // Race-safe: if another thread loaded first, drop ours and use theirs.
        let _ = FFI.set(ffi);
        Ok(FFI.get().unwrap())
    }

    pub fn get() -> &'static Ffi {
        FFI.get().expect("ffi not loaded")
    }

    fn err(&self) -> ClingoError {
        unsafe {
            let code = (self.error_code)();
            let msg_ptr = (self.error_message)();
            let message = if msg_ptr.is_null() {
                String::new()
            } else {
                CStr::from_ptr(msg_ptr).to_string_lossy().into_owned()
            };
            ClingoError { code, message }
        }
    }

    // ── safe wrappers ────────────────────────────────────────────────────────
    pub fn set_check_mode(&self, init: *mut ClingoPropagateInit, mode: ClingoCheckMode) {
        unsafe { (self.init_set_check_mode)(init, mode) }
    }

    pub fn number_of_threads(&self, init: *const ClingoPropagateInit) -> i32 {
        unsafe { (self.init_number_of_threads)(init) }
    }

    pub fn solver_literal(
        &self,
        init: *const ClingoPropagateInit,
        prog: ClingoLiteral,
    ) -> Result<ClingoLiteral, ClingoError> {
        let mut out: ClingoLiteral = 0;
        let ok = unsafe { (self.init_solver_literal)(init, prog, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn add_watch(&self, init: *mut ClingoPropagateInit, lit: ClingoLiteral) -> bool {
        unsafe { (self.init_add_watch)(init, lit) }
    }

    pub fn init_add_clause(
        &self,
        init: *mut ClingoPropagateInit,
        clause: &[ClingoLiteral],
    ) -> Result<bool, ClingoError> {
        let mut result = false;
        let ok = unsafe {
            (self.init_add_clause)(init, clause.as_ptr(), clause.len(), &mut result)
        };
        if ok {
            Ok(result)
        } else {
            Err(self.err())
        }
    }

    pub fn init_symbolic_atoms(
        &self,
        init: *const ClingoPropagateInit,
    ) -> Result<*const ClingoSymbolicAtoms, ClingoError> {
        let mut out: *const ClingoSymbolicAtoms = ptr::null();
        let ok = unsafe { (self.init_symbolic_atoms)(init, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn init_theory_atoms(
        &self,
        init: *const ClingoPropagateInit,
    ) -> Result<*const ClingoTheoryAtoms, ClingoError> {
        let mut out: *const ClingoTheoryAtoms = ptr::null();
        let ok = unsafe { (self.init_theory_atoms)(init, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn thread_id(&self, ctrl: *const ClingoPropagateControl) -> ClingoId {
        unsafe { (self.control_thread_id)(ctrl) }
    }

    pub fn control_assignment(&self, ctrl: *const ClingoPropagateControl) -> *const ClingoAssignment {
        unsafe { (self.control_assignment)(ctrl) }
    }

    pub fn add_clause(
        &self,
        ctrl: *mut ClingoPropagateControl,
        clause: &[ClingoLiteral],
    ) -> Result<bool, ClingoError> {
        let mut result = false;
        let ok = unsafe {
            (self.control_add_clause)(ctrl, clause.as_ptr(), clause.len(), CLAUSE_TYPE_LEARNT, &mut result)
        };
        if ok {
            Ok(result)
        } else {
            Err(self.err())
        }
    }

    pub fn is_true(&self, asgn: *const ClingoAssignment, lit: ClingoLiteral) -> bool {
        let mut out = false;
        let ok = unsafe { (self.assignment_is_true)(asgn, lit, &mut out) };
        ok && out
    }

    pub fn is_false(&self, asgn: *const ClingoAssignment, lit: ClingoLiteral) -> bool {
        let mut out = false;
        let ok = unsafe { (self.assignment_is_false)(asgn, lit, &mut out) };
        ok && out
    }

    pub fn is_fixed(&self, asgn: *const ClingoAssignment, lit: ClingoLiteral) -> bool {
        let mut out = false;
        let ok = unsafe { (self.assignment_is_fixed)(asgn, lit, &mut out) };
        ok && out
    }

    pub fn is_total(&self, asgn: *const ClingoAssignment) -> bool {
        unsafe { (self.assignment_is_total)(asgn) }
    }

    #[allow(dead_code)]
    pub fn decision_level(&self, asgn: *const ClingoAssignment) -> u32 {
        unsafe { (self.assignment_decision_level)(asgn) }
    }

    pub fn register_propagator(
        &self,
        control: *mut ClingoControl,
        prop: &ClingoPropagator,
        data: *mut c_void,
    ) -> Result<(), ClingoError> {
        let ok = unsafe { (self.control_register_propagator)(control, prop, data, false) };
        if ok {
            Ok(())
        } else {
            Err(self.err())
        }
    }

    pub fn register_observer(
        &self,
        control: *mut ClingoControl,
        obs: &ClingoGroundProgramObserver,
        data: *mut c_void,
    ) -> Result<(), ClingoError> {
        let ok = unsafe { (self.control_register_observer)(control, obs, false, data) };
        if ok {
            Ok(())
        } else {
            Err(self.err())
        }
    }

    // ── symbolic atoms iteration ────────────────────────────────────────────
    #[allow(dead_code)]
    pub fn signature(&self, name: &str, arity: u32) -> Result<ClingoSignature, ClingoError> {
        let cname = CString::new(name).unwrap();
        let mut out: ClingoSignature = 0;
        let ok = unsafe { (self.signature_create)(cname.as_ptr(), arity, true, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn sym_atoms_begin(
        &self,
        atoms: *const ClingoSymbolicAtoms,
        sig: Option<ClingoSignature>,
    ) -> Result<ClingoSymAtomIterator, ClingoError> {
        let mut out: ClingoSymAtomIterator = 0;
        let sig_ptr = match sig {
            Some(s) => &s as *const ClingoSignature,
            None => ptr::null(),
        };
        let ok = unsafe { (self.sym_atoms_begin)(atoms, sig_ptr, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn sym_atoms_end(&self, atoms: *const ClingoSymbolicAtoms) -> ClingoSymAtomIterator {
        let mut out: ClingoSymAtomIterator = 0;
        let _ = unsafe { (self.sym_atoms_end)(atoms, &mut out) };
        out
    }

    pub fn sym_atoms_next(
        &self,
        atoms: *const ClingoSymbolicAtoms,
        it: ClingoSymAtomIterator,
    ) -> ClingoSymAtomIterator {
        let mut out: ClingoSymAtomIterator = 0;
        let _ = unsafe { (self.sym_atoms_next)(atoms, it, &mut out) };
        out
    }

    pub fn sym_atoms_equal(
        &self,
        atoms: *const ClingoSymbolicAtoms,
        a: ClingoSymAtomIterator,
        b: ClingoSymAtomIterator,
    ) -> bool {
        let mut eq = false;
        let _ = unsafe { (self.sym_atoms_iter_equal)(atoms, a, b, &mut eq) };
        eq
    }

    pub fn sym_atoms_symbol(
        &self,
        atoms: *const ClingoSymbolicAtoms,
        it: ClingoSymAtomIterator,
    ) -> ClingoSymbol {
        let mut out: ClingoSymbol = 0;
        let _ = unsafe { (self.sym_atoms_symbol)(atoms, it, &mut out) };
        out
    }

    pub fn sym_atoms_literal(
        &self,
        atoms: *const ClingoSymbolicAtoms,
        it: ClingoSymAtomIterator,
    ) -> ClingoLiteral {
        let mut out: ClingoLiteral = 0;
        let _ = unsafe { (self.sym_atoms_literal)(atoms, it, &mut out) };
        out
    }

    // ── symbol inspection ───────────────────────────────────────────────────
    pub fn symbol_type(&self, sym: ClingoSymbol) -> ClingoSymbolType {
        unsafe { (self.symbol_type)(sym) }
    }

    /// Check whether `sym` is a function/id atom with the given name and arity.
    /// Used to filter symbolic atoms without relying on `clingo_symbolic_atoms_begin(sig)`,
    /// which returns an empty iterator during propagator init even when atoms exist.
    pub fn symbol_matches(&self, sym: ClingoSymbol, name: &str, arity: u32) -> bool {
        // Only positive function-type symbols (classical negation atoms are excluded).
        let sym_type = self.symbol_type(sym);
        if sym_type != SYMBOL_TYPE_FUNCTION {
            return false;
        }
        let mut positive = false;
        let ok = unsafe { (self.symbol_is_positive)(sym, &mut positive) };
        if !ok || !positive {
            return false;
        }
        let mut args_ptr: *const ClingoSymbol = ptr::null();
        let mut size: usize = 0;
        let ok = unsafe { (self.symbol_arguments)(sym, &mut args_ptr, &mut size) };
        if !ok || size as u32 != arity {
            return false;
        }
        let mut name_ptr: *const c_char = ptr::null();
        let ok = unsafe { (self.symbol_name)(sym, &mut name_ptr) };
        if !ok || name_ptr.is_null() {
            return false;
        }
        let sym_name = unsafe { CStr::from_ptr(name_ptr) };
        sym_name.to_bytes() == name.as_bytes()
    }

    pub fn symbol_number(&self, sym: ClingoSymbol) -> Result<i32, ClingoError> {
        let mut out: i32 = 0;
        let ok = unsafe { (self.symbol_number)(sym, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn symbol_arguments(&self, sym: ClingoSymbol) -> Result<Vec<ClingoSymbol>, ClingoError> {
        let mut args_ptr: *const ClingoSymbol = ptr::null();
        let mut size: usize = 0;
        let ok = unsafe { (self.symbol_arguments)(sym, &mut args_ptr, &mut size) };
        if !ok {
            return Err(self.err());
        }
        let slice = unsafe { std::slice::from_raw_parts(args_ptr, size) };
        Ok(slice.to_vec())
    }

    pub fn symbol_to_string(&self, sym: ClingoSymbol) -> Result<String, ClingoError> {
        let mut size: usize = 0;
        let ok = unsafe { (self.symbol_to_string_size)(sym, &mut size) };
        if !ok {
            return Err(self.err());
        }
        let mut buf = vec![0i8; size];
        let ok = unsafe { (self.symbol_to_string)(sym, buf.as_mut_ptr(), size) };
        if !ok {
            return Err(self.err());
        }
        Ok(unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned())
    }

    // ── theory atoms inspection ─────────────────────────────────────────────
    pub fn theory_atoms_size(&self, atoms: *const ClingoTheoryAtoms) -> usize {
        let mut out: usize = 0;
        let _ = unsafe { (self.theory_atoms_size)(atoms, &mut out) };
        out
    }

    pub fn theory_atom_term(&self, atoms: *const ClingoTheoryAtoms, atom: ClingoId) -> ClingoId {
        let mut out: ClingoId = 0;
        let _ = unsafe { (self.theory_atoms_atom_term)(atoms, atom, &mut out) };
        out
    }

    pub fn theory_atom_literal(
        &self,
        atoms: *const ClingoTheoryAtoms,
        atom: ClingoId,
    ) -> Result<ClingoLiteral, ClingoError> {
        let mut out: ClingoLiteral = 0;
        let ok = unsafe { (self.theory_atoms_atom_literal)(atoms, atom, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn theory_term_type(
        &self,
        atoms: *const ClingoTheoryAtoms,
        term: ClingoId,
    ) -> Result<ClingoTheoryTermType, ClingoError> {
        let mut out: ClingoTheoryTermType = 0;
        let ok = unsafe { (self.theory_atoms_term_type)(atoms, term, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn theory_term_number(&self, atoms: *const ClingoTheoryAtoms, term: ClingoId) -> Result<i32, ClingoError> {
        let mut out: i32 = 0;
        let ok = unsafe { (self.theory_atoms_term_number)(atoms, term, &mut out) };
        if ok {
            Ok(out)
        } else {
            Err(self.err())
        }
    }

    pub fn theory_term_name(
        &self,
        atoms: *const ClingoTheoryAtoms,
        term: ClingoId,
    ) -> Result<String, ClingoError> {
        let mut ptr_out: *const c_char = ptr::null();
        let ok = unsafe { (self.theory_atoms_term_name)(atoms, term, &mut ptr_out) };
        if !ok {
            return Err(self.err());
        }
        Ok(unsafe { CStr::from_ptr(ptr_out) }.to_string_lossy().into_owned())
    }

    pub fn theory_term_arguments(
        &self,
        atoms: *const ClingoTheoryAtoms,
        term: ClingoId,
    ) -> Result<Vec<ClingoId>, ClingoError> {
        let mut args_ptr: *const ClingoId = ptr::null();
        let mut size: usize = 0;
        let ok = unsafe { (self.theory_atoms_term_arguments)(atoms, term, &mut args_ptr, &mut size) };
        if !ok {
            return Err(self.err());
        }
        let slice = unsafe { std::slice::from_raw_parts(args_ptr, size) };
        Ok(slice.to_vec())
    }

    pub fn theory_term_to_string(
        &self,
        atoms: *const ClingoTheoryAtoms,
        term: ClingoId,
    ) -> Result<String, ClingoError> {
        let mut size: usize = 0;
        let ok = unsafe { (self.theory_atoms_term_to_string_size)(atoms, term, &mut size) };
        if !ok {
            return Err(self.err());
        }
        let mut buf = vec![0i8; size];
        let ok = unsafe { (self.theory_atoms_term_to_string)(atoms, term, buf.as_mut_ptr(), size) };
        if !ok {
            return Err(self.err());
        }
        Ok(unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned())
    }
}

pub fn set_runtime_error(ffi: &Ffi, msg: &str) {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("rust propagator error").unwrap());
    unsafe { (ffi.set_error)(ERROR_RUNTIME, c.as_ptr()) };
}