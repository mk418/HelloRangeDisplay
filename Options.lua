local _, addon = ...

local panel = CreateFrame("Frame", "HelloRangeDisplayOptionsPanel")
panel.name = "HelloRangeDisplay"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("HelloRangeDisplay")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetWidth(560)
subtitle:SetJustifyH("LEFT")
subtitle:SetText("See how far away your target is, in colours that mean something for your class.")

-- Every control writes straight into the settings table and re-applies, so there
-- is no apply/cancel state to keep in sync.
local function Apply()
  addon.Display:ApplySettings()
end

----------------------------------------------------------------------
-- Widget factories
----------------------------------------------------------------------

-- InterfaceOptionsCheckButtonTemplate survives in 1.15.9 only inside Blizzard's
-- DeprecatedTemplates.xml, where it is UICheckButtonTemplate at 26x26 plus an
-- OnClick sound we overwrite anyway — so inherit the non-deprecated base.
local function MakeCheck(name, label, anchor, relPoint, x, y, get, set)
  local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb:SetPoint("TOPLEFT", anchor, relPoint, x, y)
  _G[name .. "Text"]:SetText(label)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    Apply()
  end)
  cb.getValue = get
  return cb
end

local function SettingCheck(name, label, anchor, relPoint, x, y, key)
  return MakeCheck(name, label, anchor, relPoint, x, y,
    function() return addon:Settings()[key] end,
    function(v) addon:Settings()[key] = v end)
end

local function UnitCheck(name, label, anchor, relPoint, x, y, unitKey)
  return MakeCheck(name, label, anchor, relPoint, x, y,
    function() return addon:UnitSettings(unitKey).enabled end,
    function(v) addon:UnitSettings(unitKey).enabled = v end)
end

local function MakeSlider(name, label, minV, maxV, step, anchor, relPoint, x, y, key, format)
  local sl = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
  sl:SetWidth(200)
  sl:SetPoint("TOPLEFT", anchor, relPoint, x, y)
  sl:SetMinMaxValues(minV, maxV)
  sl:SetValueStep(step)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  _G[name .. "Low"]:SetText(tostring(minV))
  _G[name .. "High"]:SetText(tostring(maxV))
  sl.label, sl.format, sl.settingKey = label, format, key
  sl:SetScript("OnValueChanged", function(self, value)
    -- Snap before storing: dragging reports intermediate values even with
    -- SetObeyStepOnDrag on older builds.
    value = math.floor(value / step + 0.5) * step
    addon:Settings()[key] = value
    _G[name .. "Text"]:SetText(self.label .. ":  " .. self.format:format(value))
    Apply()
  end)
  return sl
end

----------------------------------------------------------------------
-- Layout — display options left, ranges right
----------------------------------------------------------------------

local displayHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
displayHeader:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -20)
displayHeader:SetText("Display")

local enabledCheck = SettingCheck("HelloRangeDisplayOptEnabled",
  "Show the readouts", displayHeader, "BOTTOMLEFT", -2, -8, "enabled")

local lockedCheck = SettingCheck("HelloRangeDisplayOptLocked",
  "Lock the frames (no backdrop, click-through)", enabledCheck, "BOTTOMLEFT", 0, -4, "locked")

local cursorCheck = SettingCheck("HelloRangeDisplayOptCursor",
  "Mouseover readout follows the cursor", lockedCheck, "BOTTOMLEFT", 0, -4, "followCursor")

local unitsHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
unitsHeader:SetPoint("TOPLEFT", cursorCheck, "BOTTOMLEFT", 2, -18)
unitsHeader:SetText("Units")

local targetCheck = UnitCheck("HelloRangeDisplayOptTarget",
  "Target", unitsHeader, "BOTTOMLEFT", -2, -8, "target")

local mouseoverCheck = UnitCheck("HelloRangeDisplayOptMouseover",
  "Mouseover", targetCheck, "BOTTOMLEFT", 0, -4, "mouseover")

local rangeHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
rangeHeader:SetPoint("TOPLEFT", displayHeader, "TOPLEFT", 300, 0)
rangeHeader:SetText("Readout")

local scaleSlider = MakeSlider("HelloRangeDisplayOptScale",
  "Scale", 0.5, 2, 0.05, rangeHeader, "BOTTOMLEFT", 4, -24, "scale", "%.2f")

