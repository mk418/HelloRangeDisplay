local _, addon = ...

-- RangeDisplay offers focus and arena1-5 as well; neither exists on this client,
-- and the code gating them was most of its unit-handling complexity. Its pet
-- readout is dropped too — it only ever answered "can I still heal my pet",
-- which is a hunter and warlock question and nobody else's. The pet *checker
-- list* stays: your pet can be your target or your mouseover.
addon.UNITS = {
  { key = "target",    unit = "target",    label = "Target",
    event = "PLAYER_TARGET_CHANGED",  x = 0,   y = -100 },
  { key = "mouseover", unit = "mouseover", label = "Mouseover",
    event = "UPDATE_MOUSEOVER_UNIT",  x = 12,  y = -40, cursor = true },
}

-- Four. No range thresholds, because the colour bands are derived from your own
-- spell ranges at rebuild time (see ComputeBands in RangeCheck.lua); no poll
-- rate, because the poll is too cheap for the choice to mean anything; and no
-- alert sound, because red already says it.
local DEFAULTS = {
  enabled      = true,
  locked       = false,
  scale        = 1,
  followCursor = true,
}

local UNIT_DEFAULTS = {
  target    = { enabled = true },
  mouseover = { enabled = true },
}

----------------------------------------------------------------------
-- Saved variables
----------------------------------------------------------------------

-- SavedVariables aren't populated while these files are parsed, so every read
-- goes through an accessor that fills the table in on demand.
local function Store()
  HelloRangeDisplayDB = HelloRangeDisplayDB or {}
  HelloRangeDisplayDB.settings = HelloRangeDisplayDB.settings or {}
  local s = HelloRangeDisplayDB.settings
  for k, v in pairs(DEFAULTS) do
    if s[k] == nil then s[k] = v end
  end
  return s
end

function addon:Settings() return Store() end

function addon:UnitSettings(key)
  HelloRangeDisplayDB = HelloRangeDisplayDB or {}
  HelloRangeDisplayDB.units = HelloRangeDisplayDB.units or {}
  local units = HelloRangeDisplayDB.units
  units[key] = units[key] or {}
  local u = units[key]
  local defaults = UNIT_DEFAULTS[key]
  if defaults then
    for k, v in pairs(defaults) do
      if u[k] == nil then u[k] = v end
    end
  end
  return u
end

function addon:Print(msg)
  print("|cffffd700HelloRangeDisplay:|r " .. msg)
end

----------------------------------------------------------------------
-- Should this unit be shown at all
----------------------------------------------------------------------

-- Friendly units are deliberately not filtered out. The mouseover readout works
-- on raid frames, which is the case it exists for — a healer checking whether
-- somebody is reachable without giving up their target.
function addon:ShouldTrack(unit)
  if not Store().enabled then return false end
  if not UnitExists(unit) then return false end
  if UnitIsUnit(unit, "player") then return false end
  return true
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

-- SPELLS_CHANGED fires several times during a login and again on every rank
-- learned; GET_ITEM_INFO_RECEIVED arrives once per item as the server answers
-- the opening request, which is a few hundred events in a row. Both collapse
-- into one rebuild.
local rebuildQueued = false
local function QueueRebuild()
  if rebuildQueued then return end
  rebuildQueued = true
  C_Timer.After(1, function()
    rebuildQueued = false
    addon.RC:Rebuild()
  end)
end
addon.QueueRebuild = QueueRebuild

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

-- Registering an event the client has never heard of throws, and that is
-- exactly how RangeDisplay's range library died on 1.15.9: one
-- LEARNED_SPELL_IN_TAB in its last statement took the whole file down with it.
-- Anything whose existence depends on the realm gets asked about first.
local function RegisterIfValid(event)
  if C_EventUtils and C_EventUtils.IsEventValid then
    if not C_EventUtils.IsEventValid(event) then return false end
    frame:RegisterEvent(event)
    return true
  end
  return pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("SPELLS_CHANGED")
    frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
    frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    -- Dual spec reached Era on Season of Discovery and Anniversary realms; on
    -- the original ones this event doesn't exist and the call is a no-op.
    RegisterIfValid("ACTIVE_TALENT_GROUP_CHANGED")
    for _, def in ipairs(addon.UNITS) do
      frame:RegisterEvent(def.event)
    end

    addon.RC:RequestItems()
    addon.RC:Rebuild()
    addon.Display:ApplySettings()
    return
  end

  -- A spec swap is a full rebuild, not just a band recompute: talents move
  -- spell ranges (Destructive Reach, Hawk Eye) as well as deciding whether you
  -- fight in melee.
  if event == "SPELLS_CHANGED" or event == "CHARACTER_POINTS_CHANGED"
      or event == "ACTIVE_TALENT_GROUP_CHANGED"
      or event == "GET_ITEM_INFO_RECEIVED" then
    QueueRebuild()
    return
  end

  -- A druid entering cat form is now a melee character and its colour bands say
  -- so. Only the bands move, so this is not a rebuild — and it costs nothing for
  -- the warrior stance-dancing next to them, whose answer can't change.
  if event == "UPDATE_SHAPESHIFT_FORM" then
    addon.RC:UpdateBands()
    return
  end

  -- PLAYER_ENTERING_WORLD and the target-changed events all mean the same thing
  -- here: re-check which readouts belong on screen.
  addon.Display:UnitsChanged()
