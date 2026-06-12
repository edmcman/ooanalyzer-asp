"""
results.py — generate Prolog-style .results output from a solved OOAnalyzer model.

Usage (from ooanalyzer.py):
    from results import write_results
    write_results(ctl, all_atoms, merge_pairs, output_path)
"""
import re
import sys
from collections import defaultdict
import clingo


class _Atom:
    """Prolog atom printed without quotes (e.g. false, certain, likely)."""
    __slots__ = ("s",)
    def __init__(self, s): self.s = s
    def __str__(self): return self.s


_CERTAIN = _Atom("certain")
_LIKELY  = _Atom("likely")
_FALSE   = _Atom("false")


def _arg(sym):
    if sym.type == clingo.SymbolType.Number:
        return sym.number
    if sym.type == clingo.SymbolType.String:
        return sym.string
    return str(sym)


def _index(atoms):
    bp = defaultdict(list)
    for atom in atoms:
        if atom.type == clingo.SymbolType.Function and atom.positive:
            bp[(atom.name, len(atom.arguments))].append(
                tuple(_arg(a) for a in atom.arguments)
            )
    return bp


def _input_facts(ctl, name, arity):
    for sa in ctl.symbolic_atoms.by_signature(name, arity, True):
        if sa.is_fact:
            yield tuple(_arg(a) for a in sa.symbol.arguments)


