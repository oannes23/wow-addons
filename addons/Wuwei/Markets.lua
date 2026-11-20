-- Markets view (SPEC D-058): a stock-list read of the commodity market at this house, from the pipeline's
-- `ns.PLAN.marketsByHouse[house]` (wowf-ah-analysis markets.py). Pure: rows and texts only, no frames, no queries.
-- Top level: one row per sector (median 24 h change, 7 d change, breadth), then the biggest gainers and losers across
-- sectors. A sector row opens that sector's movers. The pipeline ranks movers by move size x sqrt(turnover).
local _, ns = ...
local L = ns.L

local type, ipairs, format, floor, abs, log, sqrt, sort, max =
  type, ipairs, string.format, math.floor, math.abs, math.log, math.sqrt, table.sort, math.max

local Markets = {}
ns.Markets = Markets

local GREEN, RED, GREY = "ff40e060", "ffff5050", "ffa0a0a0"

function Markets.Data(house)
  local p = ns.Plan.Get()
  local m = p and type(p.marketsByHouse) == "table" and p.marketsByHouse[house]
  if type(m) == "table" and type(m.sectors) == "table" then return m end
  return nil
end

-- "+4.2%", "-12%", ">+999%", "n/a"; green up, red down, grey flat (|v| < 1).
function Markets.Pct(v)
  if type(v) ~= "number" then return "|c" .. GREY .. L["n/a"] .. "|r" end
  local s
  if v >= 1000 then s = ">+999%"
  elseif abs(v) >= 100 then s = format("%+d%%", floor(v + (v >= 0 and 0.5 or -0.5)))
  else s = format("%+.1f%%", v) end
  local c = v >= 1 and GREEN or (v <= -1 and RED or GREY)
  return "|c" .. c .. s .. "|r"
end

function Markets.Volume(n)
  if type(n) ~= "number" then return "" end
  if n >= 10000 then return format("%dk/d", floor(n / 1000 + 0.5)) end
  if n >= 1000 then return format("%.1fk/d", n / 1000) end
  return format("%d/d", n)
end

-- The pipeline's score when present, else the same formula: |ln(1 + chg24)| x sqrt(units/day x price).
local function Score(it)
  if type(it.score) == "number" then return it.score end
  if type(it.chg24) ~= "number" or it.chg24 <= -100 then return 0 end
  return abs(log(1 + it.chg24 / 100)) * sqrt(max(0, (it.perDay or 0) * (it.price or 0)))
end

local function ItemRow(it, sectorName)
  return {
    id = it.id, price = it.price, signal = Markets.Pct(it.chg24), signalRaw = true,
    rule = ns.Plan.Money(it.price or 0) .. " · 7d " .. Markets.Pct(it.chg7) .. (sectorName and (" · " .. sectorName) or ""),
    gainText = Markets.Volume(it.perDay), button = L["Search"],
  }
end

local function Sector(m, key)
  for _, s in ipairs(m.sectors) do if s.key == key then return s end end
end

-- Rows for the panel (at most `limit`). sectorKey nil = overview; a key = that sector's movers.
function Markets.Rows(house, sectorKey, limit)
  local m = Markets.Data(house)
  local rows = {}
  if not m then return rows end
  if sectorKey then
    local s = Sector(m, sectorKey)
    for _, it in ipairs(s and s.items or {}) do
      if #rows >= limit then break end
      if type(it) == "table" and type(it.id) == "number" then rows[#rows + 1] = ItemRow(it) end
    end
    return rows
  end
  for _, s in ipairs(m.sectors) do
    if #rows >= limit then return rows end
    rows[#rows + 1] = {
      sector = s.key, signal = Markets.Pct(s.chg24), signalRaw = true, name = s.name or s.key,
      rule = "7d " .. Markets.Pct(s.chg7) .. " · " .. format(L["%d up / %d down"], s.up or 0, s.down or 0),
      gainText = format(L["%d items"], s.n or 0), button = L["Open"],
    }
  end
  -- Gainers and losers across sectors (an item in two sectors, e.g. the raid basket, counts once).
  local seen, ups, downs = {}, {}, {}
  for _, s in ipairs(m.sectors) do
    for _, it in ipairs(type(s.items) == "table" and s.items or {}) do
      if type(it) == "table" and type(it.id) == "number" and type(it.chg24) == "number" and not seen[it.id] then
        seen[it.id] = true
        local e = { it = it, sector = s.name, score = Score(it) }
        if it.chg24 >= 1 then ups[#ups + 1] = e elseif it.chg24 <= -1 then downs[#downs + 1] = e end
      end
    end
  end
  local function bysc(a, b) if a.score ~= b.score then return a.score > b.score end return a.it.id < b.it.id end
  sort(ups, bysc)
  sort(downs, bysc)
  local room = limit - #rows - 2 -- two label rows
  if room < 2 then return rows end
  local nUp = math.min(#ups, math.ceil(room / 2))
  local nDown = math.min(#downs, room - nUp)
  nUp = math.min(#ups, room - nDown) -- give unused loser rows back to gainers
  local function block(label, list, n)
    if n <= 0 then return end
    rows[#rows + 1] = { label = true, name = label }
    for i = 1, n do rows[#rows + 1] = ItemRow(list[i].it, list[i].sector) end
  end
  block(L["Top gainers 24h"], ups, nUp)
  block(L["Top losers 24h"], downs, nDown)
  return rows
end

-- Status line under the tabs.
function Markets.StatusText(house, sectorKey)
  local m = Markets.Data(house)
  if not m then return L["Markets: no data in the current plan (run export-addon)."] end
  local at = ns.Plan.ParseTime(m.at)
  local age = at and ns.Plan.AgeText(math.max(0, GetServerTime() - at)) or "?"
  if sectorKey then
    local s = Sector(m, sectorKey)
    if s then
      return format(L["%s · median 24h %s · 7d %s · %d up / %d down · prices %s old"], s.name or s.key,
        Markets.Pct(s.chg24), Markets.Pct(s.chg7), s.up or 0, s.down or 0, age)
    end
  end
  return format(L["Markets · 24h change (median of liquid items) · 7d · breadth · prices %s old"], age)
end
