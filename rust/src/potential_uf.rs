//! Least-fixpoint over observed ground rules that populates the potential UF.
//! Port of `sameclass.py:_build_potential_uf` (lines 521–732).
//!
//! A `mergeClasses(a,b)` atom is potentially derivable only when some rule
//! deriving it has all positive-body atoms potentially derivable, where
//! `&sameClass(x,y)` is derivable iff (x,y) are already same-component in the
//! potential UF being built. Ordinary helper atoms are derived through the same
//! positive-rule fixpoint so they cannot hide circular sc deps.
//!
//! This kills the circular K-rule bootstrap: a `mergeClasses(CM,TI)` whose only
//! support is a K-rule requiring `&sameClass(CM,TI)` never enters the UF, because
//! that sc atom is cross-component until the merge edge exists.
//!
//! Falls back to union-all when no observer data is available.

use crate::entkey::EntKey;
use crate::shared::{MergeScFacts, ObsData};
use crate::uf::Uf;
use rustc_hash::{FxHashMap, FxHashSet};
use std::collections::VecDeque;

/// Populates `uf` (the potential UF) via the least fixpoint. See module docs.
pub fn build_potential_uf(uf: &mut Uf, obs: &ObsData, facts: &MergeScFacts) {
    // Observer not registered: fall back to union-all over every merge edge.
    if obs.rules.is_empty() && obs.unconditional.is_empty() {
        for (&slit, pairs) in &facts.merge_lit_to_pairs {
            for (a, b) in pairs {
                uf.union(a, b, slit, None, None);
            }
        }
        return;
    }

    let mut fx = Fixpoint {
        uf,
        obs,
        facts,
        derivable: obs.unconditional.clone(),
        sc_derivable: FxHashSet::default(),
        blocked_by_lit: FxHashMap::default(),
        ready: VecDeque::new(),
        relevant_rules: None,
        merge_proglits: facts.merge_proglit_to_pair.keys().copied().collect(),
        sc_proglits: facts.sc_proglit_to_pair.keys().copied().collect(),
        sc_by_entity: FxHashMap::default(),
    };
    fx.run();
}

struct Fixpoint<'a> {
    uf: &'a mut Uf,
    obs: &'a ObsData,
    facts: &'a MergeScFacts,
    derivable: FxHashSet<i32>,
    sc_derivable: FxHashSet<i32>,
    blocked_by_lit: FxHashMap<i32, Vec<usize>>,
    ready: VecDeque<usize>,
    relevant_rules: Option<Vec<usize>>,
    merge_proglits: FxHashSet<i32>,
    sc_proglits: FxHashSet<i32>,
    sc_by_entity: FxHashMap<EntKey, Vec<(EntKey, i32)>>,
}

impl<'a> Fixpoint<'a> {
    fn run(&mut self) {
        self.slice_relevant_rules();
        self.build_sc_by_entity();
        self.seed_unconditional_merges();
        self.seed_reflexive_sc();
        self.index_rules();
        self.drain_ready();
    }

    /// Backward slice from merge targets: collect every rule (transitively, via
    /// positive bodies) that could derive a not-yet-derivable merge atom.
    fn slice_relevant_rules(&mut self) {
        let mut relevant: FxHashSet<usize> = FxHashSet::default();
        let mut seen_targets: FxHashSet<i32> = FxHashSet::default();
        let mut pending: VecDeque<i32> = VecDeque::new();
        for pl in self.merge_proglits.iter().copied() {
            if !self.derivable.contains(&pl) {
                seen_targets.insert(pl);
                pending.push_back(pl);
            }
        }
        while let Some(target) = pending.pop_front() {
            if let Some(rule_idxs) = self.obs.head_to_rules.get(&target) {
                for &rule_idx in rule_idxs {
                    if !relevant.insert(rule_idx) {
                        continue;
                    }
                    let pos_body = &self.obs.rules[rule_idx].pos_body;
                    for &lit in pos_body {
                        if self.sc_proglits.contains(&lit)
                            || self.derivable.contains(&lit)
                            || seen_targets.contains(&lit)
                        {
                            continue;
                        }
                        seen_targets.insert(lit);
                        pending.push_back(lit);
                    }
                }
            }
        }
        // Sort for determinism (the fixpoint is confluent; this just fixes order).
        self.relevant_rules = Some(relevant.into_iter().collect::<Vec<_>>());
        self.relevant_rules.as_mut().unwrap().sort_unstable();
    }

    /// `sc_by_entity[x] = [(y, pl), ...]` for every `&sameClass(x,y)` prog-lit.
    fn build_sc_by_entity(&mut self) {
        for (&pl, (x, y)) in &self.facts.sc_proglit_to_pair {
            self.sc_by_entity
                .entry(x.clone())
                .or_default()
                .push((y.clone(), pl));
            if x != y {
                self.sc_by_entity
                    .entry(y.clone())
                    .or_default()
                    .push((x.clone(), pl));
            }
        }
    }

