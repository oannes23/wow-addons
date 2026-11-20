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
  "addons/*/Data/Ladder.lua", -- generated, gitignored
}

read_globals = {
  "AuctionHouseSearchContext",
  "C_AuctionHouse",
  "C_Calendar",
  "C_Container",
  "C_DateAndTime",
  "C_Item",
  "C_Map",
  "C_MerchantFrame",
  "C_QuestLog",
  "C_SuperTrack",
  "C_Timer",
  "C_TooltipInfo",
  "C_TradeSkillUI",
  "CreateFrame",
  "Enum",
  "EventUtil",
  "GameTooltip",
  "GetBindingAction",
  "GetBindingKey",
  "GetBuildInfo",
  "GetCurrentBindingSet",
  "GetCVar",
  "GetInboxHeaderInfo",
  "GetInboxInvoiceInfo",
  "GetInboxNumItems",
  "GetLocale",
  "GetMerchantItemID",
  "GetMerchantNumItems",
  "GetNumTrainerServices",
  "GetProfessionInfo",
  "GetProfessions",
  "GetServerTime",
  "GetSubZoneText",
  "GetTime",
  "GetTrainerServiceCost",
  "GetTrainerServiceInfo",
  "GetTrainerServiceSkillReq",
  "GetZoneText",
  "hooksecurefunc",
  "InCombatLockdown",
  "issecretvalue",
  "ItemLocation",
  "NUM_TOTAL_EQUIPPED_BAG_SLOTS",
  "QuestObjectiveTracker",
  "SaveBindings",
  "SetBinding",
  "time",
  "TooltipDataProcessor",
  "UIParent",
  "UnitFactionGroup",
}

files["addons/Athanor/"] = {
  globals = { "AthanorDB", "Athanor_OnCompartmentClick", "SLASH_ATHANOR1" },
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
