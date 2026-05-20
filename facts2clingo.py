#!/usr/bin/env python3
"""
facts2clingo.py -- Convert OOAnalyzer .facts files to Clingo-compatible .lp syntax.

Usage:
    python facts2clingo.py input.facts > output.lp
    clingo ooanalyzer.lp output.lp

What it does:
    1. Rewrites single-quoted atoms that start with an uppercase letter
       (Clingo treats them as variables, not constants).
    2. Expands Prolog list syntax [a, b, c] into separate ground facts
       for predicates that need it (e.g. rTTIClassHierarchyDescriptor).
    3. Passes everything else through unchanged.

Limitations:
    - Does NOT derive facts that require complex reasoning (those live in
      src/initial.lp). This script is purely a syntactic adapter.
    - Complex nested Prolog terms (e.g. sv/2, add/1) are rewritten to atoms.
"""

import re
import sys


def fix_quoted_string(match: re.Match) -> str:
    """Convert single-quoted Prolog strings to double-quoted Clingo strings."""
    q = match.group(0)
    inner = q[1:-1]
    return f'"{inner}"'


def expand_list_predicate(line: str) -> list[str]:
    """
    Expand predicates that contain a Prolog list as their last argument.
    Example:
        rTTIClassHierarchyDescriptor(0x41860c, 0x1, [0x418630, 0x418654]).
    Becomes:
        rTTIClassHierarchyDescriptor(0x41860c, 0x1, 0x418630).
        rTTIClassHierarchyDescriptor(0x41860c, 0x1, 0x418654).
    """
    # Find the last ", [" pattern which marks the list argument.
    idx = line.rfind(", [")
    if idx < 0:
        return [line]

    prefix = line[:idx]
    suffix = line[idx + 2:]  # e.g. " [0x418630, 0x418654]).\n"
    suffix = suffix.strip()
    # suffix should now be "[0x418630, 0x418654])."
    if not suffix.startswith("[") or not suffix.endswith(")."):
        return [line]

    inner = suffix[1:-3]  # strip leading [ and trailing ]).
    items = [item.strip() for item in inner.split(",")]
    return [f"{prefix}, {item})." for item in items]


def process_line(line: str) -> list[str]:
    # Skip comments and blank lines
    stripped = line.strip()
    if not stripped or stripped.startswith("%"):
        return [line]

    # Drop thisPtrDefinition facts -- they contain nested Prolog lists
    # (add/1, xor/1, etc.) that Clingo cannot parse, and the prototype
    # does not use them anyway (callAtOffset is derived from thisPtrOffset).
    if stripped.startswith("thisPtrDefinition("):
        return []

    # Step 1: Expand list predicates
    lines = expand_list_predicate(line)
    result = []
    for ln in lines:
        # Step 2: Convert single-quoted Prolog strings to double-quoted Clingo strings.
        # Clingo does not support single-quoted strings in predicate arguments.
        ln = re.sub(r"'[^']*'", fix_quoted_string, ln)
        result.append(ln)

    return result


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.facts> > output.lp", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        for line in f:
            for out in process_line(line):
                sys.stdout.write(out)
                if not out.endswith("\n"):
                    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
