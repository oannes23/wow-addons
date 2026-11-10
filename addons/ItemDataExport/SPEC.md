# ItemDataExport: spec

## Problem
The AH archive (private `wowf-ah-collector`) identifies items only by `item_id` plus a random-suffix `bonus_lists` id (64 ids, 12688–12761 and 12911–12920). Names, stats and classes are needed to answer "which variants sell best" (collector SPEC D-009/D-010). The static Game Data API 404s on ~43% of Forever item ids, and community databases' Forever coverage is unknown. The game client is ground truth for the build players actually see.

## Scope
- In: a **developer tool**. Takes a generated list of `(item_id[, bonus_id[, modifier_type, modifier_value]])` tuples, loads each item from the server, and records base item info, the resolved link name, item level, stats and every tooltip line, per tuple, into SavedVariables. The collector's importer turns that into `dim/*.csv`.
- In (D-006): a **calendar dump**. `/ide calendar [months]` walks the in-game calendar and records every system day event (holidays such as Darkmoon Faire and seasonal events; raid resets/lockouts if present) into SavedVariables, so the offline pipeline gets the client's authoritative holiday schedule months ahead.
- Out: any UI beyond chat output, any AH or market interaction, combat or unit data, and public release (not packaged by `release-addon.sh`; the input list is derived from the private archive and is gitignored).

## Secret-value viability (required; see reference/secret-values.md)
| Data needed | API | Secrecy flags (tools/wowapi.py, build 1.60.1.70790) | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Base item info (name, quality, ilvl, min level, class/subclass, equip loc, bind, stack, sell price) | `C_Item.GetItemInfo(link)` | SecretArguments=AllowedWhenUntainted; returns not secret; MayReturnNothing | n/a (stored, not displayed) | nil means not cached yet: retry after load |
| Async load | `C_Item.RequestLoadItemDataByID`, event `ITEM_DATA_LOAD_RESULT(itemID, success)` (SynchronousEvent) | none on returns | n/a | throttle in-flight requests; per-request timeout + one retry |
| Already cached? | `C_Item.IsItemDataCachedByID` | none on returns | n/a | skip the request |
| Stats with bonus applied | `C_Item.GetItemStats(link)` | SecretArguments=AllowedWhenUntainted; MayReturnNothing | n/a | nil stored as absent |
| Effective item level | `C_Item.GetDetailedItemLevelInfo(link)` | MayReturnNothing | n/a | |
| Full tooltip text (suffix name line, stat lines, requirements) | `C_TooltipInfo.GetHyperlink(link)` | SecretArguments=AllowedWhenUntainted; MayReturnNothing | n/a | line field names aren't in the local docs, so every string field of every line is stored (D-003) |
| Build/locale stamp | `GetBuildInfo`, `GetLocale`, `GetServerTime` | none | n/a | |

Calendar dump (build 1.60.1.70862; sources: `Blizzard_APIDocumentationGenerated/CalendarDocumentation.lua`, `Blizzard_Calendar/Mainline/Blizzard_Calendar.lua`):
| Data needed | API | Secrecy flags (tools/wowapi.py) | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Today / current month | `C_DateAndTime.GetCurrentCalendarTime()` -> CalendarTime | none | n/a | |
| Selected month (to restore) and day count | `C_Calendar.GetMonthInfo(offsetMonths=0)` -> {month, year, numDays, firstWeekday} | SecretArguments=AllowedWhenUntainted | n/a | pcall; month not restored if unreadable |
| Select a month | `C_Calendar.SetAbsMonth(month, year)` | SecretArguments=AllowedWhenUntainted | n/a | pcall; **global state**, restored afterwards |
| Ask the server for data | `C_Calendar.OpenCalendar()` | none | n/a | pcall; bounded wait on `CALENDAR_UPDATE_EVENT_LIST` (UniqueEvent) |
| Events per day | `C_Calendar.GetNumDayEvents(offsetMonths, monthDay)` | SecretArguments=AllowedWhenUntainted | n/a | skip if not a number or `issecretvalue` |
| Day event | `C_Calendar.GetDayEvent(offsetMonths, monthDay, index)` -> CalendarDayEvent | **SecretInChatMessagingLockdown**, SecretArguments=AllowedWhenUntainted; MayReturnNothing | n/a (stored, not displayed) | pcall; row skipped if `title` is secret or nil |
| Holiday description/texture | `C_Calendar.GetHolidayInfo(offsetMonths, monthDay, index)` -> {name, description, texture, startTime?, endTime?} | SecretArguments=AllowedWhenUntainted; MayReturnNothing | n/a | pcall; cached per title; row keeps no description if nil |

