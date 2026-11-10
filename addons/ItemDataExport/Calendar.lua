-- ItemDataExport · Calendar dump (SPEC.md "Calendar dump", D-006).
-- /ide calendar [months]: walks the in-game calendar and stores every system day event (holidays, raid resets)
-- in ItemDataExportDB.calendar for the offline importer. Player, guild and community events are skipped.
-- Loads before Core.lua; Core's slash handler calls ns.DumpCalendar. Nothing here is secret-valued data we branch on.
local addonName, ns = ...
local L = ns.L

local C_Calendar, C_DateAndTime, C_Timer = C_Calendar, C_DateAndTime, C_Timer
local GetServerTime, GetBuildInfo, CreateFrame = GetServerTime, GetBuildInfo, CreateFrame
local issecretvalue = issecretvalue or function() return false end
local pcall, type, tonumber, tostring = pcall, type, tonumber, tostring
local floor, sort = math.floor, table.sort

local DEFAULT_MONTHS, MAX_MONTHS = 13, 36
local WAIT = 3 -- seconds to wait for CALENDAR_UPDATE_EVENT_LIST after OpenCalendar, once per attempt
local MAX_ATTEMPTS = 2 -- the walk is repeated once if the first one found nothing (data may arrive late)
local SKIP = { PLAYER = true, GUILD_ANNOUNCEMENT = true, GUILD_EVENT = true, COMMUNITY_EVENT = true }

local function Say(msg)
  print("|cff33ff99" .. addonName .. "|r " .. msg)
end

local function Stamp(t)
  if type(t) ~= "table" or not t.year or not t.month or not t.monthDay then return nil end
  return ("%04d-%02d-%02dT%02d:%02d:00"):format(t.year, t.month, t.monthDay, t.hour or 0, t.minute or 0)
end

-- One walk over `months` months starting at the current one. Returns the de-duplicated rows, the number of
-- months actually walked, and the number of API errors swallowed. Month selection is global client state, so
-- every month is selected absolutely and read with offset 0.
local function Walk(months)
  local rows, seen, desc, errors, walked = {}, {}, {}, 0, 0
  local cur = C_DateAndTime.GetCurrentCalendarTime()
  for i = 0, months - 1 do
    local idx = cur.month - 1 + i
    local month, year = idx % 12 + 1, cur.year + floor(idx / 12)
    local ok = pcall(C_Calendar.SetAbsMonth, month, year)
    local okInfo, info = pcall(C_Calendar.GetMonthInfo, 0)
    if not ok or not okInfo or type(info) ~= "table" or not info.numDays then
      errors = errors + 1
    else
      walked = walked + 1
      for day = 1, info.numDays do
        local n = C_Calendar.GetNumDayEvents(0, day)
        if type(n) == "number" and not issecretvalue(n) then
          for index = 1, n do
            local okE, e = pcall(C_Calendar.GetDayEvent, 0, day, index)
            if not okE then
              errors = errors + 1
            elseif type(e) == "table" and not issecretvalue(e.title) and not SKIP[e.calendarType] then
              local start, finish = Stamp(e.startTime), Stamp(e.endTime)
              local key = tostring(e.title) .. "|" .. tostring(e.sequenceType) .. "|" .. (start and start:sub(1, 10) or "?")
              if not seen[key] then
                local row = { title = e.title, calendarType = e.calendarType, eventType = e.eventType,
                  sequenceType = e.sequenceType, startTime = start, endTime = finish, eventID = e.eventID,
                  iconTexture = e.iconTexture, numSequenceDays = e.numSequenceDays }
                if e.calendarType == "HOLIDAY" then
                  if desc[e.title] == nil then
                    local okH, h = pcall(C_Calendar.GetHolidayInfo, 0, day, index)
                    desc[e.title] = (okH and type(h) == "table") and { description = h.description, texture = h.texture } or false
                  end
                  local d = desc[e.title]
                  if d then
                    if d.description and d.description ~= "" then row.description = d.description end
                    if not row.iconTexture then row.iconTexture = d.texture end
                  end
                end
                seen[key] = true
                rows[#rows + 1] = row
              end
            end
          end
        end
      end
    end
  end
  sort(rows, function(a, b)
    local sa, sb = a.startTime or "", b.startTime or ""
    if sa ~= sb then return sa < sb end
    if a.title ~= b.title then return tostring(a.title) < tostring(b.title) end
    return tostring(a.sequenceType) < tostring(b.sequenceType)
  end)
  return rows, walked, errors
end

local run -- { token, months, saved, attempt } while a dump is in progress
local frame

local function Restore(saved)
  if saved and saved.month and saved.year then pcall(C_Calendar.SetAbsMonth, saved.month, saved.year) end
end

local function Finish(rows, walked, errors)
  local saved = run.saved
  local months = run.months
  run = nil
  if frame then frame:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST") end
  Restore(saved)
  if #rows == 0 then
    Say(L["no calendar events returned (%d months walked, %d errors). Existing dump left untouched."]:format(walked, errors))
    return
  end
  local build, buildNumber = GetBuildInfo()
  ns.db.calendar = { dumped = GetServerTime(), build = build, buildNumber = buildNumber, months = months, events = rows }
  Say(L["calendar: %d events over %d months walked (%d errors). /reload to write SavedVariables."]:format(#rows, walked, errors))
end

local WaitThenWalk

local function Proceed(token)
  if not run or run.token ~= token or run.proceeded == run.attempt then return end
  run.proceeded = run.attempt
  local rows, walked, errors = Walk(run.months)
  if #rows == 0 and run.attempt < MAX_ATTEMPTS then
    run.attempt = run.attempt + 1
    Say(L["calendar: nothing yet, waiting once more for the client to deliver data"])
    WaitThenWalk()
    return
  end
  Finish(rows, walked, errors)
end

function WaitThenWalk()
  local token = run.token
  run.attempt = run.attempt or 1
  frame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
  local attempt = run.attempt
  C_Timer.After(WAIT, function()
    if run and run.token == token and run.attempt == attempt and run.proceeded ~= attempt then
      Say(L["calendar: no CALENDAR_UPDATE_EVENT_LIST within %ds, reading what the client has"]:format(WAIT))
      Proceed(token)
    end
  end)
  pcall(C_Calendar.OpenCalendar)
end

function ns.DumpCalendar(arg)
  if run then Say(L["calendar dump already running"]); return end
  local months = floor(tonumber(arg) or DEFAULT_MONTHS)
  if months < 1 then months = 1 elseif months > MAX_MONTHS then months = MAX_MONTHS end
  frame = frame or CreateFrame("Frame")
  frame:SetScript("OnEvent", function()
    if run then Proceed(run.token) end
  end)
  local ok, saved = pcall(C_Calendar.GetMonthInfo, 0)
  run = { token = {}, months = months, attempt = 1,
    saved = (ok and type(saved) == "table") and { month = saved.month, year = saved.year } or nil }
  local cur = C_DateAndTime.GetCurrentCalendarTime()
  pcall(C_Calendar.SetAbsMonth, cur.month, cur.year) -- same as Blizzard's CalendarFrame_OnShow
  Say(L["calendar: walking %d months from %04d-%02d"]:format(months, cur.year, cur.month))
  WaitThenWalk()
end
