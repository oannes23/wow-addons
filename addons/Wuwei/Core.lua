-- Wuwei · WoW: Forever (Interface 16001, WOW_PROJECT_CAMELOT)
-- Phase 1: plan data, tooltip line, AH side panel, house detection. Phase 2: post helper, trade ledger. No AH data here is secret-valued.
local addonName, ns = ...
local L = ns.L

local format, tonumber = string.format, tonumber

local DEFAULTS = {
  version = 1,
  enabled = true, -- master switch: tooltip line and panel
  tooltip = true,
  post = true, -- post-helper info box
  house = nil, -- manual override (house id); nil = auto-detect
}

local function InitDB()
  WuweiDB = WuweiDB or {}
  local db = WuweiDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
  ns.db = db
end

local function Say(msg) print("|cff00ccffWuwei|r " .. msg) end

local function Status()
  local Plan, p = ns.Plan, ns.Plan.Get()
  local house, reason = ns.House.Detect()
  local n = 0
  if p and p.items then for _ in pairs(p.items) do n = n + 1 end end
  Say(format("enabled: %s", tostring(ns.db.enabled)))
  Say(format("house: %s (%s)", tostring(house), reason))
  Say(format("plan source: %s | generated: %s | age: %s | items: %d",
    Plan.IsBuiltin() and "BUILTIN SAMPLE (no Data/Plan.lua)" or tostring(p.source), tostring(p and p.generated),
    Plan.AgeText(), n))
  Say(format("plays at this house: %d", #Plan.Plays(house)))
  Say(format("ledger entries: %d | post helper: %s", #ns.Ledger.Entries(), tostring(ns.db.post)))
end

local function Probe()
  local mapID = C_Map.GetBestMapForUnit("player")
  local info = mapID and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  Say(format("uiMapID: %s | mapName: %s | zone: %s | subzone: %s | faction: %s",
    tostring(mapID), tostring(info and info.name), GetZoneText(), GetSubZoneText(), tostring(UnitFactionGroup("player"))))
end

local function OnSlash(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "" or cmd == "status" then
    Status()
  elseif cmd == "house" then
    if ns.House.Set(rest) then
      Say(format("house override: %s", ns.db.house and tostring(ns.db.house) or "auto"))
      if ns.Panel.Refresh then ns.Panel.Refresh() end
    else
      Say("usage: /wuwei house <id|auto>  (111 Alliance, 114 Horde, 117 Blackwater)")
    end
  elseif cmd == "toggle" then
    ns.db.enabled = not ns.db.enabled
    if not ns.db.enabled then ns.Panel.Hide() end
    Say(format("enabled: %s", tostring(ns.db.enabled)))
  elseif cmd == "probe" then
    Probe()
  elseif cmd == "post" then
    ns.db.post = not ns.db.post
    if not ns.db.post then ns.Post.Hide() end
    Say(format("post helper: %s", tostring(ns.db.post)))
  elseif cmd == "ledger" then
    local sub, arg = rest:match("^(%S*)%s*(%S*)")
    if sub == "clear" then
      if arg == "confirm" then
        ns.Ledger.Clear()
        Say("ledger cleared")
      else
        Say("this deletes all ledger entries. Run: /wuwei ledger clear confirm")
      end
    else
      for _, line in ipairs(ns.Ledger.Summary()) do Say(line) end
    end
  else
    Say("usage: /wuwei [status | house <id|auto> | toggle | post | ledger [clear confirm] | probe]")
  end
end

EventUtil.ContinueOnAddOnLoaded(addonName, function()
  InitDB()
  ns.Tooltip.Init()
  ns.Panel.Init()
  ns.Ledger.Init()
  ns.Post.Init()
end)

SLASH_WUWEI1 = "/wuwei"
SlashCmdList.WUWEI = OnSlash

function Wuwei_OnCompartmentClick()
  SlashCmdList.WUWEI("")
end
