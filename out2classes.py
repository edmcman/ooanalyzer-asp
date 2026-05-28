#!/usr/bin/env python3
"""
out2classes.py -- Parse clingo .out files and print class membership sets.

Usage:
    python out2classes.py foo.out [foo.symbols]
"""

import re
import sys
from collections import defaultdict


def load_symbols(path):
    names = {}
    with open(path) as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 3:
                try:
                    demangled = parts[3] if len(parts) >= 4 and parts[3] not in ('', 'None') else None
                    names[int(parts[0], 16)] = demangled or parts[2]
                except ValueError:
                    pass
    return names


def best_answer(content):
    # Each answer block: "Answer: N (Time: ...)\n<atoms on one line>"
    answers = re.findall(r'^Answer: \d+ \(Time: [^)]+\)\n(.*)', content, re.MULTILINE)
    return answers[-1] if answers else None


def union_find(pairs):
    parent = {}

    def root(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        rx, ry = root(x), root(y)
        if rx != ry:
            parent[rx] = ry

    for a, b in pairs:
        union(a, b)

    groups = defaultdict(set)
    for x in parent:
        groups[root(x)].add(x)
    return groups


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <foo.out> [foo.symbols]", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        content = f.read()

    names = load_symbols(sys.argv[2]) if len(sys.argv) > 2 else {}

    atoms = best_answer(content)
    if atoms is None:
        print("No answer found (UNSAT or empty output)", file=sys.stderr)
        sys.exit(1)

    methods = {int(m) for m in re.findall(r'\bmethod\((\d+)\)', atoms)}
    pairs = [(int(a), int(b)) for a, b in re.findall(r'sameClass\((\d+),(\d+)\)', atoms)]

    groups = union_find(pairs)

    def fmt(addr):
        name = names.get(addr)
        return f"{hex(addr)}  {name}" if name else hex(addr)

    for members in sorted(groups.values(), key=lambda s: min(s)):
        method_members = members & methods
        if not method_members:
            continue
        print(f"class {hex(min(method_members))}:")
        for m in sorted(method_members):
            print(f"  {fmt(m)}")


if __name__ == "__main__":
    main()