end)

function addon:OnCheckersChanged()
  if addon.Display then addon.Display:Refresh() end
  if addon.RefreshOptions then addon:RefreshOptions() end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------

local function DumpScan()
  local rc = addon.RC
  addon:Print(("%d spells, %d item buckets; spell classification from %s.")
    :format(rc.stats.spells, rc.stats.items, rc.stats.classified))
  local bands = rc.harm.bands
  if bands then
    print(("  |cffffd700bands (enemies):|r amber under %d, green under %.1f, red past %d")
      :format(bands.deadZone, bands.comfortMax, bands.reachMax))
  end
  for _, entry in ipairs(rc:Lists()) do
    local list = entry.list
    if #list == 0 then
      print(("  |cff888888%s:|r nothing"):format(entry.name))
    else
      local parts = {}
      for i = 1, #list do
        parts[i] = ("%d (%s)"):format(list[i].range, list[i].source)
      end
      print(("  |cffffd700%s:|r %s"):format(entry.name, table.concat(parts, ", ")))
    end
  end
  for _, def in ipairs(addon.UNITS) do
    if UnitExists(def.unit) then
      local minRange, maxRange = rc:GetRange(def.unit)
      print(("  |cff66ff66%s|r (%s): %s"):format(
        def.label, UnitName(def.unit) or "?",
        minRange and ((maxRange and ("%d - %d"):format(minRange, maxRange))
          or ("%d +"):format(minRange)) or "no estimate"))
    end
  end
end

----------------------------------------------------------------------
-- Diagnostic snapshot
----------------------------------------------------------------------

-- WoW's chat window can't be selected or copied out of, so anything worth
-- reporting has to leave the game as saved variables instead. This records the
-- things that can't be verified outside the client — which APIs exist, what the
-- talent calls actually return, where the bands landed — into
-- HelloRangeDisplayDB.scans, which the client flushes to disk on /reload or
-- logout.
local MAX_SNAPSHOTS = 10

local function CaptureTalents()
  local GetTabInfo = _G.GetTalentTabInfo
  if not GetTabInfo then return nil end
  local groups = (_G.GetNumTalentGroups and _G.GetNumTalentGroups()) or 1
  local tabs = (_G.GetNumTalentTabs and _G.GetNumTalentTabs()) or 3
  local out = {}
  for g = 1, groups do
    local group = {}
    for t = 1, tabs do
      -- Every return value, not just the one we use. This is how the
      -- "pointsSpent is the fifth return" assumption gets checked rather than
      -- trusted.
      local raw = { GetTabInfo(t, false, false, g) }
      local cells = {}
      for i = 1, 8 do cells[i] = tostring(raw[i]) end
      group[t] = table.concat(cells, " | ")
    end
    out[g] = group
  end
  return out
end

local function CaptureLists()
  local out = {}
  for _, entry in ipairs(addon.RC:Lists()) do
    local parts = {}
    for i, e in ipairs(entry.list) do
      parts[i] = ("%d=%s"):format(e.range, e.source)
    end
    out[entry.name] = table.concat(parts, ", ")
  end
  return out
end

local function CaptureSpells(spells)
  local out = {}
  for _, e in ipairs(spells or {}) do
    out[#out + 1] = ("%s (%d) %s-%s"):format(
      e.name or "?", e.spellID or 0, tostring(e.minRange or 0), tostring(e.maxRange))
  end
  return out
end

