-- QuestTrackerSort · WoW: Forever (Interface 16001, WOW_PROJECT_CAMELOT)
-- Reorders the Quests tracker by rewriting the quest watch list (SPEC D-001).
-- No secret values involved; no Blizzard functions hooked (D-002).
local addonName, ns = ...
local L = ns.L
local Sort, UI = ns.Sort, ns.UI

local DEFAULTS = {
  version = 1,
  mode = "distance",
  interval = 60,
  bucketYards = 50,
  insertMode = "prepend", -- AddQuestWatch inserts at index 1 [INGAME 2026-11-07]; still self-verified (D-006)
  debug = false,
}
local MIN_INTERVAL = 10

local function InitDB()
  QuestTrackerSortDB = QuestTrackerSortDB or {}
  local db = QuestTrackerSortDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
  if db.mode ~= "distance" and db.mode ~= "level" then db.mode = DEFAULTS.mode end
  ns.db = db
end

-- Distance re-check timer: only runs in distance mode (D-004).
local ticker
local function RestartTicker()
  if ticker then ticker:Cancel(); ticker = nil end
  if ns.db.mode == "distance" then
    ticker = C_Timer.NewTicker(ns.db.interval, function() Sort.Apply(false) end)
  end
end

function ns.SetMode(mode)
  if InCombatLockdown() then
    print("|cff88ccffQTS|r", L.MODE_LOCKED_COMBAT)
    return
  end
  ns.db.mode = mode
  UI.UpdateToggle()
  RestartTicker()
  Sort.Apply(true)
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "QUEST_WATCH_LIST_CHANGED" then
    if not Sort.busy then Sort.Schedule(0.5) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    UI.SetLocked(true)
  elseif event == "PLAYER_REGEN_ENABLED" then
    UI.SetLocked(false)
    if Sort.pending then Sort.Schedule(1) end
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
    -- Blizzard calls SortQuestWatches on these; re-apply after it.
    Sort.Schedule(1)
  end
end)

EventUtil.ContinueOnAddOnLoaded(addonName, InitDB)

EventUtil.ContinueOnPlayerLogin(function()
  EventUtil.ContinueOnAddOnLoaded("Blizzard_ObjectiveTracker", UI.Create)
  for _, e in ipairs({ "QUEST_WATCH_LIST_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    events:RegisterEvent(e)
  end
  RestartTicker()
  Sort.Schedule(2)
end)

local function Status()
  print("|cff88ccffQTS|r", L.STATUS:format(ns.db.mode, ns.db.interval, ns.db.insertMode,
    tostring(Sort.unsupported), tostring(Sort.pending)))
end

SLASH_QUESTTRACKERSORT1 = "/qts"
SLASH_QUESTTRACKERSORT2 = "/questtrackersort"
SlashCmdList.QUESTTRACKERSORT = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" or cmd == "toggle" then
    ns.SetMode(ns.db.mode == "level" and "distance" or "level")
    Status()
  elseif cmd == "distance" or cmd == "level" then
    ns.SetMode(cmd)
    Status()
  elseif cmd == "refresh" then
    Sort.Apply(true)
  elseif cmd == "interval" and tonumber(arg) then
    ns.db.interval = math.max(MIN_INTERVAL, tonumber(arg))
    RestartTicker()
    Status()
  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    print("|cff88ccffQTS|r debug", ns.db.debug)
  elseif cmd == "status" then
    Status()
  else
    print("|cff88ccffQTS|r", L.USAGE)
  end
end

function QuestTrackerSort_OnCompartmentClick()
  SlashCmdList.QUESTTRACKERSORT("toggle")
end
