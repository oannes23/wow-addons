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
function House.Detect()
  local db = ns.db
  if db and db.house then return db.house, "manual override", true end
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
