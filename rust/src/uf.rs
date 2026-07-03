//! Union-find augmented with a true-merge-edge adjacency graph and trail-based
//! snapshot/restore. Port of `sameclass.py:_UF` (lines 75-230).
//!
//! The union-find gives fast same-component checks; the adjacency graph stores
//! the actual `mergeClasses` edges (with their solver-literal "slit" labels) so
//! that BFS over it yields reason paths (clauses) — the rank-balanced UF tree's
//! parent slits do not in general witness child↔parent connectivity, so reasons
//! come from the adjacency graph, not the UF tree.
//!
//! No off-the-shelf crate provides this combination (member-set enumeration per
//! root, edge adjacency, and undo), so this is custom but built on
//! `FxHashMap`/`FxHashSet`.

use crate::entkey::EntKey;
use rustc_hash::{FxHashMap, FxHashSet};
use std::collections::VecDeque;

pub struct Uf {
    parent: FxHashMap<EntKey, EntKey>,
    size: FxHashMap<EntKey, usize>,
    members: FxHashMap<EntKey, FxHashSet<EntKey>>,
    trail: Vec<(EntKey, EntKey, usize)>, // (rb, ra, old_size_of_ra)
    adj: FxHashMap<EntKey, Vec<(EntKey, i32)>>, // node -> [(other, slit)]
    adj_trail: Vec<(EntKey, EntKey, i32)>,
}

impl Uf {
    pub fn new() -> Self {
        Uf {
            parent: FxHashMap::default(),
            size: FxHashMap::default(),
            members: FxHashMap::default(),
            trail: Vec::new(),
            adj: FxHashMap::default(),
            adj_trail: Vec::new(),
        }
    }

    /// Root with lazy single-node init. Mirrors `_UF._root` (no path compression,
    /// so trail-based restore stays simple). The walk borrows `parent` by shared
    /// reference and never clones until the final return.
    pub fn root(&mut self, x: &EntKey) -> EntKey {
        if !self.parent.contains_key(x) {
            self.parent.insert(x.clone(), x.clone());
            self.size.insert(x.clone(), 1);
            let mut s = FxHashSet::default();
            s.insert(x.clone());
            self.members.insert(x.clone(), s);
            return x.clone();
        }
        let mut cur: &EntKey = x;
        loop {
            let p = self.parent.get(cur).unwrap();
            if p == cur {
                return cur.clone();
            }
            cur = p;
        }
    }

    /// Shared-reference root walk (no lazy init, no clones). Used internally where
    /// a `&self` borrow is already held.
    fn root_ref(&self, x: &EntKey) -> Option<&EntKey> {
        let mut cur: &EntKey = x;
        loop {
            let p = self.parent.get(cur)?;
            if p == cur {
                return Some(p);
            }
            cur = p;
        }
    }

    /// Union two nodes under merge edge `slit`. Returns `Some((absorbed, root))`
    /// where `absorbed` is a snapshot (Vec) of the smaller side's member set and
    /// `root` is the absorbing (merged) component's root — or `None` if already
    /// same component (the edge is still recorded). `absorbed` is a `Vec` rather
    /// than a set because the caller sorts it by `EntKey` before emitting and a
    /// `Vec` is cheaper to build and scan; members of a root are always distinct.
    pub fn union(
        &mut self,
        a: &EntKey,
        b: &EntKey,
        slit: i32,
        ra: Option<EntKey>,
        rb: Option<EntKey>,
    ) -> Option<(Vec<EntKey>, EntKey)> {
        // Always record the actual mc edge, even if redundant.
        self.adj
            .entry(a.clone())
            .or_default()
            .push((b.clone(), slit));
        self.adj
            .entry(b.clone())
            .or_default()
            .push((a.clone(), slit));
        self.adj_trail.push((a.clone(), b.clone(), slit));

        let ra = match ra {
            Some(r) => r,
            None => self.root(a),
        };
        let rb = match rb {
            Some(r) => r,
            None => self.root(b),
        };
        if ra == rb {
            return None;
        }
        // Union by size: ra absorbs rb. Make ra the larger side.
        let (ra, rb) = if self.size[&ra] < self.size[&rb] {
            (rb, ra)
        } else {
            (ra, rb)
        };
        let absorbed: Vec<EntKey> = self.members[&rb].iter().cloned().collect();
        let old_size_ra = self.size[&ra];
        self.trail.push((rb.clone(), ra.clone(), old_size_ra));
        self.parent.insert(rb.clone(), ra.clone());
        let new_size = self.size[&ra] + self.size[&rb];
        self.size.insert(ra.clone(), new_size);
        self.members
            .get_mut(&ra)
            .unwrap()
            .extend(absorbed.iter().cloned());
        Some((absorbed, ra))
    }

    /// Live member set of a component's root (immutable borrow).
    pub fn members_of(&self, root: &EntKey) -> &FxHashSet<EntKey> {
        self.members.get(root).unwrap()
    }

    pub fn snapshot(&self) -> (usize, usize) {
        (self.trail.len(), self.adj_trail.len())
    }