No API used returns secret values (except possibly `GetDayEvent` while chat messaging is locked down [flag SecretInChatMessagingLockdown; exact trigger unverified]: run the dump in a city), and nothing branches on combat or unit state. Viable everywhere, though it's meant to run in a city.

## Forever-specific considerations (reference/forever-vs-mainline.md)
- Calendar: `Blizzard_Calendar` is LoadOnDemand with no addon-level `AllowLoadGameType`, so it loads on Camelot; `Camelot/` holds only `CalendarFilterData.lua` (filter list), `Mainline/Blizzard_Calendar.lua` is the logic. No override changes the API use here [SRC]. We never load or touch the Blizzard calendar frame: only `C_Calendar` is called. **Month selection is global client state shared with Blizzard's calendar UI**: `GetNumDayEvents`/`GetDayEvent`/`GetHolidayInfo` take a month *offset relative to the selected month*, `CalendarFrame_OnShow` does `SetAbsMonth(current)` then `OpenCalendar()` (Blizzard_Calendar.lua:1138-1145) and `CalendarFrame_OffsetMonth` calls `SetMonth(offset)` (:1775). We select each month absolutely and read with offset 0, then restore the month that `GetMonthInfo(0)` reported before the walk.
- No Blizzard frames are touched or hooked. `EventUtil` (template default) only.
- **Item string layout with bonus ids is [WIKI]-only** (not in the local source): `item:<id>:<enchant>:<gem1-4>:<suffix>:<unique>:<linkLevel>:<spec>:<modMask>:<context>:<numBonus>:<bonus...>:<numMods>:<type>:<value>...`. Self-verified (D-002): the client's canonical `itemLink` is stored next to the link we built, and the importer checks that the bonus id survived and that the name differs from the base name.

## UX
- `/ide start`: resolve every tuple in the input (resumable: already-resolved keys are skipped). Progress prints every 10%.
- `/ide status`: counts (done / pending / in flight / failed), input stamp.
- `/ide stop`: pause. `/ide reset`: clear results (asks for `/ide reset confirm`).
- When done, prints "done, /reload to write SavedVariables".
- `/ide calendar [months]`: months defaults to 13 (current month onward), clamped 1..36. Selects the current month, calls `OpenCalendar()`, waits up to 3 s for `CALENDAR_UPDATE_EVENT_LIST` (the walk starts as soon as it fires), walks every month and day, restores the previously selected month, and prints `calendar: N events over M months walked (E errors). /reload to write SavedVariables.` If nothing is found it waits once more (3 s) and re-walks, then prints `no calendar events returned (...)` and leaves any earlier dump untouched. Refuses re-entry while running.
- `/ide reset confirm` does **not** clear the calendar dump (it is cheap to regenerate but unrelated to the item results; wiping both with one command would lose hours-old schedule data for no reason). Delete `ItemDataExportDB.calendar` by running `/ide calendar` again (overwrites on success).