def _partition(merge_pairs, universe):
    parent = {}

    def root(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = root(a), root(b)
        if ra != rb:
            parent[ra] = rb

    for a, b in merge_pairs:
        ka = a.number if a.type == clingo.SymbolType.Number else str(a)
        kb = b.number if b.type == clingo.SymbolType.Number else str(b)
        parent.setdefault(ka, ka)
        parent.setdefault(kb, kb)
        union(ka, kb)

    groups = defaultdict(set)
    for x in universe:
        groups[root(x)].add(x)
    return dict(groups)


def _class_id(members, vftables_at_zero, class_vftables, real_destructors, constructors, methods):
    primary = sorted(vftables_at_zero & members)
    if primary:
        return primary[0]
    if len(class_vftables) == 1:
        return next(iter(class_vftables))
    rdtors = sorted(real_destructors & members)
    if rdtors:
        return rdtors[0]
    ctors = constructors & members
    if ctors:
        return min(ctors)
    meths = methods & members
    if meths:
        return min(meths)
    return min(members)


def _addr(x):
    if isinstance(x, int):
        return hex(x) if x != 0 else "0"
    return str(x)


def _plist(items):
    return "[" + ", ".join(_addr(i) for i in items) + "]"


_BARE_ATOM = re.compile(r'^[a-z][a-zA-Z0-9_]*$')

def _fmt(a):
    if isinstance(a, list):  return _plist(a)
    if isinstance(a, _Atom): return a.s
    if isinstance(a, str):   return a if _BARE_ATOM.match(a) else f"'{a}'"
    return _addr(a)


def _sort_key(row):
    def sk(a):
        if isinstance(a, int):   return (0, a, "")
        if isinstance(a, _Atom): return (1, 0, a.s)
        if isinstance(a, list):  return (0, a[0] if a else 0, "")
        return (1, 0, str(a))
    return tuple(sk(a) for a in row)


def write_results(ctl, all_atoms, merge_pairs, output_path):
    """Write a .results file from the optimal model."""
    bp = _index(all_atoms)

    methods          = {a for (a,) in bp[("method", 1)]}
    constructors     = {a for (a,) in bp[("constructor", 1)]}
    real_destructors = {a for (a,) in bp[("realDestructor", 1)]}
    del_destructors  = {a for (a,) in bp[("deletingDestructor", 1)]}
    vftables         = {a for (a,) in bp[("vfTable", 1)]}
    vft_size         = {v: s for v, s in bp[("vfTableSize", 2)]}

    gte_by_witness = defaultdict(list)
    for w, s in bp[("classSizeGTE", 2)]:
        gte_by_witness[w].append(s)
    lte_by_witness = defaultdict(list)
    for w, s in bp[("classSizeLTE", 2)]:
        lte_by_witness[w].append(s)
    vft_entries      = set(bp[("vfTableEntry", 3)])
    vtbc             = set(bp[("vftableBelongsToClass", 3)])
    vftables_at_zero = {v for v, o, _ in vtbc if o == 0}
    derived_classes  = set(bp[("derivedClass", 3)])
    embedded_objects = set(bp[("embeddedObject", 3)])

    file_infos     = list(_input_facts(ctl, "fileInfo", 4))
    thunks         = {(f, t) for f, t in _input_facts(ctl, "thunk", 2)}
    symbol_classes = list(_input_facts(ctl, "symbolClass", 4))
    rtti_td        = {tda: (mangled, dname)
                     for tda, _, mangled, dname in _input_facts(ctl, "rTTITypeDescriptor", 4)}

    rtti_tda2vft = defaultdict(list)
    for tda, vft in bp[("rTTITDA2VFTable", 2)]:
        rtti_tda2vft[tda].append(vft)

    # Pointer size from fileInfo; fallback to 4
    ptr_size = file_infos[0][3] if file_infos else 4

    # VFTable → COL pointer address (VFTable - PtrSize)
    rtti_col_addr = {}
    for pointer, _cola, tda, _chda, _off, _o2 in _input_facts(ctl, "rTTICompleteObjectLocator", 6):
        rtti_col_addr[pointer + ptr_size] = pointer

    thunk_map = {f: t for f, t in thunks}
    def dethunk(x):
        seen = set()
        while x in thunk_map and x not in seen:
            seen.add(x); x = thunk_map[x]
        return x

    known_virtual = {dethunk(entry) for _, _, entry in vft_entries}
    for m, prop in _input_facts(ctl, "symbolProperty", 2):
        if prop == "virtual":
            known_virtual.add(m)

    entity_universe = methods | vftables
    parts           = _partition(merge_pairs, entity_universe)
    member_to_rep   = {m: rep for rep, mset in parts.items() for m in mset}

    rep_vftables = defaultdict(set)
    for v in vftables:
        rep_vftables[member_to_rep.get(v, v)].add(v)

    vtbc_by_rep_offset = defaultdict(set)
    for v, off, witness in vtbc:
        vtbc_by_rep_offset[(member_to_rep.get(witness, witness), off)].add(v)

    derived_witnesses  = {w for t in derived_classes  for w in (t[0], t[1])}
    embedded_witnesses = {w for t in embedded_objects for w in (t[0], t[1])}

    class_id_map    = {}
    min_size_by_rep = {}
    useful_reps     = set()
    for rep, mset in parts.items():
        cmethods = methods & mset
        cvfts    = rep_vftables[rep]
        cctors   = constructors & mset
        crdtors  = real_destructors & mset
        in_rel   = (derived_witnesses | embedded_witnesses) & mset
        gte      = [s for w in mset for s in gte_by_witness.get(w, [])]
        min_size = max(gte) if gte else 0
        min_size_by_rep[rep] = min_size
        class_id_map[rep] = _class_id(mset, vftables_at_zero, cvfts, crdtors, cctors, cmethods)
        if cvfts or cctors or crdtors or len(cmethods) > 1 or in_rel or min_size > 0:
            useful_reps.add(rep)

    def to_class_id(witness):
        return class_id_map.get(member_to_rep.get(witness, witness), witness)

    facts = defaultdict(list)   # pred → list of raw-arg tuples

    for md5, name, _abi, _arch in file_infos:
        facts["finalFileInfo"].append((md5, name))

    thunk_sources = {f for f, _ in thunks}

    for rep in parts:
        if rep not in useful_reps:
            continue
        mset     = parts[rep]
        cmethods = sorted((methods & mset) - thunk_sources)
        crdtors  = real_destructors & mset
        cid      = class_id_map[rep]
        pvft     = min(vftables_at_zero & mset) if vftables_at_zero & mset else 0
        rdtor    = min(crdtors) if crdtors else 0
        lte      = [s for w in mset for s in lte_by_witness.get(w, [])]
        min_size = min_size_by_rep[rep]
        max_size = min(lte) if lte else min_size
        facts["finalClass"].append((cid, pvft, min_size, max_size, rdtor, cmethods))

    seen_rtti_class = set()   # (class_id, mangled, dname) — one entry per class
    for tda, vft_list in rtti_tda2vft.items():
        if tda not in rtti_td:
            continue
        mangled, dname = rtti_td[tda]
        for vft in vft_list:
            rep = member_to_rep.get(vft, vft)
            if rep not in useful_reps:
                continue
            cid = class_id_map.get(rep, vft)
            key = (cid, mangled, dname)
            if key in seen_rtti_class:
                continue
            seen_rtti_class.add(key)
            facts["finalDemangledName"].append((cid, mangled, dname, ""))

    for method, mangled, classname, methodname in symbol_classes:
        rep = member_to_rep.get(method, method)
        if rep in useful_reps:
            facts["finalDemangledName"].append((method, mangled, classname, methodname))

    for vft in vftables:
        size      = vft_size.get(vft, 0)
        rtti_addr = rtti_col_addr.get(vft, 0)
        rtti_name = ""
        for tda, vft_list in rtti_tda2vft.items():
            if vft in vft_list and tda in rtti_td:
                rtti_name = rtti_td[tda][0]
                break
        facts["finalVFTable"].append((vft, size, size, rtti_addr, rtti_name))

    for vft, offset, entry in vft_entries:
        facts["finalVFTableEntry"].append((vft, offset, entry))

    seen_inherit = set()
    for dw, bw, offset in derived_classes:
        dr = member_to_rep.get(dw, dw)
        br = member_to_rep.get(bw, bw)
        if dr not in useful_reps or br not in useful_reps:
            continue
        did = class_id_map.get(dr, dw)
        bid = class_id_map.get(br, bw)
        key = (did, bid, offset)
        if key in seen_inherit:
            continue
        seen_inherit.add(key)
        vtfs    = vtbc_by_rep_offset.get((dr, offset), set())
        vft_val = min(vtfs) if vtfs else 0
        facts["finalInheritance"].append((did, bid, offset, vft_val, _FALSE))

    seen_embed = set()
    for ow, iw, offset in embedded_objects:
        or_ = member_to_rep.get(ow, ow)
        ir  = member_to_rep.get(iw, iw)
        if or_ not in useful_reps or ir not in useful_reps:
            continue
        oid = class_id_map.get(or_, ow)
        iid = class_id_map.get(ir, iw)
        if oid == iid:
            continue
        key = (oid, iid, offset)
        if key in seen_embed:
            continue
        seen_embed.add(key)
        facts["finalEmbeddedObject"].append((oid, offset, iid, _LIKELY))

    _CONSTRUCTOR = _Atom("constructor")
    _REAL_DTOR   = _Atom("realDestructor")
    _DEL_DTOR    = _Atom("deletingDestructor")
    _VIRTUAL     = _Atom("virtual")

    for m in constructors:
        if member_to_rep.get(m, m) in useful_reps:
            facts["finalMethodProperty"].append((m, _CONSTRUCTOR, _CERTAIN))
    for m in del_destructors:
        if member_to_rep.get(m, m) in useful_reps:
            facts["finalMethodProperty"].append((m, _DEL_DTOR, _CERTAIN))
    for m in real_destructors:
        if member_to_rep.get(m, m) in useful_reps:
            facts["finalMethodProperty"].append((m, _REAL_DTOR, _CERTAIN))
    for m in known_virtual:
        if member_to_rep.get(m, m) in useful_reps:
            facts["finalMethodProperty"].append((m, _VIRTUAL, _CERTAIN))

    # Build the set of methods appearing in any finalClass method list
    class_method_set = set()
    for cid, pvft, _cs, _ls, rdtor, cmethods in facts.get("finalClass", []):
        class_method_set.update(cmethods)

    vft_entry_addrs = {entry for _, _, entry in vft_entries}
    for from_addr, to_addr in thunks:
        if from_addr in vft_entry_addrs and to_addr in class_method_set:
            facts["finalThunk"].append((from_addr, to_addr))

    out = open(output_path, "w") if output_path != "-" else sys.stdout
    try:
        for pred in sorted(facts):
            for row in sorted(facts[pred], key=_sort_key):
                out.write(f"{pred}({', '.join(_fmt(a) for a in row)}).\n")
        out.write("% Object detection reporting complete.\n")
        out.write("% Prolog results autogenerated by OOAnalyzer.\n")
    finally:
        if out is not sys.stdout:
            out.close()
