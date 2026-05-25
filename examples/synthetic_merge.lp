% synthetic_merge.lp — two methods should merge because they write the same vftable

possibleMethod(1000).
possibleMethod(1100).
possibleVFTableWrite(0, 1000, none, 0, 2000).
possibleVFTableWrite(0, 1100, none, 0, 2000).
possibleVFTableEntry(2000, 0, 1200).
returnsSelf(1000).
returnsSelf(1100).
noCallsBefore(1000).
noCallsBefore(1100).
