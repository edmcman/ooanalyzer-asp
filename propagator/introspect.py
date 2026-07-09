"""Reward-family helpers for the native Rust solver inspector."""

from collections import defaultdict


# Reward-atom predicate -> (family, weight). comp2 (priority @0) only.
REWARD_FAMILY = {
    "guessMethodReward": ("method", 10),
    "guessConstructor1Reward": ("ctor", 10),
    "guessConstructor2Reward": ("ctor", 9),
    "guessConstructor3Reward": ("ctor", 8),
    "guessConstructor4Reward": ("ctor", 7),
    "strongMergeReward": ("strong_merge", 10),
    "weakMergeReward": ("weak_merge", 8),
    "weakG1Bonus": ("weak_g1", 9),
    "lateF2Reward": ("late_f2", 8),
    "guessDerivedClassReward": ("composition", 10),
    "purecallNotMostDerivedReward": ("composition", 40),
    "embedsKnownBasePenalty": ("composition", -20),
}


def decompose_reward(symbols):
    """Return exact comp2 reward and atom counts grouped by family."""
    reward = defaultdict(int)
    counts = defaultdict(int)
    for sym in symbols:
        family_weight = REWARD_FAMILY.get(sym.name)
        if family_weight is None:
            continue
        family, weight = family_weight
        reward[family] += weight
        counts[family] += 1
    return dict(reward), dict(counts)
