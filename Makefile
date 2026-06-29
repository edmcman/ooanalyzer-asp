# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the propagator solver.

PYTHON       := python3
PROPAGATOR   := $(PYTHON) ooanalyzer.py
# Champion solver config for TinyXml-class merge-reward optimization (see
# .state/merge-optimization-blocker.md and autoresearch/classic-260625-0952/).
# --configuration=crafty + a --restarts=F,<N> settling point is the only combination
# that settles comp1 (vftable MaxSize+gap); F736 is the comp2 peak among settlers
# [-704,-42666], strategy-invariant across opt-cores/heuristics. Single-threaded
# (threads break comp1). opt-strategy/heuristic left at ooanalyzer.py defaults
# (bb,lin / vsids) — strategy-invariant at F736.
# Previous (pre-champion) experiment config kept commented for reference:
#PROP_FLAGS   := -n -1 --opt-strategy bb,lin --heuristic=domain --sign-def=neg --time-limit=300 -t2 --stats --show-guesses
#PROP_FLAGS   := -n -1 --heuristic=domain --opt-strategy=usc,oll,disjoint,succinct,stratify --restart-on-model --time-limit=300 --stats --show-guesses
PROP_FLAGS   := -n -1 --configuration=crafty --restarts=F,736 --time-limit=300 --stats --show-guesses
XCLINGO      := xclingo
XCLINGO_FLAGS := -n -1 0 --opt-strategy bb,lin --heuristic=domain
TIME_CMD     := /usr/bin/time

OOA_DIR      := examples/ooa
OOANALYZER_TESTS ?= $(HOME)/ooanalyzer-tests

# Source discovery — all derived from FACTS so the full DAG is known at parse time
FACTS        := $(shell find $(OOA_DIR) -name '*.facts')
SRC_LP       := $(shell find src -name '*.lp' -not -path '*/old/*')

# Derived file lists
LP_FILES              := $(FACTS:%.facts=%.lp)
OUT_FILES             := $(LP_FILES:%.lp=%.out)
RESULTS_FILES         := $(LP_FILES:%.lp=%.results)
EXPLAIN_OUT_FILES     := $(LP_FILES:%.lp=%.explain.out)
GROUND                := $(shell find $(OOA_DIR) -name '*.ground')
# Only symbolize .lp files that have a .symbols or .ground file alongside them
SYMBOLIZABLE_LP       := $(foreach lp,$(LP_FILES),\
  $(if $(or $(wildcard $(lp:.lp=.symbols)),$(wildcard $(lp:.lp=.ground))),$(lp)))
SYM_FILES             := $(SYMBOLIZABLE_LP:%.lp=%.sym) $(GROUND:%.ground=%.sym)
RESULTS_SYM_FILES     := $(SYMBOLIZABLE_LP:%.lp=%.results.sym)
# Reference results shipped by OOAnalyzer; symbolize only those with .symbols/.ground
RESULTS_ORIG          := $(shell find $(OOA_DIR) -name '*.results.orig')
RESULTS_ORIG_SYM_FILES := $(foreach r,$(RESULTS_ORIG),\
  $(if $(or $(wildcard $(r:.results.orig=.symbols)),$(wildcard $(r:.results.orig=.ground))),$(r:.results.orig=.results.orig.sym)))

# ----------------------------------------------------------------
# Default: convert all .facts and run ooanalyzer.py
# ----------------------------------------------------------------
.PHONY: all convert run verify verify-core verify-real propagator-run \
        explain-all symbolize diff edit-distance clean help single rust rust-check bindings

all: symbolize

# When 'clean' is explicitly requested alongside a build target, force
# sequencing so clean finishes before any build work starts.
ifneq ($(filter clean,$(MAKECMDGOALS)),)
convert run symbolize: clean
endif

rust:
	uvx maturin develop --release --manifest-path rust/Cargo.toml

# Regenerate rust/src/ffi/clingo_sys.rs from rust/vendor/clingo.h (bindgen,
# types/constants only). Bump rust/vendor/clingo.h when targeting a new clingo.
bindings:
	cd rust && cargo run --example gen_bindings

rust-check:
	cd rust && cargo test

