-- ItemDataExport · Disenchant logger (SPEC.md "Disenchant logger", D-011..D-014).
-- Passive. A player cast of a known disenchant spell + the bag item it locks + the loot window that follows
-- = one row in ItemDataExportDB.disenchants.rows. /ide de on|off|status|spell <id>|clear confirm.
-- Nothing secret is stored or branched on: any secret event payload makes the event ignored.
-- luacheck: read globals GetNumLootItems GetLootSlotInfo GetLootSlotLink GetLootSlotType C_Container C_Spell
local _, ns = ...
local L = ns.L
local Say = ns.Say

local C_Item, C_Container, C_Spell = C_Item, C_Container, C_Spell
local GetTime, GetServerTime, CreateFrame = GetTime, GetServerTime, CreateFrame
local GetNumLootItems, GetLootSlotInfo, GetLootSlotLink, GetLootSlotType = GetNumLootItems, GetLootSlotInfo, GetLootSlotLink, GetLootSlotType
local issecretvalue = issecretvalue or function() return false end
local pcall, type, pairs, ipairs, tonumber, tostring = pcall, type, pairs, ipairs, tonumber, tostring

local ROW_CAP = 5000 -- D-013: oldest rows are dropped beyond this
local CAST_TTL = 20 -- seconds a SENT cast stays eligible (DE channel/cast time is ~3 s; generous for latency)
local LOCK_LOOKBACK = 2 -- seconds: a bag-item lock seen this long BEFORE the cast event still counts
local LOOT_AFTER_SUCCESS = 5 -- seconds after UNIT_SPELLCAST_SUCCEEDED in which a loot window is attributed
-- [INFER] Classic's Disenchant is 13262. The id is NOT in the local Blizzard source, so it is a hypothesis: the
-- owner verifies in game (SPEC checklist) and can add ids with /ide de spell <id>. Rows record the spellID used.
local DEFAULT_SPELLS = { [13262] = true }

local state = { enabled = true, spells = {}, lastLock = nil, cast = nil, hint = nil }
local frame

local function Num(v)
  if type(v) == "number" and not issecretvalue(v) then return v end
  return nil
end

local function Str(v)
  if type(v) == "string" and not issecretvalue(v) and v ~= "" then return v end
  return nil
end

local function ItemIDFromLink(link)
  link = Str(link)
  return link and tonumber(link:match("item:(%d+)")) or nil
end

local function DB()
  local d = ns.db.disenchants
  if type(d) ~= "table" then d = {}; ns.db.disenchants = d end
  d.version = d.version or 1
  d.rows = d.rows or {}
  d.stats = d.stats or {}
  d.extraSpells = d.extraSpells or {}
  return d
end

local function Bump(key)
  local s = DB().stats
  s[key] = (s[key] or 0) + 1
end

local function IsDisenchantSpell(id)
  return state.spells[id] == true
end

-- Snapshot of the bag item in (bag, slot), taken at lock time because the item is consumed by the cast.
local function Snapshot(bag, slot)
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  if not ok or type(info) ~= "table" or issecretvalue(info.isLocked) or info.isLocked ~= true then return nil end
  local link = Str(info.hyperlink)
  local itemID = Num(info.itemID) or ItemIDFromLink(link)
  if not itemID then return nil end
  local snap = { itemID = itemID, link = link, quality = Num(info.quality), bag = bag, slot = slot }
  local okI, _, _, _, equipLoc, _, classID, subclassID = pcall(C_Item.GetItemInfoInstant, link or itemID)
  if okI then snap.classID, snap.subclassID, snap.equipLoc = Num(classID), Num(subclassID), Str(equipLoc) end
  local okL, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, link or itemID)
  snap.ilvl = okL and Num(ilvl) or nil
  if not snap.ilvl or not snap.quality then
    local okG, _, _, quality, baseIlvl = pcall(C_Item.GetItemInfo, link or itemID)
    if okG then snap.ilvl = snap.ilvl or Num(baseIlvl); snap.quality = snap.quality or Num(quality) end
  end
  return snap
end

