-- Offline harness for HelloRangeDisplay's range engine.
-- Stubs the WoW API, puts a simulated unit at a known distance, and checks the
-- bracket the engine reports against the distance we placed it at.

local DIST = 0          -- simulated yards to "target"
local RELATION = "harm" -- harm | friend | neutral
local IN_COMBAT = false

----------------------------------------------------------------------
-- Fake game data
----------------------------------------------------------------------

-- spellID = { name, minRange, maxRange, harmful }
local SPELLDB = {}
local BOOK = {}   -- spellbook order

-- `res` marks a spell that only lands on a corpse — the client still calls it
-- helpful, which is exactly the case the addon has to special-case.
local function DefSpell(id, name, minRange, maxRange, harmful, res)
  SPELLDB[id] = { name = name, minRange = minRange, maxRange = maxRange,
                  harmful = harmful, res = res }
  BOOK[#BOOK + 1] = id
end

local ITEM_RANGE = {}   -- itemID -> yards
local ITEM_CACHED = {}

local function CacheItem(id, range)
  ITEM_RANGE[id] = range
  ITEM_CACHED[id] = true
end

----------------------------------------------------------------------
-- API stubs
----------------------------------------------------------------------

Enum = {
  SpellBookSpellBank = { Player = 0, Pet = 1 },
  SpellBookItemType = { Spell = 1 },
}

C_Spell = {
  GetSpellInfo = function(id)
    local s = SPELLDB[id]
    if not s then return nil end
    return { name = s.name, minRange = s.minRange, maxRange = s.maxRange }
  end,
  IsSpellInRange = function(id, unit)
    local s = SPELLDB[id]
    if not s then return nil end
    -- The client returns nil, not false, when a spell can't target the unit at
    -- all. That is the whole reason a corpse-only or pet-only spell poisons a
    -- list it doesn't belong in.
    local targetable
    if s.harmful then targetable = (RELATION == "harm")
    elseif s.res then targetable = (RELATION == "corpse")
    else targetable = (RELATION == "friend") end
    if not targetable then return nil end
    local maxR = s.maxRange == 0 and 2 or s.maxRange
    if DIST > maxR then return false end
    if s.minRange and s.minRange > 0 and DIST < s.minRange then return false end
    return true
  end,
  IsSpellHarmful = function(id) return SPELLDB[id] and SPELLDB[id].harmful or false end,
  IsSpellHelpful = function(id) return SPELLDB[id] and not SPELLDB[id].harmful or false end,
}

C_SpellBook = {
  GetNumSpellBookSkillLines = function() return 1 end,
  GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = #BOOK } end,
  GetSpellBookItemInfo = function(index)
    local id = BOOK[index]
    if not id then return nil end
    return { itemType = Enum.SpellBookItemType.Spell, spellID = id, isPassive = false }
  end,
}

C_Item = {
  GetItemInfo = function(id) return ITEM_CACHED[id] and ("item" .. id) or nil end,
  IsItemInRange = function(id, unit)
    if not ITEM_CACHED[id] then return nil end
    -- The client refuses item checks on friendly units while you're in combat.
    if IN_COMBAT and RELATION ~= "harm" then return nil end
    return DIST <= ITEM_RANGE[id]
  end,
  RequestLoadItemDataByID = function() end,
}

function CheckInteractDistance(unit, index)
  if IN_COMBAT and RELATION ~= "harm" then return nil end
  local r = ({ [3] = 8, [4] = 28 })[index]
  return r and DIST <= r
end

function InCombatLockdown() return IN_COMBAT end
function UnitExists(unit) return true end
function UnitIsUnit(a, b) return a == b end
function UnitCanAttack() return RELATION == "harm" end
function UnitCanAssist() return RELATION == "friend" or RELATION == "corpse" end
function UnitIsDeadOrGhost() return RELATION == "corpse" end
function UnitClass() return "Mage", TEST_CLASS or "MAGE" end
function UnitRace() return "Human", "Human" end

----------------------------------------------------------------------
-- Load the addon's data + engine
----------------------------------------------------------------------

local root = (...) or "."

-- RangeCheck.lua captures the API it found at load time, so a scenario that
-- removes part of the API has to load a fresh copy.
local function LoadAddon()
  local t = {}
  assert(loadfile(root .. "/Ranges.lua"))("HelloRangeDisplay", t)
  assert(loadfile(root .. "/RangeCheck.lua"))("HelloRangeDisplay", t)
  return t
end

local addon = LoadAddon()

----------------------------------------------------------------------
-- Assertions
----------------------------------------------------------------------

local failures, checks = 0, 0

local function fmt(minR, maxR)
  if not minR then return "no estimate" end
  if not maxR then return ("%d +"):format(minR) end
  return ("%d - %d"):format(minR, maxR)
end

local function expect(label, dist, wantMin, wantMax)
  DIST = dist
  checks = checks + 1
  local gotMin, gotMax = addon.RC:GetRange("target")
  local ok = gotMin == wantMin and gotMax == wantMax
  if not ok then
    failures = failures + 1
    print(("  FAIL  %-38s at %5.1fy: got %-12s want %s")
      :format(label, dist, fmt(gotMin, gotMax), fmt(wantMin, wantMax)))
  else
    print(("  ok    %-38s at %5.1fy: %s"):format(label, dist, fmt(gotMin, gotMax)))
  end
end

local function sane(label)
  -- The bracket must always contain the true distance. This is the property
  -- that actually matters; the exact bucket depends on what's available.
  for d = 0, 60, 0.5 do
    DIST = d
    checks = checks + 1
    local minR, maxR = addon.RC:GetRange("target")
    if minR then
      if d < minR or (maxR and d > maxR) then
        failures = failures + 1
        print(("  FAIL  %-38s at %5.1fy: bracket %s excludes the true distance")
          :format(label, d, fmt(minR, maxR)))
        return
      end
    end
  end
  print(("  ok    %-38s bracket contains the true distance at every step"):format(label))
end

local function bandsOf(listName)
  for _, e in ipairs(addon.RC:Lists()) do
    if e.name == listName then return e.list.bands end
  end
end

local function expectBands(label, listName, deadZone, comfortMax, reachMax)
  local b = bandsOf(listName)
  checks = checks + 1
  local got = b and ("%g/%g/%g"):format(b.deadZone, b.comfortMax, b.reachMax) or "none"
  local want = ("%g/%g/%g"):format(deadZone, comfortMax, reachMax)
  if got ~= want then
    failures = failures + 1
    print(("  FAIL  %-38s bands %s, want %s"):format(label, got, want))
  else
    print(("  ok    %-38s dead<%g, green<%g, red>=%g"):format(label, deadZone, comfortMax, reachMax))
  end
end

local function listOf(name)
  for _, e in ipairs(addon.RC:Lists()) do
    if e.name == name then return e.list end
  end
end

local function dump(name)
  local parts = {}
  for _, e in ipairs(listOf(name) or {}) do
    parts[#parts + 1] = ("%d(%s)"):format(e.range, e.source)
  end
  print(("        %-20s %s"):format(name .. ":", table.concat(parts, " ")))
end

----------------------------------------------------------------------
-- Scenario 0: the hint tables themselves
----------------------------------------------------------------------

-- A misspelled class key is a silent no-op — that class simply gets no hints and
-- nobody finds out until someone plays one on a client with no classifier.
print("\n== hint tables ==")

local CLASSES = { "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST",
                  "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR" }
local HINT_TABLES = { "HARM_SPELLS", "FRIEND_SPELLS", "RES_SPELLS",
                      "PET_ONLY_SPELLS", "PET_SPELLS", "MELEE_CLASSES" }

local validClass = {}
for _, c in ipairs(CLASSES) do validClass[c] = true end

do
  local unknown = {}
  for _, name in ipairs(HINT_TABLES) do
    for key in pairs(addon[name]) do
      if not validClass[key] then unknown[#unknown + 1] = name .. "." .. tostring(key) end
    end
  end
  checks = checks + 1
  if #unknown > 0 then
    failures = failures + 1
    print(("  FAIL  unknown class keys: %s"):format(table.concat(unknown, ", ")))
  else
    print("  ok    every class key in every hint table is a real class")
  end

  -- Every class needs something to point at an enemy with, or its harm list
  -- falls back to interact distances alone.
  local missing = {}
  for _, c in ipairs(CLASSES) do
    if not addon.HARM_SPELLS[c] or #addon.HARM_SPELLS[c] == 0 then
      missing[#missing + 1] = c
    end
  end
  checks = checks + 1
  if #missing > 0 then
    failures = failures + 1
    print(("  FAIL  no harm hints for: %s"):format(table.concat(missing, ", ")))
  else
    print("  ok    all 9 classes have harm hints")
  end

  -- A pet spell that isn't also marked pet-only would be excluded from nothing,
  -- and would leak back into the friendly list.
  local leaked = {}
  for c, ids in pairs(addon.PET_SPELLS) do
    local only = {}
    for _, id in ipairs(addon.PET_ONLY_SPELLS[c] or {}) do only[id] = true end
    for _, id in ipairs(ids) do
      if not only[id] then leaked[#leaked + 1] = ("%s:%d"):format(c, id) end
    end
  end
  checks = checks + 1
  if #leaked > 0 then
    failures = failures + 1
    print(("  FAIL  pet spells missing from PET_ONLY_SPELLS: %s"):format(table.concat(leaked, ", ")))
  else
    print("  ok    every pet-range spell is also excluded from the friendly list")
  end

  -- No spell ID may appear on both sides: it would be a checker in two lists
  -- with opposite target requirements, stuck on "no" in one of them.
  local clash = {}
  for _, c in ipairs(CLASSES) do
    local harm = {}
    for _, id in ipairs(addon.HARM_SPELLS[c] or {}) do harm[id] = true end
    for _, name in ipairs({ "FRIEND_SPELLS", "RES_SPELLS", "PET_ONLY_SPELLS" }) do
      for _, id in ipairs(addon[name][c] or {}) do
        if harm[id] then clash[#clash + 1] = ("%s:%d in HARM and %s"):format(c, id, name) end
      end
    end
  end
  checks = checks + 1
  if #clash > 0 then
    failures = failures + 1
    print(("  FAIL  %s"):format(table.concat(clash, ", ")))
  else
    print("  ok    no spell is listed as both harmful and helpful")
  end
end

----------------------------------------------------------------------
-- Scenario 1: a mage — plenty of spells, plenty of cached items
----------------------------------------------------------------------

print("\n== mage, spells + items ==")
DefSpell(133, "Fireball", 0, 35, true)
DefSpell(116, "Frostbolt", 0, 30, true)
DefSpell(2136, "Fire Blast", 0, 20, true)
DefSpell(5019, "Shoot", 8, 30, true)      -- wand: has a minimum range
DefSpell(118, "Polymorph", 0, 30, true)
DefSpell(1459, "Arcane Intellect", 0, 30, false)
DefSpell(168, "Frost Armor", 0, nil, false)  -- self buff, no range at all

CacheItem(1191, 20)     -- harm 20
CacheItem(835, 30)      -- harm 30
CacheItem(4945, 40)     -- harm 40
CacheItem(8149, 5)      -- harm 5
CacheItem(9606, 10)     -- harm 10
CacheItem(1251, 15)     -- friend 15
CacheItem(954, 30)      -- friend 30
CacheItem(1713, 40)     -- friend 40

RELATION = "harm"
addon.RC:Rebuild()
dump("harm")
dump("friend")

expect("inside everything", 3, 0, 5)
expect("between 5 and 10", 7, 5, 10)
expect("between 20 and 30", 24, 20, 30)
expect("between 35 and 40", 37, 35, 40)
expect("past the longest check", 55, 40, nil)
sane("harm brackets")
-- Fireball at 35 sets the reach; the 40y item bucket is a checker, not a
-- statement of how far a mage can fight.
expectBands("mage bands off Fireball, not the 40y item", "harm", 0, 26.25, 35)

----------------------------------------------------------------------
-- Scenario 2: friendly target, and the in-combat restriction
----------------------------------------------------------------------

print("\n== friendly target ==")
RELATION = "friend"
expect("out of combat, item buckets available", 22, 15, 30)
sane("friend brackets, out of combat")

IN_COMBAT = true
print("  (in combat: items and interact checks are refused on friendlies)")
expect("in combat, spells only", 22, 0, 30)
expect("in combat, past the only spell", 44, 30, nil)
sane("friend brackets, in combat")
IN_COMBAT = false

----------------------------------------------------------------------
-- Scenario 3: a hunter — every ranged attack has a minimum range
----------------------------------------------------------------------

print("\n== hunter, minimum-range spells ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "HUNTER"
DefSpell(75, "Auto Shot", 5, 35, true)
DefSpell(3044, "Arcane Shot", 5, 35, true)
DefSpell(1130, "Hunter's Mark", 0, 100, true)
-- The client calls these helpful, but they only ever land on your own pet.
DefSpell(136, "Mend Pet", 0, 45, false)
DefSpell(982, "Revive Pet", 0, 45, false)
CacheItem(8149, 5)      -- harm 5
CacheItem(1191, 20)     -- harm 20

RELATION = "harm"
addon.RC:Rebuild()
dump("harm")

-- Auto Shot answers "no" both beyond 35y and inside 5y. Paired with the 5y item
-- check it stays monotone, so standing in melee must not read as "35+".
expect("inside the spell's minimum range", 2, 0, 5)
expect("in the usable band", 25, 20, 35)
expect("past it", 50, 35, 100)
sane("hunter brackets")

local function hasSource(listName, needle)
  for _, e in ipairs(listOf(listName) or {}) do
    if e.source:find(needle, 1, true) then return true end
  end
  return false
end

local function assertTrue(label, got, want)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    print(("  FAIL  %-38s got %s, want %s"):format(label, tostring(got), tostring(want)))
  else
    print(("  ok    %s"):format(label))
  end
end

dump("friend")
dump("pet")
-- A pet-only spell in the friendly list is a checker stuck on "no" for every
-- unit that isn't your pet, which drags the whole estimate out with it.
assertTrue("Mend Pet kept out of the friendly list", hasSource("friend", "Mend Pet"), false)
assertTrue("Mend Pet used for the pet list", hasSource("pet", "Mend Pet"), true)
assertTrue("Revive Pet kept out of both", hasSource("friend", "Revive Pet") or hasSource("pet", "Revive Pet"), false)

-- Hunter's Mark reaches 100 yards and is a fine checker, but a hunter does not
-- fight at 100 yards. The 40y cap keeps it out of the band maths, and Auto
-- Shot's 5y minimum becomes the amber dead zone.
expectBands("hunter bands ignore the 100y utility cast", "harm", 5, 26.25, 35)

----------------------------------------------------------------------
-- Scenario 4: nothing cached, no classification API
----------------------------------------------------------------------

print("\n== warrior, no items cached, no spell classifier ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "WARRIOR"
DefSpell(355, "Taunt", 0, 30, true)
DefSpell(772, "Rend", 0, 0, true)         -- melee, and NOT in the hint table
DefSpell(100, "Charge", 8, 25, true)

-- Drop the classifier before loading, so the hint tables are the only source.
C_Spell.IsSpellHarmful, C_Spell.IsSpellHelpful = nil, nil
addon = LoadAddon()

RELATION = "harm"
addon.RC:Rebuild()
dump("harm")
print(("        classification source: %s"):format(addon.RC.stats.classified))
-- Taunt and Charge are in the hint table; Rend is not, so the melee bucket goes
-- with it and the interact checks carry the short end instead.
expect("interact fallback covers the short end", 6, 0, 8)
expect("between the duel check and Charge", 20, 8, 25)
expect("past everything", 40, 30, nil)
sane("warrior brackets")
-- A warrior is banded against melee, not against Throw: green means "in melee",
-- and everything out to Taunt's 30 yards is the approach.
expectBands("warrior bands against melee, not Taunt", "harm", 0, 2, 30)

----------------------------------------------------------------------
-- Scenario 5: a priest — the corpse case
----------------------------------------------------------------------

print("\n== priest, living friendly vs corpse ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "PRIEST"
C_Spell.IsSpellHarmful = function(id) return SPELLDB[id] and SPELLDB[id].harmful or false end
C_Spell.IsSpellHelpful = function(id) return SPELLDB[id] and not SPELLDB[id].harmful or false end
addon = LoadAddon()

DefSpell(2050, "Lesser Heal", 0, 40, false)
DefSpell(2061, "Flash Heal", 0, 40, false)
DefSpell(585, "Smite", 0, 30, true)
DefSpell(2006, "Resurrection", 0, 30, false, true)   -- corpse only
CacheItem(1251, 15)   -- friend 15
CacheItem(954, 30)    -- friend 30

RELATION = "friend"
addon.RC:Rebuild()
dump("friend")
dump("resurrect")
assertTrue("Resurrection kept out of the friendly list", hasSource("friend", "Resurrection"), false)
assertTrue("Resurrection used for corpses", hasSource("resurrect", "Resurrection"), true)

expect("living friendly", 20, 15, 30)
sane("living friendly brackets")
-- A paladin would be melee-banded against enemies but must not be against
-- friendlies; a priest is caster-banded either way. Heals reach 40.
expectBands("friendly bands off the heal, not melee", "friend", 0, 30, 40)

RELATION = "corpse"
-- Without the corpse branch every heal answers nil here and a body at your feet
-- reads as maximum range.
expect("corpse at your feet", 3, 0, 8)
expect("corpse inside res range", 10, 8, 28)
expect("corpse past res range", 45, 30, nil)
sane("corpse brackets")

----------------------------------------------------------------------
-- Scenario 6: hybrids — form for druids, talents for shamans
----------------------------------------------------------------------

print("\n== druid, banded by shapeshift form ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "DRUID"
FORM_ID = 0                      -- 0 = caster form
function GetShapeshiftFormID() return FORM_ID ~= 0 and FORM_ID or nil end
addon = LoadAddon()

DefSpell(5176, "Wrath", 0, 32, true)
DefSpell(22568, "Ferocious Bite", 0, 0, true)   -- melee
CacheItem(1191, 20)

RELATION = "harm"
addon.RC:Rebuild()
dump("harm")
expectBands("caster form bands against Wrath", "harm", 0, 24, 32)

FORM_ID = 1   -- cat
addon.RC:UpdateBands()
expectBands("cat form bands against melee", "harm", 0, 2, 32)

FORM_ID = 5   -- bear
addon.RC:UpdateBands()
expectBands("bear form still melee", "harm", 0, 2, 32)

FORM_ID = 3   -- travel
addon.RC:UpdateBands()
expectBands("travel form is back to caster", "harm", 0, 24, 32)

FORM_ID = 0
GetShapeshiftFormID = nil

print("\n== shaman, banded by talent tab ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "SHAMAN"

-- Dual spec is real in Classic Era on Season of Discovery and Anniversary
-- realms, so the stub models two talent groups. GetTalentTabInfo's fifth return
-- is pointsSpent, and its fourth *argument* is the group being asked about.
TALENTS = { { 0, 0, 0 }, { 0, 0, 0 } }
ACTIVE_GROUP = 1
function GetNumTalentTabs() return 3 end
function GetActiveTalentGroup() return ACTIVE_GROUP end
function GetTalentTabInfo(i, _, _, group)
  return "tab", "name", nil, "icon", TALENTS[group or 1][i]
end
addon = LoadAddon()

DefSpell(403, "Lightning Bolt", 0, 30, true)
DefSpell(8042, "Earth Shock", 0, 20, true)
CacheItem(1191, 20)

RELATION = "harm"
TALENTS = { { 31, 5, 0 }, { 0, 0, 0 } }     -- group 1: Elemental
addon.RC:Rebuild()
expectBands("elemental bands as a caster", "harm", 0, 22.5, 30)

TALENTS = { { 0, 31, 5 }, { 0, 0, 0 } }     -- group 1: Enhancement
addon.RC:Rebuild()
expectBands("enhancement bands as melee", "harm", 0, 2, 30)

TALENTS = { { 0, 0, 0 }, { 0, 0, 0 } }      -- fresh, nothing spent
addon.RC:Rebuild()
expectBands("untalented stays a caster", "harm", 0, 22.5, 30)

-- The one that matters for dual spec: group 1 is Elemental, group 2 is
-- Enhancement, and the character is sitting in group 2. Reading talents without
-- asking which group is active answers "caster" here, which is the bug.
TALENTS = { { 31, 5, 0 }, { 0, 31, 5 } }
ACTIVE_GROUP = 2
addon.RC:Rebuild()
expectBands("second spec is the one that's read", "harm", 0, 2, 30)

ACTIVE_GROUP = 1
addon.RC:Rebuild()
expectBands("swapping back returns to caster bands", "harm", 0, 22.5, 30)

GetNumTalentTabs, GetTalentTabInfo, GetActiveTalentGroup = nil, nil, nil

----------------------------------------------------------------------
-- Scenario 7: how 1.15.9 actually reports ranges
----------------------------------------------------------------------

-- Taken from a real /hrd dump on a level 18 Orc shaman. On this client
-- C_Spell.GetSpellInfo returns maxRange 0 for every spell, and only the legacy
-- global reports the truth. Preferring the modern call collapsed every caster to
-- a 2-yard melee character — the harm list read "2=spell:Earth Shock" and the
-- readout went red past two yards.
print("\n== 1.15.9 range reporting ==")
SPELLDB, BOOK, ITEM_CACHED, ITEM_RANGE = {}, {}, {}, {}
TEST_CLASS = "SHAMAN"
TALENTS = { { 0, 9, 0 }, { 0, 0, 0 } }   -- Enhancement, as the dump showed
ACTIVE_GROUP = 1
function GetNumTalentTabs() return 3 end
function GetActiveTalentGroup() return ACTIVE_GROUP end
function GetTalentTabInfo(i, _, _, group)
  return "tab", "name", nil, "icon", TALENTS[group or 1][i]
end

-- The legacy global tells the truth, positionally: name, rank, icon, castTime,
-- minRange, maxRange.
function GetSpellInfo(id)
  local s = SPELLDB[id]
  if not s then return nil end
  return s.name, nil, nil, nil, s.minRange, s.maxRange
end

-- ...while the modern call reports zeros, exactly as the live client does.
C_Spell.GetSpellInfo = function(id)
  local s = SPELLDB[id]
  if not s then return nil end
  return { name = s.name, minRange = 0, maxRange = 0 }
end
C_Spell.IsSpellPassive = function(id) return SPELLDB[id] and SPELLDB[id].passive or false end
C_Spell.SpellHasRange = function(id) return SPELLDB[id] and not SPELLDB[id].passive or false end
addon = LoadAddon()

DefSpell(548, "Lightning Bolt", 0, 30, true)
DefSpell(8045, "Earth Shock", 0, 20, true)
DefSpell(370, "Purge", 0, 30, true)
DefSpell(331, "Healing Wave", 0, 40, false)
DefSpell(2008, "Ancestral Spirit", 0, 30, false, true)
-- The Orc racial that ended up in the friendly list at 2 yards.
SPELLDB[196] = { name = "Axe Specialization", minRange = 0, maxRange = 0, passive = true }
BOOK[#BOOK + 1] = 196

CacheItem(1191, 20)
CacheItem(4945, 40)

RELATION = "harm"
addon.RC:Rebuild()
dump("harm")
dump("friend")
dump("resurrect")

expectBands("enhancement shaman is melee-banded", "harm", 0, 2, 30)
assertTrue("Lightning Bolt keeps its real 30y range", hasSource("harm", "Lightning Bolt"), true)
assertTrue("the passive racial is excluded", hasSource("friend", "Axe Specialization"), false)
assertTrue("Ancestral Spirit is still corpse-only", hasSource("friend", "Ancestral Spirit"), false)
expect("a caster range survives", 25, 20, 30)

GetSpellInfo, GetNumTalentTabs, GetTalentTabInfo, GetActiveTalentGroup = nil, nil, nil, nil

----------------------------------------------------------------------

print()
if failures == 0 then
  print(("PASS — %d checks"):format(checks))
else
  print(("FAIL — %d of %d checks failed"):format(failures, checks))
  os.exit(1)
end
