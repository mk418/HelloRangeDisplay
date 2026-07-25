local _, addon = ...

-- Static range data. Nothing here states a yardage for a *spell*: spell ranges
-- are read from the client at build time, because talents move them (Destructive
-- Reach, Hawk Eye, Nature's Reach) and a hard-coded number would quietly lie
-- about a talented character. The spell tables below are classification hints
-- only — "this spell is worth checking, and it points at enemies" — used when
-- the client won't classify a spell for us. See DESIGN.md.

----------------------------------------------------------------------
-- Melee
----------------------------------------------------------------------

-- A spell whose data says range 0 is a melee ability. The distance at which the
-- client actually reports one in range is a function of both combatants' reach,
-- so it isn't a constant; 2 is LibRangeCheck's measured figure for player-sized
-- targets and the number RangeDisplay users have been reading for years.
addon.MELEE_RANGE = 2

----------------------------------------------------------------------
-- What counts as "your fighting range"
----------------------------------------------------------------------

-- No attack spell in vanilla reaches past 40 yards. Anything longer is utility
-- — Hunter's Mark is 100 — and makes an excellent range *checker* while being a
-- terrible statement of how far you can fight. Spells past this cap still get
-- checkers; they just don't get a vote on where the colour bands fall.
addon.COMBAT_RANGE_CAP = 40

-- Classes whose damage happens in melee however they're specced. For these,
-- "comfortably in range" means in melee — a warrior at 20 yards is not in a good
-- place, however far Throw reaches. Everyone else is banded against their
-- longest spell.
--
-- Paladin belongs here even Holy: there is no ranged attack anywhere in the
-- vanilla paladin kit, so they fight in melee regardless.
addon.MELEE_CLASSES = {
  WARRIOR = true,
  ROGUE   = true,
  PALADIN = true,
}

-- Hybrids are decided per character rather than per class.

-- Shaman is the one class where talents settle it. Tab indices come from the
-- game's own data and are the same in every locale — only the tab *name* is
-- translated — so this reads points spent and never touches a string.
addon.MELEE_TALENT_TAB = {
  SHAMAN = 2,   -- Enhancement
}

-- Druid is settled by shapeshift form instead, which beats talents on both
-- counts: it's exact, and it's live. A feral druid standing in caster form is
-- casting, and a balance druid who just shifted to bear is not — talent points
-- would get both of those wrong.
addon.MELEE_FORMS = {
  DRUID = {
    [_G.CAT_FORM or 1]        = true,
    [_G.BEAR_FORM or 5]       = true,
    [_G.DIRE_BEAR_FORM or 8]  = true,
  },
}

----------------------------------------------------------------------
-- Interact distances
----------------------------------------------------------------------

-- CheckInteractDistance indices. 1 (inspect) and 2 (trade) are deliberately
-- unused: they need a same-faction player, so they'd silently stop working on
-- exactly the units you most want a range for. 3 (duel) and 5 are also
-- faction-gated in practice but degrade to false rather than erroring, and 3 is
-- the only sub-10y check available to a class with no short spell.
--
-- These are measured, not documented, and they vary by the *player's* race
-- because hitboxes differ.
addon.INTERACT_RANGES = {
  [3] = 8,   -- Duel
  [4] = 28,  -- Follow
}

addon.INTERACT_BY_RACE = {
  Tauren  = { [3] = 6, [4] = 25 },
  Scourge = { [3] = 7, [4] = 27 },
}

----------------------------------------------------------------------
-- Item range buckets
----------------------------------------------------------------------

-- C_Item.IsItemInRange works on any item whose data the client has cached,
-- whether or not you own one. Each bucket lists a few alternates because item
-- data arrives asynchronously and some of these never resolve on a given realm;
-- the first one that caches wins and the rest are ignored.
--
-- Item IDs and their ranges are taken from LibRangeCheck-3.0 (MIT, © 2023 The
-- WoWUIDev Community), trimmed to the entries that exist in Classic Era. The
-- full library carries ~1400 lines of these to cover every expansion.

addon.FRIEND_ITEMS = {
  [5] = {
    1970,   -- Restoring Balm
    8149,   -- Voodoo Charm
    15826,  -- Curative Animal Salve
    16308,  -- Northridge Crowbar
    17117,  -- Rat Catcher's Flute
    20403,  -- Proxy of Nozdormu
  },
  [10] = {
    17626,  -- Frostwolf Muzzle
    17689,  -- Stormpike Training Collar
    21267,  -- Toasting Goblet
    23164,  -- Bubbly Beverage
  },
  [15] = {
    1251,   -- Linen Bandage
    2581,   -- Heavy Linen Bandage
    3530,   -- Wool Bandage
    3531,   -- Heavy Wool Bandage
    6450,   -- Silk Bandage
    8544,   -- Mageweave Bandage
    14529,  -- Runecloth Bandage
  },
  [20] = {
    12450,  -- Juju Flurry
    12451,  -- Juju Power
    12455,  -- Juju Ember
    12457,  -- Juju Chill
    17757,  -- Amulet of Spirits
    21519,  -- Mistletoe
  },
  [25] = {
    13289,  -- Egan's Blaster
  },
  [30] = {
    954,    -- Scroll of Strength
    955,    -- Scroll of Intellect
    1180,   -- Scroll of Stamina
    1181,   -- Scroll of Spirit
    3012,   -- Scroll of Agility
    3013,   -- Scroll of Protection
  },
  [35] = {
    18904,  -- Zorbin's Ultra-Shrinker
  },
  [40] = {
    1713,   -- Ankh of Life
    5205,   -- Sprouted Frond
    5323,   -- Everglow Lantern
    8346,   -- Gauntlets of the Sea
    11562,  -- Crystal Restore
    18640,  -- Happy Fun Rock
  },
  [45] = {
    221316, -- Premo's Poise-Demanding Uniform
  },
  [50] = {
    221315, -- Rainbow Generator
  },
  [100] = {
    23715,  -- Permanent Lung Juice Cocktail
    23718,  -- Permanent Ground Scorpok Assay
    23719,  -- Permanent Cerebral Cortex Compound
    23721,  -- Permanent Gizzard Gum
    23722,  -- Permanent R.O.I.D.S.
  },
}

addon.HARM_ITEMS = {
  [5] = {
    8149,   -- Voodoo Charm
    15826,  -- Curative Animal Salve
    16308,  -- Northridge Crowbar
    17117,  -- Rat Catcher's Flute
    22259,  -- Unbestowed Friendship Bracelet
    22432,  -- Devilsaur Barb
  },
  [10] = {
    9606,   -- Treant Muisek Vessel
    9618,   -- Wildkin Muisek Vessel
    9619,   -- Hippogryph Muisek Vessel
    9620,   -- Faerie Dragon Muisek Vessel
    9621,   -- Mountain Giant Muisek Vessel
    10699,  -- Yeh'kinya's Bramble
  },
  [20] = {
    1191,   -- Bag of Marbles
    4388,   -- Discombobulator Ray
    10645,  -- Gnomish Death Ray
    13892,  -- Kodo Kombobulator
    17757,  -- Amulet of Spirits
    22048,  -- Lord Valthalak's Amulet
  },
  [25] = {
    13289,  -- Egan's Blaster
  },
  [30] = {
    835,    -- Large Rope Net
    1404,   -- Tidal Charm
    1434,   -- Glowing Wax Stick
    2091,   -- Magic Dust
    3434,   -- Slumber Sand
    4479,   -- Burning Charm
  },
  [35] = {
    1399,   -- Magic Candle
    1402,   -- Brimstone
    18904,  -- Zorbin's Ultra-Shrinker
  },
  [40] = {
    4945,   -- Faintly Glowing Skull
    8348,   -- Helm of Fire
  },
  [45] = {
    221316, -- Premo's Poise-Demanding Uniform
  },
  [100] = {
    23715,  -- Permanent Lung Juice Cocktail
    23718,  -- Permanent Ground Scorpok Assay
    23719,  -- Permanent Cerebral Cortex Compound
    23721,  -- Permanent Gizzard Gum
    23722,  -- Permanent R.O.I.D.S.
  },
}

----------------------------------------------------------------------
-- Spell classification hints
----------------------------------------------------------------------

-- Only consulted for spells the client refuses to classify (see RangeCheck.lua).
-- Rank 1 IDs throughout: the scan resolves them by name to whatever rank you
-- actually know, so the rank listed here doesn't matter.
--
-- Being short is fine. A missing entry costs one bucket of precision; a wrong
-- entry — a friendly spell listed as harmful — puts a checker in the list that
-- always answers "no" and drags every estimate out to maximum range.

addon.HARM_SPELLS = {
  DRUID   = { 5176, 339, 6795, 8921, 22568 },        -- Wrath, Entangling Roots, Growl, Moonfire, Ferocious Bite
  HUNTER  = { 75, 2764, 1130, 3044 },                -- Auto Shot, Throw, Hunter's Mark, Arcane Shot
  MAGE    = { 133, 116, 118, 2136, 5019 },           -- Fireball, Frostbolt, Polymorph, Fire Blast, Shoot
  PALADIN = { 879, 853, 20271 },                     -- Exorcism, Hammer of Justice, Judgement
  PRIEST  = { 589, 585, 8092, 18807, 5019 },         -- SW:Pain, Smite, Mind Blast, Mind Flay, Shoot
  -- Distract is deliberately absent: it's ground-targeted, so it has no unit to
  -- range-check against and would sit in the list answering "no" forever.
  ROGUE   = { 2764, 2094, 921 },                     -- Throw, Blind, Pick Pocket
  SHAMAN  = { 403, 8042, 8056, 370 },                -- Lightning Bolt, Earth Shock, Frost Shock, Purge
  WARLOCK = { 686, 172, 348, 5782, 689, 5019 },      -- Shadow Bolt, Corruption, Immolate, Fear, Drain Life, Shoot
  WARRIOR = { 355, 100, 2764, 5246 },                -- Taunt, Charge, Throw, Intimidating Shout
}

addon.FRIEND_SPELLS = {
  DRUID   = { 5185, 8936, 774, 2782 },               -- Healing Touch, Regrowth, Rejuvenation, Remove Corruption
  MAGE    = { 1459, 475, 130 },                      -- Arcane Intellect, Remove Curse, Slow Fall
  PALADIN = { 635, 19750, 4987, 1044 },              -- Holy Light, Flash of Light, Cleanse, Blessing of Freedom
  PRIEST  = { 2050, 2061, 527, 1243 },               -- Lesser Heal, Flash Heal, Dispel Magic, PW:Fortitude
  SHAMAN  = { 331, 526, 2870, 546 },                 -- Healing Wave, Cure Poison, Cure Disease, Water Walking
  WARLOCK = { 132, 5697 },                           -- Detect Invisibility, Unending Breath
}

-- Resurrection spells. Same problem as the pet spells below and the same fix:
-- the client calls them helpful, but they only land on a corpse, so in the
-- living-friendly list they are a checker permanently stuck on "no". Pulled out
-- into their own list, they're the right — and only — way to answer "is that
-- body close enough to raise".
--
-- Soulstone is deliberately absent: in Era it is cast on a *living* player
-- ahead of time, so it belongs in the friendly list, and the client puts it
-- there on its own.
addon.RES_SPELLS = {
  DRUID   = { 20484 },                               -- Rebirth
  PALADIN = { 7328 },                                -- Redemption
  PRIEST  = { 2006 },                                -- Resurrection
  SHAMAN  = { 2008 },                                -- Ancestral Spirit
}

-- Spells that can only ever be cast on your own pet. The client happily calls
-- these helpful, so left alone they end up in the friendly list, where they
-- answer "no" for every unit that isn't your pet — a checker stuck on "no" in
-- the middle of the list drags the whole estimate out with it. These are kept
-- out of the friendly list for that reason alone.
--
-- A lower bound, like every hand-written list here. A missed entry costs
-- accuracy on friendly units, not correctness on your pet.
addon.PET_ONLY_SPELLS = {
  HUNTER  = { 136, 6991, 982 },                      -- Mend Pet, Feed Pet, Revive Pet
  WARLOCK = { 755 },                                 -- Health Funnel
}

-- The subset of the above that works as a range check on a *live* pet, so
-- Revive Pet — which needs a dead one — is excluded.
addon.PET_SPELLS = {
  HUNTER  = { 136 },                                 -- Mend Pet
  WARLOCK = { 755 },                                 -- Health Funnel
}
