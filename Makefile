# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the propagator solver.

PYTHON       := python3
PROPAGATOR   := $(PYTHON) ooanalyzer.py
PROP_FLAGS   := -n -1 --opt-strategy bb,lin --heuristic vsids --sign-def=neg --time-limit=300 -t2 --stats
XCLINGO      := xclingo
XCLINGO_FLAGS := -n -1 0 --opt-strategy bb,lin --heuristic=vsids
TIME_CMD     := /usr/bin/time

OOA_DIR      := examples/ooa

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

# ----------------------------------------------------------------
# Default: convert all .facts and run ooanalyzer.py
# ----------------------------------------------------------------
.PHONY: all convert run verify verify-core verify-real propagator-run \
        explain-all symbolize clean help single

all: symbolize

# When 'clean' is explicitly requested alongside a build target, force
# sequencing so clean finishes before any build work starts.
ifneq ($(filter clean,$(MAKECMDGOALS)),)
convert run symbolize: clean
endif

help:
	@echo "Targets:"
	@echo "  make convert       — convert all .facts to .lp"
	@echo "  make run           — convert and run ooanalyzer.py on all .lp files"
	@echo "  make explain-all   — convert and explain optimal models via xclingo"
	@echo "  make symbolize     — symbolize all .out → .sym"
	@echo "  make verify        — run marker checks for core fixtures"
	@echo "  make propagator-run — alias for run"
	@echo "  make clean         — remove generated .lp/.out/.sym files"
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
	echo "=== Verifying examples/example.lp ==="; \
	run_case 'OPTIMUM FOUND' '' '' '' $(PROPAGATOR) examples/example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/invalid_example.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(PROPAGATOR) examples/invalid_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/strong_negation_contradiction.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(PROPAGATOR) examples/strong_negation_contradiction.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/constructor_vftable_entry_example.lp ==="; \
	run_case 'SATISFIABLE' '-vfTableEntry(2000,0,1000)' '' '' $(PROPAGATOR) examples/constructor_vftable_entry_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/symbol_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '' $(PROPAGATOR) examples/symbol_conflict_example.lp $(PROP_FLAGS); \
	echo "=== Verifying examples/symbol_missing_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '-mergeClasses\\(3000,4000\\)' $(PROPAGATOR) examples/symbol_missing_conflict_example.lp $(PROP_FLAGS)

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

symbolize: $(SYM_FILES) $(RESULTS_SYM_FILES)

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.out scripts/symbolize.py
	@echo "=== Symbolizing $* ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.ground $(OOA_DIR)/%.out scripts/symbolize.py
	@echo "=== Symbolizing $* (ground) ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.results.sym: $(OOA_DIR)/%.out $(OOA_DIR)/%.symbols scripts/symbolize.py
	@echo "=== Symbolizing $*.results ==="
	$(SYMBOLIZE) $(word 2,$^) $(@:.results.sym=.results) -o $@

$(OOA_DIR)/%.results.sym: $(OOA_DIR)/%.out $(OOA_DIR)/%.ground scripts/symbolize.py
	@echo "=== Symbolizing $*.results (ground) ==="
	$(SYMBOLIZE) $(word 2,$^) $(@:.results.sym=.results) -o $@

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
	find $(OOA_DIR) -name '*.time' -delete
	find $(OOA_DIR) -name '*.err' -delete
	find $(OOA_DIR) -name '*.explain.out' -delete
	find $(OOA_DIR) -name '*.sym' -delete
