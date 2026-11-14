-- Steals: a bounded, click-started scan of the pipeline's curated watchlist (ns.PLAN.steals) for listings far below
-- fair value, plus free harvesting of browse results the player loads. Read-only (SPEC D-033 to D-040): no
-- HasRestrictions API is called here; buying stays Blizzard's Buyout button after the panel's Search hand-off (D-007).
--   keys  : C_AuctionHouse.SearchForItemKeys(itemKeys, sorts), every item, up to CHUNK keys per query; gear adds a
--           second key carrying its item level, since gear browse keys have one
--   Fallback when SearchForItemKeys never answers (this session):
--   class : C_AuctionHouse.SendBrowseQuery{ searchString = "", itemClassFilters = {class} }, non-gear by subclass
--   name  : C_AuctionHouse.SendBrowseQuery{ searchString = name, itemClassFilters = {class} }, gear, one per item
-- All three answer as browse results (AUCTION_HOUSE_BROWSE_RESULTS_UPDATED/ADDED, BrowseResultInfo.minPrice).
local _, ns = ...
local L = ns.L

local pairs, ipairs, type, tostring, pcall = pairs, ipairs, type, tostring, pcall
local floor, huge, format, sort, concat = math.floor, math.huge, string.format, table.sort, table.concat
local GetTime = GetTime

local Steals = {}
ns.Steals = Steals

Steals.MAX_PER_SCAN = 40 -- queries (incl. page requests) per click (D-036)
Steals.RESERVE = 30 -- stop when fewer shared throttle tokens than this are free (D-036)
Steals.GAP = 0.5 -- s between sends
Steals.TIMEOUT = 6 -- s without an answer: skip the query
Steals.CHUNK = 25 -- item keys per SearchForItemKeys
Steals.MAX_PAGES = 2 -- RequestMoreBrowseResults per job
Steals.MAX_ROWS = 5 -- STEAL rows in the panel (D-038)
Steals.SOUND_GAP = 10 -- s between alert sounds
Steals.SOUND_FALLBACK = 3175 -- SOUNDKIT.MAP_PING (Blizzard_SharedXML/Mainline/SoundKitConstants.lua)

local GEAR = { [2] = true, [4] = true } -- Enum.ItemClass.Weapon, Enum.ItemClass.Armor (tools/wowapi.py)
-- Enum.AuctionHouseFilter quality values Blizzard turns on by default (Mainline AUCTION_HOUSE_DEFAULT_FILTERS).
local QUALITY_FILTERS = { "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality",
  "LegendaryQuality", "ArtifactQuality" }

-- Scan state. found/notified live for one AH visit (cleared on close, D-037).
local S = { active = false, queue = {}, qi = 0, sent = 0 }
Steals.state = S
local found, notified = {}, {}
Steals.found = found

local function Say(msg) print("|cff00ccffWuwei|r " .. msg) end
local function Money(c) return ns.Plan.Money(c) end

----------------------------------------------------------------------------------------------------
-- Data
----------------------------------------------------------------------------------------------------
-- The steals block of the active plan, or nil (old plan, or no data): then the whole feature is off.
function Steals.Data()
  local p = ns.Plan.Get()
  local s = p and p.steals
  if type(s) ~= "table" or type(s.items) ~= "table" then return nil end
  return s
end

function Steals.On()
  return ns.db ~= nil and ns.db.enabled and ns.db.steals ~= false and Steals.Data() ~= nil
end

local function Valid(e) return type(e) == "table" and type(e.buyMax) == "number" and type(e.fair) == "number" end

function Steals.Entry(id)
  local s = Steals.Data()
  local e = s and s.items[id]
  return Valid(e) and e or nil
end

function Steals.Count()
  local s, n = Steals.Data(), 0
  if s then for _, e in pairs(s.items) do if Valid(e) then n = n + 1 end end end
  return n
end

local function AHOpen()
  local ahf = _G.AuctionHouseFrame
  return ahf and ahf:IsShown() and ahf or nil
end

