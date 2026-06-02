# examples/ — Test Corpus Conventions

Two kinds of test inputs live here; treat them differently.

## Hand-written examples (`examples/*.lp`)

- Use **simplified predicates** (vocabulary A from root AGENTS.md).
- Method IDs are small decimal integers for readability.
- Expected output documented in a comment at the top of each file.
- `invalid_example.lp` is an intentional UNSAT demo; don't "fix" it.
- `selfdefeating.lp` documents the hard-merge / `sameClass` anti-pattern.

Run one:
```sh
clingo ooanalyzer.lp examples/example.lp        # optimal model
clingo ooanalyzer.lp examples/example.lp 0      # all models
```

## Real OOAnalyzer fixtures (`examples/ooa/`)

- Organized by build: `ooex_vs2008/Debug`, `ooex_vs2010/Lite`, `ooex_vs2010/Debug`, etc.
- Each binary has matching-basename artifacts: `.facts`, `.symbols`, `.json`, `.results`.
- **`.lp` and `.out` files are generated; never edit or commit them** (covered by `.gitignore`).
- Use `oo.facts` (complete export); `ooex0.facts` is an early-stage export that lacks vftable/RTTI and is not suitable.

Convert and run:
```sh
python scripts/facts2clingo.py examples/ooa/ooex_vs2008/Debug/oo.facts > /tmp/oo.lp
clingo ooanalyzer.lp /tmp/oo.lp
# or via Makefile:
make examples/ooa/ooex_vs2008/Debug/oo.lp   # convert one
make run                                     # convert + run all
```

## Validation

There is no automated diff target in this repo. Manual comparison:
- For real fixtures: compare clingo output against the golden `.results` file (set comparison; order doesn't matter).
- CI runs all examples via `make run` and uploads outputs as artifacts; check the uploaded `.out` files.
- Upstream harness: `pharos/tools/ooanalyzer/tests/ooanalyzer-test.py.in` supports `--accept` for updating goldens.

## Adding a new example

1. Create `examples/<name>.lp` with simplified predicates.
2. Add expected output in a comment at the top.
3. Verify: `clingo ooanalyzer.lp examples/<name>.lp`.
