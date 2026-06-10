#!/usr/bin/env python3
"""Regression tests for the OOAnalyzer facts-to-Clingo syntax adapter."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from facts2clingo import process_line


def check(name: str, source: str, expected: list[str]) -> bool:
    actual = process_line(source)
    ok = actual == expected
    status = "PASS" if ok else "FAIL"
    print(f"  {status}  {name}")
    if not ok:
        print(f"       got:  {actual!r}")
        print(f"       want: {expected!r}")
    return ok


def main() -> int:
    tests = [
        (
            "escaped single quote",
            "symbolClass(0x102478f0, '`vbase destructor\\'').\n",
            ['symbolClass(0x102478f0, "`vbase destructor\'").\n'],
        ),
        (
            "embedded escaped quote",
            "rTTITypeDescriptor(0x52974c, 0x518f48, 'boost::\\'anonymous namespace\\'::thread').\n",
            ['rTTITypeDescriptor(0x52974c, 0x518f48, "boost::\'anonymous namespace\'::thread").\n'],
        ),
        (
            "double quote escaped for clingo",
            "demangledName(0x4bf51c, string, 'char[19] = \"`vbase destructor\\'\"').\n",
            ['demangledName(0x4bf51c, string, "char[19] = \\"`vbase destructor\'\\"").\n'],
        ),
    ]

    passed = sum(1 for name, source, expected in tests if check(name, source, expected))
    failed = len(tests) - passed
    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
