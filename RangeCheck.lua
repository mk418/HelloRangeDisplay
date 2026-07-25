local _, addon = ...

-- The range engine. There is no API that returns a distance, so range is
-- bracketed: collect every "is this unit within N yards" test the character can
-- perform, sort them by N, and binary-search for the boundary between the tests
-- that answer yes and the ones that answer no. That gives "between 20 and 30
-- yards" — never an exact figure, and the display never pretends otherwise.

local RC = {}
addon.RC = RC

local floor = math.floor
local tinsert = table.insert

----------------------------------------------------------------------
-- API surface
----------------------------------------------------------------------

-- 1.15.9 moved Classic Era onto the shared modern UI codebase. The namespaced
-- calls are the real ones now; the legacy globals below are kept only so the
-- addon still functions on a pre-1.15.9 client, and their signatures differ —
-- C_Spell.IsSpellInRange takes a spell ID, the old global took a name.
local GetSpellInfo    = C_Spell and C_Spell.GetSpellInfo
local IsSpellInRange  = C_Spell and C_Spell.IsSpellInRange
local IsSpellHarmful  = C_Spell and C_Spell.IsSpellHarmful
local IsSpellHelpful  = C_Spell and C_Spell.IsSpellHelpful
local GetItemInfo     = C_Item and C_Item.GetItemInfo
local IsItemInRange   = C_Item and C_Item.IsItemInRange
local RequestItemData = C_Item and C_Item.RequestLoadItemDataByID

local SPELL_BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or "spell"
local SPELL_ITEM_TYPE = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell

-- What the last rebuild actually managed to use, for /hrd scan.
RC.stats = { spells = 0, items = 0, classified = "none" }

----------------------------------------------------------------------
-- Checker factories
----------------------------------------------------------------------

-- Every checker answers exactly one question: "is unit within my range".
-- Anything other than a definite yes is a no — an ambiguous answer would break
-- the ordering the binary search depends on.

local function SpellChecker(spellID, name)
  if IsSpellInRange then
    return function(unit) return IsSpellInRange(spellID, unit) == true end
  end
  local legacy = _G.IsSpellInRange
  if legacy and name then
    return function(unit) return legacy(name, unit) == 1 end
  end
end

local function ItemChecker(itemID)
  if IsItemInRange then
    return function(unit) return IsItemInRange(itemID, unit) == true end
  end
  local legacy = _G.IsItemInRange
  if legacy then
    return function(unit)
      local r = legacy(itemID, unit)
      return r == true or r == 1
    end
  end
end

local function InteractChecker(index)
  local check = _G.CheckInteractDistance
  if not check then return nil end
  return function(unit) return check(unit, index) and true or false end
end

----------------------------------------------------------------------
-- Spellbook scan
----------------------------------------------------------------------

local function NumSpellBookSpells()
  if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
    local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    if lines == 0 then return 0 end
    local info = C_SpellBook.GetSpellBookSkillLineInfo(lines)
    if not info then return 0 end
    return (info.itemIndexOffset or 0) + (info.numSpellBookItems or 0)
  end
  local tabs = _G.GetNumSpellTabs and _G.GetNumSpellTabs() or 0
  if tabs == 0 then return 0 end
  local _, _, offset, count = _G.GetSpellTabInfo(tabs)
  return (offset or 0) + (count or 0)
end

local function SpellBookSpellID(index)
  if C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
    local info = C_SpellBook.GetSpellBookItemInfo(index, SPELL_BANK)
    if info and (not SPELL_ITEM_TYPE or info.itemType == SPELL_ITEM_TYPE) and not info.isPassive then
      return info.spellID
    end
    return nil
  end
  local itemType, id = _G.GetSpellBookItemInfo(index, "spell")
  if itemType == "SPELL" then return id end
end

