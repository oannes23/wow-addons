-- House detection: which auction house is the player standing at (111 Alliance, 114 Horde, 117 Blackwater).
-- Blackwater AHs are expected in Booty Bay, Gadgetzan and Everlook. uiMapIDs are unknown (SPEC [TODO-INGAME]);
-- fill House.BLACKWATER_MAPS from the in-game probe. Zone names are the working fallback. In vanilla geography
-- these towns are subzones of Stranglethorn Vale / Tanaris / Winterspring, so zone and subzone are both checked.
local addonName, ns = ...

local House = {}
ns.House = House

House.BLACKWATER_MAPS = {} -- [uiMapID] = true; [TODO-INGAME] Booty Bay, Gadgetzan, Everlook
House.BLACKWATER_ZONES = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }
local FACTION_HOUSE = { Horde = 114, Alliance = 111 }

-- Returns houseID (or nil if unknown) and a short reason string for `/wuwei status`.
function House.Detect()
  local db = ns.db
  if db and db.house then return db.house, "manual override" end
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if mapID and House.BLACKWATER_MAPS[mapID] then return ns.Plan.BLACKWATER, "map " .. mapID end
  local zone = GetZoneText and GetZoneText() or ""
  local sub = GetSubZoneText and GetSubZoneText() or ""
  if House.BLACKWATER_ZONES[zone] or House.BLACKWATER_ZONES[sub] then
    return ns.Plan.BLACKWATER, "zone " .. (House.BLACKWATER_ZONES[sub] and sub or zone)
  end
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local h = faction and FACTION_HOUSE[faction]
  if h then return h, "faction " .. faction end
  return nil, "unknown (faction " .. tostring(faction) .. ")"
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