    /// Seed the UF with merge atoms that are unconditionally derivable.
    fn seed_unconditional_merges(&mut self) {
        // Collect first to avoid borrowing self.facts while mutating self.uf.
        let seeds: Vec<(EntKey, EntKey, i32)> = self
            .merge_proglits
            .iter()
            .copied()
            .filter(|pl| self.derivable.contains(pl))
            .map(|pl| {
                let (a, b) = self.facts.merge_proglit_to_pair[&pl].clone();
                let slit = self.facts.merge_proglit_to_slit[&pl];
                (a, b, slit)
            })
            .collect();
        for (a, b, slit) in seeds {
            self.uf.union(&a, &b, slit, None, None);
        }
    }

    /// Reflexive and seed-connected sameClass atoms are available before any
    /// rule indexing.
    fn seed_reflexive_sc(&mut self) {
        let seeds: Vec<(i32, bool)> = self
            .facts
            .sc_proglit_to_pair
            .iter()
            .map(|(&pl, (x, y))| (pl, self.uf.same(x, y)))
            .collect();
        for (pl, connected) in seeds {
            if connected {
                self.sc_derivable.insert(pl);
            }
        }
    }

    /// Place each relevant rule on `ready` (no positive-body blocker) or behind
    /// its first blocker in `blocked_by_lit`.
    fn index_rules(&mut self) {
        let rules = self.relevant_rules.take().unwrap();
        for idx in rules {
            let pos_body = self.obs.rules[idx].pos_body.clone();
            if pos_body.is_empty() {
                self.ready.push_back(idx);
            } else {
                self.block_or_ready(idx, &pos_body);
            }
        }
    }

    /// First positive-body literal that is not yet derivable (an sc lit counts
    /// as derivable only if in `sc_derivable`), or `None` if the rule is ready.
    fn first_blocker(&self, pos_body: &[i32]) -> Option<i32> {
        for &lit in pos_body {
            if self.sc_proglits.contains(&lit) {
                if !self.sc_derivable.contains(&lit) {
                    return Some(lit);
                }
            } else if !self.derivable.contains(&lit) {
                return Some(lit);
            }
        }
        None
    }

    fn block_or_ready(&mut self, rule_idx: usize, pos_body: &[i32]) {
        match self.first_blocker(pos_body) {
            None => self.ready.push_back(rule_idx),
            Some(blocker) => {
                self.blocked_by_lit
                    .entry(blocker)
                    .or_default()
                    .push(rule_idx);
            }
        }
    }

    /// Re-examine every rule blocked on `lit` now that `lit` is derivable.
    fn wake(&mut self, lit: i32) {
        if let Some(waiting) = self.blocked_by_lit.remove(&lit) {
            for rule_idx in waiting {
                let pos_body = self.obs.rules[rule_idx].pos_body.clone();
                self.block_or_ready(rule_idx, &pos_body);
            }
        }
    }

    fn mark_sc_derivable(&mut self, pl: i32) {
        if self.sc_derivable.insert(pl) {
            self.wake(pl);
        }
    }

    /// Record the merge edge and, if it newly joins two components, mark every
    /// `&sameClass` atom whose endpoints straddle the join as derivable.
    fn add_potential_merge(&mut self, pl: i32) {
        let (a, b) = self.facts.merge_proglit_to_pair[&pl].clone();
        let slit = self.facts.merge_proglit_to_slit[&pl];
        let already_connected = self.uf.same(&a, &b);
        let (comp_a, comp_b) = if already_connected {
            (FxHashSet::default(), FxHashSet::default())
        } else {
            (self.uf.component(&a), self.uf.component(&b))
        };
        // Always record the edge (redundant edges are still needed by later
        // bridge-edge tests over the full potential merge graph).
        self.uf.union(&a, &b, slit, None, None);
        if already_connected {
            return;
        }
        // Iterate the smaller side against the larger. Collect the sc-lits to
        // mark first so we don't hold an immutable borrow of `sc_by_entity` across
        // the mutable `mark_sc_derivable` call.
        let (small, large) = if comp_a.len() > comp_b.len() {
            (comp_b, comp_a)
        } else {
            (comp_a, comp_b)
        };
        let to_mark: Vec<i32> = small
            .iter()
            .flat_map(|x| self.sc_by_entity.get(x).into_iter().flatten())
            .filter(|(y, _)| large.contains(y))
            .map(|(_, sc_pl)| *sc_pl)
            .collect();
        for sc_pl in to_mark {
            self.mark_sc_derivable(sc_pl);
        }
    }

    fn mark_derivable(&mut self, pl: i32) {
        if self.derivable.insert(pl) {
            self.wake(pl);
            if self.facts.is_merge_proglit(pl) {
                self.add_potential_merge(pl);
            }
        }
    }

    fn drain_ready(&mut self) {
        while let Some(rule_idx) = self.ready.pop_front() {
            let heads = self.obs.rules[rule_idx].heads.clone();
            for pl in heads {
                self.mark_derivable(pl);
            }
        }
    }
}
