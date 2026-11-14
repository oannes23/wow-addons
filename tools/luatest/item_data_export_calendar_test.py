"""Offline harness for addons/ItemDataExport Calendar.lua (the /ide calendar dump).

  uv run --no-project --with lupa python tools/luatest/item_data_export_calendar_test.py
Mocks C_Calendar with a small schedule: a holiday spanning a month boundary (START/ONGOING/END), a one-day
holiday, a raid lockout, plus player and guild events that must be skipped. Covers shape, de-duplication,
month restoration, the async wait/timeout path, the empty-calendar message and /ide reset leaving the dump alone.
"""
import lupa.lua51 as lua51

import item_data_export_test as base

CAL_MOCK = r"""
function GetBuildInfo() return "1.60.1", "70862", "Nov 4 2026", 16001 end
timers = {}
C_Timer.After = function(sec, fn) timers[#timers+1] = { at = now + sec, fn = fn } end
local oldStep = step
function step(dt)
  now = now + (dt or 0.1)
  local due = {}
  for i = #timers, 1, -1 do if timers[i].at <= now then due[#due+1] = table.remove(timers, i) end end
  for i = #due, 1, -1 do due[i].fn() end
end
C_DateAndTime = { GetCurrentCalendarTime = function() return { year = 2026, month = 11, monthDay = 9, hour = 12, minute = 0 } end }
sel = { month = 3, year = 2027 }; absCalls = {}; opened = 0
local function T(y, m, d, h, mi) return { year = y, month = m, monthDay = d, hour = h or 0, minute = mi or 0, weekday = 1 } end
local function Ev(title, ctype, seq, s, e, extra)
  local ev = { eventID = 1, title = title, calendarType = ctype, sequenceType = seq, eventType = 4, startTime = s, endTime = e,
    numSequenceDays = 1 }
  for k, v in pairs(extra or {}) do ev[k] = v end
  return ev
end
local fairS, fairE = T(2026, 11, 28, 0, 1), T(2026, 12, 3, 23, 59)
schedule = {
  ["2026-11-20"] = { Ev("Harvest Day", "HOLIDAY", "", T(2026,11,20), T(2026,11,20,23,59), { iconTexture = 111 }) },
  ["2026-11-21"] = { Ev("Raid reset", "RAID_LOCKOUT", "", T(2026,11,21,3), T(2026,11,21,3)),
                     Ev("Bob's party", "PLAYER", "", T(2026,11,21,20), T(2026,11,21,22)) },
  ["2026-11-28"] = { Ev("Test Fair", "HOLIDAY", "START", fairS, fairE, { iconTexture = 222, numSequenceDays = 6 }) },
  ["2026-11-29"] = { Ev("Test Fair", "HOLIDAY", "ONGOING", fairS, fairE) },
  ["2026-11-30"] = { Ev("Test Fair", "HOLIDAY", "ONGOING", fairS, fairE), Ev("Guild raid", "GUILD_EVENT", "", T(2026,11,30,20), T(2026,11,30,23)) },
  ["2026-12-01"] = { Ev("Test Fair", "HOLIDAY", "ONGOING", fairS, fairE) },
  ["2026-12-03"] = { Ev("Test Fair", "HOLIDAY", "END", fairS, fairE) },
}
local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function at(off) local i = sel.month - 1 + off return i % 12 + 1, sel.year + math.floor(i / 12) end
local function evs(off, day) local m, y = at(off) return schedule[("%04d-%02d-%02d"):format(y, m, day)] or {} end
C_Calendar = {
  SetAbsMonth = function(m, y) sel = { month = m, year = y } absCalls[#absCalls+1] = ("%04d-%02d"):format(y, m) end,
  OpenCalendar = function() opened = opened + 1 end,
  GetMonthInfo = function(off) local m, y = at(off or 0) return { month = m, year = y, numDays = DAYS[m], firstWeekday = 1 } end,
  GetNumDayEvents = function(off, day) return #evs(off, day) end,
  GetDayEvent = function(off, day, i) return evs(off, day)[i] end,
  GetHolidayInfo = function(off, day, i) local e = evs(off, day)[i]
    return e and { name = e.title, description = e.title .. " description", texture = 999 } end,
}
function said(pat) for _, p in ipairs(printed) do if p:find(pat, 1, true) then return true end end return false end
"""


