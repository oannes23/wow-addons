-- Athanor · WoW: Forever (Interface 16001). Profession levelling planner (SPEC.md).
-- No secret-flagged data drives logic; the one event that can carry secrets (UNIT_SPELLCAST_SUCCEEDED) is tested
-- with issecretvalue before any use (Scan.lua, P-017).
local addonName, ns = ...
local L = ns.L
local format = string.format

local DEFAULTS = {
  version = 1,
  shown = true,          -- panel beside the profession window
  includeTrainer = true, -- plan with unlearned trainer recipes (marked Learn)
  house = "both",        -- "both" | 114 | 117
  target = {},           -- [profession] = skill to plan to (else the current cap)
  trainer = {},          -- [recipe spell] = { skill, cost, level, at } from trainer visits (Scan.lua)
  trainerSeen = {},      -- [profession] = highest learn skill a scanned trainer listed (D-003)
  vendor = {},           -- [item] = copper per unit, from merchant visits (Scan.lua)
  log = {},              -- craft log: "time spell skillAtBegin skillAtSuccess" (Scan.lua, D-004)
}

local function InitDB()
  AthanorDB = AthanorDB or {}
  local db = AthanorDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = type(v) == "table" and {} or v end
  end
  ns.db = db
end

-- Planner context for the profession on screen (SPEC D-001).
function ns.Context(state)
  local db, Ld = ns.db or DEFAULTS, ns.LADDER
  local houses = (db.house == 114 or db.house == 117) and { db.house } or (Ld and Ld.houses) or { 114, 117 }
  local deSkill
  local ench = state and state.enchanting
  if type(ench) == "number" and ench > 0 then deSkill = ench end
  return {
    houses = houses, learned = state and state.learned or {}, trainer = db.trainer, trainerSeen = db.trainerSeen,
    vendor = db.vendor,
    deSkill = deSkill, includeTrainer = db.includeTrainer,
  }
end

local function Say(msg) print("|cffd08a3cAthanor|r: " .. msg) end
ns.Say = Say

local function Usage()
  Say(L["/athanor (toggle panel) · target N · target cap · house both|horde|blackwater · trainer on|off · debug"])
end

EventUtil.ContinueOnAddOnLoaded(addonName, function()
  InitDB()
  if ns.Scan then ns.Scan.Init() end
  if ns.Panel then ns.Panel.Init() end
end)

SLASH_ATHANOR1 = "/athanor"
SlashCmdList.ATHANOR = function(msg)
  local db = ns.db
  if not db then return end
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  local state = ns.Scan and ns.Scan.State()
  if cmd == "" then
    db.shown = not db.shown
    Say(db.shown and L["panel on"] or L["panel off"])
  elseif cmd == "target" then
    if not (state and state.prof) then return Say(L["Open a profession first."]) end
    local n = tonumber(arg)
    db.target[state.prof] = (n and n > 0) and math.floor(n) or nil
    Say(db.target[state.prof] and format(L["planning to %d"], db.target[state.prof]) or L["planning to your cap"])
  elseif cmd == "house" then
    db.house = (arg == "horde" and 114) or (arg == "blackwater" and 117) or "both"
    Say(format(L["buying at: %s"], db.house == 114 and L["Horde"] or db.house == 117 and L["Blackwater"] or L["both houses"]))
  elseif cmd == "trainer" then
    db.includeTrainer = arg ~= "off"
    Say(db.includeTrainer and L["planning with trainer recipes"] or L["planning with known recipes only"])
  elseif cmd == "debug" then
    if not (state and state.prof) then return Say(L["Open a profession first."]) end
    ns.Panel.Debug(state)
    return
  else
    return Usage()
  end
  if ns.Panel then ns.Panel.Refresh() end
end

function Athanor_OnCompartmentClick()
  SlashCmdList.ATHANOR("")
end
