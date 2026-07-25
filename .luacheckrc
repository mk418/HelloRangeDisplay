-- luacheck configuration for HelloRangeDisplay (World of Warcraft Classic Era
-- addon). WoW runs on Lua 5.1. From the addon root, run:  luacheck .

std = "lua51"

-- Comment tables and format strings push some lines long; line length is
-- stylistic, not a correctness signal here.
max_line_length = false

-- Silence unused-argument noise: event handlers (event, ...), OnUpdate(self,
-- elapsed) and the implicit `self` all legitimately ignore some parameters.
unused_args = false

ignore = {
    "211/ADDON_NAME",  -- `local _, addon = ...` idiom; name unused in every file
    "432/self",        -- inner callbacks (OnClick/OnDragStart/...) take their own `self`
}

-- True globals this addon owns or mutates. Everything else lives on the `addon`
-- table threaded in via `local _, addon = ...`.
globals = {
    "HelloRangeDisplayDB",   -- SavedVariables
    "SlashCmdList",          -- we install a handler key
    "SLASH_HELLORANGEDISPLAY1",
    "SLASH_HELLORANGEDISPLAY2",
    "StaticPopupDialogs",    -- we install a dialog key
}

-- WoW Classic Era API surface used by the addon. Read-only: indexing is fine,
-- assignment would be a real mistake worth flagging.
read_globals = {
    -- Frames / UI
    "CreateFrame",
    "UIParent",
    "C_Timer",
    "Enum",
    "print",
    "GetCursorPosition",

    "StaticPopup_Show",
    -- Options panel registration (modern, then the pre-1.15.9 fallback)
    "Settings",
    "InterfaceOptions_AddCategory",
    "InterfaceOptionsFrame_OpenToCategory",
    -- Spells and items
    "C_Spell",
    "C_SpellBook",
    "C_Item",
    -- Units and distance
    "UnitClass",
    "UnitRace",
    "UnitName",
    "UnitExists",
    "UnitIsUnit",
    "UnitCanAttack",
    "UnitCanAssist",
    "UnitIsDeadOrGhost",
    "CheckInteractDistance",
    "InCombatLockdown",
    "C_Seasons",
    "GetBuildInfo",
    "UnitLevel",
    "date",
    "C_EventUtils",
}

-- Tests.lua is the offline harness: it runs under plain `lua`, not in the game,
-- and its whole job is to define and mutate a stubbed WoW API. It is not listed
-- in the TOC, so the client never loads it.
files["Tests.lua"] = {
    globals = {
        "C_Spell", "C_SpellBook", "C_Item", "Enum",
        "CheckInteractDistance", "InCombatLockdown",
        "UnitExists", "UnitIsUnit", "UnitCanAttack", "UnitCanAssist",
        "UnitIsDeadOrGhost", "UnitClass", "UnitRace",
        "GetShapeshiftFormID", "GetNumTalentTabs", "GetTalentTabInfo",
        "GetActiveTalentGroup", "GetSpellInfo", "SpellHasRange", "IsPassiveSpell",
        "TEST_CLASS", "FORM_ID", "TALENTS", "ACTIVE_GROUP",
    },
}