local function Refresh() if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end end

local function ItemLink(id)
  local name, link = C_Item.GetItemInfo(id)
  return link or name or C_Item.GetItemNameByID(id) or ("item:" .. id)
end

----------------------------------------------------------------------------------------------------
-- Harvest: any browse reply (ours or the player's) is checked against the watchlist. No queries.
----------------------------------------------------------------------------------------------------
local lastSound = -huge

local function PlayAlert()
  if ns.db.stealsSound == false then return end
  local now = GetTime()
  if now - lastSound < Steals.SOUND_GAP then return end
  local snd, kits = _G.C_Sound, _G.SOUNDKIT
  if snd and snd.PlaySound then
    lastSound = now
    pcall(snd.PlaySound, (kits and kits.MAP_PING) or Steals.SOUND_FALLBACK)
  end
end

local function Notify(id, e, price)
  local pct = floor(price / e.fair * 100 + 0.5)
  Say(format(L["STEAL %s listed at %s · fair %s (%d%%) · alert ≤ %s · Search in the Wuwei panel"], ItemLink(id),
    Money(price), Money(e.fair), pct, Money(e.buyMax)))
end

-- One watched item seen at `price` (lowest minPrice over its keys in this reply). Returns true if newly announced.
function Steals.Observe(id, price, key)
  local e = Steals.Entry(id)
  if not e then return false end
  if S.job and S.job.seen then S.job.seen[id] = true end
  if price > e.buyMax then
    found[id] = nil
    return false
  end
  found[id] = { id = id, price = price, key = key, fair = e.fair, buyMax = e.buyMax, pct = price / e.fair, at = GetTime() }
  if notified[id] == nil or price < notified[id] then
    notified[id] = price
    Notify(id, e, price)
    return true
  end
  return false
end

function Steals.Harvest(results)
  if not (Steals.On() and type(results) == "table") then return 0 end
  local s = Steals.Data()
  local best = {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    local id = key and key.itemID
    if id and s.items[id] and type(r.minPrice) == "number" and (not best[id] or r.minPrice < best[id].minPrice) then
      best[id] = r
    end
  end
  local new = 0
  for id, r in pairs(best) do
    if Steals.Observe(id, r.minPrice, r.itemKey) then new = new + 1 end
  end
  if new > 0 then PlayAlert() end
  return new
end

-- Rows for the panel: deepest discount first, at most `limit`.
function Steals.Rows(limit)
  local out = {}
  if not Steals.On() then return out end
  for _, f in pairs(found) do out[#out + 1] = f end
  sort(out, function(a, b)
    if a.pct ~= b.pct then return a.pct < b.pct end
    return a.id < b.id
  end)
  for i = #out, (limit or Steals.MAX_ROWS) + 1, -1 do out[i] = nil end
  return out
end

----------------------------------------------------------------------------------------------------
-- Jobs
----------------------------------------------------------------------------------------------------
local function ClassJobs(ids, items, jobs)
  local groups, order = {}, {}
  for _, id in ipairs(ids) do
    local e = items[id]
    if type(e.classID) == "number" then
      local k = e.classID .. ":" .. tostring(e.subclassID)
      if not groups[k] then
        groups[k] = { kind = "class", key = "class:" .. k, classID = e.classID, subclassID = e.subclassID, ids = {} }
        order[#order + 1] = k
      end
      local g = groups[k].ids
      g[#g + 1] = id
    end
  end
  sort(order)
  for _, k in ipairs(order) do jobs[#jobs + 1] = groups[k] end
end

-- Item keys for one watched item: the ilvl-0 key, plus (gear, item level cached) the key with its item level. Which
-- one the server matches is [TODO-INGAME]; asking for both costs a key slot, not a query.
local function KeysFor(id, e)
  local AH = C_AuctionHouse
  local keys = { AH.MakeItemKey(id) }
  if GEAR[e.classID] then
    local _, _, _, ilvl = C_Item.GetItemInfo(id)
    if type(ilvl) == "number" and ilvl > 0 then keys[2] = AH.MakeItemKey(id, ilvl) end
  end
  return keys
end

-- Stable job list for the current data. keysOK == false (this session) swaps keys chunks for class groups and gear
-- name searches (D-034).
function Steals.BuildJobs()
  local s = Steals.Data()
  local jobs = {}
  if not s then return jobs end
  local plain, gear = {}, {}
  for id, e in pairs(s.items) do
    if type(id) == "number" and Valid(e) then
      if GEAR[e.classID] then gear[#gear + 1] = id else plain[#plain + 1] = id end
    end
  end
  sort(plain)
  sort(gear)
  if Steals.keysOK ~= false then
    local all = {}
    for _, id in ipairs(plain) do all[#all + 1] = id end
    for _, id in ipairs(gear) do all[#all + 1] = id end
    local ids, keys = {}, {}
    local function flush()
      if #ids > 0 then jobs[#jobs + 1] = { kind = "keys", key = "keys:" .. ids[1], ids = ids, keys = keys } end
      ids, keys = {}, {}
    end
    for _, id in ipairs(all) do
      local ks = KeysFor(id, s.items[id])
      if #keys + #ks > Steals.CHUNK then flush() end
      ids[#ids + 1] = id
      for _, k in ipairs(ks) do keys[#keys + 1] = k end
    end
    flush()
    return jobs
  end
  ClassJobs(plain, s.items, jobs)
  for _, id in ipairs(gear) do
    local e = s.items[id]
    jobs[#jobs + 1] = { kind = "name", key = "name:" .. id, ids = { id }, classID = e.classID, subclassID = e.subclassID }
  end
  return jobs
end

local function Sorts()
  local so = Enum and Enum.AuctionHouseSortOrder
  return { { sortOrder = so and so.Price or 0, reverseSort = false } }
end

local function Filters()
  local f, out = Enum and Enum.AuctionHouseFilter, {}
  if f then for _, name in ipairs(QUALITY_FILTERS) do if f[name] then out[#out + 1] = f[name] end end end
  return out
end

local function ClassFilter(job)
  return { { classID = job.classID, subClassID = job.subclassID } }
end

-- Sends the job's query. Returns false (nothing sent) when a name job's item name isn't cached yet.
local function Send(job)
  local AH = C_AuctionHouse
  if job.kind == "keys" then
    AH.SearchForItemKeys(job.keys, Sorts())
  elseif job.kind == "name" then
    AH.SendBrowseQuery({ searchString = job.name, sorts = Sorts(), filters = Filters(), itemClassFilters = ClassFilter(job) })
  else
    AH.SendBrowseQuery({ searchString = "", sorts = Sorts(), filters = Filters(), itemClassFilters = ClassFilter(job) })
  end
end

----------------------------------------------------------------------------------------------------
-- Scan driver: one query in flight, paced by an OnUpdate ticker while active (never from event handlers).
----------------------------------------------------------------------------------------------------
local ticker

local function Free() return ns.Throttle.Free() end

function Steals.Stop(reason)
  if not S.active then return end
  S.active, S.awaiting, S.result, S.endedAt = false, nil, reason or "stopped", GetTime()
  -- Rotation (D-036): the next scan starts at the first job this one did not finish.
  local nextJob
  for i = math.max(S.qi, 1), #S.queue do
    if not S.queue[i].done then nextJob = S.queue[i] break end
  end
  Steals.cursor = (reason ~= "done" and nextJob) and nextJob.key or nil
  S.job = nil
  if ticker then ticker:SetScript("OnUpdate", nil) end
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  S.foundCount = n
  if reason == "done" or reason == "budget" then
    local tail = ""
    if reason == "budget" then tail = L[" (partial: search budget; Scan again in a minute to continue)"] end
    if (S.namesMissing or 0) > 0 then tail = tail .. format(L[" · %d gear names still loading"], S.namesMissing) end
    Say(format(L["Steals scan: %d found · queries: %d%s."], n, S.sent, tail))
  elseif reason == "player" then
    Say(L["Steals scan stopped because you searched; Scan again to resume."])
  end
  Refresh()
end

-- A job is done: on a complete reply, watched items it did not list are no longer for sale (D-037). A failed reply
-- says nothing about them.
local function FinishJob(job)
  if not job or job.done then return end
  job.done = true
  if job.answered and job.full and not job.failed then
    for _, id in ipairs(job.ids) do if not job.seen[id] then found[id] = nil end end
  end
end

-- SearchForItemKeys stays mute: the rest of this scan (and session) uses class groups and gear name searches (D-034).
local function FallBack()
  Steals.keysOK = false
  Say(L["SearchForItemKeys got no answer; using category and name browse for this session."])
  local q = {}
  for i = 1, S.qi do q[i] = S.queue[i] end
  for _, j in ipairs(Steals.BuildJobs()) do q[#q + 1] = j end
  S.queue = q
end

-- One step of the scan. Returns nothing; safe to call any time.
function Steals.Tick()
  if not S.active then return end
  if not AHOpen() or not Steals.On() then return Steals.Stop("closed") end
  local now = GetTime()
  local job = S.job
  if S.awaiting then
    if now - S.sentAt < Steals.TIMEOUT then return end
    S.awaiting = nil -- no answer: skip this query
    if job and job.kind == "keys" and Steals.keysOK == nil then
      FinishJob(job)
      FallBack()
    else
      S.timeouts = (S.timeouts or 0) + 1
      FinishJob(job)
    end
  end
  if now - (S.lastSend or -huge) < Steals.GAP then return end
  local AH = C_AuctionHouse
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then
    S.waitSince = S.waitSince or now
    if now - S.waitSince > 2 * Steals.TIMEOUT then return Steals.Stop("budget") end
    return
  end
  S.waitSince = nil

  -- More pages for the current job?
  local wantMore = job and job.answered and not job.done and not job.full and job.pages < Steals.MAX_PAGES
  if not wantMore then
    FinishJob(job)
    -- Next job that can be sent (name jobs need a cached item name).
    repeat
      S.qi = S.qi + 1
      job = S.queue[S.qi]
      if job and job.kind == "name" then
        job.name = C_Item.GetItemNameByID(job.ids[1])
        if not job.name then
          C_Item.RequestLoadItemDataByID(job.ids[1])
          S.namesMissing = (S.namesMissing or 0) + 1
          job.done = true
          job = false
        end
      end
    until job ~= false
    S.job = job
    if not job then return Steals.Stop("done") end
  end
  if S.sent >= Steals.MAX_PER_SCAN or Free() < Steals.RESERVE or not ns.Throttle.Take() then
    if not wantMore then S.qi = S.qi - 1 end -- not sent: the next scan starts here
    S.job = S.queue[S.qi]
    return Steals.Stop("budget")
  end
  S.sent, S.lastSend, S.sentAt, S.awaiting = S.sent + 1, now, now, true -- in flight BEFORE the call: replies are synchronous
  local ok, err
  if wantMore then
    job.pages, job.answered = job.pages + 1, false
    ok, err = pcall(AH.RequestMoreBrowseResults)
  else
    job.seen, job.pages, job.answered, job.full = {}, 0, false, false
    ok, err = pcall(Send, job)
  end
  if not ok then
    S.awaiting = nil
    S.errors = (S.errors or 0) + 1
    if job.kind == "keys" and Steals.keysOK == nil then FinishJob(job) FallBack() else FinishJob(job) end
    S.lastError = tostring(err)
  end
  Refresh()
end

-- A browse reply arrived (or failed): the query in flight is answered.
local function Answered(failed)
  local job = S.job
  if not (S.active and S.awaiting and job) then return end
  S.awaiting = nil
  job.answered = true
  job.full = failed and true or C_AuctionHouse.HasFullBrowseResults()
  if failed then job.failed = true end
  if job.kind == "keys" and not failed then Steals.keysOK = true end
end

-- Start a scan (the panel button and `/wuwei steals scan`). Click-started only (D-035).
function Steals.Scan()
  if not (ns.db and ns.db.enabled) then Say(L["Wuwei is toggled off (/wuwei toggle)."]) return false end
  local s = Steals.Data()
  if not s then Say(L["No steals list in the current plan."]) return false end
  if ns.db.steals == false then Say(L["Steals are off (/wuwei steals on)."]) return false end
  if not AHOpen() then Say(L["Open the auction house first."]) return false end
  if S.active then Say(L["Steals scan already running."]) return false end
  local AH = C_AuctionHouse
  if not (AH.SendBrowseQuery and AH.GetBrowseResults and AH.SearchForItemKeys) then
    Say(L["This client lacks the browse API; steals scan unavailable."])
    return false
  end
  local house = ns.House.Detect()
  if s.house and house ~= s.house then
    Say(format(L["The steals list is for house %s; you are at %s. Use /wuwei house %s if detection is wrong."],
      tostring(s.house), tostring(house), tostring(s.house)))
    return false
  end
  local jobs = Steals.BuildJobs()
  if #jobs == 0 then Say(L["No steals list in the current plan."]) return false end
  -- Rotate so this scan starts where the last partial one stopped.
  local start = 1
  for i, j in ipairs(jobs) do if j.key == Steals.cursor then start = i end end
  local q = {}
  for i = start, #jobs do q[#q + 1] = jobs[i] end
  for i = 1, start - 1 do q[#q + 1] = jobs[i] end
  S.queue, S.qi, S.sent, S.job, S.awaiting = q, 0, 0, nil, nil
  S.timeouts, S.errors, S.namesMissing, S.result, S.lastSend, S.waitSince = 0, 0, 0, nil, nil, nil
  S.active, S.startedAt = true, GetTime()
  if ticker then ticker:SetScript("OnUpdate", function() Steals.Tick() end) end
  Steals.Tick()
  return true
end

----------------------------------------------------------------------------------------------------
-- Status text (panel second line, /wuwei status, /wuwei steals)
----------------------------------------------------------------------------------------------------
local function Ago(t) return ns.Plan.AgeText(floor(GetTime() - t)) end

function Steals.StatusText()
  if not Steals.On() then return "" end
  if S.active then return format(L["Steals: scanning %d/%d..."], math.max(S.qi, 1), #S.queue) end
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  if S.endedAt then
    return format(L["Steals: %d found · scanned %s ago · queries: %d%s"], n, Ago(S.endedAt), S.sent,
      S.result == "budget" and L[" · partial"] or (S.result == "player" and L[" · stopped"] or ""))
  end
  if n > 0 then return format(L["Steals: %d found in browsed results · %d watched"], n, Steals.Count()) end
  return format(L["Steals: %d watched · Scan steals to check"], Steals.Count())
end

function Steals.StatusLine()
  local s = Steals.Data()
  if not s then return L["steals: no list in the current plan"] end
  local age = ns.Plan.ParseTime(s.generated)
  return format(L["steals: %s · %d watched (house %s, %s old) · sound %s"], ns.db.steals == false and "off" or "on",
    Steals.Count(), tostring(s.house), age and ns.Plan.AgeText(math.max(0, GetServerTime() - age)) or "?",
    ns.db.stealsSound == false and "off" or "on")
end

-- Tooltip line for an item that is only in the steals list (D-039; the plan line wins elsewhere).
function Steals.TooltipLine(id)
  if not Steals.On() then return nil end
  local e = Steals.Entry(id)
  if not e then return nil end
  local Plan = ns.Plan
  local parts = { Plan.Colorize("STEAL", "STEAL ≤ " .. Money(e.buyMax)),
    "fair " .. Money(e.fair) .. (e.n and (" (n " .. e.n .. ")") or "") }
  if found[id] then parts[#parts + 1] = "live " .. Money(found[id].price) end
  local s = Steals.Data()
  local house = ns.House.Detect()
  if s.house and house ~= s.house then parts[#parts + 1] = "(" .. tostring(s.house) .. ")" end
  local t = Plan.ParseTime(s.generated)
  parts[#parts + 1] = t and Plan.AgeText(math.max(0, GetServerTime() - t)) or "?"
  return "Wuwei: " .. concat(parts, " · ")
end

----------------------------------------------------------------------------------------------------
-- /wuwei steals [on|off|scan|sound [on|off]]
----------------------------------------------------------------------------------------------------
function Steals.Slash(arg)
  local sub, rest = (arg or ""):lower():match("^(%S*)%s*(%S*)")
  if sub == "on" then
    ns.db.steals = true
  elseif sub == "off" then
    ns.db.steals = false
    Steals.Stop("off")
  elseif sub == "scan" then
    Steals.Scan()
    return
  elseif sub == "sound" then
    if rest == "on" then ns.db.stealsSound = true
    elseif rest == "off" then ns.db.stealsSound = false
    else ns.db.stealsSound = ns.db.stealsSound == false end
  elseif sub ~= "" then
    Say(L["usage: /wuwei steals [on | off | scan | sound [on|off]]"])
    return
  end
  Say(Steals.StatusLine())
  local st = Steals.StatusText()
  if st ~= "" then Say(st) end
  Refresh()
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------
-- The player started a browse of their own (search bar, category, re-sort, favorites): stop, don't overwrite it.
function Steals.OnPlayerBrowse()
  if S.active then Steals.Stop("player") end
end

local function Hook(ahf)
  if not ahf or Steals.hooked == ahf then return end
  Steals.hooked = ahf
  local function safe(fn) return function(...) pcall(fn, ...) end end
  if type(ahf.SendBrowseQueryInternal) == "function" then
    hooksecurefunc(ahf, "SendBrowseQueryInternal", safe(Steals.OnPlayerBrowse))
  end
  if type(ahf.QueryAll) == "function" then
    hooksecurefunc(ahf, "QueryAll", safe(function(_, ctx)
      local c = _G.AuctionHouseSearchContext
      if c and ctx == c.AllFavorites then Steals.OnPlayerBrowse() end
    end))
  end
end

-- Gear keys need the item level, and the name fallback needs the name (D-034): ask the client for uncached gear
-- early (client-side item data, not an AH query) so the first scan can use them.
local function PreloadGear()
  local s = Steals.Data()
  if not s then return end
  for id, e in pairs(s.items) do
    if Valid(e) and GEAR[e.classID] and not C_Item.GetItemInfo(id) then C_Item.RequestLoadItemDataByID(id) end
  end
end

local function Clear()
  for k in pairs(found) do found[k] = nil end
  for k in pairs(notified) do notified[k] = nil end
end

local H = {}
function H.AUCTION_HOUSE_SHOW()
  Clear()
  S.endedAt, S.result, S.sent = nil, nil, 0
  Hook(_G.AuctionHouseFrame)
  if Steals.On() then PreloadGear() end
end
function H.AUCTION_HOUSE_CLOSED()
  Steals.Stop("closed")
  Clear()
end
function H.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
  if Steals.On() then Steals.Harvest(C_AuctionHouse.GetBrowseResults()) end
  Answered(false)
end
function H.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(added)
  if Steals.On() then Steals.Harvest(added) end
  Answered(false)
end
function H.AUCTION_HOUSE_BROWSE_FAILURE() Answered(true) end
function H.AUCTION_HOUSE_NEW_RESULTS_RECEIVED(itemKey)
  if itemKey == nil then Answered(false) end -- nil payload = a browse query (doc comment)
end

function Steals.Init()
  if Steals.events then return end
  local ev = CreateFrame("Frame")
  for name in pairs(H) do ev:RegisterEvent(name) end
  ev:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    local ok, err = pcall(H[event], ...)
    if not ok then S.lastError = tostring(err) end
    if event ~= "AUCTION_HOUSE_CLOSED" then Refresh() end
  end)
  Steals.events = ev
  ticker = CreateFrame("Frame")
end