-- Scale is the only slider. There are no threshold sliders because the bands
-- come from your own spell ranges, and no update-rate slider because the poll is
-- too cheap for the choice to mean anything.
local bandsHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
bandsHeader:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", -4, -34)
bandsHeader:SetText("Colours")

local bandsBody = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
bandsBody:SetPoint("TOPLEFT", bandsHeader, "BOTTOMLEFT", 2, -8)
bandsBody:SetWidth(250)
bandsBody:SetJustifyH("LEFT")
bandsBody:SetSpacing(2)
bandsBody:SetText(
  "|cffff8000Amber|r  too close to use your longest attack\n" ..
  "|cff09dc00Green|r  comfortably in range\n" ..
  "|cffffd100Gold|r   at the edge of your range\n" ..
  "|cffe61013Red|r    nothing you know reaches")

local bandsLive = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
bandsLive:SetPoint("TOPLEFT", bandsBody, "BOTTOMLEFT", 0, -10)
bandsLive:SetWidth(250)
bandsLive:SetJustifyH("LEFT")

----------------------------------------------------------------------
-- Buttons and live state
----------------------------------------------------------------------

local resetPosBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
resetPosBtn:SetSize(130, 22)
resetPosBtn:SetPoint("TOPLEFT", mouseoverCheck, "BOTTOMLEFT", 2, -22)
resetPosBtn:SetText("Reset positions")
resetPosBtn:SetScript("OnClick", function()
  addon.Display:ResetPositions()
  addon:Print("frame positions reset.")
end)

local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
resetBtn:SetSize(130, 22)
resetBtn:SetPoint("LEFT", resetPosBtn, "RIGHT", 8, 0)
resetBtn:SetText("Reset settings")
resetBtn:SetScript("OnClick", function()
  StaticPopup_Show("HELLORANGEDISPLAY_RESET")
end)

-- What the engine actually found on this character. A paladin with one item
-- bucket cached gets coarser brackets than a mage with six, and that's worth
-- being able to see rather than guess at.
local status = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
status:SetPoint("TOPLEFT", resetPosBtn, "BOTTOMLEFT", 0, -14)
status:SetWidth(270)
status:SetJustifyH("LEFT")

local checks = { enabledCheck, lockedCheck, cursorCheck,
                 targetCheck, mouseoverCheck }
local sliders = { scaleSlider }

local function Refresh()
  local s = addon:Settings()
  for _, cb in ipairs(checks) do
    cb:SetChecked(cb.getValue() and true or false)
  end
  for _, sl in ipairs(sliders) do
    local value = s[sl.settingKey] or 0
    sl:SetValue(value)
    _G[sl:GetName() .. "Text"]:SetText(sl.label .. ":  " .. sl.format:format(value))
  end

  local stats = addon.RC.stats
  status:SetText(("Range checks in use: %d spells, %d item buckets.\nSpell classification: %s.\n/hrd scan lists them all.")
    :format(stats.spells, stats.items, stats.classified))

  -- Where those bands actually landed for this character, so the derivation
  -- isn't something you have to take on faith.
  local bands = addon.RC.harm.bands
  if bands then
    local parts = {}
    if bands.deadZone > 0 then
      parts[#parts + 1] = ("amber under %d yd"):format(bands.deadZone)
    end
    parts[#parts + 1] = ("green to %d yd"):format(math.floor(bands.comfortMax))
    parts[#parts + 1] = ("gold to %d yd"):format(bands.reachMax)
    parts[#parts + 1] = "red beyond"
    bandsLive:SetText("Against enemies right now: " .. table.concat(parts, ", ") .. ".")
  else
    bandsLive:SetText("No range checks found for this character yet.")
  end
end

panel:SetScript("OnShow", Refresh)

function addon:RefreshOptions()
  if panel:IsShown() then Refresh() end
end

if Settings and Settings.RegisterCanvasLayoutCategory then
  local category = Settings.RegisterCanvasLayoutCategory(panel, "HelloRangeDisplay")
  -- Do not override category.ID with a string: since 1.15.9,
  -- Settings.OpenToCategory feeds the ID straight into the native
  -- C_SettingsUtil.OpenSettingsPanel, which requires the auto-assigned numeric
  -- ID and errors on anything else.
  Settings.RegisterAddOnCategory(category)
  addon.OptionsCategoryID = category:GetID()
elseif InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(panel)
end

function addon:OpenOptions()
  if Settings and Settings.OpenToCategory and addon.OptionsCategoryID then
    Settings.OpenToCategory(addon.OptionsCategoryID)
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
  end
end
