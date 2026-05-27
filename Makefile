# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the solver.

PYTHON       := python3
TIME         := time
CLINGO       := clingo
CLINGO_FLAGS := ooanalyzer.lp --quiet=1,2 --time-limit=300 --opt-strategy bb,inc --heuristic=domain
DUALGROUNDER := $(PYTHON) DualGrounder/dualgrounder.py
DG_FLAGS     := -v --max-time 300
XCLINGO      := xclingo -n -1 0
XCLINGO_FLAGS := --opt-strategy=bb,inc --heuristic=domain

OOA_DIR      := examples/ooa
# Recursively find all .facts files in the test subdirectories
FACTS        := $(shell find $(OOA_DIR) -name '*.facts')
LP_FILES     := $(FACTS:%.facts=%.lp)

# ----------------------------------------------------------------
# Default: convert all .facts and run clingo
# ----------------------------------------------------------------
.PHONY: all convert run verify verify-core verify-real lazyrun explain-all symbolize clean help

all: run

help:
	@echo "Targets:"
	@echo "  make convert    — convert all $(OOA_DIR)/*/*/*.facts to .lp"
	@echo "  make run        — convert and run clingo on all .lp files"
	@echo "  make verify     — run marker checks for core fixtures"
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
# Run clingo on generated .lp files
# ----------------------------------------------------------------
OUT_FILES := $(LP_FILES:%.lp=%.out)

define CLINGO_RUN
	rc=0; $(TIME) $(CLINGO) $(CLINGO_FLAGS) $(1) >"$(2)" 2>&1 || rc=$$?; \
	case "$$rc" in 0|10|20|30) ;; *) echo "warning: $(1) exited $$rc" >>"$(2)" ;; esac
endef

run: $(OUT_FILES)

$(OOA_DIR)/%.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/*.lp)
	@echo "=== Running: $(CLINGO) $(CLINGO_FLAGS) $< ==="
	$(call CLINGO_RUN,$<,$@)
	@tail -6 $@

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
	run_case 'OPTIMUM FOUND' '' '' '' $(CLINGO) $(CLINGO_FLAGS) examples/example.lp; \
	echo "=== Verifying examples/invalid_example.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(CLINGO) $(CLINGO_FLAGS) examples/invalid_example.lp; \
	echo "=== Verifying examples/strong_negation_contradiction.lp ==="; \
	run_case 'UNSATISFIABLE' '' '' '' $(CLINGO) $(CLINGO_FLAGS) examples/strong_negation_contradiction.lp; \
	echo "=== Verifying examples/constructor_vftable_entry_example.lp ==="; \
	run_case 'SATISFIABLE' '-vfTableEntry(2000,0,1000)' '' '' $(CLINGO) $(CLINGO_FLAGS) examples/constructor_vftable_entry_example.lp; \
	echo "=== Verifying examples/symbol_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '' $(CLINGO) $(CLINGO_FLAGS) examples/symbol_conflict_example.lp; \
	echo "=== Verifying examples/symbol_missing_conflict_example.lp ==="; \
	run_case 'SATISFIABLE' '-mergeClasses(1000,2000)' '' '-mergeClasses\\(3000,4000\\)' $(CLINGO) $(CLINGO_FLAGS) examples/symbol_missing_conflict_example.lp; \
	echo "=== Verifying diagnostic contradiction fixture ==="; \
	run_case 'SATISFIABLE' 'violate(insanityTwoRealDestructorsOnClass' '' '' $(CLINGO) --const diagnose=1 ooanalyzer.lp examples/strong_negation_contradiction.lp --quiet=1,2

# ----------------------------------------------------------------
# Run dualgrounder on generated .lp files
# ----------------------------------------------------------------
LAZY_OUT_FILES := $(LP_FILES:%.lp=%.lazy.out)

lazyrun: $(LAZY_OUT_FILES)

$(OOA_DIR)/%.lazy.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/*.lp)
	@echo "=== Running: $(DUALGROUNDER) $(DG_FLAGS) ooanalyzer.lp $< ==="
	$(TIME) $(DUALGROUNDER) $(DG_FLAGS) ooanalyzer.lp $< > $@ 2>&1 || true
	@tail -6 $@

# ----------------------------------------------------------------
# Explain: run xclingo on optimal model only
# ----------------------------------------------------------------
EXPLAIN_OUT_FILES := $(LP_FILES:%.lp=%.explain.out)

explain-all: $(EXPLAIN_OUT_FILES)

$(OOA_DIR)/%.explain.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/modules/*.lp)
	@echo "=== Explaining: $(XCLINGO) ooanalyzer.lp $< ==="
	$(TIME) $(XCLINGO) $(XCLINGO_FLAGS) ooanalyzer.lp $< > $@ 2>/dev/null || true
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

$(OOA_DIR)/%.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.out
	@echo "=== Symbolizing $* ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

$(OOA_DIR)/%.lazy.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.lazy.out
	@echo "=== Symbolizing $* (lazy) ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

# ----------------------------------------------------------------
# Clean generated files
# ----------------------------------------------------------------
clean:
	find $(OOA_DIR) -name '*.lp' -delete
	find $(OOA_DIR) -name '*.out' -delete
	find $(OOA_DIR) -name '*.explain.out' -delete
	find $(OOA_DIR) -name '*.sym' -delete
	find $(OOA_DIR) -name '*.lazy.sym' -delete
	find $(OOA_DIR) -name '*.lazy.out' -delete
