-- StraightHook · spot info: one set of lines for the panel and the bobber tooltip (SPEC scope 3).
local _, ns = ...
local Info = {}
ns.Info = Info
local L = ns.L

local floor, format, type, pairs, ipairs, tonumber, GetTime = math.floor, string.format, type, pairs, ipairs, tonumber, GetTime
local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local HOUSE = { [114] = "H", [117] = "B" }
local HOUSE_NAME = { [114] = "Horde", [117] = "Blackwater" }

----------------------------------------------------------------------------------------------------
-- Prices (Data/Prices.lua, generated; same part format as Wuwei D-043)
----------------------------------------------------------------------------------------------------
local FIELDS = { "floor", "median", "units", "cheap", "sells", "n", "perDay10", "trend", "sellsDays" }
local cache, cacheOf = {}, nil

-- Typical value of one unit of `id` per house: { [114] = copper, [117] = copper } or nil.
function Info.Value(id)
  local P = ns.PRICES
  if not (P and type(P.items) == "table" and type(P.houses) == "table") then return nil end
  if cacheOf ~= P then cache, cacheOf = {}, P end
  local hit = cache[id]
  if hit ~= nil then return hit or nil end
  local s, out = P.items[id], false
  if type(s) == "string" then
    local i = 0
    for part in (s .. ";"):gmatch("([^;]*);") do
      i = i + 1
      local h, d, k = P.houses[i], {}, 0
      for v in (part .. ","):gmatch("([^,]*),") do
        k = k + 1
        if FIELDS[k] then d[FIELDS[k]] = tonumber(v) end
      end
      local v = d.sells or d.median or d.floor
      if h and v then out = out or {} out[h] = v end
    end
  end
  cache[id] = out
  return out or nil
end

function Info.Houses()
  local pick = ns.db and ns.db.house or "both"
  if pick == "114" or pick == 114 then return { 114 } end
  if pick == "117" or pick == 117 then return { 117 } end
  return { 114, 117 }
end

function Info.Money(c)
  if type(c) ~= "number" then return "?" end
  c = floor(c + 0.5)
  if c >= 10000 then
    local g, s = floor(c / 10000), floor((c % 10000) / 100 + 0.5)
    if s == 100 then g, s = g + 1, 0 end
    return s > 0 and format("%dg %ds", g, s) or format("%dg", g)
  elseif c >= 100 then
    local s, cc = floor(c / 100), c % 100
    return cc > 0 and format("%ds %02dc", s, cc) or format("%ds", s)
  end
  return format("%dc", c)
end

----------------------------------------------------------------------------------------------------
-- Skill
----------------------------------------------------------------------------------------------------
-- "Fishing 87/150 (+25)", effective skill (rank + modifier); nil when unknown.
-- GetProfessions/GetProfessionInfo exist on Forever (GlobalAPI) and returned the fishing skill in game.
function Info.Skill()
  if not (GetProfessions and GetProfessionInfo) then return nil end
  local ok, _, _, _, fishing = pcall(GetProfessions)
  if not ok or type(fishing) ~= "number" then return nil end
  local ok2, name, _, rank, maxRank, _, _, _, mod = pcall(GetProfessionInfo, fishing)
  if not ok2 or type(rank) ~= "number" or Secret(rank) then return nil end
  local s = format("%s %d/%d", type(name) == "string" and name or PROFESSIONS_FISHING or "Fishing", rank, maxRank or 0)
  mod = (type(mod) == "number" and not Secret(mod)) and mod or 0
  if mod > 0 then s = s .. format(" (+%d)", mod) end
  return s, rank + mod
end

----------------------------------------------------------------------------------------------------
-- Classic prior (Data/Seed.lua, SPEC D-006): looked up by the client's own area names
----------------------------------------------------------------------------------------------------
local GETAWAY_MARGIN = 95 -- fish stop getting away at base + 95 (guides for Classic and Forever agree)
local OWN_MIN = 10        -- loots at a spot before its own table leads
local byName