help:
	@echo "Targets:"
	@echo "  make convert       — convert all .facts to .lp"
	@echo "  make run           — convert and run ooanalyzer.py on all .lp files"
	@echo "  make explain-all   — convert and explain optimal models via xclingo"
	@echo "  make symbolize     — symbolize all .out → .sym"
	@echo "  make verify        — run marker checks for core fixtures"
	@echo "  make propagator-run — alias for run"
	@echo "  make diff          — diff .results.sym vs .results.orig.sym for all available pairs"
	@echo "  make edit-distance — compare local .results with OOANALYZER_TESTS ($(OOANALYZER_TESTS))"
	@echo "  make clean         — remove generated .lp/.out/.sym files"
	@echo "  make rust          — build the Rust &sameClass propagator (maturin develop)"
	@echo "  make bindings      — regenerate rust/src/ffi/clingo_sys.rs from rust/vendor/clingo.h"
	@echo ""
	@echo "Single-file pipeline:"
	@echo "  make single STEM=ooex_vs2010/Debug/ooex0"
	@echo "  make $(OOA_DIR)/ooex_vs2008/Debug/oo.sym"

# ----------------------------------------------------------------
# Conversion: .facts → .lp
# ----------------------------------------------------------------
convert: $(LP_FILES)

$(OOA_DIR)/%.lp: $(OOA_DIR)/%.facts scripts/facts2clingo.py
	@echo "=== Converting $< → $@ ==="
	@mkdir -p $(dir $@)
	$(PYTHON) scripts/facts2clingo.py $< > $@

# ----------------------------------------------------------------
# Run ooanalyzer.py on generated .lp files
# ----------------------------------------------------------------
run: $(OUT_FILES)

$(OOA_DIR)/%.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(SRC_LP)
	@echo "=== Running: $(PROPAGATOR) $< $(PROP_FLAGS) ==="
	@rc=0; $(TIME_CMD) -o $(@:.out=.time) $(PROPAGATOR) $< $(PROP_FLAGS) --results $(@:.out=.results) >$@ 2>&1 || rc=$$?; \
	case "$$rc" in 0|10|20|30) ;; *) echo "error: $< exited $$rc" >>$@; exit $$rc ;; esac

verify: verify-core

verify-core:
	@set -eu; \
	run_case() { \
		expected="$${1}"; positive1="$${2}"; positive2="$${3}"; forbidden="$${4}"; shift 4; \
		out="$$(mktemp)"; \
		rc=0; \
		$(TIME_CMD) "$${@}" >"$$out" 2>&1 || rc=$$?; \
		case "$$rc" in 0|10|20|30) ;; *) cat "$$out"; rm -f "$$out"; exit "$$rc" ;; esac; \
		grep -qF -- "$$expected" "$$out"; \
		[ -z "$$positive1" ] || grep -qF -- "$$positive1" "$$out"; \
		[ -z "$$positive2" ] || grep -qF -- "$$positive2" "$$out"; \
		if [ -n "$$forbidden" ] && grep -Eq -- "$$forbidden" "$$out"; then cat "$$out"; rm -f "$$out"; exit 1; fi; \
		rm -f "$$out"; \
	}; \
	echo "=== Verifying examples/manual/example.lp ==="; \
	run_case 'OPTIMUM FOUND' '' '' '' $(PROPAGATOR) examples/manual/example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/manual/invalid_example.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(PROPAGATOR) examples/manual/invalid_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/manual/strong_negation_contradiction.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(PROPAGATOR) examples/manual/strong_negation_contradiction.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/manual/constructor_vftable_entry_example.lp ==="; \
	run_case 'SATISFIABLE' '-vfTableEntry(2000,0,1000)' '' '' $(PROPAGATOR) examples/manual/constructor_vftable_entry_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/manual/symbol_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '' $(PROPAGATOR) examples/manual/symbol_conflict_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/manual/symbol_missing_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '-mergeClasses\\(3000,4000\\)' $(PROPAGATOR) examples/manual/symbol_missing_conflict_example.lp $(PROP_FLAGS)

propagator-run: run

# ----------------------------------------------------------------
# Explain: run xclingo on optimal model only
# ----------------------------------------------------------------
explain-all: $(EXPLAIN_OUT_FILES)

