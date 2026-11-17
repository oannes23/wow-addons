-- StraightHook · catch log (SPEC D-003, D-004): per spot (map + subzone) items, casts and one outcome per cast.
local _, ns = ...
local Log = {}
ns.Log = Log

local tonumber, pairs, type, GetTime = tonumber, pairs, type, GetTime

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- Where the player stands: key "map:subzone", plus display parts.
function Log.Here()
  local map = C_Map.GetBestMapForUnit("player")
  local zone, sub = GetRealZoneText() or "", GetSubZoneText() or ""
  if Secret(map) or Secret(zone) or Secret(sub) then return nil end
  return (map or 0) .. ":" .. sub, map, zone, sub
end

local function Spot(key, map, zone, sub)
  local spots = ns.db.spots
  local s = spots[key]
  if not s then
    s = { map = map, zone = zone, sub = sub, casts = 0, caught = 0, escaped = 0, missed = 0, early = 0, loots = 0, items = {} }
    spots[key] = s
  end
  return s
end
Log.Spot = Spot

-- Session (not saved): reset on login.
Log.session = { start = nil, casts = 0, caught = 0, escaped = 0, missed = 0, units = 0, items = {} }

local cast -- the open cast: { key, spot, outcome }

function Log.CastStart()
  local key, map, zone, sub = Log.Here()
  if not key then cast = nil return end
  local s = Spot(key, map, zone, sub)
  s.casts = s.casts + 1
  local ses = Log.session
  ses.start = ses.start or GetTime()
  ses.casts = ses.casts + 1
  cast = { key = key, spot = s }
end

local function Outcome(kind)
  if not cast or cast.outcome then return end
  cast.outcome = kind
  cast.spot[kind] = cast.spot[kind] + 1
  Log.session[kind] = Log.session[kind] + 1
end

-- The channel ended. Loot opens after the channel stops, so the verdict waits a moment (Core calls Finish later).
function Log.CastFinish()
  if cast and not cast.outcome then Outcome("missed") end
  cast = nil
end

function Log.Escaped() Outcome("escaped") end

function Log.Early()
  if cast then cast.spot.early = cast.spot.early + 1 end
end

local function ItemID(link)
  if type(link) ~= "string" or Secret(link) then return nil end
  return tonumber(link:match("|Hitem:(%d+)") or link:match("^item:(%d+)"))
end
Log.ItemID = ItemID

-- LOOT_OPENED with IsFishingLoot(): record every item slot. Works whether or not the cast is still open (the channel
-- may already have stopped): falls back to the spot where the player stands.
function Log.Loot()
  local s
  if cast then s = cast.spot else
    local key, map, zone, sub = Log.Here()
    if not key then return 0 end
    s = Spot(key, map, zone, sub)
  end
  local n = 0
  for i = 1, GetNumLootItems() do
    local link = GetLootSlotLink(i)
    local _, name, qty, currencyID, _, _, _, _, _, isCoin = GetLootSlotInfo(i)
    local id = ItemID(link)
    if id and not isCoin and not currencyID then
      qty = (type(qty) == "number" and not Secret(qty) and qty > 0) and qty or 1
      s.items[id] = (s.items[id] or 0) + qty
      if type(name) == "string" and not Secret(name) then ns.db.names[id] = name end
      local ses = Log.session
      ses.items[id] = (ses.items[id] or 0) + qty
      ses.units = ses.units + qty
      n = n + qty
    end
  end
  s.loots = s.loots + 1
  if cast then Outcome("caught") else
    s.caught = s.caught + 1
    Log.session.caught = Log.session.caught + 1
  end
  return n
end

-- Catch table for the spot `key`, or the zone total (all spots on that map) when the spot has no loot yet.
-- Returns rows sorted by units { id, units, share }, total units, the stats table, and "spot"|"zone".
function Log.Table(key)
  local spots = ns.db.spots
  local s = key and spots[key]
  local scope, stats = "spot", s
  if not s or s.loots == 0 then
    local map = s and s.map or (key and tonumber(key:match("^(%d+):")))
    if not map then return {}, 0, s, "spot" end
    stats = { casts = 0, caught = 0, escaped = 0, missed = 0, early = 0, loots = 0, items = {} }
    for _, x in pairs(spots) do
      if x.map == map then
        for k in pairs(stats) do if k ~= "items" then stats[k] = stats[k] + (x[k] or 0) end end
        for id, u in pairs(x.items) do stats.items[id] = (stats.items[id] or 0) + u end
      end
    end
    scope = "zone"
  end
  local rows, total = {}, 0
  for id, u in pairs(stats.items) do rows[#rows + 1] = { id = id, units = u } total = total + u end
  table.sort(rows, function(a, b) if a.units ~= b.units then return a.units > b.units end return a.id < b.id end)
  for _, r in ipairs(rows) do r.share = r.units / total end
  return rows, total, stats, scope
end

function Log.Forget(key) if key then ns.db.spots[key] = nil end end
