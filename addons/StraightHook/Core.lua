-- StraightHook · WoW: Forever (Interface 16001). See SPEC.md.
-- Secret-value rules apply: every read that can be secret is guarded; a secret means "skip", never a branch on data.
local addonName, ns = ...
local L = ns.L

local DEFAULTS = { version = 1, sound = true, panel = true, house = "both" }
local FINISH_DELAY = 1.0 -- s after the channel stops: loot or "got away" arrive just after

ns.S = { fishing = false, bobberGUID = nil }
local S = ns.S

local function Say(msg) print("|cff66ccffStraightHook|r " .. msg) end
ns.Say = Say
local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function InitDB()
  StraightHookDB = StraightHookDB or {}
  local db = StraightHookDB
  for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
  db.names = db.names or {}
  db.spots = db.spots or {}
  db.probe = db.probe or { on = false, casts = 0, pre = {}, base = {} }
  ns.db = db
end

----------------------------------------------------------------------------------------------------
-- Fishing detection
----------------------------------------------------------------------------------------------------
local fishingName = PROFESSIONS_FISHING or FISHING or "Fishing"

function ns.IsFishingSpell(spellID)
  if spellID == nil or Secret(spellID) then return false end
  local name = C_Spell.GetSpellName(spellID)
  return name ~= nil and not Secret(name) and name == fishingName
end

local outcome -- the current cast's outcome for the probe ("caught" | "escaped" | nil)
local castSeq = 0
local pending -- the previous cast's finisher, while its FINISH_DELAY runs

local function Flush() if pending then pending() end end

local function OnCastStart()
  Flush() -- a quick recast: settle the previous cast before opening this one
  castSeq = castSeq + 1
  S.fishing, S.bobberGUID, outcome = true, nil, nil
  ns.Log.CastStart()
  ns.Sound.Engage()
  ns.Probe.Start()
  ns.Info.Show()
end

local function OnCastStop()
  if not S.fishing then return end
  S.fishing = false
  local finish
  finish = function()
    if pending ~= finish then return end
    pending = nil
    ns.Probe.Stop(outcome)
    ns.Log.CastFinish()
    ns.Info.Refresh()
  end
  pending = finish
  C_Timer.After(FINISH_DELAY, function() if pending == finish then finish() end end)
  ns.Sound.ScheduleRestore()
  ns.Info.HideLater()
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------
local H = {}

function H.UNIT_SPELLCAST_CHANNEL_START(unit, _, spellID)
  if unit == "player" and ns.IsFishingSpell(spellID) then OnCastStart() end
end

function H.UNIT_SPELLCAST_CHANNEL_STOP(unit, _, spellID)
  if unit ~= "player" or not S.fishing then return end
  if spellID ~= nil and not Secret(spellID) and not ns.IsFishingSpell(spellID) then return end
  OnCastStop()
end

function H.PLAYER_SOFT_INTERACT_CHANGED(_, newTarget)
  if not S.fishing or newTarget == nil or Secret(newTarget) or type(newTarget) ~= "string" then return end
  if newTarget:find("^GameObject%-") then
    S.bobberGUID = newTarget
    local entry = tonumber(newTarget:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
    if entry then ns.db.bobber = ns.db.bobber or {} ns.db.bobber.entry = entry end
  end
end

function H.LOOT_OPENED()
  if not (IsFishingLoot and IsFishingLoot()) then return end
  outcome = "caught"
  ns.Log.Loot()
  ns.Info.Refresh()
end

local function OnMessage(_, message)
  if message == nil or Secret(message) then return end
  if message == ERR_FISH_ESCAPED then
    outcome = "escaped"
    ns.Log.Escaped()
    ns.Info.Refresh()
  elseif message == ERR_FISH_NOT_HOOKED then
    ns.Log.Early()
  end
end
H.UI_ERROR_MESSAGE = OnMessage
H.UI_INFO_MESSAGE = OnMessage

function H.PLAYER_LOGOUT() ns.Sound.Restore() end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...) local fn = H[event] if fn then fn(...) end end)

EventUtil.ContinueOnAddOnLoaded(addonName, function()
  InitDB()
  ns.Sound.Restore() -- a crash or /reload mid-cast left the focus values in place
  for event in pairs(H) do
    if event:find("^UNIT_") then frame:RegisterUnitEvent(event, "player") else frame:RegisterEvent(event) end
  end
  ns.Info.HookTooltip()
end)

----------------------------------------------------------------------------------------------------
-- Slash
----------------------------------------------------------------------------------------------------
local function Status()
  local db = ns.db
  Say(format(L["sound focus %s · panel %s · values %s · probe %s · %d spots logged"], db.sound and "on" or "off",
    db.panel and "on" or "off", db.house == "both" and "Horde + Blackwater" or (ns.Info.HOUSE_NAME[tonumber(db.house)] or db.house),
    db.probe.on and "on" or "off", (function() local n = 0 for _ in pairs(db.spots) do n = n + 1 end return n end)()))
  Say(L["/hook sound on|off · panel on|off|reset · house 114|117|both · probe on|off|report · forget here · show"])
end

local function OnOff(arg, cur) if arg == "on" then return true elseif arg == "off" then return false end return not cur end

SLASH_STRAIGHTHOOK1, SLASH_STRAIGHTHOOK2 = "/hook", "/straighthook"
SlashCmdList.STRAIGHTHOOK = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  local db = ns.db
  if cmd == "sound" then
    db.sound = OnOff(arg, db.sound)
    if not db.sound then ns.Sound.Restore() elseif S.fishing then ns.Sound.Engage() end
    Say(L["sound focus "] .. (db.sound and "on" or "off"))
  elseif cmd == "panel" then
    if arg == "reset" then ns.Info.ResetPos() Say(L["panel position reset"]) return end
    db.panel = OnOff(arg, db.panel)
    if db.panel then ns.Info.Show() else ns.Info.Hide() end
    Say(L["panel "] .. (db.panel and "on" or "off"))
  elseif cmd == "show" then
    for _, line in ipairs(ns.Info.Lines()) do print(line) end
  elseif cmd == "house" then
    if arg == "114" or arg == "117" or arg == "both" then db.house = arg end
    Say(L["values: "] .. db.house)
    ns.Info.Refresh()
  elseif cmd == "probe" then
    if arg == "report" then ns.Probe.Report(Say) return end
    if arg == "reset" then db.probe = { on = db.probe.on, casts = 0, pre = {}, base = {} } Say(L["probe reset"]) return end
    db.probe.on = OnOff(arg, db.probe.on)
    Say(L["probe "] .. (db.probe.on and L["on: fish normally, then /hook probe report"] or "off"))
  elseif cmd == "forget" and arg == "here" then
    local key = ns.Log.Here()
    ns.Log.Forget(key)
    Say(L["forgot this spot"])
    ns.Info.Refresh()
  else
    Status()
  end
end

function StraightHook_OnCompartmentClick() SlashCmdList.STRAIGHTHOOK("") end
