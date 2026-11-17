-- Headcount · WoW: Forever (Interface 16001). Census seeds (SPEC.md; wowf-ah-collector ADR 0006): the full names of
-- players your client already shows you, kept in HeadcountDB for the owner's push script. Passive: no /who is sent,
-- no message text is read, nothing is transmitted. Any secret value means "skip this name", never a branch on it.
local addonName, ns = ...
local L = ns.L

local type, pairs, ipairs, pcall, time, format = type, pairs, ipairs, pcall, time, string.format

local Headcount = {}
ns.Headcount = Headcount
Headcount.MAX_NAMES, Headcount.MAX_GUILDS = 20000, 2000

local DEFAULTS = { version = 1, enabled = true }

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- "Name Surname" from UnitName's (name, surname) pair, or from a full name that already carries the surname
-- ("Name Surname" or "Name-Surname"). nil when there's no surname: the profile API can't look those up.
function Headcount.Full(name, surname)
  if type(name) ~= "string" or name == "" or Secret(name) then return nil end
  if surname ~= nil and (Secret(surname) or type(surname) ~= "string") then return nil end
  if surname and surname ~= "" then return name .. " " .. surname end
  local a, b = name:match("^([^%s%-]+)[%s%-]+(.+)$")
  if a then return a .. " " .. b end
  return nil
end

local counts = { names = 0, guilds = 0 }

local function Count()
  local n, g = 0, 0
  for _ in pairs(ns.db.names) do n = n + 1 end
  for _ in pairs(ns.db.guilds) do g = g + 1 end
  counts.names, counts.guilds = n, g
end

-- Drop the oldest tenth of a table (value = epoch, or { t = epoch }) when it is full.
local function Trim(tbl, max, key)
  local ts = {}
  for k, v in pairs(tbl) do ts[#ts + 1] = { k, type(v) == "table" and v.t or v } end
  table.sort(ts, function(a, b) return a[2] < b[2] end)
  local drop = #ts - math.floor(max * 0.9)
  for i = 1, drop do tbl[ts[i][1]] = nil end
  counts[key] = #ts - math.max(drop, 0)
end

function Headcount.NoteGuild(guild)
  local db = ns.db
  if not (db and db.enabled) or type(guild) ~= "string" or guild == "" or Secret(guild) then return end
  if db.guilds[guild] == nil then
    if counts.guilds >= Headcount.MAX_GUILDS then Trim(db.guilds, Headcount.MAX_GUILDS, "guilds") end
    counts.guilds = counts.guilds + 1
  end
  db.guilds[guild] = time()
end

function Headcount.Note(full, src, guild, level, class)
  local db = ns.db
  if not (db and db.enabled and full) or full == Headcount.me then return end
  local row = db.names[full]
  if not row then
    if counts.names >= Headcount.MAX_NAMES then Trim(db.names, Headcount.MAX_NAMES, "names") end
    counts.names = counts.names + 1
    row = {}
    db.names[full] = row
  end
  row.t, row.s = time(), src
  if type(guild) == "string" and guild ~= "" and not Secret(guild) then
    row.g = guild
    Headcount.NoteGuild(guild)
  end
  if type(level) == "number" and not Secret(level) and level > 0 then row.l = level end
  if type(class) == "string" and class ~= "" and not Secret(class) then row.c = class end
end

function Headcount.FromUnit(unit, src)
  local okP, isPlayer = pcall(UnitIsPlayer, unit)
  if not okP or Secret(isPlayer) or not isPlayer then return end
  local ok, name, surname = pcall(UnitName, unit)
  if not ok then return end
  local full = Headcount.Full(name, surname)
  if not full then return end
  local guild
  if GetGuildInfo then
    local okG, g = pcall(GetGuildInfo, unit)
    if okG and type(g) == "string" and not Secret(g) then guild = g end
  end
  Headcount.Note(full, src, guild)
end

function Headcount.FromWho()
  if not (C_FriendList and C_FriendList.GetNumWhoResults and C_FriendList.GetWhoInfo) then return end
  local ok, n = pcall(C_FriendList.GetNumWhoResults)
  if not ok or type(n) ~= "number" or Secret(n) then return end
  for i = 1, n do
    local okI, info = pcall(C_FriendList.GetWhoInfo, i)
    if okI and type(info) == "table" then
      Headcount.Note(Headcount.Full(info.fullName), "who", info.fullGuildName, info.level, info.filename)
    end
  end
end

local PUBLIC_CHAT = { CHAT_MSG_SAY = true, CHAT_MSG_YELL = true, CHAT_MSG_CHANNEL = true }

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "NAME_PLATE_UNIT_ADDED" then
    if type(a1) == "string" and not Secret(a1) then Headcount.FromUnit(a1, "np") end
  elseif event == "UPDATE_MOUSEOVER_UNIT" then
    Headcount.FromUnit("mouseover", "mo")
  elseif event == "PLAYER_TARGET_CHANGED" then
    Headcount.FromUnit("target", "mo")
  elseif event == "WHO_LIST_UPDATE" then
    Headcount.FromWho()
  elseif PUBLIC_CHAT[event] then
    Headcount.Note(Headcount.Full(a2), "ch") -- a2 = sender; the message text (a1) is never read
  end
end)

local function InitDB()
  HeadcountDB = HeadcountDB or {}
  local db = HeadcountDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then db[k] = v end
  end
  db.names = type(db.names) == "table" and db.names or {}
  db.guilds = type(db.guilds) == "table" and db.guilds or {}
  ns.db = db
  Count()
end

local EVENTS = { "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED", "WHO_LIST_UPDATE",
  "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL" }

local function OnLogin()
  local ok, name, surname = pcall(UnitName, "player")
  Headcount.me = ok and Headcount.Full(name, surname) or nil
  for _, e in ipairs(EVENTS) do frame:RegisterEvent(e) end
end

EventUtil.ContinueOnAddOnLoaded(addonName, InitDB)
EventUtil.ContinueOnPlayerLogin(OnLogin)

function Headcount.StatusLine()
  local db = ns.db
  local oldest
  for _, v in pairs(db.names) do if not oldest or v.t < oldest then oldest = v.t end end
  local src = {}
  for _, v in pairs(db.names) do src[v.s or "?"] = (src[v.s or "?"] or 0) + 1 end
  local parts = {}
  for _, k in ipairs({ "np", "mo", "ch", "who" }) do if src[k] then parts[#parts + 1] = k .. " " .. src[k] end end
  return format(L["Headcount: %d names, %d guilds%s%s%s"], counts.names, counts.guilds,
    #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "",
    oldest and format(L[" · oldest %dd"], math.floor((time() - oldest) / 86400)) or "",
    db.enabled and "" or L[" · paused"])
end

SLASH_HEADCOUNT1 = "/headcount"
SlashCmdList.HEADCOUNT = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "off" then ns.db.enabled = false
  elseif msg == "on" then ns.db.enabled = true
  elseif msg == "clear" then ns.db.names, ns.db.guilds = {}, {}; counts.names, counts.guilds = 0, 0
  elseif msg ~= "" then print(L["usage: /headcount [on | off | clear]"]) return end
  print(Headcount.StatusLine())
end

function Headcount_OnCompartmentClick()
  SlashCmdList.HEADCOUNT("")
end
