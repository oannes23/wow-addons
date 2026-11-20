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
local found, notified, notifiedCheck, verdict = {}, {}, {}, {} -- verdict[id]: the player's own item search (D-051)
Steals.found = found

local function Say(msg) print("|cff00ccffWuwei|r " .. msg) end
local function Money(c) return ns.Plan.Money(c) end

----------------------------------------------------------------------------------------------------
-- Data
----------------------------------------------------------------------------------------------------
local function AHOpen()
  local ahf = _G.AuctionHouseFrame
  return ahf and ahf:IsShown() and ahf or nil
end

local lastHouse -- last house detected at an AH (or confidently elsewhere)

-- The house whose steals block is active (D-050): at an AH, or with a confident detection or `/wuwei house N`, the
-- detected house (remembered); otherwise the last remembered one, else 114.
function Steals.ActiveHouse()
  local h, _, confident = ns.House.Detect()
  if h and (confident or AHOpen()) then lastHouse = h return h end
  if AHOpen() then return h end
  return lastHouse or 114
end

-- The steals block of the active plan, or nil (old plan, no data, or no block for this house): then the feature is off.
-- stealsByHouse (0.5.0) wins; `steals` (the 114 block) serves plans without it.
function Steals.Data()
  local p = ns.Plan.Get()
  if not p then return nil end
  local s
  if type(p.stealsByHouse) == "table" then
    local h = Steals.ActiveHouse()
    s = h and p.stealsByHouse[h]
  else
    s = p.steals
  end
  if type(s) ~= "table" or type(s.items) ~= "table" then return nil end
  return s
end

-- Floor-drop guard of a block: pct, max, or nil when the plan has none (then every alert is a STEAL as before).
local function Near(s)
  local n = s and s.near
  if type(n) == "table" and type(n.pct) == "number" and type(n.max) == "number" then return n.pct, n.max end
end

-- "resell @Horde" when the item sells at another house than the active one, else nil.
local function Resale(e, house)
  if type(e.sell) == "number" and e.sell ~= house then return "resell @" .. ns.Plan.HouseName(e.sell) end
end
function Steals.ResaleText(e) return Resale(e, Steals.ActiveHouse()) end

function Steals.On()
  return ns.db ~= nil and ns.db.enabled and ns.db.steals ~= false and Steals.Data() ~= nil
end

local function Valid(e) return type(e) == "table" and type(e.buyMax) == "number" and type(e.fair) == "number" end

