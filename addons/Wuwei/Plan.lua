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

-- Shuttle toggle (SPEC D-028): off by default. Off = faction side only: a SHUTTLE item is seen through View().
function Plan.ShuttleOn() return ns.db ~= nil and ns.db.shuttle == true end

-- The item as the player should see it now. With the shuttle toggle off, a SHUTTLE item becomes its faction-side
-- verdict (`alt`, from the exporter: SELL/HOLD) or a passive INFO line; the shuttle numbers stay under `.shuttle`.
-- Callers never act on INFO (not in Plays, not in the key queue); the tooltip still shows it.
function Plan.View(it)
  if not it or it.signal ~= "SHUTTLE" or Plan.ShuttleOn() then return it end
  local v = {}
  for k, x in pairs(it) do v[k] = x end
  v.shuttle, v.buyMax, v.qtyCap, v.alt = it, nil, nil, nil
  local alt = it.alt
  if alt then
    v.signal, v.sellMin, v.gain, v.note = alt.signal, alt.sellMin, alt.gain or 0, alt.note
  else
    v.signal, v.sellMin, v.gain = "INFO", nil, 0
  end
  return v
end

function Plan.RawItem(id)
  local p = Plan.Get()
  return p and p.items and p.items[id] or nil
end

function Plan.Item(id) return Plan.View(Plan.RawItem(id)) end

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

-- Plays for a house, descending by gain (nil gain = 0, ties by item id). AVOID and INFO rows are dropped.
-- Items are the View() (shuttle toggle applied).
local NOT_A_PLAY = { AVOID = true, INFO = true }
function Plan.Plays(house, limit)
  local out = {}
  local p = Plan.Get()
  if not (p and p.items and house) then return out end
  for id, raw in pairs(p.items) do
    local it = Plan.View(raw)
    if not NOT_A_PLAY[it.signal] and it.ref and it.ref[house] then
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

-- SHUTTLE items hidden or downgraded by the toggle at this house (0 when the toggle is on).
function Plan.ShuttleHidden(house)
  local p = Plan.Get()
  if Plan.ShuttleOn() or not (p and p.items) then return 0 end
  local n = 0
  for _, it in pairs(p.items) do
    if it.signal == "SHUTTLE" and it.ref and it.ref[house] then n = n + 1 end
  end
  return n
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

-- INFO is muted orange: shuttle information, not a play.
local COLORS = { SELL = "ff40e060", BUY = "ff40c0ff", SHUTTLE = "ffffa030", HOLD = "ffa0a0a0", AVOID = "ffff4040",
  INFO = "ffb08050" }
local LABELS = { INFO = "SHUTTLE (off)" }
function Plan.Colorize(signal, text) return "|c" .. (COLORS[signal] or "ffffffff") .. text .. "|r" end
function Plan.Label(signal) return LABELS[signal] or signal end

-- The shuttle numbers as plain information: "BW ≥ 13s (2.4×)". nil unless the item is a SHUTTLE (raw or viewed).
function Plan.ShuttleInfo(it)
  local sh = it and (it.shuttle or (it.signal == "SHUTTLE" and it)) or nil
  if not (sh and sh.sellMin) then return nil end
  local src, dst = sh.ref and sh.ref[114], sh.ref and sh.ref[BLACKWATER]
  local ratio = (src and dst and src > 0) and format(" (%.1f×)", dst / src) or ""
  return format("%s ≥ %s%s", Plan.HouseShort(BLACKWATER), Plan.Money(sh.sellMin), ratio)
end

-- The floor a sale at `house` should respect. A SHUTTLE item's sellMin is the Blackwater exit, so at a faction house
-- the floor is its faction-side verdict's (`alt`), if any; posting it there under the BW price is not a mistake.
function Plan.SellFloor(it, house)
  if not it then return nil end
  if it.signal == "SHUTTLE" and house ~= BLACKWATER then return it.alt and it.alt.sellMin or nil end
  return it.sellMin
end

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
  elseif sig == "INFO" then
    return "→ " .. (Plan.ShuttleInfo(it) or "")
  end
  local ref = Plan.RefPrice(it, house)
  return ref and ("ref " .. Plan.Money(ref)) or ""
end
