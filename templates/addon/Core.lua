-- __ADDON__ · WoW: Forever (Interface 16001, WOW_PROJECT_CAMELOT)
-- Secret-value rules apply: display secrets via widget sinks; never branch on them.
-- See reference/secret-values.md
local addonName, ns = ...
local L = ns.L

local DEFAULTS = {
  version = 1,
}

local function InitDB()
  __ADDON__DB = __ADDON__DB or {}
  local db = __ADDON__DB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
  ns.db = db
end

local function OnLogin()
  -- Player exists; most character APIs are safe here.
end

EventUtil.ContinueOnAddOnLoaded(addonName, function()
  InitDB()
end)

EventUtil.ContinueOnPlayerLogin(OnLogin)

SLASH___ADDON_UPPER__1 = "/__ADDON_LOWER__"
SlashCmdList.__ADDON_UPPER__ = function(msg)
  print(addonName, msg)
end

function __ADDON___OnCompartmentClick()
  SlashCmdList.__ADDON_UPPER__("")
end
