local _, addon = ...

local Display = {}
addon.Display = Display

local WIDTH, HEIGHT = 112, 36

-- Offset from the cursor for the mouseover readout, in the frame's own units —
-- down and to the right, where a tooltip sits. Deliberately not configurable and
-- deliberately not the frame's drag position: RangeDisplay reuses the dragged
-- position as the cursor offset, so moving the frame while unlocked throws the
-- cursor-anchored readout halfway across the screen.
local CURSOR_X, CURSOR_Y = 24, -24

-- Four answers, and every one of them is about what you can do rather than how
-- many yards away something is: too close to attack, comfortably in range, at
-- the edge of your range, out of reach.
local AMBER = { 1.00, 0.50, 0.00 }
local GREEN = { 0.03, 0.86, 0.00 }
local GOLD  = { 1.00, 0.82, 0.00 }
local RED   = { 0.90, 0.06, 0.08 }

local frames = {}

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------

local function DefaultPoint(def)
  return { point = "CENTER", relPoint = "CENTER", x = def.x, y = def.y }
end

local function RestorePosition(f)
  local p = addon:UnitSettings(f.key).point or DefaultPoint(f.def)
  f:ClearAllPoints()
  f:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
end

local function SavePosition(f)
  local point, _, relPoint, x, y = f:GetPoint(1)
  if point then
    addon:UnitSettings(f.key).point = { point = point, relPoint = relPoint, x = x, y = y }
  end
end

local function CreateReadout(def)
  local f = CreateFrame("Frame", "HelloRangeDisplay" .. def.key, UIParent, "BackdropTemplate")
  f.key, f.def, f.unit = def.key, def, def.unit
  f:SetSize(WIDTH, HEIGHT)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  -- Opt out of WoW's per-character layout cache: position lives in the addon's
  -- own saved variables so it's shared across the account, like the rest of the
  -- family's windows.
  f:SetUserPlaced(false)
  f:SetFrameStrata("MEDIUM")
  f:Hide()

  f:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })

  -- NumberFontNormalHuge is Arial Narrow with an outline, which is the only
  -- outlined family Blizzard ships by name. A readout that sits over the game
  -- world needs the outline, and inheriting a font object keeps the family rule
  -- of never calling SetFont with a path — size comes from the scale slider.
  f.text = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
  f.text:SetPoint("CENTER")
  f.text:SetJustifyH("CENTER")

  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOM", f, "BOTTOM", 0, 3)
  f.label:SetText(def.label)
  f.label:Hide()

  f:SetScript("OnDragStart", function(self)
    if addon:Settings().locked then return end
    self:StartMoving()
  end)

  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false)
    SavePosition(self)
  end)

  return f
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------

-- The bracket is compared at its *far* edge, so a bracket straddling a boundary
-- takes the more cautious colour. Being warned a yard early beats being told
-- you're fine and eating "out of range".
local function BandColor(bands, minRange, maxRange)
  if not bands then return GOLD end
  if bands.deadZone > 0 and maxRange and maxRange <= bands.deadZone then return AMBER end
  if minRange >= bands.reachMax then return RED end
  if maxRange and maxRange <= bands.comfortMax then return GREEN end
  return GOLD
end

local function RefreshOne(f)
  -- Unlocked frames stay on screen with a sample reading so they can be
  -- positioned without having to go and find a target first.
  if not addon:ShouldTrack(f.unit) then
    f.text:SetText("40 - 45")
    f.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    return
  end

  local minRange, maxRange, bands = addon.RC:GetRange(f.unit)

  if not minRange then
    -- No test this character owns applies to this unit. Say nothing rather than
    -- inventing a bracket.
    f.text:SetText("")
    return
  end

  -- Once you're out of reach, exactly *how* far out isn't actionable, and the
  -- long checkers that would resolve it are the least trustworthy ones. Collapse
  -- to a floor instead.
  if bands and minRange >= bands.reachMax then maxRange = nil end

  if maxRange then
    f.text:SetFormattedText("%d - %d", minRange, maxRange)
  else
    f.text:SetFormattedText("%d +", minRange)
  end

  local color = BandColor(bands, minRange, maxRange)
  f.text:SetTextColor(color[1], color[2], color[3])
