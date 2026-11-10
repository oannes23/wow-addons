-- ItemDataExport · WoW: Forever (Interface 16001, WOW_PROJECT_CAMELOT)
-- Dev tool: resolves (item[, bonus[, modType, modValue]]) tuples to item info, stats and tooltip text in
-- SavedVariables for the AH collector's importer (SPEC.md). No secret values; no Blizzard frames touched.
local addonName, ns = ...
local L = ns.L

local C_Item, C_TooltipInfo, C_Timer = C_Item, C_TooltipInfo, C_Timer
local GetItemInfo, GetItemStats = C_Item.GetItemInfo, C_Item.GetItemStats
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local RequestLoad, IsCached = C_Item.RequestLoadItemDataByID, C_Item.IsItemDataCachedByID
local GetHyperlink = C_TooltipInfo.GetHyperlink
local GetTime, GetServerTime, GetBuildInfo, GetLocale = GetTime, GetServerTime, GetBuildInfo, GetLocale
local pairs, ipairs, next, type, tostring, concat, floor = pairs, ipairs, next, type, tostring, table.concat, math.floor

local MAX_INFLIGHT = 20 -- D-004
local TIMEOUT = 10 -- seconds per load request
local MAX_TRIES = 2 -- load attempts per item (and capture attempts per tuple after a successful load)
local TUPLES_PER_TICK = 100 -- captures per tick from cached items (bounds frame time; ~19 ms/200 under lupa, real C calls cost more)
local TICK = 0.1

local function InitDB()
  ItemDataExportDB = ItemDataExportDB or {}
  local db = ItemDataExportDB
  db.version = db.version or 1
  db.meta = db.meta or {}
  db.items = db.items or {}
  db.results = db.results or {}
  db.failed = db.failed or {}
  ns.db = db
end

local function Input()
  return ns.INPUT or ns.BUILTIN
end

local function Key(t)
  local parts = {}
  for i, v in ipairs(t) do parts[i] = tostring(v) end
  return concat(parts, ":")
end

