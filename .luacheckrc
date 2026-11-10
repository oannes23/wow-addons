-- luacheck config for WoW: Forever addons (Lua 5.1 dialect)
std = "lua51"
max_line_length = false
codes = true
exclude_files = {
  "reference/",
  ".release/",
  "templates/",
  "addons/*/Data/Plan.lua",   -- generated, gitignored
  "addons/*/Data/Pairs.lua",  -- generated, gitignored
}

read_globals = {
  "AuctionHouseSearchContext",
  "C_AuctionHouse",
  "C_Container",
  "C_Item",
  "C_Map",
  "C_QuestLog",
  "C_SuperTrack",
  "C_Timer",
  "C_TooltipInfo",
  "CreateFrame",
  "Enum",
  "EventUtil",
  "GameTooltip",
  "GetBindingAction",
  "GetBindingKey",
  "GetBuildInfo",
  "GetCVar",
  "GetCurrentBindingSet",
  "GetLocale",
  "GetServerTime",
  "GetSubZoneText",
  "GetTime",
  "GetZoneText",
  "InCombatLockdown",
  "ItemLocation",
  "NUM_TOTAL_EQUIPPED_BAG_SLOTS",
  "QuestObjectiveTracker",
  "SaveBindings",
  "SetBinding",
  "TooltipDataProcessor",
  "UIParent",
  "UnitFactionGroup",
  "hooksecurefunc",
  "issecretvalue",
}

files["addons/ItemDataExport/"] = {
  globals = { "ItemDataExportDB", "ItemDataExport_OnCompartmentClick", "SLASH_ITEMDATAEXPORT1" },
}
files["addons/QuestTrackerSort/"] = {
  globals = { "QuestTrackerSortDB", "QuestTrackerSort_OnCompartmentClick", "SLASH_QUESTTRACKERSORT1", "SLASH_QUESTTRACKERSORT2" },
}
files["addons/Wuwei/"] = {
  globals = { "WuweiDB", "Wuwei_OnCompartmentClick", "Wuwei_Accept", "Wuwei_Skip",
              "BINDING_HEADER_WUWEI", "BINDING_NAME_WUWEI_ACCEPT", "BINDING_NAME_WUWEI_SKIP",
              "SLASH_WUWEI1" },
}
-- every addon may register slash commands
globals = { "SlashCmdList" }
