# OOAnalyzer Clingo Prototype — Makefile
# Converts OOAnalyzer .facts files to Clingo .lp and runs the solver.

PYTHON     := python3
CLINGO     := clingo
CLINGO_FLAGS := ooanalyzer.lp

OOA_DIR    := examples/ooa
FACTS      := $(wildcard $(OOA_DIR)/*.facts)
LP_FILES   := $(FACTS:%.facts=%.lp)

# ----------------------------------------------------------------
# Default: convert all .facts and run clingo
# ----------------------------------------------------------------
.PHONY: all convert run clean help

all: run

help:
	@echo "Targets:"
	@echo "  make convert    — convert all $(OOA_DIR)/*.facts to .lp"
	@echo "  make run        — convert and run clingo on all .lp files"
	@echo "  make clean      — remove generated .lp files"
	@echo "  make $(OOA_DIR)/oo.lp  — convert a single .facts file"

# ----------------------------------------------------------------
# Conversion: .facts → .lp
# ----------------------------------------------------------------
convert: $(LP_FILES)

$(OOA_DIR)/%.lp: $(OOA_DIR)/%.facts facts2clingo.py
	@echo "=== Converting $< → $@ ==="
	$(PYTHON) facts2clingo.py $< > $@

# ----------------------------------------------------------------
# Run clingo on generated .lp files
# ----------------------------------------------------------------
run: $(LP_FILES)
	@for lp in $(LP_FILES); do \
		echo ""; \
		echo "========================================"; \
		echo "Running: $(CLINGO) $(CLINGO_FLAGS) $$lp"; \
		echo "========================================"; \
		$(CLINGO) $(CLINGO_FLAGS) $$lp 2>&1 | tail -6; \
	done

# ----------------------------------------------------------------
# Clean generated files
# ----------------------------------------------------------------
clean:
	rm -f $(LP_FILES)