local function RecordSnapshot()
  local rc = addon.RC
  rc:Rebuild()

  local version, build, _, tocversion = GetBuildInfo()
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  local bands = rc.harm.bands

  HelloRangeDisplayDB = HelloRangeDisplayDB or {}
  HelloRangeDisplayDB.scans = HelloRangeDisplayDB.scans or {}
  local scans = HelloRangeDisplayDB.scans

  scans[#scans + 1] = {
    when      = date and date("%Y-%m-%d %H:%M:%S") or nil,
    client    = ("%s build %s toc %s"):format(tostring(version), tostring(build), tostring(tocversion)),
    character = ("%s / %s %s / level %s"):format(
      tostring(UnitName("player")), tostring(race), tostring(class), tostring(UnitLevel("player"))),
    season    = C_Seasons and C_Seasons.GetActiveSeason and C_Seasons.GetActiveSeason() or "none",

    api = {
      IsSpellHarmful        = (C_Spell and C_Spell.IsSpellHarmful) ~= nil,
      IsSpellHelpful        = (C_Spell and C_Spell.IsSpellHelpful) ~= nil,
      IsSpellInRange        = (C_Spell and C_Spell.IsSpellInRange) ~= nil,
      GetActiveTalentGroup  = _G.GetActiveTalentGroup ~= nil,
      GetNumTalentGroups    = _G.GetNumTalentGroups ~= nil,
      GetShapeshiftFormID   = _G.GetShapeshiftFormID ~= nil,
      CheckInteractDistance = _G.CheckInteractDistance ~= nil,
      IsEventValid          = (C_EventUtils and C_EventUtils.IsEventValid) ~= nil,
    },

    classification = rc.stats.classified,
    meleePrimary   = rc.meleePrimary,
    activeGroup    = _G.GetActiveTalentGroup and _G.GetActiveTalentGroup() or "n/a",
    numGroups      = _G.GetNumTalentGroups and _G.GetNumTalentGroups() or "n/a",
    form           = _G.GetShapeshiftFormID and (_G.GetShapeshiftFormID() or "none") or "n/a",
    -- "index: v1 | v2 | ... | v8" per tab, per talent group
    talents        = CaptureTalents(),

    bands = bands and ("deadZone %s, comfortMax %s, reachMax %s")
      :format(bands.deadZone, bands.comfortMax, bands.reachMax) or "none",

    harmSpells = CaptureSpells(rc.harmSpells),
    lists      = CaptureLists(),
  }

  while #scans > MAX_SNAPSHOTS do table.remove(scans, 1) end

  addon:Print(("snapshot %d recorded. Type |cffffd700/reload|r when you've taken "
    .. "the ones you need — nothing reaches disk until then."):format(#scans))
end

StaticPopupDialogs["HELLORANGEDISPLAY_RESET"] = {
  text = "Reset all HelloRangeDisplay settings and frame positions to defaults?",
  button1 = "Reset",
  button2 = "Cancel",
  OnAccept = function()
    HelloRangeDisplayDB = nil
    addon.Display:ApplySettings()
    addon:Print("settings reset.")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

SLASH_HELLORANGEDISPLAY1 = "/hrd"
SLASH_HELLORANGEDISPLAY2 = "/hellorangedisplay"
SlashCmdList["HELLORANGEDISPLAY"] = function(msg)
  -- Leading %s* matters: without it "/hrd  lock" parses as an empty command and
  -- silently toggles the addon instead of running anything.
  local cmd = ((msg or ""):match("^%s*(%S*)") or ""):lower()
  local s = Store()

  if cmd == "" then
    s.enabled = not s.enabled
    addon.Display:ApplySettings()
    addon:Print(s.enabled and "readouts shown." or "readouts hidden.")

  elseif cmd == "config" or cmd == "options" then
    if addon.OpenOptions then addon:OpenOptions() end

  elseif cmd == "lock" or cmd == "unlock" then
    s.locked = (cmd == "lock")
    addon.Display:ApplySettings()
    addon:Print(s.locked and "frames locked."
      or "frames unlocked — drag them, they're labelled.")

  elseif cmd == "resetpos" then
    addon.Display:ResetPositions()
    addon:Print("frame positions reset.")

  elseif cmd == "reset" then
    StaticPopup_Show("HELLORANGEDISPLAY_RESET")

  elseif cmd == "scan" or cmd == "status" then
    DumpScan()

  elseif cmd == "dump" then
    RecordSnapshot()

  else
    addon:Print("commands: (none) toggles | config | lock | unlock | resetpos | reset | scan | dump")
  end
end