$(OOA_DIR)/%.explain.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(SRC_LP)
	@echo "=== Explaining: $(XCLINGO) ooanalyzer.lp $< ==="
	$(TIME_CMD) $(XCLINGO) ooanalyzer.lp $< $(XCLINGO_FLAGS) > $@ 2> $@.err || true

# ----------------------------------------------------------------
# Symbolize: .out + .symbols → .sym (human-readable)
# Filter to key predicates; override with FILTER= for custom grep.
# ----------------------------------------------------------------
SYMBOLIZE    := $(PYTHON) scripts/symbolize.py
SYM_FILTER   ?= classRep\|constructor\|derivedClass\|embeddedObject\|classHasNoBase

symbolize: $(SYM_FILES) $(RESULTS_SYM_FILES) $(RESULTS_ORIG_SYM_FILES)

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.out scripts/symbolize.py
	@echo "=== Symbolizing $* ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.ground $(OOA_DIR)/%.out scripts/symbolize.py
	@echo "=== Symbolizing $* (ground) ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.results.sym: $(OOA_DIR)/%.out $(OOA_DIR)/%.symbols scripts/symbolize.py
	@echo "=== Symbolizing $*.results ==="
	$(SYMBOLIZE) $(word 2,$^) $(@:.results.sym=.results) | sort -o $@

$(OOA_DIR)/%.results.sym: $(OOA_DIR)/%.out $(OOA_DIR)/%.ground scripts/symbolize.py
	@echo "=== Symbolizing $*.results (ground) ==="
	$(SYMBOLIZE) $(word 2,$^) $(@:.results.sym=.results) | sort -o $@

# Symbolize OOAnalyzer's shipped reference results (.results.orig → .results.orig.sym)
$(OOA_DIR)/%.results.orig.sym: $(OOA_DIR)/%.results.orig $(OOA_DIR)/%.symbols scripts/symbolize.py
	@echo "=== Symbolizing $*.results.orig ==="
	$(SYMBOLIZE) $(word 2,$^) $< | sort -o $@

$(OOA_DIR)/%.results.orig.sym: $(OOA_DIR)/%.results.orig $(OOA_DIR)/%.ground scripts/symbolize.py
	@echo "=== Symbolizing $*.results.orig (ground) ==="
	$(SYMBOLIZE) $(word 2,$^) $< | sort -o $@

# ----------------------------------------------------------------
# Diff: .results.orig.sym vs .results.sym → .diff
# Only built for stems that have a .results.orig file.
# ----------------------------------------------------------------
DIFF_FILES := $(foreach lp,$(SYMBOLIZABLE_LP),\
  $(if $(wildcard $(lp:.lp=.results.orig)),$(lp:.lp=.results.sym.diff)))

diff: $(DIFF_FILES)

$(OOA_DIR)/%.results.sym.diff: $(OOA_DIR)/%.results.orig.sym $(OOA_DIR)/%.results.sym
	diff $^ > $@ || true

# ----------------------------------------------------------------
# Edit distance: local .results against ground truth in ooanalyzer-tests
# ----------------------------------------------------------------
edit-distance:
	@$(PYTHON) scripts/edit_distance.py \
		--tests-root "$(OOANALYZER_TESTS)" \
		--results-root "$(OOA_DIR)"

# ----------------------------------------------------------------
# Convenience: single-file pipeline
# Usage: make single STEM=ooex_vs2010/Debug/ooex0
# ----------------------------------------------------------------
single: $(OOA_DIR)/$(STEM).sym

# ----------------------------------------------------------------
# Clean generated files
# ----------------------------------------------------------------
clean:
	find $(OOA_DIR) -name '*.lp' -delete
	find $(OOA_DIR) -name '*.out' -delete
	find $(OOA_DIR) -name '*.results' -delete
	find $(OOA_DIR) -name '*.results.sym' -delete
	find $(OOA_DIR) -name '*.results.orig.sym' -delete
	find $(OOA_DIR) -name '*.results.sym.diff' -delete
	find $(OOA_DIR) -name '*.time' -delete
	find $(OOA_DIR) -name '*.err' -delete
	find $(OOA_DIR) -name '*.explain.out' -delete
	find $(OOA_DIR) -name '*.sym' -delete