## Data model (SavedVariables `ItemDataExportDB`)
```lua
ItemDataExportDB = {
  version = 1,
  meta = { build = "1.60.1", buildNumber = "70790", interface = 16001, locale = "enUS",
           input = { generated = "...", source = "...", n = 12345 }, started = <epoch>, finished = <epoch> },
  items = { [itemID] = { name=, quality=, ilvl=, minLevel=, type=, subType=, equipLoc=, classID=, subclassID=,
                         bind=, stack=, sell=, expansion=, reagent= } },
  results = { ["3195:12918"] = { link = <built>, clientLink = <canonical>, name =, ilvl =, stats = { ITEM_MOD_*=n },
                                 tip = { { leftText="...", ... }, ... } } },   -- key: item[:bonus[:modType:modValue]]
  failed = { [key] = "reason" },
  calendar = {                       -- written by /ide calendar (D-006); absent until run
    dumped = <GetServerTime epoch>, build = "1.60.1", buildNumber = "70862", months = 13,
    events = {                       -- sorted by startTime, title, sequenceType; one row per (title, sequenceType, start date)
      { title = "Darkmoon Faire", calendarType = "HOLIDAY", eventType = 4, sequenceType = "START",
        startTime = "2026-11-28T00:01:00", endTime = "2026-12-03T23:59:00",   -- realm-local wall clock, no zone
        eventID = 479, iconTexture = 235448, numSequenceDays = 6, description = "..." },
      -- "ONGOING" / "END" rows for the same holiday follow; calendarType may also be "RAID_LOCKOUT", "RAID_RESET", "SYSTEM"
    },
  },
}
```

Calendar rows come from `CalendarDayEvent` (eventID, title, calendarType, sequenceType, eventType, iconTexture, numSequenceDays, startTime, endTime) plus, for `HOLIDAY` rows, `CalendarHolidayInfo` (description, texture, used as `iconTexture` when the event has none). `CalendarTime` fields used: year, month, monthDay, hour, minute (seconds are written as `00`); weekday is dropped. Kept: every `calendarType` except `PLAYER`, `GUILD_ANNOUNCEMENT`, `GUILD_EVENT`, `COMMUNITY_EVENT` (strings per Blizzard_Calendar.lua:396-423). The importer collapses START/ONGOING/END itself, so `sequenceType` is kept. The `example event` values above are illustrative, not observed.

## Input (generated, gitignored)
`Data/Pairs.lua` is written by the collector's `scripts/export_pairs.py`, which runs on bob read-only:
```lua
local _, ns = ...
ns.INPUT = { generated = "2026-11-09T...", source = "item_snapshot/v1 all houses",
  tuples = { {869}, {3195, 12918}, {3195, 12918, 28, 5254}, ... } }
```
If it's missing, `Data/Builtin.lua` provides a ~10-tuple smoke set (items verified on house 114). The client logs the missing file and continues [INFER, verify].

## Open questions / in-game verification
- [x] Bonus-list item strings resolve to the suffixed name: 22,081/22,081, in both the link name and tooltip line 1, and the bonus id survives in the client's canonical link. The [WIKI] layout is confirmed. [INGAME 2026-11-09, build 1.60.1.70862]
- [x] `GetItemStats(link)` reflects the suffix: stats differ across suffixes on all 1,058 multi-suffix items. [INGAME 2026-11-09]
- [x] Modifier type 28 changes nothing visible (ilvl, stats, tooltip identical across 150 probes). [INGAME 2026-11-09]
- [ ] Does a missing `Data/Pairs.lua` cause a visible error? (not exercised: the first run had the file)
- [x] Throughput: 26,583 tuples / 5,498 items in one session with 0 failures at 20 in flight. SavedVariables 21.4 MB. [INGAME 2026-11-09]

