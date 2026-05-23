# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the solver.

PYTHON       := python3
CLINGO       := clingo
CLINGO_FLAGS := ooanalyzer.lp --quiet=1,2 --time-limit=300

OOA_DIR      := examples/ooa
# Recursively find all .facts files in the test subdirectories
FACTS        := $(shell find $(OOA_DIR) -name '*.facts')
LP_FILES     := $(FACTS:%.facts=%.lp)

# ----------------------------------------------------------------
# Default: convert all .facts and run clingo
# ----------------------------------------------------------------
.PHONY: all convert run symbolize clean help

all: run

help:
	@echo "Targets:"
	@echo "  make convert    — convert all $(OOA_DIR)/*/*/*.facts to .lp"
	@echo "  make run        — convert and run clingo on all .lp files"
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

run: $(OUT_FILES)

$(OOA_DIR)/%.out: $(OOA_DIR)/%.lp ooanalyzer.lp $(wildcard src/*.lp)
	@echo "=== Running: $(CLINGO) $(CLINGO_FLAGS) $< ==="
	$(CLINGO) $(CLINGO_FLAGS) $< > $@ 2>&1 || true
	@tail -6 $@

# ----------------------------------------------------------------
# Symbolize: .out + .symbols → .sym (human-readable)
# Filter to key predicates; override with FILTER= for custom grep.
# ----------------------------------------------------------------
SYMBOLIZE    := $(PYTHON) symbolize.py
SYM_FILTER   ?= classRep\|factConstructor\|factDerivedClass\|factEmbeddedObject\|factClassHasNoBase

SYMBOLS_FILES := $(shell find $(OOA_DIR) -name '*.symbols')
# Only symbolize when a matching .out already exists
SYM_FILES     := $(foreach sym,$(patsubst %.symbols,%.sym,$(SYMBOLS_FILES)),\
                   $(if $(wildcard $(sym:.sym=.out)),$(sym)))

symbolize: $(SYM_FILES)

# Match e.g. ooex_vs2008/Debug/ooex1.sym from ooex1.symbols + ooex1.out
$(OOA_DIR)/%.sym: $(OOA_DIR)/%.symbols $(OOA_DIR)/%.out
	@echo "=== Symbolizing $* ==="
	$(SYMBOLIZE) $< $(word 2,$^) -o $@

# ----------------------------------------------------------------
# Clean generated files
# ----------------------------------------------------------------
clean:
	find $(OOA_DIR) -name '*.lp' -delete
	find $(OOA_DIR) -name '*.out' -delete
	find $(OOA_DIR) -name '*.sym' -delete