-- Ranges are the one thing the modern call gets wrong here: on 1.15.9
-- C_Spell.GetSpellInfo reports maxRange 0 for every spell, which turns every
-- caster into a 2-yard melee character. The legacy global still returns real
-- ranges at positions 5 and 6 — which is why LibRangeCheck reaches for it first
-- and never notices — so both are asked and the larger answer wins. A genuinely
-- melee spell reads 0 from both, and the day the legacy global is finally
-- removed this keeps working off whichever call is still answering.
local function SpellRanges(spellID)
  local name, minRange, maxRange

  local legacy = _G.GetSpellInfo
  if legacy then
    local legacyName, _, _, _, lMin, lMax = legacy(spellID)
    name, minRange, maxRange = legacyName, lMin, lMax
  end

  if GetSpellInfo then
    local info = GetSpellInfo(spellID)
    if info then
      name = name or info.name
      if (info.maxRange or 0) > (maxRange or 0) then
        minRange, maxRange = info.minRange, info.maxRange
      end
    end
  end

  return name, minRange, maxRange
end

-- Passives have no range and can never be cast at anything, so left in they
-- become a checker stuck on "no" — an Orc shaman's Axe Specialization sitting in
-- the friendly list at 2 yards.
local function IsPassive(spellID)
  local check = (C_Spell and C_Spell.IsSpellPassive) or _G.IsPassiveSpell
  return check and check(spellID) and true or false
end

-- Separates a melee ability from something with no range concept at all. Both
-- report range 0; only the melee ability is worth a checker.
local function HasRange(spellID)
  local check = (C_Spell and C_Spell.SpellHasRange) or _G.SpellHasRange
  if not check then return true end
  return check(spellID) and true or false
end

