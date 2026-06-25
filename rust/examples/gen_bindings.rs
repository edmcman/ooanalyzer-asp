//! Regenerate `src/clingo_sys.rs` from `vendor/clingo.h`.
//!
//! Run from the `rust/` crate root:
//!     cargo run --example gen_bindings
//! Override the header with `CLINGO_INCLUDE_DIR=/path/to/dir` (containing
//! clingo.h) and the output with `CLINGO_BINDINGS_OUT=/path/to/clingo_sys.rs`.
//!
//! Types/constants only — no `extern "C"` function block. We never link
//! libclingo at build time; `ffi.rs` dlsym-resolves every function at runtime
//! against the Python-loaded libclingo. Allowlist mode (types + vars, no
//! functions) is what suppresses the function declarations.

use bindgen::Builder;
use std::path::PathBuf;

fn main() {
    let header: PathBuf = std::env::var("CLINGO_INCLUDE_DIR")
        .map(PathBuf::from)
        .map(|d| d.join("clingo.h"))
        .unwrap_or_else(|_| PathBuf::from("vendor/clingo.h"));

    let out: PathBuf = std::env::var("CLINGO_BINDINGS_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("src/ffi/clingo_sys.rs"));

    eprintln!("bindgen: {header:?} -> {out:?}");

    let bindings = Builder::default()
        .header(header.to_str().expect("non-utf8 header path"))
        // Suppress the bindgen naming-lint noise (snake_case structs, etc.) so a
        // clean build stays clean. Prepended before the generated banner comment.
        .raw_line(
            "#![allow(dead_code, non_camel_case_types, non_snake_case, non_upper_case_globals)]",
        )
        // Types and constants only: allowlisting types+vars (but not functions)
        // puts bindgen in allowlist mode, which also drops the `extern "C"` fn
        // block — exactly what we want (we dlsym the functions at runtime).
        .allowlist_type("clingo_.*")
        .allowlist_var("clingo_.*")
        // Keep the generated file small and reviewable.
        .layout_tests(false)
        .size_t_is_usize(true)
        .generate_comments(false)
        .generate()
        .expect("bindgen failed to parse clingo.h");

    bindings
        .write_to_file(&out)
        .unwrap_or_else(|e| panic!("failed to write {out:?}: {e}"));
    eprintln!("wrote {}", out.display());
}