def main() -> None:
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(base.MOCK)
    rt.execute(CAL_MOCK)
    g = rt.globals()
    ns = rt.table()
    base.load(rt, ns, ["Locales/enUS.lua", "Data/Builtin.lua", "Export.lua", "Calendar.lua", "Core.lua"])
    slash = g.SlashCmdList["ITEMDATAEXPORT"]

    # 1. Normal run: 3 months; the walk waits for the event, then proceeds.
    slash("calendar 3")
    assert g.opened == 1 and g.ItemDataExportDB.calendar is None  # waiting for data, nothing stored yet
    g.fire("CALENDAR_UPDATE_EVENT_LIST")
    cal = g.ItemDataExportDB.calendar
    assert cal.months == 3 and cal.build == "1.60.1" and cal.buildNumber == "70862" and cal.dumped == 1794200000
    assert list(g.absCalls.values()) == ["2026-11", "2026-11", "2026-12", "2027-01", "2027-03"], list(g.absCalls.values())
    assert (g.sel.month, g.sel.year) == (3, 2027)  # selection restored
    ev = cal.events
    got = [(ev[i].title, ev[i].calendarType, ev[i].sequenceType, ev[i].startTime) for i in range(1, len(ev) + 1)]
    assert got == [
        ("Harvest Day", "HOLIDAY", "", "2026-11-20T00:00:00"),
        ("Raid reset", "RAID_LOCKOUT", "", "2026-11-21T03:00:00"),
        ("Test Fair", "HOLIDAY", "END", "2026-11-28T00:01:00"),  # ties on start sort by sequenceType
        ("Test Fair", "HOLIDAY", "ONGOING", "2026-11-28T00:01:00"),  # 3 ONGOING rows de-duplicated to 1
        ("Test Fair", "HOLIDAY", "START", "2026-11-28T00:01:00"),
    ], got
    assert ev[5].endTime == "2026-12-03T23:59:00" and ev[5].iconTexture == 222 and ev[5].numSequenceDays == 6
    assert ev[5].description == "Test Fair description" and ev[1].iconTexture == 111 and ev[1].eventType == 4
    assert ev[2].description is None  # raid lockout: no holiday info call
    assert g.said("calendar: 5 events over 3 months walked") and g.said("/reload to write SavedVariables")

    # 2. Reset must not wipe the calendar dump.
    slash("reset confirm")
    assert g.ItemDataExportDB.calendar.events[1].title == "Harvest Day"

    # 3. Empty calendar, no event ever arrives: two bounded waits, clear message, previous dump kept, month restored.
    g.schedule = rt.eval("{}")
    g.sel = rt.eval("{ month = 1, year = 2028 }")
    g.printed = rt.eval("{}")
    slash("calendar 2")
    for _ in range(100):
        g.step(0.1)  # 10 s: past both 3 s waits
    assert g.said("no CALENDAR_UPDATE_EVENT_LIST within 3s") and g.said("no calendar events returned (2 months walked, 0 errors)")
    assert g.ItemDataExportDB.calendar.events[1].title == "Harvest Day"  # untouched
    assert (g.sel.month, g.sel.year) == (1, 2028)
    assert g.opened == 3  # initial open + one retry

    # 4. Default is 13 months, year wrap, late timers from a finished run are no-ops, re-entry is refused.
    g.absCalls = rt.eval("{}")
    g.schedule = rt.eval('{ ["2027-11-05"] = { { title = "Late", calendarType = "HOLIDAY", sequenceType = "", eventType = 4, '
                         'startTime = { year = 2027, month = 11, monthDay = 5, hour = 0, minute = 0 }, endTime = {} } } }')
    slash("calendar")
    slash("calendar")
    assert g.said("already running")
    g.fire("CALENDAR_UPDATE_EVENT_LIST")
    assert len(list(g.absCalls.values())) == 1 + 13 + 1 and g.absCalls[14] == "2027-11", list(g.absCalls.values())
    assert g.ItemDataExportDB.calendar.months == 13 and g.ItemDataExportDB.calendar.events[1].title == "Late"
    assert g.ItemDataExportDB.calendar.events[1].endTime is None  # incomplete CalendarTime -> no string
    g.step(5)
    print("ItemDataExport calendar harness: OK")


if __name__ == "__main__":
    main()