## Calendar dump: open [TODO-INGAME]
- [ ] Does `C_Calendar` return holidays on Forever at all (Darkmoon Faire, seasonal events, raid resets)? Everything below depends on it.
- [ ] Time zone of `startTime`/`endTime`: realm local (as Blizzard's UI shows via `GameTime_GetFormattedTime`) or client local? Step 6 below compares.
- [ ] How far ahead does the client know the schedule? (`C_Calendar.GetMaxCreateDate()` exists but bounds event creation, not holidays; the walk does not clamp to it.) Inspect the last month with events in the dump.
- [ ] Is data asynchronous? Blizzard calls `OpenCalendar()` and refreshes on `CALENDAR_UPDATE_EVENT_LIST` (Blizzard_Calendar.lua:1104). Whether holidays need that round trip, and whether `SetAbsMonth` to another month triggers more fetches, is unknown; the dump handles both (event or 3 s timeout, one retry).
- [ ] Do ONGOING rows carry the holiday's original `startTime` or that day's? The de-duplication key (title, sequenceType, start date) collapses them only in the first case; otherwise expect one ONGOING row per day (the importer should collapse).
- [ ] Is `eventID` stable across days/months for one holiday, and are `SYSTEM`/`RAID_*` types present at all?
- [ ] Does `GetDayEvent` ever return secret values outside chat lockdown?

## Calendar dump: in-game verification (owner steps)
1. `/console scriptErrors 1`, then log in to a city (not mid-encounter).
2. Probe first, one line as its own chat message (253 characters; prints today's event count and the first event). It selects the current calendar month, which is harmless (the dump does the same):
```
/run local d=C_DateAndTime.GetCurrentCalendarTime();C_Calendar.SetAbsMonth(d.month,d.year);local n=C_Calendar.GetNumDayEvents(0,d.monthDay);local e=C_Calendar.GetDayEvent(0,d.monthDay,1);print("IDEcal today events:",n,e and e.title,e and e.calendarType)
```
   Expected: `IDEcal today events: <n> <title or nil> <HOLIDAY|...|nil>`. `0 nil nil` on a day with no holiday is not a failure; try a day inside Darkmoon Faire week. A Lua error means a signature or global differs from the docs: report it verbatim.
3. `/ide calendar` (13 months) and wait for the summary line. Messages to report verbatim if they appear: `no CALENDAR_UPDATE_EVENT_LIST within 3s`, `nothing yet`, `no calendar events returned`.
4. `/reload` (SavedVariables are written on reload/logout).
5. File: `/Applications/World of Warcraft/_forever_/WTF/Account/<ACCOUNT>/SavedVariables/ItemDataExport.lua`, table `ItemDataExportDB.calendar`.
6. Cross-check: open the Blizzard calendar (default keybind none; `/run ToggleCalendar()`), compare one holiday's start/end date and time to the stored row, and compare the displayed server time (`/run print(date("%H:%M"), GetGameTime())`) against the stored hour fields to settle the time-zone question.

## Decisions
- D-001 (2026-11-09): input is a generated Lua file shipped with the addon (gitignored), not SavedVariables edits. The client only reads SavedVariables at login and overwrites them on logout, so hand-editing them is fragile.
- D-002 (2026-11-09): self-verifying output. Store the built link and the client's canonical link, the link name, `GetItemStats` and the full tooltip for every tuple, and let the offline importer decide which source is trustworthy. One in-game session then answers all of the open questions.
- D-003 (2026-11-09): tooltip lines are stored as every string-valued field of each line, because the `TooltipDataLine` field names aren't in the local docs.
- D-004 (2026-11-09): load throttling: ≤ 20 requests in flight, 10 s timeout, one retry, then the key is marked failed. Items already cached skip the request. Captures from cached items are budgeted at 100 **tuples** per 0.1 s tick, not items (the first real input has 26,583 tuples over 5,498 items, up to 46 per item). Tooltip lines keep string fields only, to bound SavedVariables size.
- D-005 (2026-11-09): not released publicly. A dev tool for one account, so no CHANGELOG/semver release flow until there's a reason.
- D-006 (2026-11-09): the calendar dump lives in ItemDataExport, not a new addon. Same dev-tool pattern: the game client is ground truth, results go through SavedVariables to an offline importer in the private collector, and it is never released publicly (D-005). It shares the slash entry, the SavedVariables table and the review/harness setup, and a one-command, ~100-line dump does not justify another addon directory, TOC and spec. Consequence: the addon is now "client-truth exporter" rather than "item resolver"; if a third export appears, split a common `Export` core instead of growing Core.lua. `/ide reset confirm` leaves the calendar alone. Stored as client-local wall-clock strings (no zone) because `CalendarTime` has none; the importer must attach the realm zone once [TODO-INGAME] settles it. Walk strategy: select each month absolutely, read with offset 0, restore the user's month (global state shared with Blizzard's calendar UI).