-- Loot slots -> { { itemID, qty } | { currencyID, qty } }. Money slots are skipped.
local function ReadLoot()
  local out = {}
  local nOk, n = pcall(GetNumLootItems)
  n = nOk and Num(n) or 0
  for i = 1, n do
    local okT, slotType = pcall(GetLootSlotType, i)
    local okI, _, _, qty, currencyID = pcall(GetLootSlotInfo, i)
    slotType, qty, currencyID = okT and Num(slotType) or nil, okI and Num(qty) or nil, okI and Num(currencyID) or nil
    if slotType == 1 then -- Enum.LootSlotType.Item
      local okL, link = pcall(GetLootSlotLink, i)
      local itemID = okL and ItemIDFromLink(link) or nil
      if itemID then out[#out + 1] = { itemID = itemID, qty = qty or 1 } end
    elseif slotType == 3 and currencyID then -- Enum.LootSlotType.Currency
      out[#out + 1] = { currencyID = currencyID, qty = qty or 1 }
    end
  end
  return out
end

local function AddRow(cast, loot)
  local d = DB()
  local src = cast.src
  local build, buildNumber = ns.BuildStamp()
  d.rows[#d.rows + 1] = { ts = GetServerTime(), build = build, buildNumber = buildNumber, spellID = cast.spellID,
    itemID = src.itemID, link = src.link, ilvl = src.ilvl, quality = src.quality, classID = src.classID,
    subclassID = src.subclassID, equipLoc = src.equipLoc, loot = loot }
  local over = #d.rows - ROW_CAP
  if over > 0 then
    for i = 1, #d.rows - over do d.rows[i] = d.rows[i + over] end
    for i = #d.rows, #d.rows - over + 1, -1 do d.rows[i] = nil end
    d.stats.dropped = (d.stats.dropped or 0) + over
  end
  d.stats.rows = (d.stats.rows or 0) + 1
end

local function OnLoot()
  local cast = state.cast
  if not cast then return end
  local now = GetTime()
  if now - cast.sent > CAST_TTL or (cast.succeeded and now - cast.succeeded > LOOT_AFTER_SUCCESS) then
    state.cast = nil
    return
  end
  local loot = ReadLoot()
  if #loot == 0 then return end -- not the window (or empty/money only): keep waiting
  state.cast = nil -- consumed: LOOT_READY and LOOT_OPENED both land here, the second finds no cast
  if not cast.src then
    Bump("noSource")
    Say(L["disenchant: loot seen after spell %s but no bag item was seen locking; row skipped (/ide de status)"]:format(tostring(cast.spellID)))
    return
  end
  AddRow(cast, loot)
end

local function OnLockChanged(bag, slot)
  if not state.enabled or not Num(bag) or not Num(slot) then return end
  local snap = Snapshot(bag, slot)
  if not snap then return end
  snap.t = GetTime()
  local cast = state.cast
  if cast and (not cast.src or cast.src.t < cast.sent) then
    cast.src = snap -- a lock after SENT beats one found by look-back (e.g. an unrelated item pickup just before)
  elseif not cast then
    state.lastLock = snap -- may precede the SENT event
    -- Remember a recent unmatched spell that locked this item, so /ide de status can offer its id.
    local h = state.hint
    if h and snap.t - h.t <= LOCK_LOOKBACK and not IsDisenchantSpell(h.spellID) then h.locked = snap.itemID end
  end
end

local function OnSent(spellID)
  if not Num(spellID) then return end
  local now = GetTime()
  if not IsDisenchantSpell(spellID) then
    state.hint = { spellID = spellID, t = now }
    return
  end
  local cast = { spellID = spellID, sent = now }
  local ll = state.lastLock
  if ll and now - ll.t <= LOCK_LOOKBACK then cast.src = ll end
  state.lastLock = nil
  state.cast = cast
end

local function OnEvent(_, event, a, b, c, d)
  if not state.enabled then return end
  -- Secret payloads (SecretWhenUnitSpellCastRestricted) are ignored unseen: a secret is never compared or stored.
  if issecretvalue(a) then return end
  if event == "UNIT_SPELLCAST_SENT" then
    if a == "player" then OnSent(d) end -- (unit, target, castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a == "player" and state.cast and Num(c) == state.cast.spellID then state.cast.succeeded = GetTime() end -- (unit, castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
    if a == "player" and state.cast and not state.cast.succeeded and Num(c) == state.cast.spellID then state.cast = nil end
  elseif event == "ITEM_LOCK_CHANGED" then
    OnLockChanged(a, b)
  elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
    OnLoot()
  end
end

local EVENTS = { "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_FAILED_QUIET", "ITEM_LOCK_CHANGED", "LOOT_READY", "LOOT_OPENED" }

local function Apply()
  frame = frame or CreateFrame("Frame")
  frame:SetScript("OnEvent", OnEvent)
  frame:UnregisterAllEvents()
  if state.enabled then
    for _, e in ipairs(EVENTS) do
      if e:find("^UNIT_SPELLCAST") then frame:RegisterUnitEvent(e, "player") else frame:RegisterEvent(e) end
    end
  end
end

local function SpellName(id)
  local ok, name = pcall(C_Spell.GetSpellName, id)
  return ok and Str(name) or "?"
end

local function Status()
  local d = DB()
  local ids = {}
  for id in pairs(state.spells) do ids[#ids + 1] = ("%d (%s)"):format(id, SpellName(id)) end
  table.sort(ids)
  local s = d.stats
  Say(L["disenchant logger %s: %d rows (cap %d, %d dropped), %d skipped without source; spells: %s"]:format(
    state.enabled and "ON" or "OFF", #d.rows, ROW_CAP, s.dropped or 0, s.noSource or 0, table.concat(ids, ", ")))
  local h = state.hint
  if h and h.locked then
    Say(L["disenchant: last unmatched spell that locked a bag item: %d (%s). If that is Disenchant: /ide de spell %d"]:format(
      h.spellID, SpellName(h.spellID), h.spellID))
  end
end

local function Command(arg, rest)
  local d = DB()
  if arg == "on" or arg == "off" then
    state.enabled = arg == "on"
    d.enabled = state.enabled
    Apply()
    Status()
  elseif arg == "spell" then
    local id = tonumber(rest)
    if not id then Say(L["/ide de spell <spellID>"]); return end
    d.extraSpells[#d.extraSpells + 1] = id
    state.spells[id] = true
    Status()
  elseif arg == "clear" then
    if rest ~= "confirm" then Say(L["/ide de clear confirm deletes all logged disenchants"]); return end
    d.rows, d.stats = {}, {}
    Say(L["disenchant log cleared"])
  else
    Status()
  end
end

ns.OnDBReady(function()
  local d = DB()
  state.enabled = d.enabled ~= false -- default on
  state.spells = {}
  for id in pairs(DEFAULT_SPELLS) do state.spells[id] = true end
  for _, id in ipairs(d.extraSpells) do if Num(id) then state.spells[id] = true end end
  Apply()
end)

ns.RegisterCommand("de", Command, "de on|off|status|spell <id>|clear confirm")
ns.RegisterStatus(function()
  if ns.db and ns.db.disenchants then Status() else Say(L["disenchant logger: no data yet"]) end
end)