    pub fn restore(&mut self, snap: (usize, usize)) {
        let (tl, al) = snap;
        while self.trail.len() > tl {
            let (rb, ra, old_size_ra) = self.trail.pop().unwrap();
            // rb was a root before the union and its member set was never mutated,
            // so it is exactly the set absorbed into ra. Move it out, subtract
            // from ra, then restore it as rb's own set — no clone of the member set.
            let rb_members = std::mem::take(self.members.get_mut(&rb).unwrap());
            {
                let merged = self.members.get_mut(&ra).unwrap();
                for m in &rb_members {
                    merged.remove(m);
                }
            }
            self.members.insert(rb.clone(), rb_members);
            self.size.insert(ra.clone(), old_size_ra);
            self.parent.insert(rb.clone(), rb);
        }
        while self.adj_trail.len() > al {
            let (a, b, slit) = self.adj_trail.pop().unwrap();
            // Pop the LAST matching entry (LIFO matches addition order).
            if let Some(v) = self.adj.get_mut(&a) {
                if let Some(pos) = (0..v.len()).rev().find(|&i| v[i] == (b.clone(), slit)) {
                    v.remove(pos);
                }
            }
            if let Some(v) = self.adj.get_mut(&b) {
                if let Some(pos) = (0..v.len()).rev().find(|&i| v[i] == (a.clone(), slit)) {
                    v.remove(pos);
                }
            }
        }
    }

    /// BFS through true mc edges; slits along an x→y path, or None if unreachable.
    pub fn path_between(&self, x: &EntKey, y: &EntKey) -> Option<Vec<i32>> {
        if x == y {
            return Some(Vec::new());
        }
        if !self.adj.contains_key(x) {
            return None;
        }
        let mut parent: FxHashMap<EntKey, (EntKey, i32)> = FxHashMap::default();
        parent.insert(x.clone(), (x.clone(), 0)); // sentinel
        let mut queue: VecDeque<EntKey> = VecDeque::new();
        queue.push_back(x.clone());
        while let Some(node) = queue.pop_front() {
            if let Some(edges) = self.adj.get(&node) {
                for (other, slit) in edges {
                    if parent.contains_key(other) {
                        continue;
                    }
                    parent.insert(other.clone(), (node.clone(), *slit));
                    if other == y {
                        let mut path = Vec::new();
                        let mut cur = y.clone();
                        while cur != *x {
                            let (prev, s) = parent[&cur].clone();
                            path.push(s);
                            cur = prev;
                        }
                        path.reverse();
                        return Some(path);
                    }
                    queue.push_back(other.clone());
                }
            }
        }
        None
    }

    pub fn same_with_reason(&mut self, a: &EntKey, b: &EntKey) -> (bool, Vec<i32>) {
        if a == b {
            return (true, Vec::new());
        }
        if !self.parent.contains_key(a) && !self.parent.contains_key(b) {
            return (false, Vec::new());
        }
        let ra = self.root(a);
        let rb = self.root(b);
        if ra != rb {
            return (false, Vec::new());
        }
        match self.path_between(a, b) {
            Some(path) => (true, path),
            None => (false, Vec::new()),
        }
    }

    /// Side-effect-free connectivity (does not lazy-init absent nodes).
    pub fn same(&self, a: &EntKey, b: &EntKey) -> bool {
        if a == b {
            return true;
        }
        match (self.root_ref(a), self.root_ref(b)) {
            (Some(ra), Some(rb)) => ra == rb,
            _ => false,
        }
    }

    /// Member set of x's component (fresh copy), or {x} if x unseen.
    pub fn component(&mut self, x: &EntKey) -> FxHashSet<EntKey> {
        if !self.parent.contains_key(x) {
            let mut s = FxHashSet::default();
            s.insert(x.clone());
            return s;
        }
        let r = self.root(x);
        self.members[&r].clone()
    }

    /// All true mc edges (slits) with both endpoints inside `members`.
    pub fn component_reasons(&self, members: &FxHashSet<EntKey>) -> FxHashSet<i32> {
        let mut reasons: FxHashSet<i32> = FxHashSet::default();
        for n in members {
            if let Some(edges) = self.adj.get(n) {
                for (other, slit) in edges {
                    if members.contains(other) {
                        reasons.insert(*slit);
                    }
                }
            }
        }
        reasons
    }

    pub fn groups(&mut self, universe: &FxHashSet<EntKey>) -> FxHashMap<EntKey, FxHashSet<EntKey>> {
        let mut out: FxHashMap<EntKey, FxHashSet<EntKey>> = FxHashMap::default();
        for x in universe {
            let r = self.root(x);
            out.entry(r).or_default().insert(x.clone());
        }
        out
    }

    /// Whether `a` and `b` are connected through true mc edges *excluding* any
    /// edge labelled `excluded_slit`. Port of `_potential_connected_without_lit`.
    pub fn connected_without_lit(&self, a: &EntKey, b: &EntKey, excluded_slit: i32) -> bool {
        if a == b {
            return true;
        }
        if !self.adj.contains_key(a) {
            return false;
        }
        let mut visited: FxHashSet<EntKey> = FxHashSet::default();
        visited.insert(a.clone());
        let mut queue: VecDeque<EntKey> = VecDeque::new();
        queue.push_back(a.clone());
        while let Some(node) = queue.pop_front() {
            if let Some(edges) = self.adj.get(&node) {
                for (other, slit) in edges {
                    if *slit == excluded_slit {
                        continue;
                    }
                    if other == b {
                        return true;
                    }
                    if visited.insert(other.clone()) {
                        queue.push_back(other.clone());
                    }
                }
            }
        }
        false
    }
}

impl Default for Uf {
    fn default() -> Self {
        Self::new()
    }
}