-- item:<id>:<enchant>:<gem1>:<gem2>:<gem3>:<gem4>:<suffix>:<unique>:<linkLevel>:<spec>:<modMask>:<context>
--   :<numBonus>[:<bonus>...]:<numMods>[:<type>:<value>...]   [WIKI layout; self-verified via clientLink, SPEC D-002]
local function BuildLink(t)
  local id, bonus, modType, modValue = t[1], t[2], t[3], t[4]
  if not bonus and not modType then return "item:" .. id end
  local f = { "item", id, "", "", "", "", "", "", "", "", "", "", "" } -- 11 empty fields after the id
  if bonus then f[#f + 1] = 1; f[#f + 1] = bonus else f[#f + 1] = 0 end
  if modType then f[#f + 1] = 1; f[#f + 1] = modType; f[#f + 1] = modValue end
  return concat(f, ":")
end

local function Plain(tbl, stringsOnly)
  -- Copy scalars only (tooltip lines hold color mixins / nested tables we don't need). Tooltip lines keep strings
  -- only: ~26.6k tuples x ~10 lines would otherwise bloat SavedVariables with per-line numeric fields.
  local out = {}
  for k, v in pairs(tbl) do
    local tv = type(v)
    if tv == "string" or (not stringsOnly and (tv == "number" or tv == "boolean")) then out[k] = v end
  end
  return out
end

local function CaptureBase(id)
  local db = ns.db
  if db.items[id] then return true end
  local name, _, quality, ilvl, minLevel, itype, subType, stack, equipLoc, _, sell, classID, subclassID, bind,
    expansion, _, reagent = GetItemInfo(id)
  if not name then return false end
  db.items[id] = { name = name, quality = quality, ilvl = ilvl, minLevel = minLevel, type = itype,
    subType = subType, stack = stack, equipLoc = equipLoc, sell = sell, classID = classID,
    subclassID = subclassID, bind = bind, expansion = expansion, reagent = reagent }
  return true
end

local function Capture(t, key)
  local link = BuildLink(t)
  local name, clientLink, _, ilvl = GetItemInfo(link)
  if not name then return false end
  local r = { link = link, clientLink = clientLink, name = name, ilvl = ilvl }
  local actual = GetDetailedItemLevelInfo(link)
  if actual then r.actualIlvl = actual end
  local stats = GetItemStats(link)
  if type(stats) == "table" then r.stats = Plain(stats) end
  local data = GetHyperlink(link)
  if type(data) == "table" and type(data.lines) == "table" then
    local tip = {}
    for i, line in ipairs(data.lines) do tip[i] = Plain(line, true) end
    r.tip = tip
  end
  ns.db.results[key] = r
  return true
end

-- Run state (not persisted: rebuilt from input minus results/failed on every /ide start).
local run = { active = false }

local function Counts()
  local db, input = ns.db, Input()
  local done, failed = 0, 0
  for _, t in ipairs(input.tuples) do
    local k = Key(t)
    if db.results[k] then done = done + 1 elseif db.failed[k] then failed = failed + 1 end
  end
  local inflight = 0
  for _ in pairs(run.inflight or {}) do inflight = inflight + 1 end
  return #input.tuples, done, failed, inflight
end

local function Say(msg)
  print("|cff33ff99" .. addonName .. "|r " .. msg)
end

local function Progress()
  local total, done, failed = Counts()
  local pct = total > 0 and floor((done + failed) * 100 / total) or 100
  if pct >= (run.nextPct or 0) then
    Say(L["%d%%: %d resolved, %d failed of %d"]:format(pct, done, failed, total))
    run.nextPct = (floor(pct / 10) + 1) * 10
  end
end

-- Try every pending tuple of one loaded item. Tuples that still return nothing get MAX_TRIES attempts.
local function ProcessItem(id)
  local db = ns.db
  local pending = run.byItem[id]
  if not pending then return end
  CaptureBase(id)
  local left = {}
  for _, p in ipairs(pending) do
    if not Capture(p.t, p.key) then
      p.tries = (p.tries or 0) + 1
      if p.tries >= MAX_TRIES then db.failed[p.key] = "no item info after load" else left[#left + 1] = p end
    end
  end
  if #left > 0 then
    run.byItem[id] = left
    run.queue[#run.queue + 1] = id -- retried by Tick's queue loop (same tick if budget remains), up to MAX_TRIES
  else
    run.byItem[id] = nil
  end
end

local function Finish()
  run.active = false
  if run.ticker then run.ticker:Cancel(); run.ticker = nil end
  ns.db.meta.finished = GetServerTime()
  local total, done, failed = Counts()
  Say(L["done: %d resolved, %d failed of %d. /reload to write SavedVariables."]:format(done, failed, total))
end

local function Tick()
  local now = GetTime()
  for id, req in pairs(run.inflight) do -- timeouts
    if now - req.sent > TIMEOUT then
      run.inflight[id] = nil
      if req.tries >= MAX_TRIES then
        for _, p in ipairs(run.byItem[id] or {}) do ns.db.failed[p.key] = "load timeout" end
        run.byItem[id] = nil
      else
        run.retry[id] = req.tries
        run.queue[#run.queue + 1] = id
      end
    end
  end
  local budget = TUPLES_PER_TICK
  while #run.queue > 0 do
    local id = run.queue[#run.queue]
    if not run.byItem[id] or run.inflight[id] then
      run.queue[#run.queue] = nil
    elseif IsCached(id) then
      if budget <= 0 then break end
      budget = budget - #run.byItem[id]
      run.queue[#run.queue] = nil
      ProcessItem(id)
    else
      local n = 0
      for _ in pairs(run.inflight) do n = n + 1 end
      if n >= MAX_INFLIGHT then break end
      run.queue[#run.queue] = nil
      run.inflight[id] = { sent = now, tries = (run.retry[id] or 0) + 1 }
      RequestLoad(id)
    end
  end
  Progress()
  if #run.queue == 0 and next(run.inflight) == nil then Finish() end
end

local function OnItemLoaded(id, success)
  local req = run.inflight and run.inflight[id]
  if not run.active or not req then return end
  run.inflight[id] = nil
  if success then
    ProcessItem(id)
  elseif req.tries >= MAX_TRIES then
    for _, p in ipairs(run.byItem[id] or {}) do ns.db.failed[p.key] = "load failed (item may not exist)" end
    run.byItem[id] = nil
  else
    run.retry[id] = req.tries
    run.queue[#run.queue + 1] = id
  end
end

local function Start()
  if run.active then Say(L["already running"]); return end
  local db, input = ns.db, Input()
  run.byItem, run.inflight, run.retry, run.queue, run.nextPct = {}, {}, {}, {}, 0
  local n = 0
  for _, t in ipairs(input.tuples) do
    local k = Key(t)
    if not db.results[k] and not db.failed[k] then
      local id = t[1]
      if not run.byItem[id] then
        run.byItem[id] = {}
        run.queue[#run.queue + 1] = id
      end
      local list = run.byItem[id]
      list[#list + 1] = { t = t, key = k }
      n = n + 1
    end
  end
  local build, buildNumber, _, interface = GetBuildInfo()
  db.meta.build, db.meta.buildNumber, db.meta.interface, db.meta.locale = build, buildNumber, interface, GetLocale()
  db.meta.input = { generated = input.generated, source = input.source, n = #input.tuples }
  db.meta.started = db.meta.started or GetServerTime()
  if n == 0 then Say(L["nothing to do (all tuples resolved or failed). /ide reset confirm to start over."]); return end
  Say(L["resolving %d tuples over %d items (input: %s)"]:format(n, #run.queue, tostring(input.generated)))
  run.active = true
  run.ticker = C_Timer.NewTicker(TICK, Tick)
end

local function Stop()
  if not run.active then return end
  run.active = false
  if run.ticker then run.ticker:Cancel(); run.ticker = nil end
  Say(L["stopped; /ide start resumes"])
end

local function Status()
  local total, done, failed, inflight = Counts()
  local input = Input()
  Say(L["input %s (%s): %d tuples; %d resolved, %d failed, %d in flight%s"]:format(
    tostring(input.generated), tostring(input.source), total, done, failed, inflight,
    run.active and L[", running"] or ""))
end

EventUtil.ContinueOnAddOnLoaded(addonName, function()
  InitDB()
  if not ns.INPUT then Say(L["no Data/Pairs.lua: using the builtin smoke set"]) end
end)

local f = CreateFrame("Frame")
f:RegisterEvent("ITEM_DATA_LOAD_RESULT")
f:SetScript("OnEvent", function(_, _, itemID, success) OnItemLoaded(itemID, success) end)

SLASH_ITEMDATAEXPORT1 = "/ide"
SlashCmdList.ITEMDATAEXPORT = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
  if cmd == "start" then Start()
  elseif cmd == "stop" then Stop()
  elseif cmd == "calendar" then ns.DumpCalendar(arg)
  elseif cmd == "reset" then
    if arg ~= "confirm" then Say(L["/ide reset confirm clears all results"]); return end
    Stop()
    local db = ns.db
    db.items, db.results, db.failed, db.meta = {}, {}, {}, {}
    Say(L["results cleared"])
  else Status(); Say("/ide start | stop | status | calendar [months] | reset confirm") end
end

function ItemDataExport_OnCompartmentClick()
  SlashCmdList.ITEMDATAEXPORT("")
end