-- true (harmful) / false (helpful) / nil (the client won't say, or says both).
-- Nothing here guesses: an unclassified spell is left to the hint tables rather
-- than being dropped into a list where a wrong side would poison every estimate.
local function Classify(spellID, name)
  local harm, help
  if IsSpellHarmful and IsSpellHelpful then
    harm, help = IsSpellHarmful(spellID), IsSpellHelpful(spellID)
  elseif _G.IsHarmfulSpell and _G.IsHelpfulSpell and name then
    harm, help = _G.IsHarmfulSpell(name), _G.IsHelpfulSpell(name)
  else
    return nil
  end
  harm, help = harm and true or false, help and true or false
  if harm == help then return nil end
  return harm
end

local function Round(n)
  if not n then return nil end
  return floor(n + 0.5)
end

-- Walks the spellbook once and returns:
--   byName  — lowercase name -> entry, holding the longest-ranged known rank
--   harm    — entries the client called harmful
--   friend  — entries the client called helpful
local function ScanSpellbook()
  local byName, harm, friend = {}, {}, {}
  local classified = false

  for index = 1, NumSpellBookSpells() do
    local spellID = SpellBookSpellID(index)
    if spellID and not IsPassive(spellID) then
      local name, minRange, maxRange = SpellRanges(spellID)
      maxRange = Round(maxRange)
      minRange = Round(minRange)
      -- maxRange nil means the spell has no range concept at all (self-buffs,
      -- auras). maxRange 0 is either melee — a perfectly good short bucket — or
      -- something that simply isn't cast at a unit, which HasRange separates.
      if maxRange == 0 then
        maxRange = HasRange(spellID) and addon.MELEE_RANGE or nil
        minRange = nil
      end

      if name and maxRange then
        local key = name:lower()
        local prev = byName[key]
        -- With "show all spell ranks" enabled every rank is its own spellbook
        -- entry, and rank 1 comes first. Keeping the longest-ranged one makes
        -- the choice independent of that setting.
        if not prev or maxRange > prev.maxRange then
          local entry = {
            spellID  = spellID,
            name     = name,
            minRange = (minRange and minRange > 0) and minRange or nil,
            maxRange = maxRange,
          }
          byName[key] = entry
        end
      end
    end
  end

  -- byName is keyed by string, so pairs() order varies run to run. Two spells
  -- with the same range collapse to one checker and whichever arrived first
  -- wins, which would make /hrd scan report a different spell each rebuild for
  -- no reason. Sorting makes the lists reproducible.
  local names = {}
  for key in pairs(byName) do names[#names + 1] = key end
  table.sort(names)

  for _, key in ipairs(names) do
    local entry = byName[key]
    local isHarm = Classify(entry.spellID, entry.name)
    if isHarm ~= nil then
      classified = true
      tinsert(isHarm and harm or friend, entry)
    end
  end

  return byName, harm, friend, classified
end

-- Turns a list of base-rank spell IDs into a set of the spell IDs actually
-- known, via the same name bridge the hints use.
local function Resolve(ids, byName)
  local set = {}
  if not ids then return set end
  for _, id in ipairs(ids) do
    local name = SpellRanges(id)
    local entry = name and byName[name:lower()]
    if entry then set[entry.spellID] = true end
  end
  return set
end

-- Hint lists name base-rank spell IDs; the spellbook holds whatever rank you
-- learned. Resolving through the name bridges the two.
local function AddHints(list, ids, byName, seen)
  if not ids then return end
  for _, id in ipairs(ids) do
    local name = SpellRanges(id)
    local entry = name and byName[name:lower()]
    if entry and not seen[entry.spellID] then
      seen[entry.spellID] = true
      tinsert(list, entry)
    end
  end
end

----------------------------------------------------------------------
-- Checker lists
----------------------------------------------------------------------

-- Descending by range, one checker per distinct range. First writer wins, and
-- callers add in priority order: spells before items, because item and interact
-- checks are blocked on friendly units while you're in combat.
local function AddChecker(list, range, checker, source)
  if not checker or not range or range <= 0 then return end
  for i = 1, #list do
    local e = list[i]
    if e.range == range then return end
    if range > e.range then
      tinsert(list, i, { range = range, checker = checker, source = source })
      return
    end
  end
  list[#list + 1] = { range = range, checker = checker, source = source }
end

local function CheckerWithin(list, minRange, maxRange)
  for i = 1, #list do
    local e = list[i]
    if e.range >= minRange and e.range <= maxRange then return e.checker end
  end
end

local function AddItems(list, buckets)
  local used = 0
  for range, ids in pairs(buckets) do
    for _, id in ipairs(ids) do
      if GetItemInfo and GetItemInfo(id) then
        AddChecker(list, range, ItemChecker(id), "item:" .. id)
        used = used + 1
        break
      end
    end
  end
  return used
end

local function AddInteract(list, interact)
  for index, range in pairs(interact) do
    AddChecker(list, range, InteractChecker(index), "interact:" .. index)
  end
end

-- Spells with a minimum range answer "no" both when the unit is too far *and*
-- when it is too close, which is not a monotone test and would send the binary
-- search to the wrong half of the list. Pairing one with any shorter checker
-- that reaches at least its minimum restores the ordering: "in range, or nearer
-- than my minimum". A spell with no such partner is dropped rather than
-- silently distorting the result.
local function AddSpells(list, spells)
  local deferred = {}
  for _, e in ipairs(spells) do
    if e.minRange then
      deferred[#deferred + 1] = e
    else
      AddChecker(list, e.maxRange, SpellChecker(e.spellID, e.name), "spell:" .. e.name)
    end
  end
  return deferred
end

local function AddDeferredSpells(list, deferred)
  for _, e in ipairs(deferred) do
    local near = CheckerWithin(list, e.minRange, e.maxRange)
    if near then
      local inRange = SpellChecker(e.spellID, e.name)
      if inRange then
        AddChecker(list, e.maxRange, function(unit)
          return inRange(unit) or near(unit)
        end, ("spell:%s (min %d)"):format(e.name, e.minRange))
      end
    end
  end
end

----------------------------------------------------------------------
-- Colour bands
----------------------------------------------------------------------

-- The bands are derived from what this character can actually do, so there is
-- nothing to configure and nothing to go stale. Three numbers per list:
--
--   deadZone    below this you cannot use your longest attack at all
--   comfortMax  you are well inside your range
--   reachMax    past this, nothing you know reaches
--
-- Everything between comfortMax and reachMax is the warning band: still
-- castable, but one step from not being.
local COMFORT_FRACTION = 0.75

-- Is this character fighting in melee right now? Three answers, cheapest first.
--
-- Talent points come from GetTalentTabInfo's *fifth* return in Classic Era, and
-- are read by tab index rather than tab name, so no locale is involved.
local function IsMeleeSpec(class)
  local wanted = addon.MELEE_TALENT_TAB[class]
  local GetTabInfo = _G.GetTalentTabInfo
  if not wanted or not GetTabInfo then return false end

  -- Classic Era does have dual spec, on Season of Discovery and Anniversary
  -- realms, so the active talent group is passed explicitly. Without it the
  -- points read can describe the spec you are not currently in — an Enhancement
  -- shaman sitting in their second spec would be banded as a caster.
  local group = _G.GetActiveTalentGroup and _G.GetActiveTalentGroup() or nil

  local bestPoints, bestTab = 0, nil
  for i = 1, (_G.GetNumTalentTabs and _G.GetNumTalentTabs() or 3) do
    local _, _, _, _, points = GetTabInfo(i, false, false, group)
    if points and points > bestPoints then bestPoints, bestTab = points, i end
  end
  -- An untalented character hasn't said anything yet; leave them a caster.
  return bestTab == wanted
end

local function IsMeleeForm(class)
  local forms = addon.MELEE_FORMS[class]
  local GetFormID = _G.GetShapeshiftFormID
  if not forms or not GetFormID then return false end
  local form = GetFormID()
  return form ~= nil and forms[form] or false
end

function RC:MeleePrimary(class)
  class = class or self.class
  if not class then return false end
  return addon.MELEE_CLASSES[class] or IsMeleeForm(class) or IsMeleeSpec(class) or false
end

local function ComputeBands(list, spells, meleePrimary)
  local cap = addon.COMBAT_RANGE_CAP
  local castMax, castMin

  if spells then
    for _, e in ipairs(spells) do
      if e.maxRange <= cap then
        if not castMax or e.maxRange > castMax then
          castMax, castMin = e.maxRange, e.minRange or 0
        elseif e.maxRange == castMax then
          -- Two spells reaching the same distance: the one that also works up
          -- close wins, because then there is no dead zone to warn about.
          castMin = math.min(castMin, e.minRange or 0)
        end
      end
    end
  end

  -- No spells at all — the misc list, or a character who has learned nothing
  -- yet. The longest checker is then the best statement of reach available.
  local reachMax = castMax or (list[1] and list[1].range)
  if not reachMax then return nil end

  if meleePrimary then
    -- Green means "in melee". Everything out to the longest thing you own
    -- (Throw, Taunt) is the amber-ish approach band, not a comfortable place.
    return { deadZone = 0, comfortMax = addon.MELEE_RANGE, reachMax = reachMax }
  end

  return {
    deadZone   = castMin or 0,
    comfortMax = reachMax * COMFORT_FRACTION,
    reachMax   = reachMax,
  }
end

local function BuildList(spells, items, interact, meleePrimary)
  local list = {}
  local deferred = spells and AddSpells(list, spells) or nil
  local itemsUsed = items and AddItems(list, items) or 0
  -- Interact distances are race-dependent estimates, so they only fill in for a
  -- character that has nothing better. An item bucket beats them every time.
  if interact and itemsUsed == 0 then AddInteract(list, interact) end
  if deferred then AddDeferredSpells(list, deferred) end
  list.bands = ComputeBands(list, spells, meleePrimary)
  return list
end

----------------------------------------------------------------------
-- Rebuild
----------------------------------------------------------------------

RC.harm, RC.friend, RC.friendRestricted = {}, {}, {}
RC.pet, RC.petRestricted, RC.misc = {}, {}, {}
RC.res, RC.resRestricted = {}, {}

function RC:Rebuild()
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")

  local interact = addon.INTERACT_BY_RACE[race] or addon.INTERACT_RANGES

  local byName, harmSpells, rawFriendSpells, classified = ScanSpellbook()

  -- Strip the spells the client called helpful that can't actually be cast on a
  -- living friendly unit — pet-only and resurrection — before they reach the
  -- friendly list. See Ranges.lua for why that matters.
  local petOnly = Resolve(addon.PET_ONLY_SPELLS[class], byName)
  local resOnly = Resolve(addon.RES_SPELLS[class], byName)
  local friendSpells, resSpells = {}, {}
  for _, e in ipairs(rawFriendSpells) do
    if resOnly[e.spellID] then
      resSpells[#resSpells + 1] = e
    elseif not petOnly[e.spellID] then
      friendSpells[#friendSpells + 1] = e
    end
  end
  -- A res spell the classifier never labelled won't be in resSpells yet, so the
  -- hint list still gets its turn. `seen` has to reflect what was actually added.
  local seenRes = {}
  for _, e in ipairs(resSpells) do seenRes[e.spellID] = true end
  AddHints(resSpells, addon.RES_SPELLS[class], byName, seenRes)

  -- The hint tables top up whatever the client classified. When the classifier
  -- is missing entirely they are the whole story, which is why they exist.
  local seenHarm, seenFriend = {}, {}
  for _, e in ipairs(harmSpells) do seenHarm[e.spellID] = true end
  for _, e in ipairs(friendSpells) do seenFriend[e.spellID] = true end
  -- Pre-seeded with the spells just excluded, so no future edit to the hint
  -- tables can put a corpse-only or pet-only spell back into the friendly list.
  for id in pairs(petOnly) do seenFriend[id] = true end
  for id in pairs(resOnly) do seenFriend[id] = true end
  AddHints(harmSpells, addon.HARM_SPELLS[class], byName, seenHarm)
  AddHints(friendSpells, addon.FRIEND_SPELLS[class], byName, seenFriend)

  local petSpells, seenPet = {}, {}
  for _, e in ipairs(friendSpells) do
    petSpells[#petSpells + 1] = e
    seenPet[e.spellID] = true
  end
  AddHints(petSpells, addon.PET_SPELLS[class], byName, seenPet)

  -- Kept so the bands can be recomputed on a form change without walking the
  -- spellbook and re-testing every item bucket again.
  self.class = class
  self.harmSpells = harmSpells

  -- Only the harm list bands against melee: a paladin heals at 40 yards like
  -- anybody else, they just don't fight there.
  local melee = self:MeleePrimary(class)
  self.meleePrimary = melee

  self.harm   = BuildList(harmSpells, addon.HARM_ITEMS, interact, melee)
  self.friend = BuildList(friendSpells, addon.FRIEND_ITEMS, interact)
  self.pet    = BuildList(petSpells, addon.FRIEND_ITEMS, interact)
  -- No items for corpses: item checks don't apply to a dead unit, but the
  -- interact distances still do.
  self.res    = BuildList(resSpells, nil, interact)
  self.misc   = BuildList(nil, nil, interact)

  -- In combat the client refuses item and interact checks against anything you
  -- can't attack, so a friendly unit gets a spell-only list. Without this the
  -- readout would jump to maximum range the moment you were pulled into combat.
  self.friendRestricted = BuildList(friendSpells, nil, nil)
  self.petRestricted    = BuildList(petSpells, nil, nil)
  self.resRestricted    = BuildList(resSpells, nil, nil)

  -- The restricted lists lose their item and interact checkers, but the bands
  -- describe the character, not the list, so combat must not move them.
  self.friendRestricted.bands = self.friend.bands
  self.petRestricted.bands    = self.pet.bands
  self.resRestricted.bands    = self.res.bands

  self.stats.spells = #harmSpells + #friendSpells
  self.stats.items = 0
  for _, e in ipairs(self.harm) do
    if e.source:find("^item") then self.stats.items = self.stats.items + 1 end
  end
  self.stats.classified = classified and "client" or (IsSpellHarmful and "client (nothing matched)" or "hint tables")

  if addon.OnCheckersChanged then addon:OnCheckersChanged() end
end

-- A druid shifts in and out of melee several times a fight, and the only thing
-- that changes is where the bands fall. Recomputing three numbers is cheap;
-- rebuilding the lists for it would not be.
function RC:UpdateBands()
  if not self.harmSpells then return end
  local melee = self:MeleePrimary()
  if melee == self.meleePrimary then return end
  self.meleePrimary = melee
  self.harm.bands = ComputeBands(self.harm, self.harmSpells, melee)
  if addon.OnCheckersChanged then addon:OnCheckersChanged() end
end

----------------------------------------------------------------------
-- Item data
----------------------------------------------------------------------

-- Item info arrives asynchronously and only after somebody asks for it. Ask for
-- everything once, then rebuild when the answers land.
function RC:RequestItems()
  if not RequestItemData then return end
  for _, buckets in ipairs({ addon.FRIEND_ITEMS, addon.HARM_ITEMS }) do
    for _, ids in pairs(buckets) do
      for _, id in ipairs(ids) do
        if not (GetItemInfo and GetItemInfo(id)) then RequestItemData(id) end
      end
    end
  end
end

----------------------------------------------------------------------
-- Query
----------------------------------------------------------------------

local function Search(list, unit)
  local n = #list
  if n == 0 then return nil, nil end

  local lo, hi = 1, n
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    if list[mid].checker(unit) then
      lo = mid + 1
    else
      hi = mid - 1
    end
  end

  if lo > n then
    -- Inside even the shortest check.
    return 0, list[n].range
  elseif lo == 1 then
    -- Outside the longest one; we know a floor and nothing else.
    return list[1].range, nil
  end
  return list[lo].range, list[lo - 1].range
end

local function Result(list, unit)
  local minRange, maxRange = Search(list, unit)
  return minRange, maxRange, list.bands
end

-- Returns minRange, maxRange, bands — or nil when this character owns no test
-- that applies to the unit. maxRange nil means "further than anything we can
-- measure"; bands is what the colour is decided from.
function RC:GetRange(unit)
  if not UnitExists(unit) then return nil, nil end

  local restricted = InCombatLockdown() and not UnitCanAttack("player", unit)

  -- Corpses first: a dead unit is still "assistable", but every heal answers no
  -- on one, so routing it to the friendly list would report maximum range for a
  -- body lying at your feet.
  if UnitIsDeadOrGhost(unit) then
    if UnitCanAssist("player", unit) then
      return Result(restricted and self.resRestricted or self.res, unit)
    end
    if restricted then return nil, nil end
    return Result(self.misc, unit)
  end

  if UnitCanAttack("player", unit) then
    return Result(self.harm, unit)
  elseif UnitIsUnit(unit, "pet") then
    return Result(restricted and self.petRestricted or self.pet, unit)
  elseif UnitCanAssist("player", unit) then
    return Result(restricted and self.friendRestricted or self.friend, unit)
  end

  -- Neutral, or a corpse you can't resurrect: nothing but interact distances,
  -- and not even those while you're in combat.
  if restricted then return nil, nil end
  return Result(self.misc, unit)
end

-- For /hrd scan.
function RC:Lists()
  return {
    { name = "harm", list = self.harm },
    { name = "friend", list = self.friend },
    { name = "friend (in combat)", list = self.friendRestricted },
    { name = "pet", list = self.pet },
    { name = "resurrect", list = self.res },
    { name = "misc", list = self.misc },
  }
end
