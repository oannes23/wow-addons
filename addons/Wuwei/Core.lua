-- Wuwei · WoW: Forever (Interface 16001, WOW_PROJECT_CAMELOT)
-- Secret-value rules apply: display secrets via widget sinks; never branch on them.
-- See reference/secret-values.md
local addonName, ns = ...
local L = ns.L

local DEFAULTS = {
  version = 1,
}

local function InitDB()
  WuweiDB = WuweiDB or {}
  local db = WuweiDB
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

SLASH_WUWEI1 = "/wuwei"
SlashCmdList.WUWEI = function(msg)
  print(addonName, msg)
end

function Wuwei_OnCompartmentClick()
  SlashCmdList.WUWEI("")
end
