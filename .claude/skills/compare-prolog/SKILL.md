---
name: compare-prolog
description: Look up Prolog reasoning logs to understand why an address got (or didn't get) a specific fact. Helps diagnose ASP divergences by showing the exact Prolog reasoning chain, then comparing it against the ASP output.
argument-hint: "<hex-address> [predicate]  e.g. 0x4125f0 constructor"
---

Compare Prolog vs ASP conclusions for: $ARGUMENTS

## Goal

Show exactly why Prolog concluded what it did about `$ARGUMENTS`, then compare with the ASP result to identify missing rules.

## Step 1 — Find the Prolog log

Prolog logs live in `~/ooanalyzer-tests/code/testcases/<testcase>/<binary>.results.log.gz`.

Determine which test case is relevant from context (e.g., the currently open `.lp` or `.results` file, or the user's phrasing). The testcase directory name matches the binary name (e.g. `optionparser/example_arg.exe`).

List the log candidates:
```sh
find ~/ooanalyzer-tests/code/testcases -name "*.results.log.gz" | sort
```

Pick the right one. If ambiguous, ask the user.

## Step 2 — Search the log for the address

```sh
zcat <logfile> | grep -i "<address>"
```

Look for lines of the form:
- `reason<Predicate>_<Variant>(...)` — a rule that fired to support the conclusion
- `Concluding fact<Predicate>(...)` — the forward-chaining conclusion
- `Guessing fact<Predicate>(...)` — a guess (choice point)
- `Proposing fact<Predicate>...([...])` — a candidate list before a guess
- `reason NOT <Predicate>_<Variant>(...)` — a rule that blocked the predicate

Trace the chain: which `reason*` rule produced the key `Concluding`/`Guessing` line?

## Step 3 — Read the Prolog rule

Look up the cited rule variant in the Prolog source:
```sh
grep -n "reason<Predicate>_<Variant>" pharos/share/prolog/oorules/*.pl
```

Read the rule body to understand exactly what conditions fired.

## Step 4 — Check ASP results

Look at the ASP `.results` file in `examples/ooa/...` for the same binary and check what it concluded about the address. Compare the difference.

## Step 5 — Find the missing/wrong ASP rule

Search the ASP source for the ported counterpart:
```sh
grep -rn "<Predicate>_<Variant>\|<Predicate>" src/ --include="*.lp" | grep -v "old/"
```

Check `TODO.md` for the rule's port status:
```sh
grep "<variant>" TODO.md
```

## Step 6 — Report

Report concisely:
1. What Prolog concluded and which rule(s) drove it
2. What ASP concluded (and why it differs)
3. Whether the rule is missing (`[ ]` in TODO.md), mis-ported, or the upstream input differs
4. The ASP rule that should be added or fixed, written out in full
