local _, ns = ...
-- Where to fish (SPEC D-007): extra lines on the Fishing spell's tooltip. Zones are ranked by expected AH value
-- per cast (catch chance × value per catch) from the Classic prior, and coloured by the zone's level range
-- relative to the player's level the way the world map colours zone names.
local Guide = {}
ns.Guide = Guide
local L = ns.L

local floor, max, min = math.floor, math.max, math.min
local CLEAN, STRETCH = 5, 3 -- rows per section
local STRETCH_MIN = 0.5      -- catch chance floor for the "stretch" list

-- Catch chance at effective skill `eff` in a zone of base level `base`: skill − base + 5, capped to 0–100 %.
-- Matches the guides' "no getaways at base + 95" [INFER]; the formula is the emulator's (Classic analog).
function Guide.Catch(eff, base) return max(0, min(100, eff - base + 5)) / 100 end

local function Secret(v) return issecretvalue and issecretvalue(v) end

-- uiMap zone name -> { minLevel, maxLevel }. Built once from the top of the player's map tree.
local levels
local function Levels()
  if levels then return levels end
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo and C_Map.GetMapChildrenInfo and C_Map.GetMapLevels) then
    levels = {}
    return levels
  end
  local top = C_Map.GetBestMapForUnit("player")
  if not top then return {} end -- loading screen: try again next time
  for _ = 1, 10 do
    local info = C_Map.GetMapInfo(top)
    if not info or not info.parentMapID or info.parentMapID == 0 then break end
    top = info.parentMapID
  end
  levels = {}
  local ok, kids = pcall(C_Map.GetMapChildrenInfo, top, Enum.UIMapType and Enum.UIMapType.Zone, true)
  for _, k in ipairs(ok and type(kids) == "table" and kids or {}) do
    local lo, hi = C_Map.GetMapLevels(k.mapID)
    if k.name and lo and hi and lo > 0 and hi > 0 and not levels[k.name] then levels[k.name] = { lo, hi } end
  end
  return levels
end

-- Colour code for a zone's level range, as the world map does it (AreaLabelDataProvider).
local function LevelColor(lv)
  if not (lv and GetQuestDifficultyColor and RGBTableToColorCode and UnitLevel) then return "|cffffffff" end
  local p = UnitLevel("player")
  local c
  if p < lv[1] then
    c = GetQuestDifficultyColor(lv[1])
  elseif p > lv[2] then
    c = GetQuestDifficultyColor(lv[2] - 2) -- zones entirely below the player aren't yellow
  else
    c = QuestDifficultyColors and QuestDifficultyColors.difficult
  end
  return c and RGBTableToColorCode(c) or "|cffffffff"
end

local function AreaName(id)
  local ok, n = pcall(C_Map.GetAreaInfo, id)
  if ok and type(n) == "string" and not Secret(n) and n ~= "" then return n end
end

-- One row per seed area with a main loot table: { name, zoneName, base, catch, ev, perCast, levels }.
function Guide.Rows(eff)
  local seed = ns.SEED
  if not (seed and seed.areas and C_Map and C_Map.GetAreaInfo) then return {} end
  local house = ns.Info.Houses()[1]
  local lv, rows = Levels(), {}
  for id, a in pairs(seed.areas) do
    local zone = a.zone and seed.areas[a.zone]
    local base = a.base or (zone and zone.base)
    local name = AreaName(id)
    local hasMain = false
    for _, e in ipairs(a.loot or {}) do if e[3] == 1 then hasMain = true break end end
    if base and name and hasMain then
      local ev = 0
      for _, e in ipairs(a.loot) do
        local v = e[3] == 1 and not e[4] and ns.Info.Value(e[1])
        if v and v[house] then ev = ev + v[house] * e[2] / 100 end
      end
      local zoneName = a.zone and AreaName(a.zone)
      local catch = Guide.Catch(eff, base)
      rows[#rows + 1] = { name = name, zoneName = zoneName, base = base, catch = catch, ev = ev, perCast = ev * catch,
        levels = lv[name] or (zoneName and lv[zoneName]) }
    end
  end
  return rows
end

local function Label(r)
  local text = r.name .. (r.zoneName and r.zoneName ~= r.name and (" (" .. r.zoneName .. ")") or "")
  if r.levels then text = text .. format(" %d–%d", r.levels[1], r.levels[2]) end
  if r.more then text = text .. format(L[" (+%d nearby)"], r.more) end
  return LevelColor(r.levels) .. text .. "|r"
end

local function byValue(a, b)
  if a.perCast ~= b.perCast then return a.perCast > b.perCast end
  return a.base > b.base
end

-- { {left, right}, ... } for the tooltip; nil when there is nothing to say.
function Guide.Lines()
  local _, eff = ns.Info.Skill()
  if not eff then return nil end
  local clean, stretch = {}, {}
  for _, r in ipairs(Guide.Rows(eff)) do
    if r.catch >= 1 then clean[#clean + 1] = r elseif r.catch >= STRETCH_MIN then stretch[#stretch + 1] = r end
  end
  if #clean + #stretch == 0 then return nil end
  table.sort(clean, byValue)
  table.sort(stretch, byValue)
  -- Subzones sharing their zone's table and value collapse into one row ("(+3 nearby)").
  local function Dedupe(list)
    local out, seen = {}, {}
    for _, r in ipairs(list) do
      local key = (r.zoneName or r.name) .. ":" .. floor(r.perCast) .. ":" .. r.base
      local first = seen[key]
      if first then first.more = (first.more or 0) + 1 else seen[key] = r out[#out + 1] = r end
    end
    return out
  end
  clean, stretch = Dedupe(clean), Dedupe(stretch)
  local priced = ns.PRICES ~= nil
  local function Value(r) return priced and (ns.Info.Money(floor(r.perCast + 0.5)) .. L["/cast"]) or "" end
  local out = { { " ", " " }, { "|cff66ccffStraightHook: where to fish|r", format(L["skill %d"], eff) } }
  if #clean > 0 then
    out[#out + 1] = { L["|cffaaaaaaNo getaways:|r"], priced and L["|cffaaaaaa≈ value|r"] or "" }
    for i = 1, min(CLEAN, #clean) do out[#out + 1] = { Label(clean[i]), Value(clean[i]) } end
  end
  if #stretch > 0 then
    out[#out + 1] = { L["|cffaaaaaaStretch (some get away):|r"], L["|cffaaaaaacatch · value|r"] }
    for i = 1, min(STRETCH, #stretch) do
      local r = stretch[i]
      out[#out + 1] = { Label(r), format("%d%%", floor(r.catch * 100)) .. (priced and (" · " .. Value(r)) or "") }
    end
  end
  out[#out + 1] = { L["|cff808080Classic tables; Forever may differ. Skill-ups come from catches only.|r"], "" }
  return out
end

function Guide.HookTooltip()
  if not (TooltipDataProcessor and Enum.TooltipDataType and Enum.TooltipDataType.Spell) then return end
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
    if not (ns.db and ns.db.guide ~= false and data) then return end
    local id = data.id
    if type(id) ~= "number" or Secret(id) or not (C_Spell and C_Spell.GetSpellName) then return end
    if C_Spell.GetSpellName(id) ~= (PROFESSIONS_FISHING or "Fishing") then return end
    local lines = Guide.Lines()
    if not lines then return end
    for _, l in ipairs(lines) do tooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 0.85, 0.85, 0.85) end
  end)
end
