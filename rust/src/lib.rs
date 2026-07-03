//! `ooanalyzer_sameclass` — native Rust port of the `&sameClass` clingo theory
//! propagator (`propagator/sameclass.py`). PyO3/maturin cdylib that registers its
//! own `extern "C"` clingo propagator/observer trampolines against the
//! Python-loaded libclingo (resolved via `dlsym`), so the hot solve path runs
//! entirely in Rust with no GIL/Python crossing.
//!
//! The GIL is held only at `register()` (one-time, before solving) and
//! `partition()` (post-solve). During `init`/`propagate`/`undo`/`check` the
//! trampolines receive raw C pointers and run pure Rust.

use pyo3::prelude::*;
use pyo3::types::{PyDict, PySet};
use std::ffi::c_void;

use crate::entkey::EntKey;
use crate::ffi::ClingoControl;
use crate::shared::PropData;
use crate::uf::Uf;

mod entkey;
mod ffi;
mod potential_uf;
mod propagator;
mod shared;
mod threadstate;
mod trampoline;
mod uf;

/// Native `SameClassPropagator`. Constructed from Python, then `register(ctl)`
/// wires the Rust trampolines into libclingo. `data` holds the raw
/// `Box<PropData>` pointer (as `usize` so the pyclass stays `Send`); reclaimed
/// in `Drop` once the Python object is released.
#[pyclass(name = "SameClassPropagator")]
pub struct SameClassPropagator {
    data: usize,
}

impl SameClassPropagator {
    fn propdata(&self) -> PyResult<&'static PropData> {
        if self.data == 0 {
            return Err(pyo3::exceptions::PyRuntimeError::new_err(
                "SameClassPropagator not registered",
            ));
        }
        // Safe: the pointer is a live Box<PropData> kept alive by self (Drop).
        Ok(unsafe { &*(self.data as *const PropData) })
    }
}

#[pymethods]
impl SameClassPropagator {
    /// `foundedness_check`/`dump_lemmas`/`decide_outputs`/`decide_inputs` are
    /// re-passed to `register()`; kept in the constructor purely for API parity.
    #[new]
    #[pyo3(signature = (foundedness_check=false, dump_lemmas=false, decide_outputs=false, decide_inputs=false))]
    fn new(
        foundedness_check: bool,
        dump_lemmas: bool,
        decide_outputs: bool,
        decide_inputs: bool,
    ) -> Self {
        let _ = (
            foundedness_check,
            dump_lemmas,
            decide_outputs,
            decide_inputs,
        );
        SameClassPropagator { data: 0 }
    }

    /// Extract the `clingo_control_t*` from the cffi `Control._rep` cdata and
    /// register the Rust propagator + observer against libclingo. Replaces
    /// `ctl.register_observer(prop); ctl.register_propagator(prop)`.
    #[pyo3(name = "register", signature = (ctl, foundedness_check=false, dump_lemmas=false, decide_outputs=false, decide_inputs=false))]
    fn register(
        &mut self,
        ctl: &Bound<'_, PyAny>,
        foundedness_check: bool,
        dump_lemmas: bool,
        decide_outputs: bool,
        decide_inputs: bool,
    ) -> PyResult<()> {
        let ffi = ffi::Ffi::load().map_err(pyo3_err)?;
        let py = ctl.py();
        let internal = py.import("clingo._internal")?;
        let cffi = internal.getattr("_ffi")?;
        let rep = ctl.getattr("_rep")?;
        let cdata = cffi.getattr("cast")?.call1(("uintptr_t", rep.unbind()))?;
        let addr = py
            .import("builtins")?
            .getattr("int")?
            .call1((cdata.unbind(),))?
            .extract::<i64>()?;
        let control = addr as usize as *mut ClingoControl;

        let raw = Box::into_raw(PropData::new(
            foundedness_check,
            dump_lemmas,
            decide_outputs,
            decide_inputs,
        )) as *mut c_void;
        self.data = raw as usize;

        let prop = trampoline::propagator_struct(decide_outputs, decide_inputs);
        let obs = trampoline::observer_struct();
        ffi.register_propagator(control, &prop, raw)
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.message))?;
        ffi.register_observer(control, &obs, raw)
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.message))?;
        Ok(())
    }

    /// Post-solve partition. With `merge_pairs`, builds a fresh UF over the
    /// `mergeClasses` atom pairs and groups all known entities. With `None`,
    /// reads thread 0's live UF (for legacy callers). Returns a Python dict
    /// mapping a representative key to a set of member keys.
    #[pyo3(name = "partition", signature = (merge_pairs=None))]
    fn partition(
        &self,
        py: Python<'_>,
        merge_pairs: Option<Vec<(Py<PyAny>, Py<PyAny>)>>,
    ) -> PyResult<PyObject> {
        // FFI must be loaded (register ran first).
        let _ = ffi::Ffi::get();
        let pd = self.propdata()?;
        let shared = pd.shared.get().ok_or_else(|| {
            pyo3::exceptions::PyRuntimeError::new_err("propagator not initialized")
        })?;
        let entities = &shared.entities;

        let groups = if let Some(pairs) = merge_pairs {
            let mut uf = Uf::new();
            for (a, b) in pairs {
                let ka = py_sym_key(a.bind(py))?;
                let kb = py_sym_key(b.bind(py))?;
                uf.union(&ka, &kb, 0, None, None);
            }
            uf.groups(entities)
        } else {
            let mut state = shared
                .states
                .get(0)
                .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err("no thread state"))?
                .lock()
                .map_err(|_| pyo3::exceptions::PyRuntimeError::new_err("thread state poisoned"))?;
            state.uf.groups(entities)
        };

        let dict = PyDict::new(py);
        for (rep, members) in groups {
            let py_set = PySet::empty(py)?;
            for m in members {
                py_set.add(ent_to_py(py, &m)?)?;
            }
            dict.set_item(ent_to_py(py, &rep)?, py_set)?;
        }
        Ok(dict.unbind().into_any())
    }
}

impl Drop for SameClassPropagator {
    fn drop(&mut self) {
        if self.data != 0 {
            // Safe: the pointer is a Box<PropData> we allocated in register().
            unsafe {
                drop(Box::from_raw(self.data as *mut PropData));
            }
        }
    }
}

fn pyo3_err(msg: String) -> PyErr {
    pyo3::exceptions::PyRuntimeError::new_err(msg)
}

/// Replicate Python `_sym_key`: a Number symbol → its integer value, anything
/// else → `str(symbol)`. Accessing `.number` on a non-Number clingo Symbol
/// raises, so we fall back to `str()`.
fn py_sym_key(sym: &Bound<'_, PyAny>) -> PyResult<EntKey> {
    match sym.getattr("number") {
        Ok(n) => match n.extract::<i64>() {
            Ok(v) => Ok(EntKey::Num(v)),
            Err(_) => Ok(EntKey::Str(sym.str()?.to_string_lossy().into_owned())),
        },
        Err(_) => Ok(EntKey::Str(sym.str()?.to_string_lossy().into_owned())),
    }
}

#[allow(deprecated)]
fn ent_to_py(py: Python<'_>, e: &EntKey) -> PyResult<PyObject> {
    match e {
        EntKey::Num(n) => Ok(n.into_py(py)),
        EntKey::Str(s) => Ok(s.clone().into_py(py)),
    }
}

#[pymodule]
fn ooanalyzer_sameclass(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<SameClassPropagator>()?;
    // clingo is imported before this module in the driver, so the dlsym probes
    // usually succeed here. If not (clingo not yet loaded), register() retries.
    let _ = ffi::Ffi::load();
    Ok(())
}