----------------------------------------------------------------------------------------------------
-- Confidence (D-059, owner request 2026-11-20): how likely a found steal resells near fair. A product of three
-- factors in [0, 1], each a plain step table so the chat line can say why:
--   gap    : the next listing above it. After your own item search (depth check) the second-lowest buyout is known:
--            second / fair, scaled so >= 80% of fair is full support (the market agrees with fair), floor 0.3.
--            Before it, only the browse row's listing count: 1 listed 0.8, 2 listed 0.6, more 0.4.
--            The only listing, confirmed by a search: 0.85 (nothing undercuts the resale, nothing confirms fair).
--   fair   : sales behind the fair value (n): >= 20 1.0, >= 8 0.85, >= 3 0.7, else 0.5. A fair taken from asking
--            prices (basis "listings", the pipeline's thin rule, D-060) gets 0.4: weaker than any sales count.
--   resale : sales per day (perDay, from the pipeline): >= 3 1.0, >= 1 0.85, >= 0.3 0.7, else 0.5; unknown 0.75.
--   haul   : resale at another house 0.9 (a trip, a second cut model).
-- high >= 60%, med >= 40%, else low. A heuristic, not a calibrated probability: the step values are judgement until
-- the pipeline backtests them against what cheap listings actually sold for.
----------------------------------------------------------------------------------------------------
Steals.CONF_HIGH, Steals.CONF_MED = 0.6, 0.4
Steals.CONF_LISTINGS = 0.4 -- fair factor for a listing-based fair (D-060)

local function Step(v, steps, otherwise)
  if type(v) ~= "number" then return otherwise end
  for _, s in ipairs(steps) do if v >= s[1] then return s[2] end end
  return steps[#steps][3]
end

-- f: a found row { price, fair, qty, second?, searched?, n?, perDay?, sell?, basis? }. Returns pct (0-100), label, factors.
function Steals.Confidence(f, house)
  local gap
  if f.searched then
    if type(f.second) == "number" and f.second > 0 then
      gap = math.max(0.3, math.min(1, f.second / f.fair / 0.8))
    else
      gap = 0.85
    end
  else
    gap = (f.qty == 1 and 0.8) or (f.qty == 2 and 0.6) or (type(f.qty) == "number" and 0.4) or 0.6
  end
  local fair = f.basis == "listings" and Steals.CONF_LISTINGS or Step(f.n, { { 20, 1.0 }, { 8, 0.85 }, { 3, 0.7, 0.5 } }, 0.7)
  local resale = Step(f.perDay, { { 3, 1.0 }, { 1, 0.85 }, { 0.3, 0.7, 0.5 } }, 0.75)
  local haul = (type(f.sell) == "number" and house and f.sell ~= house) and 0.9 or 1
  local c = gap * fair * resale * haul
  local label = c >= Steals.CONF_HIGH and "high" or (c >= Steals.CONF_MED and "med" or "low")
  return floor(c * 100 + 0.5), label, { gap = gap, fair = fair, resale = resale, haul = haul }
end

local function ConfText(f)
  local pct, label = Steals.Confidence(f, Steals.ActiveHouse())
  return format(L["confidence %d%% (%s)"], pct, L[label])
end
Steals.ConfText = ConfText

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

local function Notify(id, e, price, qty, check, f)
  local house = Steals.ActiveHouse()
  local resale = Resale(e, house)
  local tail = ""
  if resale then
    tail = " · " .. resale .. (e.net and (" (net " .. Money(e.net) .. ")") or "")
  end
  if check then
    Say(format(L["%s at %s (%d listed): may be a falling floor; Search to check depth"], ItemLink(id), Money(price), qty) .. tail)
    return
  end
  local pct = floor(price / e.fair * 100 + 0.5)
  local depth = ""
  if qty and select(2, Near(Steals.Data())) then
    depth = " · " .. (qty == 1 and L["only listing"] or format(L["%d listed"], qty))
  end
  Say(format(L["STEAL %s listed at %s · fair %s (%d%%) · alert ≤ %s · Search in the Wuwei panel"], ItemLink(id),
    Money(price), Money(e.fair), pct, Money(e.buyMax)) .. (e.basis == "listings" and L[" · fair from asking prices"] or "")
    .. depth .. tail .. (f and (" · " .. ConfText(f)) or ""))
end

-- One watched item seen at `price` (lowest minPrice over its keys in this reply, `qty` = that row's totalQuantity).
-- Returns true if a new STEAL was announced (the sound-worthy case; a CHECK is quiet, D-051).
function Steals.Observe(id, price, key, qty)
  local e = Steals.Entry(id)
  if not e then return false end
  if type(price) ~= "number" or price <= 0 then -- not a listing (D-041)
    found[id] = nil
    return false
  end
  if S.job and S.job.seen then S.job.seen[id] = true end
  if price > e.buyMax then
    found[id] = nil
    return false
  end
  local _, nearMax = Near(Steals.Data())
  local check = nearMax ~= nil and type(qty) == "number" and qty > nearMax
  local v = verdict[id]
  if v and v.price ~= price then verdict[id], v = nil, nil end -- the listing it judged is gone or changed
  if v then
    if v.floor then
      found[id] = nil
      return false
    end
    check = false -- depth check confirmed it
  end
  local prev = found[id]
  found[id] = { id = id, price = price, key = key, fair = e.fair, buyMax = e.buyMax, pct = price / e.fair, at = GetTime(),
    qty = qty, check = check or nil, net = e.net, sell = e.sell, n = e.n, perDay = e.perDay, basis = e.basis }
  if v and prev and prev.price == price then -- keep what the depth check learned about this listing (D-059)
    found[id].searched, found[id].second = prev.searched, prev.second
  end
  if notified[id] == nil or price < notified[id] or (notifiedCheck[id] and not check) then
    notified[id], notifiedCheck[id] = price, check
    if not v then Notify(id, e, price, qty, check, found[id]) end
    return not check
  end
  return false
end

function Steals.Harvest(results)
  if not (Steals.On() and type(results) == "table") then return 0 end
  local s = Steals.Data()
  local best, empty = {}, {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    local id = key and key.itemID
    if id and s.items[id] then
      -- SearchForItemKeys (and favorites browse) answer every requested key, including keys with nothing listed:
      -- totalQuantity 0, minPrice 0. Blizzard's list dims those rows ("noneAvailable"). They are not listings (D-041).
      local p, q = r.minPrice, r.totalQuantity
      if type(p) == "number" and p > 0 and (type(q) ~= "number" or q > 0) then
        if not best[id] or p < best[id].minPrice then best[id] = r end
      else
        empty[id] = true
      end
    end
  end
  for id in pairs(empty) do if not best[id] then found[id] = nil end end
  local new = 0
  for id, r in pairs(best) do
    if Steals.Observe(id, r.minPrice, r.itemKey, r.totalQuantity) then new = new + 1 end
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
    if (a.check or false) ~= (b.check or false) then return not a.check end -- verified STEALs above CHECKs
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
    -- Scan order (D-057): the pipeline's rank (best observed yield first), so the first replies cover the items most
    -- likely to be mispriced; unranked items (older plans) follow, non-gear before gear, by item ID as before.
    local all = {}
    for _, id in ipairs(plain) do all[#all + 1] = id end
    for _, id in ipairs(gear) do all[#all + 1] = id end
    local pos = {}
    for i, id in ipairs(all) do pos[id] = i end
    local function rank(id) local r = s.items[id].rank return type(r) == "number" and r or huge end
    sort(all, function(a, b)
      local ra, rb = rank(a), rank(b)
      if ra ~= rb then return ra < rb end
      return pos[a] < pos[b]
    end)
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
  elseif reason == "player" or reason == "search" then
    Say(L["Steals scan stopped because you searched; Scan again to resume."])
  elseif reason == "cancel" then
    Say(L["Steals scan cancelled; Scan again to resume."])
  end
  Refresh()
end

-- Cancel (D-057): the panel's Stop button ("cancel") and every Wuwei Search click ("search", before the search is
-- sent). Stopping first matters: the client's throttled-message queue holds one pending query, and the scan's next
-- send dropped the player's queued item search, leaving Blizzard's buy frame waiting forever [INFER from the
-- AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED/DROPPED events; owner report 2026-11-20]. True when a scan was running.
function Steals.Cancel(reason)
  if not S.active then return false end
  Steals.Stop(reason or "cancel")
  return true
end

function Steals.Active() return S.active end

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
  -- A keys reply holds every requested key (at most CHUNK): it is complete, and RequestMoreBrowseResults after it
  -- only burns queries (D-041). Browse replies page until HasFullBrowseResults.
  job.full = failed and true or job.kind == "keys" or C_AuctionHouse.HasFullBrowseResults()
  if failed then job.failed = true end
  if job.kind == "keys" and not failed then Steals.keysOK = true end
end

-- Start a scan (the panel button and `/wuwei steals scan`). Click-started only (D-035).
function Steals.Scan()
  if not (ns.db and ns.db.enabled) then Say(L["Wuwei is toggled off (/wuwei toggle)."]) return false end
  local s = Steals.Data()
  if not s then
    local p = ns.Plan.Get()
    if p and type(p.stealsByHouse) == "table" then
      Say(format(L["No steals list for house %s."], tostring(Steals.ActiveHouse())))
    else
      Say(L["No steals list in the current plan."])
    end
    return false
  end
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
  if ns.Panel and ns.Panel.SetMode then ns.Panel.SetMode("steals", true) end
  if ticker then ticker:SetScript("OnUpdate", function() Steals.Tick() end) end
  Steals.Tick()
  return true
end

----------------------------------------------------------------------------------------------------
-- Status text (panel second line, /wuwei status, /wuwei steals)
----------------------------------------------------------------------------------------------------
local function Ago(t) return ns.Plan.AgeText(floor(GetTime() - t)) end

function Steals.Stopped()
  local r = S.result
  return r == "player" or r == "search" or r == "cancel"
end

function Steals.StatusText()
  if not Steals.On() then return "" end
  if S.active then return format(L["Steals: scanning %d/%d..."], math.max(S.qi, 1), #S.queue) end
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  if S.endedAt then
    return format(L["Steals: %d found · scanned %s ago · queries: %d%s"], n, Ago(S.endedAt), S.sent,
      S.result == "budget" and L[" · partial"] or (Steals.Stopped() and L[" · stopped"] or ""))
  end
  if n > 0 then return format(L["Steals: %d found in browsed results · %d watched"], n, Steals.Count()) end
  return format(L["Steals: %d watched · Scan steals to check"], Steals.Count())
end

function Steals.StatusLine()
  local s = Steals.Data()
  if not s then
    local p = ns.Plan.Get()
    if p and type(p.stealsByHouse) == "table" then
      return format(L["steals: no list for house %s"], tostring(Steals.ActiveHouse()))
    end
    return L["steals: no list in the current plan"]
  end
  local age = ns.Plan.ParseTime(s.generated)
  return format(L["steals: %s · %d watched (house %s, %s old) · sound %s"], ns.db.steals == false and "off" or "on",
    Steals.Count(), tostring(s.house or Steals.ActiveHouse()), age and ns.Plan.AgeText(math.max(0, GetServerTime() - age)) or "?",
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
  local s = Steals.Data()
  local house = Steals.ActiveHouse()
  local resale = Resale(e, house)
  if resale then parts[#parts + 1] = resale .. (e.net and (" net " .. Money(e.net)) or "") end
  if found[id] then parts[#parts + 1] = "live " .. Money(found[id].price) end
  if s.house and house ~= s.house then parts[#parts + 1] = "(" .. tostring(s.house) .. ")" end
  local t = Plan.ParseTime(s.generated)
  parts[#parts + 1] = t and Plan.AgeText(math.max(0, GetServerTime() - t)) or "?"
  return "Wuwei: " .. concat(parts, " · ")
end

----------------------------------------------------------------------------------------------------
-- /wuwei steals [on|off|scan|stop|sound [on|off]]
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
  elseif sub == "stop" or sub == "cancel" then
    if not Steals.Cancel("cancel") then Say(L["No steals scan running."]) end
    return
  elseif sub == "sound" then
    if rest == "on" then ns.db.stealsSound = true
    elseif rest == "off" then ns.db.stealsSound = false
    else ns.db.stealsSound = ns.db.stealsSound == false end
  elseif sub ~= "" then
    Say(L["usage: /wuwei steals [on | off | scan | stop | sound [on|off]]"])
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
-- Depth check (D-051): the player's own item search (Search click, Blizzard's buy frame) loaded every listing of one
-- watched item. Read them (no query from here) and judge whether a cheap price stands alone or is a falling floor.
local function Lowest(itemKey, pct)
  local AH = C_AuctionHouse
  local ok, n = pcall(AH.GetNumItemSearchResults, itemKey)
  if not (ok and type(n) == "number" and n > 0) then return nil end
  local rows, lowest = {}, huge
  for i = 1, n do
    local okr, r = pcall(AH.GetItemSearchResultInfo, itemKey, i)
    local b = okr and type(r) == "table" and r.buyoutAmount
    if type(b) == "number" and b > 0 then -- bid-only rows have no buyout
      rows[#rows + 1] = { b, type(r.quantity) == "number" and r.quantity > 0 and r.quantity or 1 }
      if b < lowest then lowest = b end
    end
  end
  if #rows == 0 then return nil end
  local cap, count = lowest * (1 + pct / 100), 0
  for _, r in ipairs(rows) do if r[1] <= cap then count = count + r[2] end end
  -- The next price a buyer would pay after the cheapest unit (D-059): another unit of the cheapest row, else the
  -- lowest other row. nil when the cheapest is the only unit listed.
  local second
  for _, r in ipairs(rows) do
    if r[1] == lowest and r[2] > 1 then second = lowest end
  end
  if not second then
    local seenLowest = false
    for _, r in ipairs(rows) do
      if r[1] == lowest and not seenLowest then seenLowest = true
      elseif not second or r[1] < second then second = r[1] end
    end
  end
  return lowest, count, second
end

function Steals.OnItemSearch(itemKey)
  if not Steals.On() or type(itemKey) ~= "table" then return end
  local id = itemKey.itemID
  local e = id and Steals.Entry(id)
  local s = Steals.Data()
  local pct, nearMax = Near(s)
  local AH = C_AuctionHouse
  if not (e and pct and AH.GetNumItemSearchResults and AH.GetItemSearchResultInfo) then return end
  local lowest, count, second = Lowest(itemKey, pct)
  if not lowest then return end
  local partial = false
  if AH.HasFullItemSearchResults then
    local ok, full = pcall(AH.HasFullItemSearchResults, itemKey)
    partial = ok and full == false
  end
  local tail = partial and L[" (partial results)"] or ""
  local v = verdict[id]
  if count > nearMax then
    if not (v and v.floor and v.price == lowest and v.count == count) then
      Say(format(L["%s: %d listed within %d%% of %s: falling floor, not a steal"], ItemLink(id), count, pct, Money(lowest)) .. tail)
    end
    verdict[id] = { floor = true, price = lowest, count = count }
    found[id] = nil
  elseif lowest <= e.buyMax then
    local f = found[id]
    if f and f.price == lowest then
      f.check = nil
    else
      f = { id = id, price = lowest, key = itemKey, fair = e.fair, buyMax = e.buyMax, pct = lowest / e.fair,
        at = GetTime(), qty = count, net = e.net, sell = e.sell, n = e.n, perDay = e.perDay, basis = e.basis }
      found[id] = f
    end
    f.searched, f.second = true, second
    if not (v and not v.floor and v.price == lowest and v.count == count) then
      local nextText = second and format(L[" · next %s (%.1fx)"], Money(second), second / lowest) or L[" · only listing"]
      Say(format(L["%s: STEAL confirmed, %d near %s"], ItemLink(id), count, Money(lowest)) .. nextText .. " · "
        .. ConfText(f) .. tail)
    end
    verdict[id] = { price = lowest, count = count }
    notified[id], notifiedCheck[id] = math.min(notified[id] or lowest, lowest), false
  else
    verdict[id] = nil -- above the alert price: not a steal (D-037)
    found[id] = nil
  end
end

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
  if type(ahf.QueryItem) == "function" then -- item search: a browse-row click, or Blizzard's buy-frame refresh
    hooksecurefunc(ahf, "QueryItem", safe(function() Steals.Cancel("search") end))
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
  for k in pairs(notifiedCheck) do notifiedCheck[k] = nil end
  for k in pairs(verdict) do verdict[k] = nil end
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
function H.ITEM_SEARCH_RESULTS_UPDATED(itemKey) Steals.OnItemSearch(itemKey) end
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
