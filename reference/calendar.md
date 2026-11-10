# In-game calendar API (Forever)

Confidence key as in [forever-platform.md](forever-platform.md). Source build 1.60.1.70862. Run in the client on 2026-11-09 (build 70862), see "In-game results" below. Used by `addons/ItemDataExport/Calendar.lua` (`/ide calendar`).

| Fact | Evidence |
|---|---|
| `Blizzard_Calendar` loads on Forever: its TOC has no addon-level `AllowLoadGameType`. The only Camelot override is `Camelot/CalendarFilterData.lua` (a filter list), so the Mainline logic applies. | [SRC] `Blizzard_Calendar/Blizzard_Calendar.toc`, `Blizzard_Calendar/Camelot/` |
| **The selected month is global client state.** The month offset in `C_Calendar.GetNumDayEvents`, `GetDayEvent` and `GetHolidayInfo` is relative to it, and `GetMonthInfo()` with no argument reads it. Code that walks months must select each one with `SetAbsMonth(month, year)`, read at offset 0, and restore the previous selection. | [SRC] `Blizzard_Calendar/Mainline/Blizzard_Calendar.lua` (`CalendarFrame_OffsetMonth`, the open sequence near `C_Calendar.OpenCalendar()`) |
| Blizzard's open sequence: `SetAbsMonth(current)` → frame update → `C_Calendar.OpenCalendar()`. Data arrival is signalled by `CALENDAR_UPDATE_EVENT_LIST` (no payload). Whether data is in fact asynchronous on Forever is [TODO-INGAME]. | [SRC] same file |
| `CalendarDayEvent.calendarType` is a string: `PLAYER`, `GUILD_ANNOUNCEMENT`, `GUILD_EVENT`, `COMMUNITY_EVENT`, `SYSTEM`, `HOLIDAY`, `RAID_LOCKOUT`, `RAID_RESET`. `sequenceType` is `START`, `ONGOING`, `END` or `""`; a day's first holiday row can be `ONGOING`. | [SRC] same file |
| `CalendarTime` has `year, month, monthDay, weekday, hour, minute`: no seconds and no time zone. Hours are realm-local, not client-local [INFER from the 2026-11-09 dump: the fishing tournament reads 14:00–16:00 on a client set to US Eastern, matching its server-time schedule]. | [SRC] `tools/wowapi.py table CalendarTime` |
| `C_Calendar.GetDayEvent` carries `SecretInChatMessagingLockdown`: its return may be secret during a chat lockdown. Guard with `issecretvalue` before using a title as a table key. | [SRC] `tools/wowapi.py fn C_Calendar.GetDayEvent` |

## In-game results (2026-11-09, build 70862)
| Fact | Confidence |
|---|---|
| The calendar returns holidays on Forever. A 13-month walk gave 13 `HOLIDAY` titles: Darkmoon Faire (monthly, 7 days), Stranglethorn Fishing Extravaganza (weekly, Sunday 14:00–16:00), Call to Arms: Arathi Basin / Warsong Gulch / Darkspear Islands (weekly rotation, Tuesday), Hallow's End, Feast of Winter Veil, Lunar Festival, Love is in the Air, Noblegarden, Midsummer Fire Festival, Fireworks Spectacular, Harvest Festival. | [INGAME 2026-11-09] |
| Every `START`/`ONGOING`/`END` row of one occurrence carries the holiday's own `startTime` and `endTime`, not the day's. Group rows by title + `startTime`; do not rely on row order. | [INGAME 2026-11-09] |
| The realm clock of the US Normal realm is US Central time (20:35 realm at 21:35 Eastern). Convert with a zone name (`America/Chicago`), not a fixed offset: the calendar crosses DST. | [INGAME 2026-11-09] |
