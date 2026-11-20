-- House detection: which auction house is the player standing at (111 Alliance, 114 Horde, 117 Blackwater).
-- Blackwater AHs are expected in Booty Bay, Gadgetzan and Everlook. uiMapIDs are unknown (SPEC [TODO-INGAME]);
-- fill House.BLACKWATER_MAPS from the in-game probe. Zone names are the working fallback. In vanilla geography
-- these towns are subzones of Stranglethorn Vale / Tanaris / Winterspring, so zone and subzone are both checked.
local _, ns = ...

local House = {}
ns.House = House

House.BLACKWATER_MAPS = {} -- [uiMapID] = true; [TODO-INGAME] Booty Bay, Gadgetzan, Everlook
House.BLACKWATER_ZONES = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }
local FACTION_HOUSE = { Horde = 114, Alliance = 111 }

-- Faction capitals (enUS names, [INFER]/[TODO-INGAME]): the faction fallback is trusted only standing in one of these.
House.FACTION_CAPITALS = {
  Horde = { Orgrimmar = true, ["Thunder Bluff"] = true, Undercity = true },
  Alliance = { ["Stormwind City"] = true, Ironforge = true, Darnassus = true },
}

-- Returns houseID (or nil if unknown), a short reason string for `/wuwei status`, and `confident` (boolean): true for
-- a manual override, a map or Blackwater zone match, or the faction fallback inside a faction capital. When false the
-- house is a guess; Ledger.OnOwnedUpdated then refuses to act on it (SPEC D-030).
-- Deposit probe (D-057): no API names the open auction house, but its deposit quote does. Blackwater charges 5x the
-- faction rate (12.5%/h vs 2.5%/h of vendor price, reference/auction-house.md [INGAME 2026-11-15]): 100 Light Leather
-- (vendor 15c) for 24 h quote 9s at a faction house and 45s at Blackwater. The quote is a client-side calculation (no
-- query, no throttle). The rotating Crossroads camp auctioneer opens Blackwater, so location alone can't tell.
House.PROBE_ITEM, House.PROBE_QTY, House.PROBE_DURATION = 2318, 100, 3 -- Light Leather, 100, 24 h (luaIndex 3)
House.PROBE_VENDOR = 15 -- copper, checked against the tooltip 2026-11-15; used when GetItemInfo has no sell price yet
House.PROBE_SPLIT = 1.5 -- deposit per (vendor x qty) over 24 h: 0.6 faction, 3.0 Blackwater; split between them
local probe -- { house = id } while the AH is open; nil = not probed (or the quote wasn't available yet)

local function AHOpen()
  local ahf = _G.AuctionHouseFrame
  return ahf and ahf.IsShown and ahf:IsShown()
end

-- Returns 117, the faction house, or nil (no quote: API missing, item data not loaded, not at an AH).
function House.Probe()
  local AH = C_AuctionHouse
  if not (AH and AH.CalculateCommodityDeposit) then return nil end
  local ok, dep = pcall(AH.CalculateCommodityDeposit, House.PROBE_ITEM, House.PROBE_DURATION, House.PROBE_QTY)
  if not ok or type(dep) ~= "number" or dep <= 0 then return nil end
  local vendor = select(11, C_Item.GetItemInfo(House.PROBE_ITEM))
  if type(vendor) ~= "number" or vendor <= 0 then vendor = House.PROBE_VENDOR end
  local ratio = dep / (vendor * House.PROBE_QTY)
  if ratio >= House.PROBE_SPLIT then return ns.Plan.BLACKWATER end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  return faction and FACTION_HOUSE[faction] or nil
end

function House.ResetProbe() probe = nil end

function House.Detect()
  local db = ns.db
  if db and db.house then return db.house, "manual override", true end
  if AHOpen() then
    if not probe then
      local h = House.Probe()
      if h then probe = { house = h } end
    end
    if probe then return probe.house, "deposit quote", true end
  else
    probe = nil
  end
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if mapID and House.BLACKWATER_MAPS[mapID] then return ns.Plan.BLACKWATER, "map " .. mapID, true end
  local zone = GetZoneText and GetZoneText() or ""
  local sub = GetSubZoneText and GetSubZoneText() or ""
  if House.BLACKWATER_ZONES[zone] or House.BLACKWATER_ZONES[sub] then
    return ns.Plan.BLACKWATER, "zone " .. (House.BLACKWATER_ZONES[sub] and sub or zone), true
  end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local h = faction and FACTION_HOUSE[faction]
  if h then
    local caps = House.FACTION_CAPITALS[faction]
    return h, "faction " .. faction, (caps and caps[zone]) and true or false
  end
  return nil, "unknown (faction " .. tostring(faction) .. ")", false
end

-- "auto"/empty clears the override; a number sets it. Returns false on bad input.
function House.Set(arg)
  local db = ns.db
  if arg == nil or arg == "" or arg == "auto" then db.house = nil return true end
  local n = tonumber(arg)
  if not n or n ~= math.floor(n) or n < 0 then return false end
  db.house = n
  return true
end