local function AreaIndex()
  if byName then return byName end
  byName = {}
  local seed = ns.SEED
  if not (seed and seed.areas and C_Map and C_Map.GetAreaInfo) then return byName end
  for id, a in pairs(seed.areas) do
    local ok, name = pcall(C_Map.GetAreaInfo, id)
    if ok and type(name) == "string" and not Secret(name) and name ~= "" then
      local cur = byName[name]
      if not cur or (a.loot and not seed.areas[cur].loot) then byName[name] = id end
    end
  end
  return byName
end

-- The prior for a zone/subzone: { area, base, loot } (subzone area first, then the zone), or nil.
function Info.Prior(zone, sub)
  local idx, areas = AreaIndex(), ns.SEED and ns.SEED.areas
  if not areas then return nil end
  local subID, zoneID = sub and sub ~= "" and idx[sub], zone and idx[zone]
  local la = (subID and areas[subID].loot and subID) or (zoneID and areas[zoneID].loot and zoneID)
  local ba = (subID and areas[subID].base and subID) or (zoneID and areas[zoneID].base and zoneID)
  if not (la or ba) then return nil end
  return { area = la or ba, base = ba and areas[ba].base, loot = la and areas[la].loot or {} }
end

-- Is `k` of `n` far from share `p`? Two-sided, ~1 % level: exact binomial for small n, normal approximation above.
function Info.Differs(k, n, p)
  if n < OWN_MIN or p <= 0 or p >= 1 then return false end
  if n > 60 then return math.abs(k - n * p) / math.sqrt(n * p * (1 - p)) > 2.58 end
  local pmf, lo, hi = (1 - p) ^ n, 0, 0
  for i = 0, n do
    if i <= k then lo = lo + pmf end
    if i >= k then hi = hi + pmf end
    pmf = pmf * (n - i) / (i + 1) * p / (1 - p)
  end
  return math.min(lo, hi) < 0.005
end

----------------------------------------------------------------------------------------------------
-- Lines
----------------------------------------------------------------------------------------------------
local requested = {}
local function Name(id)
  local n = ns.db.names[id]
  if not n and C_Item and C_Item.GetItemNameByID then n = C_Item.GetItemNameByID(id) end
  if not n and not requested[id] and C_Item and C_Item.RequestLoadItemDataByID then
    requested[id] = true
    C_Item.RequestLoadItemDataByID(id) -- the name shows on the next refresh
  end
  return n or ("item " .. id)
end

local function Pct(a, b) return b > 0 and floor(a / b * 100 + 0.5) or 0 end

-- Value of a set of { [id] = units }: per house copper, and the share of units that had a price.
local function SetValue(items)
  local houses, total, priced, v = Info.Houses(), 0, 0, {}
  for id, u in pairs(items) do
    total = total + u
    local val = Info.Value(id)
    if val then
      priced = priced + u
      for _, h in ipairs(houses) do v[h] = (v[h] or 0) + (val[h] or 0) * u end
    end
  end
  return v, total > 0 and priced / total or 0
end