end

function Display:Refresh()
  for _, f in ipairs(frames) do
    if f:IsShown() then RefreshOne(f) end
  end
end

----------------------------------------------------------------------
-- Visibility
----------------------------------------------------------------------

-- The mouseover unit goes away without an event — you just move the cursor off
-- it — so visibility is re-tested on every tick rather than only when something
-- fires. While unlocked every enabled frame stays put regardless, because it's
-- being dragged into place.
local function ShouldShow(f)
  local s = addon:Settings()
  if not s.enabled then return false end
  if not addon:UnitSettings(f.key).enabled then return false end
  if not s.locked then return true end
  return addon:ShouldTrack(f.unit)
end

local driver = CreateFrame("Frame")
driver:Hide()

function Display:UnitsChanged()
  local any = false
  for _, f in ipairs(frames) do
    if ShouldShow(f) then
      if not f:IsShown() then f:Show() end
      RefreshOne(f)
      any = true
    else
      f:Hide()
    end
  end
  -- No readout on screen means no polling at all. There is no "unit moved"
  -- event, so this tick is the one place the addon spends CPU, and it should
  -- only spend it while something is actually being displayed.
  driver:SetShown(any)
end

----------------------------------------------------------------------
-- Tick
----------------------------------------------------------------------

-- Ten times a second, matching RangeDisplay. Not configurable, because there is
-- nothing to trade off: resolving a unit is a binary search over roughly eleven
-- checkers, so about four API calls, times two readouts, times ten — under a
-- hundred calls a second. No setting makes that meaningfully cheaper, and going
-- slower only makes the number lag behind the target.
local TICK = 0.1

local elapsed = 0

driver:SetScript("OnUpdate", function(_, delta)
  -- Cursor anchoring has to keep up with the mouse, so it runs every frame;
  -- the range estimate itself is throttled to TICK.
  for _, f in ipairs(frames) do
    if f:IsShown() and f.followsCursor then
      -- GetCursorPosition reports screen pixels; SetPoint offsets are in the
      -- frame's own coordinate space, so the scale has to come back out.
      local x, y = GetCursorPosition()
      local scale = f:GetEffectiveScale()
      f:ClearAllPoints()
      f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale + CURSOR_X, y / scale + CURSOR_Y)
    end
  end

  elapsed = elapsed + delta
  if elapsed < TICK then return end
  elapsed = 0

  local any = false
  for _, f in ipairs(frames) do
    if f:IsShown() then
      -- A mouseover unit can vanish silently; anything else can die or become
      -- unattackable while shown.
      if ShouldShow(f) then
        RefreshOne(f)
        any = true
      else
        f:Hide()
      end
    end
  end
  if not any then driver:Hide() end
end)

----------------------------------------------------------------------
-- Settings application
----------------------------------------------------------------------

function Display:ApplySettings()
  local s = addon:Settings()

  if #frames == 0 then
    for _, def in ipairs(addon.UNITS) do
      frames[#frames + 1] = CreateReadout(def)
    end
  end

  for _, f in ipairs(frames) do
    f:SetScale(s.scale or 1)

    -- Locked frames follow the cursor if asked; unlocked ones sit still at the
    -- stored position so there's something to grab.
    f.followsCursor = f.def.cursor and s.locked and s.followCursor

    -- The backdrop and the label are the drag affordance: visible only while
    -- unlocked, so a locked readout is just a number over the world.
    if s.locked then
      f:SetBackdropColor(0, 0, 0, 0)
      f:SetBackdropBorderColor(0, 0, 0, 0)
      f.label:Hide()
    else
      f:SetBackdropColor(0, 0, 0, 0.6)
      f:SetBackdropBorderColor(1, 0.82, 0, 0.6)
      f.label:Show()
    end

    f:EnableMouse(not s.locked)

    if not f.followsCursor then RestorePosition(f) end
  end

  Display:UnitsChanged()
end

function Display:ResetPositions()
  for _, f in ipairs(frames) do
    addon:UnitSettings(f.key).point = nil
    f:SetUserPlaced(false)
  end
  Display:ApplySettings()
end
