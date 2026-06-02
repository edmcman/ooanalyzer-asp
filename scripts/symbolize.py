#!/usr/bin/env python3
"""
Symbolize clingo output by replacing decimal addresses with human-readable
symbols from an OOAnalyzer .symbols file.

Usage:
    python scripts/symbolize.py SYMBOLS_FILE [INPUT_FILE] [-o OUTPUT_FILE] [-f FILTER]

SYMBOLS_FILE: tab-separated: addr  type  idasymbol  demangled_name
INPUT_FILE:   clingo .out (or any text with decimal addresses); stdin if omitted
-f FILTER:    only print lines containing this substring (e.g. classRep, derivedClass)

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
    """Return dict: int_addr -> display_string.

    Supports two formats:
      .symbols: tab-separated lines  hex  kind  idasym  [demangled]
      .ground:  symbol(0xHEX, kind, 'name') and demangledName(0xHEX, kind, 'demangled')
    """
    m = {}
    with open(symbols_file) as f:
        lines = f.readlines()
    if symbols_file.endswith('.ground'):
        import re as _re
        _sym = _re.compile(r"symbol\((0x[0-9a-fA-F]+)\s*,\s*\w+\s*,\s*'([^']*)'\)")
        _dem = _re.compile(r"demangledName\((0x[0-9a-fA-F]+)\s*,\s*[^,]*\s*,\s*'([^']*)'\)")
        for line in lines:
            mo = _dem.match(line)
            if mo:
                addr = int(mo.group(1), 16)
                m[addr] = _fixup(mo.group(2))
                continue
            mo = _sym.match(line)
            if mo:
                addr = int(mo.group(1), 16)
                if addr not in m:
                    m[addr] = mo.group(2)
    elif symbols_file.endswith('.symbols'):
        for line in lines:
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
            return f"{addr_map[n]}@{m.group(0)}"
        return m.group(0)
    return re.sub(r'(?<![0-9a-fA-F.])\d{6,}(?!\d)', replacer, text)

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

    facts, equiv, other = [], [], []
    try:
        for line in inp:
            tokens = line.split()
            if tokens and all(re.match(r'^-?\w+\(', t) for t in tokens):
                for fact in tokens:
                    fact = symbolize(fact, addr_map)
                    if args.filter and args.filter not in fact:
                        continue
                    facts.append(fact)
            else:
                line = symbolize(line, addr_map)
                if args.filter and args.filter not in line:
                    continue
                (equiv if line.startswith('%   {') else other).append(line)
    finally:
        if args.input_file:
            inp.close()
    for line in other:
        out.write(line)
    for fact in sorted(facts):
        out.write(fact + '\n')
    for line in sorted(equiv):
        out.write(line)
    if args.output_file:
        out.close()

if __name__ == '__main__':
    main()
