-- Plan accessors: item lookup, per-house plays sorted by gain, data age, money formatting.
local addonName, ns = ...

local pairs, type, tonumber, floor, sort, format = pairs, type, tonumber, math.floor, table.sort, string.format

local Plan = {}
ns.Plan = Plan

local BLACKWATER = 117
Plan.BLACKWATER = BLACKWATER
local HOUSE_NAMES = { [111] = "Alliance", [114] = "Horde", [117] = "Blackwater" } -- fallback; the plan's `houses` wins
local HOUSE_SHORT = { [111] = "AH", [114] = "AH", [117] = "BW" }

function Plan.Get() return ns.PLAN or ns.BUILTIN_PLAN end
function Plan.IsBuiltin() return ns.PLAN == nil end

function Plan.Item(id)
  local p = Plan.Get()
  return p and p.items and p.items[id] or nil
end

function Plan.HouseName(house)
  local p = Plan.Get()
  return (p and p.houses and p.houses[house]) or HOUSE_NAMES[house] or ("house " .. tostring(house))
end

function Plan.HouseShort(house) return HOUSE_SHORT[house] or tostring(house) end

-- Where a SHUTTLE item is sold: Blackwater from a faction house; from Blackwater it is the sell side itself.
function Plan.ShuttleDest(house)
  if house == BLACKWATER then return nil end
  return BLACKWATER
end

-- Plays for a house, descending by gain (nil gain = 0, ties by item id). AVOID rows are dropped.
function Plan.Plays(house, limit)
  local out = {}
  local p = Plan.Get()
  if not (p and p.items and house) then return out end
  for id, it in pairs(p.items) do
    if it.signal ~= "AVOID" and it.ref and it.ref[house] then
      out[#out + 1] = { id = id, item = it, gain = it.gain or 0 }
    end
  end
  sort(out, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.id < b.id
  end)
  if limit then for i = #out, limit + 1, -1 do out[i] = nil end end
  return out
end

-- Reference price for display: this house if present, else the lowest-numbered house with one.
function Plan.RefPrice(it, house)
  if not it.ref then return nil end
  if house and it.ref[house] then return it.ref[house], house end
  local best
  for h in pairs(it.ref) do if not best or h < best then best = h end end
  return best and it.ref[best], best
end

function Plan.Regime(house)
  local p = Plan.Get()
  local ix = p and p.index
  if not ix then return nil end
  local e = (house and ix[house]) or select(2, next(ix))
  return e and e.regime or nil
end

-- "2026-11-09T07:00:00Z" -> unix seconds (UTC). Civil-date arithmetic; os.* is unavailable in the WoW client.
local function DaysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local doy = floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function Plan.ParseTime(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return DaysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
end

function Plan.AgeSeconds()
  local p = Plan.Get()
  local t = p and Plan.ParseTime(p.generated)
  if not t then return nil end
  local age = GetServerTime() - t
  return age < 0 and 0 or age
end

function Plan.AgeText(age)
  if age == nil then age = Plan.AgeSeconds() end
  if not age then return "?" end
  if age < 3600 then return floor(age / 60) .. "m" end
  if age < 86400 then return floor(age / 3600) .. "h" end
  return floor(age / 86400) .. "d"
end

-- copper -> "1g 2s 3c" (zero parts dropped; "0c" for nothing). Plain text, safe in any FontString/tooltip.
function Plan.Money(c)
  if type(c) ~= "number" then return "?" end
  c = floor(c + 0.5)
  local g, s, cc = floor(c / 10000), floor(c / 100) % 100, c % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if cc > 0 or #parts == 0 then parts[#parts + 1] = cc .. "c" end
  return table.concat(parts, " ")
end

local COLORS = { SELL = "ff40e060", BUY = "ff40c0ff", SHUTTLE = "ffffa030", HOLD = "ffa0a0a0", AVOID = "ffff4040" }
function Plan.Colorize(signal, text) return "|c" .. (COLORS[signal] or "ffffffff") .. text .. "|r" end

-- The price rule for a signal as seen from `house`. Short, plain text.
function Plan.Rule(it, house)
  local sig = it.signal
  if sig == "SELL" then
    return "≥ " .. Plan.Money(it.sellMin)
  elseif sig == "BUY" then
    return "≤ " .. Plan.Money(it.buyMax)
  elseif sig == "SHUTTLE" then
    local dest = Plan.ShuttleDest(house)
    if dest then
      return format("→ %s ≥ %s", Plan.HouseShort(dest), Plan.Money(it.sellMin))
    end
    return "sell ≥ " .. Plan.Money(it.sellMin)
  end
  local ref = Plan.RefPrice(it, house)
  return ref and ("ref " .. Plan.Money(ref)) or ""
end