local function HouseText(v, suffix)
  local parts = {}
  for _, h in ipairs(Info.Houses()) do
    if v[h] then parts[#parts + 1] = HOUSE[h] .. " " .. Info.Money(v[h]) .. (suffix or "") end
  end
  return table.concat(parts, " · ")
end

-- All lines for the spot `key` (default: where the player stands). opts.top = rows of the catch table.
function Info.Lines(key, opts)
  opts = opts or {}
  local out = {}
  local here, _, zone, sub = ns.Log.Here()
  key = key or here
  local s = key and ns.db.spots[key]
  local title = (s and s.zone or zone or "?") .. ((s and s.sub or sub or "") ~= "" and (" – " .. (s and s.sub or sub)) or "")
  out[#out + 1] = "|cff66ccffStraightHook|r  " .. title
  local prior = Info.Prior(s and s.zone or zone, s and s.sub or sub)
  local skill, eff = Info.Skill()
  if prior and prior.base then
    local clear = prior.base + GETAWAY_MARGIN
    local warn = eff and eff < clear
    skill = (skill and (skill .. " · ") or "") .. format(L["%sno getaways at %d%s"], warn and "|cffff6060" or "", clear,
      warn and "|r" or "") .. L[" (Classic)"]
  end
  if skill then out[#out + 1] = skill end

  local rows, total, stats, scope = ns.Log.Table(key)
  if stats and stats.casts and stats.casts > 0 then
    local hooked = stats.caught + stats.escaped
    out[#out + 1] = format(L["%s: %d casts · %d caught · %d got away (%d%%) · %d missed"],
      scope == "zone" and L["Zone"] or L["Here"], stats.casts, stats.caught, stats.escaped, Pct(stats.escaped, hooked), stats.missed)
  end
  -- Classic shares per item (group 1 = one item per catch) for comparison.
  local pp = {}
  for _, e in ipairs(prior and prior.loot or {}) do if e[3] == 1 and not e[4] then pp[e[1]] = e[2] / 100 end end
  local loots = stats and stats.loots or 0
  local top = opts.top or 8
  local own = total > 0 and loots >= OWN_MIN and scope == "spot"
  if total > 0 then
    if scope == "zone" then out[#out + 1] = L["|cff999999(no catches at this spot yet: zone totals)|r"] end
    if not own then out[#out + 1] = format(L["|cff999999Your catches (%d):|r"], loots) end
    for i, r in ipairs(rows) do
      if i > top then break end
      local val = Info.Value(r.id)
      local price = val and HouseText(val) or ""
      local cmp = ""
      if pp[r.id] then
        cmp = format(L[" · Classic %s%%"], (format("%.1f", pp[r.id] * 100):gsub("%.0$", "")))
        if Info.Differs(math.min(r.units, loots), loots, pp[r.id]) then cmp = cmp .. " |cffffcc00≠|r" end
      elseif prior and #prior.loot > 0 then
        cmp = L[" · |cffffcc00not in Classic|r"]
      end
      out[#out + 1] = format("%3d%%  %s (%d)%s%s", floor(r.share * 100 + 0.5), Name(r.id), r.units, cmp,
        price ~= "" and ("   " .. price) or "")
    end
    -- Classic items you should have seen by now but haven't.
    for id, p in pairs(pp) do
      if not stats.items[id] and Info.Differs(0, loots, p) then
        out[#out + 1] = format(L["  0%%  %s · Classic %d%% |cffffcc00≠ (none in %d)|r"], Name(id), floor(p * 100 + 0.5), loots)
      end
    end
    local v, cover = SetValue(stats.items)
    if next(v) and loots > 0 then
      for h in pairs(v) do v[h] = v[h] / loots end
      out[#out + 1] = L["≈ per catch: "] .. HouseText(v) .. (cover < 0.95 and format(L[" (%d%% priced)"], floor(cover * 100)) or "")
    end
  elseif not stats or (stats.casts or 0) == 0 then
    out[#out + 1] = L["|cff999999No catches logged here yet.|r"]
  end
  -- The Classic prior until this spot has enough of its own catches.
  if prior and #prior.loot > 0 and not own then
    out[#out + 1] = L["|cff999999Classic table (vanilla; Forever may differ):|r"]
    local ev, n = {}, 0
    for _, e in ipairs(prior.loot) do
      local id, pct, group, kind = e[1], e[2], e[3], e[4]
      local val = Info.Value(id)
      if val and group == 1 and not kind then for h, c in pairs(val) do ev[h] = (ev[h] or 0) + c * pct / 100 end end
      if n < top and pct >= 1 then
        n = n + 1
        out[#out + 1] = format("%3s%%  %s%s%s", (format("%.0f", pct)), Name(id), kind and (" |cff999999(" .. kind .. ")|r") or "",
          val and ("   " .. HouseText(val)) or "")
      end
    end
    if next(ev) then out[#out + 1] = L["≈ per catch (Classic table): "] .. HouseText(ev) end
  end

  local ses = ns.Log.session
  if ses.start and ses.casts > 0 then
    local hours = math.max((GetTime() - ses.start) / 3600, 1 / 60)
    local line = format(L["Session: %d casts · %d fish · %d/h"], ses.casts, ses.units, floor(ses.units / hours + 0.5))
    local v = SetValue(ses.items)
    if next(v) then
      for h in pairs(v) do v[h] = v[h] / hours end
      line = line .. " · ≈ " .. HouseText(v, "/h")
    end
    out[#out + 1] = line
  end
  if not ns.PRICES then out[#out + 1] = L["|cff999999No AH values (Data/Prices.lua not generated).|r"] end
  return out
end

----------------------------------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------------------------------
local panel, text
local HIDE_AFTER = 20 -- s after fishing stops

local function SavePos()
  local point, _, _, x, y = panel:GetPoint(1)
  ns.db.panelPos = { point, x, y }
end

local function Place()
  panel:ClearAllPoints()
  local p = ns.db.panelPos
  if p and p[1] then panel:SetPoint(p[1], UIParent, p[1], p[2], p[3]) else panel:SetPoint("CENTER", UIParent, "CENTER", 0, -180) end
end

local function Build()
  panel = CreateFrame("Frame", nil, UIParent)
  panel:SetFrameStrata("MEDIUM")
  panel:SetClampedToScreen(true)
  panel:EnableMouse(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos() end)
  local bg = panel:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.55)
  text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT", 8, -6)
  text:SetJustifyH("LEFT")
  Place()
  panel:Hide()
  Info.panel = panel
end

function Info.Refresh()
  if not panel or not panel:IsShown() then return end
  text:SetText(table.concat(Info.Lines(nil, { top = 6 }), "\n"))
  panel:SetSize((text:GetStringWidth() or 200) + 16, (text:GetStringHeight() or 60) + 12)
end

local hideToken = 0
function Info.Show()
  if ns.db.panel == false then return end
  if not panel then Build() end
  hideToken = hideToken + 1
  panel:Show()
  Info.Refresh()
end

function Info.HideLater()
  if not panel then return end
  hideToken = hideToken + 1
  local mine = hideToken
  C_Timer.After(HIDE_AFTER, function()
    if mine == hideToken and not ns.S.fishing then panel:Hide() end
  end)
end

function Info.Hide() if panel then hideToken = hideToken + 1 panel:Hide() end end
function Info.ResetPos() ns.db.panelPos = nil if panel then Place() end end

----------------------------------------------------------------------------------------------------
-- Bobber tooltip
----------------------------------------------------------------------------------------------------
-- A world-object tooltip is the bobber when its GUID is the soft-interact GameObject seen during this cast, or its first
-- line is the learned bobber name.
function Info.IsBobber(data)
  if type(data) ~= "table" then return false end
  local guid = data.guid
  if guid and not Secret(guid) and ns.S.bobberGUID and guid == ns.S.bobberGUID then
    local first = data.lines and data.lines[1] and data.lines[1].leftText
    if type(first) == "string" and not Secret(first) then
      ns.db.bobber = ns.db.bobber or {}
      ns.db.bobber.name = first
    end
    return true
  end
  local first = data.lines and data.lines[1] and data.lines[1].leftText
  return type(first) == "string" and not Secret(first) and ns.db.bobber ~= nil and first == ns.db.bobber.name
end

local function OnObjectTooltip(tooltip, data)
  if tooltip ~= GameTooltip or not ns.db or not Info.IsBobber(data) then return end
  local lines = Info.Lines(nil, { top = 5 })
  for i = 2, #lines do tooltip:AddLine(lines[i], 1, 1, 1) end
end

function Info.HookTooltip()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Object then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, OnObjectTooltip)
  end
end

Info.HOUSE_NAME = HOUSE_NAME
