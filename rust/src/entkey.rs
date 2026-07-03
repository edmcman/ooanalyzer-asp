//! Entity key: the normalized identity of a `mergeClasses`/`sameClass` endpoint.
//!
//! Mirrors `sameclass.py:_sym_key` / `_theory_key` — a clingo `Symbol`/theory term
//! is reduced to either its integer value (for Number symbols/terms) or its
//! string representation. `clingo.Symbol` objects live only at the FFI edge; all
//! long-lived propagator state keys on `EntKey`.
//!
//! The derived `Ord` matches `_okey(k) = (0, k) if int else (1, str(k))`: `Num`
//! sorts before `Str`, numeric within `Num`, lexicographic within `Str`. This
//! total order is load-bearing — it makes clause-emission order, and thus the
//! solver's search trajectory, deterministic (see `sameclass.py:66-72`).

use crate::ffi::{
    ClingoId, ClingoSymbol, ClingoTheoryAtoms, Ffi, SYMBOL_TYPE_NUMBER, THEORY_TERM_TYPE_NUMBER,
};
use std::hash::{Hash, Hasher};

#[derive(Clone, Debug)]
pub enum EntKey {
    Num(i64),
    Str(String),
}

impl EntKey {
    pub fn from_symbol(ffi: &Ffi, sym: ClingoSymbol) -> EntKey {
        if ffi.symbol_type(sym) == SYMBOL_TYPE_NUMBER {
            // symbol_number only succeeds for Number symbols.
            match ffi.symbol_number(sym) {
                Ok(n) => EntKey::Num(n as i64),
                // Defensive: type said Number but number() failed — fall back to string.
                Err(_) => EntKey::Str(ffi.symbol_to_string(sym).unwrap_or_default()),
            }
        } else {
            EntKey::Str(ffi.symbol_to_string(sym).unwrap_or_default())
        }
    }

    pub fn from_theory_term(ffi: &Ffi, atoms: *const ClingoTheoryAtoms, term: ClingoId) -> EntKey {
        match ffi.theory_term_type(atoms, term) {
            Ok(t) if t == THEORY_TERM_TYPE_NUMBER => match ffi.theory_term_number(atoms, term) {
                Ok(n) => EntKey::Num(n as i64),
                Err(_) => EntKey::Str(ffi.theory_term_to_string(atoms, term).unwrap_or_default()),
            },
            _ => EntKey::Str(ffi.theory_term_to_string(atoms, term).unwrap_or_default()),
        }
    }
}

impl PartialEq for EntKey {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (EntKey::Num(a), EntKey::Num(b)) => a == b,
            (EntKey::Str(a), EntKey::Str(b)) => a == b,
            _ => false,
        }
    }
}
impl Eq for EntKey {}

impl Hash for EntKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        match self {
            EntKey::Num(n) => {
                0u8.hash(state);
                n.hash(state);
            }
            EntKey::Str(s) => {
                1u8.hash(state);
                s.hash(state);
            }
        }
    }
}

impl PartialOrd for EntKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for EntKey {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            (EntKey::Num(a), EntKey::Num(b)) => a.cmp(b),
            (EntKey::Num(_), EntKey::Str(_)) => std::cmp::Ordering::Less,
            (EntKey::Str(_), EntKey::Num(_)) => std::cmp::Ordering::Greater,
            (EntKey::Str(a), EntKey::Str(b)) => a.cmp(b),
        }
    }
}
