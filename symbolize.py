#!/usr/bin/env python3
"""
Symbolize clingo output by replacing decimal addresses with human-readable
symbols from an OOAnalyzer .symbols file.

Usage:
    python symbolize.py SYMBOLS_FILE [INPUT_FILE] [-o OUTPUT_FILE] [-f FILTER]

SYMBOLS_FILE: tab-separated: addr  type  idasymbol  demangled_name
INPUT_FILE:   clingo .out (or any text with decimal addresses); stdin if omitted
-f FILTER:    only print lines containing this substring (e.g. classRep, factDerivedClass)

Based on pharos/tools/ooanalyzer/tests/ooanalyzer-symbolizer.py.in
"""
import argparse
import re
import sys

# Abbreviate noisy C++ decorations for readability
_FIXUPS = [
    ('public: ', ''),
    ('private: ', ''),
    ('protected: ', ''),
    ('__thiscall ', ''),
    ('void ', ''),
    ('struct std::char_traits<char>', 'CHAR_TRAITS'),
    ('class std::allocator<char>', 'CHAR_ALLOC'),
]

def _fixup(sym):
    for old, new in _FIXUPS:
        sym = sym.replace(old, new)
    return sym

def build_symbol_map(symbols_file):
    """Return dict: int_addr -> display_string."""
    m = {}
    with open(symbols_file) as f:
        for line in f:
            line = line.rstrip()
            if not line:
                continue
            parts = line.split(None, 3)
            if len(parts) < 3:
                continue
            addr_hex, _kind, idasym = parts[0], parts[1], parts[2]
            demangled = parts[3] if len(parts) == 4 else None
            addr = int(addr_hex, 16)
            label = _fixup(demangled) if demangled and demangled != 'None' else idasym
            m[addr] = label
    return m

def symbolize(text, addr_map):
    """Replace every decimal integer that appears in addr_map with its symbol."""
    # Match bare decimal integers (not preceded/followed by a hex digit or dot)
    def replacer(m):
        n = int(m.group(0))
        if n in addr_map:
            return addr_map[n]
        return m.group(0)
    return re.sub(r'\b\d{6,}\b', replacer, text)

def main():
    ap = argparse.ArgumentParser(description='Symbolize OOAnalyzer/clingo output')
    ap.add_argument('symbols_file', metavar='SYMBOLS_FILE')
    ap.add_argument('input_file', metavar='INPUT_FILE', nargs='?')
    ap.add_argument('-o', '--output-file', metavar='OUTPUT_FILE')
    ap.add_argument('-f', '--filter', metavar='SUBSTR',
                    help='only print lines containing this substring')
    args = ap.parse_args()

    addr_map = build_symbol_map(args.symbols_file)

    inp = open(args.input_file) if args.input_file else sys.stdin
    out = open(args.output_file, 'w') if args.output_file else sys.stdout

    try:
        for line in inp:
            line = symbolize(line, addr_map)
            if args.filter and args.filter not in line:
                continue
            out.write(line)
    finally:
        if args.input_file:
            inp.close()
        if args.output_file:
            out.close()

if __name__ == '__main__':
    main()
