-- QuestTrackerSort · Sort.lua
-- Compute the desired watch order and rewrite C_QuestLog's watch list to match.
-- No secret values involved: quest/map APIs return plain values (see SPEC viability table).
local _, ns = ...
local L = ns.L

local C_QuestLog, C_SuperTrack = C_QuestLog, C_SuperTrack
local ipairs, sort, floor, huge, sqrt = ipairs, table.sort, math.floor, math.huge, math.sqrt
local InCombatLockdown = InCombatLockdown

local Sort = {}
ns.Sort = Sort

Sort.busy = false        -- true while we are rewriting (suppress our own QUEST_WATCH_LIST_CHANGED)
Sort.pending = false     -- a sort was requested during combat
Sort.unsupported = false -- latched when read-back shows the client re-sorts by itself

local function dprint(...)
  if ns.db and ns.db.debug then print("|cff88ccffQTS|r", ...) end
end
ns.dprint = dprint

function Sort.ReadWatches()
  local ids = {}
  for i = 1, C_QuestLog.GetNumQuestWatches() do
    local id = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
    if id then ids[#ids + 1] = id end
  end
  return ids
end

local function SameOrder(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function Reversed(a)
  local r = {}
  for i = #a, 1, -1 do r[#r + 1] = a[i] end
  return r
end

-- Build sort keys. Unknown / off-continent distance sorts last.
local function BuildKeys(ids)
  local bucket = ns.db.bucketYards
  local keys = {}
  for _, id in ipairs(ids) do
    local dSq, onContinent = C_QuestLog.GetDistanceSqToQuest(id)
    local d = (dSq and onContinent) and dSq or huge
    keys[id] = {
      d = d,
      b = (d == huge) and huge or floor(sqrt(d) / bucket),
      lvl = C_QuestLog.GetQuestDifficultyLevel(id) or 0,
    }
  end
  return keys
end

local comparators = {
  -- closest first (bucketed), then lowest level, then questID for a stable total order
  distance = function(keys)
    return function(a, b)
      local ka, kb = keys[a], keys[b]
      if ka.b ~= kb.b then return ka.b < kb.b end
      if ka.lvl ~= kb.lvl then return ka.lvl < kb.lvl end
      return a < b
    end
  end,
  -- lowest level first, then closest (raw distance), then questID
  level = function(keys)
    return function(a, b)
      local ka, kb = keys[a], keys[b]
      if ka.lvl ~= kb.lvl then return ka.lvl < kb.lvl end
      if ka.d ~= kb.d then return ka.d < kb.d end
      return a < b
    end
  end,
}

function Sort.ComputeOrder(ids, mode)
  local want = {}
  for i, id in ipairs(ids) do want[i] = id end
  sort(want, comparators[mode](BuildKeys(want)))
  return want
end

local function Rewrite(order, prepend)
  local superID = C_SuperTrack.GetSuperTrackedQuestID()
  for _, id in ipairs(order) do
    C_QuestLog.RemoveQuestWatch(id)
  end
  if prepend then
    for i = #order, 1, -1 do C_QuestLog.AddQuestWatch(order[i]) end
  else
    for i = 1, #order do C_QuestLog.AddQuestWatch(order[i]) end
  end
  if superID and superID ~= 0 and C_SuperTrack.GetSuperTrackedQuestID() ~= superID then
    C_SuperTrack.SetSuperTrackedQuestID(superID)
  end
end

-- Apply the current mode's order. `manual` = user pressed Refresh (clears the unsupported latch).
function Sort.Apply(manual)
  if Sort.busy then return end
  if manual then Sort.unsupported = false end
  if Sort.unsupported then return end
  if InCombatLockdown() then
    if manual and not Sort.pending then print("|cff88ccffQTS|r", L.PENDING_COMBAT) end
    Sort.pending = true
    return
  end
  Sort.pending = false

  local cur = Sort.ReadWatches()
  if #cur < 2 then return end
  local want = Sort.ComputeOrder(cur, ns.db.mode)
  if SameOrder(cur, want) then
    dprint("order unchanged")
    return
  end

  Sort.busy = true
  Rewrite(want, ns.db.insertMode == "prepend")
  local got = Sort.ReadWatches()
  if not SameOrder(got, want) and SameOrder(got, Reversed(want)) then
    -- Our insertion assumption was backwards; learn and redo once.
    ns.db.insertMode = (ns.db.insertMode == "prepend") and "append" or "prepend"
    if ns.db.insertMode == "prepend" then print("|cff88ccffQTS|r", L.LEARNED_PREPEND) end
    Rewrite(want, ns.db.insertMode == "prepend")
    got = Sort.ReadWatches()
  end
  Sort.busy = false

  if SameOrder(got, want) then
    dprint("rewrote", #want, "watches, mode", ns.db.mode)
  else
    Sort.unsupported = true
    print("|cff88ccffQTS|r", L.UNSUPPORTED)
  end
end

-- Coalesce bursts of events into one Apply shortly after.
local scheduled = false
function Sort.Schedule(delay)
  if scheduled then return end
  scheduled = true
  C_Timer.After(delay or 0.5, function()
    scheduled = false
    Sort.Apply(false)
  end)
end
