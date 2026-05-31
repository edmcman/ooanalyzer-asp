# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the propagator solver.

PYTHON       := python3
DUALGROUNDER := $(PYTHON) DualGrounder/dualgrounder.py
DG_FLAGS     := -v --max-time 300
PROPAGATOR   := $(PYTHON) ooanalyzer.py
PROP_FLAGS   := -n -1 --opt-strategy bb,inc --heuristic domain --time-limit=30
XCLINGO      := xclingo
XCLINGO_FLAGS := -n -1 0 --opt-strategy bb,inc --heuristic=domain

OOA_DIR      := examples/ooa
# Recursively find all .facts files in the test subdirectories
FACTS        := $(shell find $(OOA_DIR) -name '*.facts')
LP_FILES     := $(FACTS:%.facts=%.lp)

# ----------------------------------------------------------------
# Default: convert all .facts and run ooanalyzer.py
# ----------------------------------------------------------------
.PHONY: all convert run verify verify-core verify-real lazyrun propagator-run explain-all symbolize clean help

all: run

help:
	@echo "Targets:"
	@echo "  make convert    — convert all $(OOA_DIR)/*/*/*.facts to .lp"
	@echo "  make run        — convert and run ooanalyzer.py on all .lp files"
	@echo "  make verify     — run marker checks for core fixtures"
	@echo "  make propagator-run — alias for run"
	@echo "  make lazyrun    — convert and run dualgrounder on all .lp files"
	@echo "  make explain-all — convert and explain optimal models via xclingo"
	@echo "  make symbolize  — symbolize all .out files to .sym files"
	@echo "  make clean      — remove generated .lp/.out/.sym files"
	@echo "  make $(OOA_DIR)/ooex_vs2008/Debug/oo.lp  — convert a single .facts file"

# ----------------------------------------------------------------
# Conversion: .facts → .lp
# ----------------------------------------------------------------
convert: $(LP_FILES)

$(OOA_DIR)/%.lp: $(OOA_DIR)/%.facts facts2clingo.py
	@echo "=== Converting $< → $@ ==="
	@mkdir -p $(dir $@)
	$(PYTHON) facts2clingo.py $< > $@

# ----------------------------------------------------------------
# Run ooanalyzer.py on generated .lp files
# ----------------------------------------------------------------
OUT_FILES := $(LP_FILES:%.lp=%.out)

define PROPAGATOR_RUN
	rc=0; /usr/bin/time -o "$(3)" $(PROPAGATOR) $(1) $(PROP_FLAGS) >"$(2)" 2>&1 || rc=$$?; \
	case "$$rc" in 0|10|20|30) ;; *) echo "error: $(1) exited $$rc" >>"$(2)"; exit "$$rc" ;; esac
endef

run: $(OUT_FILES)

$(OOA_DIR)/%.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/**/*.lp)
	@echo "=== Running: $(PROPAGATOR) $< $(PROP_FLAGS) ==="
	$(call PROPAGATOR_RUN,$<,$@,$(@:.out=.time))
	@tail -20 $@

verify: verify-core

verify-core:
	@set -eu; \
	run_case() { \
		expected="$${1}"; positive1="$${2}"; positive2="$${3}"; forbidden="$${4}"; shift 4; \
		out="$$(mktemp)"; \
		rc=0; \
		$(TIME) "$${@}" >"$$out" 2>&1 || rc=$$?; \
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

# ----------------------------------------------------------------
# Run dualgrounder on generated .lp files
# ----------------------------------------------------------------
LAZY_OUT_FILES := $(LP_FILES:%.lp=%.lazy.out)

propagator-run: run

lazyrun: $(LAZY_OUT_FILES)

$(OOA_DIR)/%.lazy.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/*.lp)
	@echo "=== Running: $(DUALGROUNDER) $(DG_FLAGS) ooanalyzer.lp $< ==="
	$(TIME) $(DUALGROUNDER) $(DG_FLAGS) ooanalyzer.lp $< > $@ 2> $@.err || true
	@tail -6 $@

# ----------------------------------------------------------------
# Explain: run xclingo on optimal model only
# ----------------------------------------------------------------
EXPLAIN_OUT_FILES := $(LP_FILES:%.lp=%.explain.out)

explain-all: $(EXPLAIN_OUT_FILES)

$(OOA_DIR)/%.explain.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/modules/*.lp)
	@echo "=== Explaining: $(XCLINGO) ooanalyzer.lp $< ==="
	$(TIME) $(XCLINGO) ooanalyzer.lp $< $(XCLINGO_FLAGS) > $@ 2> $@.err || true
	@tail -6 $@

# ----------------------------------------------------------------
# Symbolize: .out + .symbols → .sym (human-readable)
# Filter to key predicates; override with FILTER= for custom grep.
# ----------------------------------------------------------------
SYMBOLIZE    := $(PYTHON) symbolize.py
SYM_FILTER   ?= classRep\|constructor\|derivedClass\|embeddedObject\|classHasNoBase

SYMBOLS_FILES := $(shell find $(OOA_DIR) -name '*.symbols')
# Only symbolize when a matching output file exists
SYM_FILES     := $(foreach sym,$(patsubst %.symbols,%.sym,$(SYMBOLS_FILES)),\
                   $(if $(wildcard $(sym:.sym=.out)),$(sym)))
LAZY_SYM_FILES := $(foreach sym,$(patsubst %.symbols,%.lazy.sym,$(SYMBOLS_FILES)),\
                    $(if $(wildcard $(sym:.lazy.sym=.lazy.out)),$(sym)))

symbolize: $(SYM_FILES) $(LAZY_SYM_FILES)

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.out symbolize.py
	@echo "=== Symbolizing $* ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.lazy.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.lazy.out symbolize.py
	@echo "=== Symbolizing $* (lazy) ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

# ----------------------------------------------------------------
# Clean generated files
# ----------------------------------------------------------------
clean:
	find $(OOA_DIR) -name '*.lp' -delete
	find $(OOA_DIR) -name '*.out' -delete
	find $(OOA_DIR) -name '*.time' -delete
	find $(OOA_DIR) -name '*.explain.out' -delete
	find $(OOA_DIR) -name '*.sym' -delete
	find $(OOA_DIR) -name '*.lazy.sym' -delete
	find $(OOA_DIR) -name '*.lazy.out' -delete
