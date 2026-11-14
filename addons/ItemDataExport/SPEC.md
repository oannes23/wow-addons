# ItemDataExport: spec

## Problem
The AH archive (private `wowf-ah-collector`) identifies items only by `item_id` plus a random-suffix `bonus_lists` id (64 ids, 12688–12761 and 12911–12920). Names, stats and classes are needed to answer "which variants sell best" (collector SPEC D-009/D-010). The static Game Data API 404s on ~43% of Forever item ids, and community databases' Forever coverage is unknown. The game client is ground truth for the build players actually see.

## Scope
- In: a **developer tool**. Takes a generated list of `(item_id[, bonus_id[, modifier_type, modifier_value]])` tuples, loads each item from the server, and records base item info, the resolved link name, item level, stats and every tooltip line, per tuple, into SavedVariables. The collector's importer turns that into `dim/*.csv`.
- In (D-006): a **calendar dump**. `/ide calendar [months]` walks the in-game calendar and records every system day event (holidays such as Darkmoon Faire and seasonal events; raid resets/lockouts if present) into SavedVariables, so the offline pipeline gets the client's authoritative holiday schedule months ahead.
- In (D-008..D-010): a **recipe dump**. `/ide recipes` records every recipe of the open profession window (learned and unlearned), with output, reagents, difficulty and category, merged by recipe id across professions and runs. The pipeline computes crafting conversion spreads and profession-levelling demand from it.
- In (D-011..D-014): a passive **disenchant logger**. Every disenchant the player performs is logged (source item, loot) so the pipeline can test whether Forever uses the Classic disenchant table instead of trusting it.
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

Recipe dump (build 1.60.1.70862; sources: `Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua`, `TradeSkillUITypesDocumentation.lua`, `Blizzard_Professions/Camelot/*`, `Blizzard_ProfessionsTemplates/Blizzard_Professions.lua`, `BlizzardInterfaceResources/Resources/GlobalAPI.lua`):
| Data needed | API | Secrecy flags (tools/wowapi.py) | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Open profession (id, name, rank, max, modifier) | `C_TradeSkillUI.GetChildProfessionInfo()` then `GetBaseProfessionInfo()` -> ProfessionInfo {professionID, professionName, parentProfessionID/Name, skillLevel, maxSkillLevel, skillModifier} | no flags, returns not secret | n/a (stored) | same fallback order as `Professions.GetProfessionInfo` (Blizzard_Professions.lua:1665-1681); `professionID == 0` means no window |
| Recipe ids | `C_TradeSkillUI.GetAllRecipeIDs()`, `GetFilteredRecipeIDs()` | **not in the generated docs** (`wowapi.py exists`: `in_GlobalAPI` true, `documented_as` empty), so flags unknown; Blizzard's recipe list iterates `GetFilteredRecipeIDs` (Blizzard_Professions.lua:847) | n/a | union of both, pcall, `type == number` filter; empty list = window not loaded yet |
| Recipe facts (name, learned, category, difficulty, trivial level, skill-ups) | `C_TradeSkillUI.GetRecipeInfo(recipeID)` -> TradeSkillRecipeInfo? | SecretArguments=AllowedWhenUntainted; returns not secret | n/a | pcall; nil row skipped; every stored scalar passes `issecretvalue` |
| Output item + quantity, reagent slots | `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` -> CraftingRecipeSchematic {outputItemID?, quantityMin/Max, reagentSlotSchematics} | SecretArguments=AllowedWhenUntainted | n/a | pcall; `isRecraft` is always false |
| Output fallback | `C_TradeSkillUI.GetRecipeOutputItemData(recipeID)` -> {itemID?} | SecretArguments=AllowedWhenUntainted | n/a | only when the schematic has no `outputItemID` |
| Cooldown | `C_TradeSkillUI.GetRecipeCooldown(recipeID)` -> cooldown, isDayCooldown, charges, maxCharges | **not in the generated docs** (in GlobalAPI.lua; Blizzard calls it, Blizzard_Professions.lua:1571) | n/a | pcall; **remaining** seconds at dump time, not the period |
| Category tree | `C_TradeSkillUI.GetCategoryInfo(categoryID)` | **not in the generated docs**, struct not documented | n/a | all scalar fields kept (D-003 style), parent chain followed (max depth 8) |
| `all` mode | `C_TradeSkillUI.OpenTradeSkill(skillLineID)`, `GetProfessions()`, `GetProfessionInfo(i)` (7th return = skill line), event `TRADE_SKILL_LIST_UPDATE` (UniqueEvent) | OpenTradeSkill: SecretArguments=AllowedWhenUntainted, **not** flagged IsProtectedFunction; GetProfessions/GetProfessionInfo undocumented (GlobalAPI.lua) | n/a | pcall; unopenable profession is reported and skipped |
| Filter state | `C_TradeSkillUI.GetShowUnlearned()` | none | n/a | read-only: we never call `SetShowUnlearned` (global UI state) |

No recipe API returns secret values: crafting data is not combat/unit/aura/cooldown-restricted. Cooldown here is a **recipe** cooldown (trade-skill system), not a spell-cooldown API, so the cooldown secrecy (`C_Secrets.ShouldCooldownsBeSecret`) is not expected to apply; `issecretvalue` guards every read anyway [INFER, verify in combat only if it ever matters].

Disenchant logger (build 1.60.1.70862; sources: `UnitDocumentation.lua`, `ContainerDocumentation.lua`, `LootDocumentation.lua`, `Blizzard_UIPanels_Game/Mainline/LootFrame.lua`):
| Data needed | API | Secrecy flags (tools/wowapi.py) | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Player began a cast | event `UNIT_SPELLCAST_SENT(unit, target, castGUID, spellID)` | **SecretWhenUnitSpellCastRestricted=True**, SynchronousEvent | n/a | registered with `RegisterUnitEvent(..., "player")`; handler returns if the unit payload is secret; `spellID` must be a non-secret number; `target` (item name) is never read |
| Cast finished / failed | events `UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID, castBarID?)` (SecretWhenUnitSpellCastRestricted=True), `UNIT_SPELLCAST_INTERRUPTED`, `UNIT_SPELLCAST_FAILED`, `UNIT_SPELLCAST_FAILED_QUIET` (no secrecy flag on the latter three) | as listed | n/a | same guard |
| Which bag item was consumed | event `ITEM_LOCK_CHANGED(bagOrSlotIndex, slotIndex?)` (SynchronousEvent) + `C_Container.GetContainerItemInfo(bag, slot)` -> {itemID, hyperlink, quality, isLocked, ...} | SecretArguments=AllowedWhenUntainted; MayReturnNothing; no secret returns | n/a | snapshot **at lock time** (the item is gone after the cast); `isLocked` must be true; pcall + type checks |
| Class/subclass/equip slot | `C_Item.GetItemInfoInstant(link)` | SecretArguments=AllowedWhenUntainted; MayReturnNothing | n/a | no cache dependency (instant) |
| Item level, quality | `C_Item.GetDetailedItemLevelInfo(link)`; fallback `C_Item.GetItemInfo(link)` (ilvl 4th, quality 3rd) | same | n/a | fallback only when the first is nil |
| Loot window | events `LOOT_READY(autoloot)`, `LOOT_OPENED(autoLoot, isFromItem)`, globals `GetNumLootItems`, `GetLootSlotType`, `GetLootSlotInfo` (texture, name, quantity, currencyID, quality, ...), `GetLootSlotLink` | events: SynchronousEvent only. The four loot globals are **not in the generated docs** (GlobalAPI.lua only), so flags unknown; signatures taken from `LootFrame.lua:227-228,477,515` | n/a | every call pcall'd; secret/non-number/non-string results are ignored; `Enum.LootSlotType` Item=1, Money=2, Currency=3 (LootConstantsDocumentation.lua) |
| Spell name (status line) | `C_Spell.GetSpellName(id)` | SecretArguments=AllowedWhenTainted; MayReturnNothing | n/a | display only |
| Build stamp | `GetBuildInfo`, `GetServerTime` | none | n/a | |

Nothing is branched on combat state. The only secrecy exposure is the `UNIT_SPELLCAST_*` payload under `SecretWhenUnitSpellCastRestricted`; a disenchant is cast out of combat on the player, so the payload is expected to be readable, and when it is not the event is dropped (no row, no error). Rows hold only data read from non-secret returns.

No API used returns secret values (except possibly `GetDayEvent` while chat messaging is locked down [flag SecretInChatMessagingLockdown; exact trigger unverified]: run the dump in a city), and nothing branches on combat or unit state. Viable everywhere, though it's meant to run in a city.

## Forever-specific considerations (reference/forever-vs-mainline.md)
- Calendar: `Blizzard_Calendar` is LoadOnDemand with no addon-level `AllowLoadGameType`, so it loads on Camelot; `Camelot/` holds only `CalendarFilterData.lua` (filter list), `Mainline/Blizzard_Calendar.lua` is the logic. No override changes the API use here [SRC]. We never load or touch the Blizzard calendar frame: only `C_Calendar` is called. **Month selection is global client state shared with Blizzard's calendar UI**: `GetNumDayEvents`/`GetDayEvent`/`GetHolidayInfo` take a month *offset relative to the selected month*, `CalendarFrame_OnShow` does `SetAbsMonth(current)` then `OpenCalendar()` (Blizzard_Calendar.lua:1138-1145) and `CalendarFrame_OffsetMonth` calls `SetMonth(offset)` (:1775). We select each month absolutely and read with offset 0, then restore the month that `GetMonthInfo(0)` reported before the walk.
- No Blizzard frames are touched or hooked. `EventUtil` (template default) only.
- **Item string layout with bonus ids is [WIKI]-only** (not in the local source): `item:<id>:<enchant>:<gem1-4>:<suffix>:<unique>:<linkLevel>:<spec>:<modMask>:<context>:<numBonus>:<bonus...>:<numMods>:<type>:<value>...`. Self-verified (D-002): the client's canonical `itemLink` is stored next to the link we built, and the importer checks that the bonus id survived and that the name differs from the base name.

- Professions UI: `Blizzard_Professions` is the **modern** crafting UI on Forever (TOC `[Game]\Blizzard_ProfessionsFrame.lua [AllowLoadGameType camelot]`), and `Camelot/Blizzard_ProfessionsFrame.lua` only re-implements the right-hand tabs via `GetProfessions()`/`GetProfessionInfo()` and `CanTradeSkillShowCraftingUI`. Recipe enumeration is therefore Mainline's `C_TradeSkillUI` (`GetFilteredRecipeIDs`, `GetRecipeInfo`, `GetCategories`/`GetCategoryInfo`; Blizzard_Professions.lua:300,847,877), not a classic `GetTradeSkillInfo(index)` list. `GetAllRecipeIDs` is in GlobalAPI.lua but not in the generated docs [SRC]. We do not hook or anchor to any Professions frame.
- **Skill thresholds are not exposed as numbers.** Mainline gives `relativeDifficulty` (0 Optimal/orange, 1 Medium/yellow, 2 Easy/green, 3 Trivial/gray) at the **current** rank plus `maxTrivialLevel` (the gray point) and `numSkillUps`. There is no `required skill`/orange/yellow/green number in the documented structs. The dump stores the gray point and a list of (rank, difficulty) observations that grows each time a recipe is dumped at a new rank, so the importer can bracket the thresholds; `info` keeps every raw scalar field so an undocumented Forever field (e.g. a required-skill number) will show up without a code change.
- Enchanting recipes have no output item (`outputItemID` nil; the schematic is the enchant); the "output" is the enchant effect on a target item, flagged `isEnchantingRecipe`.
- Disenchant spell id is **not in the local source**. `13262` (Classic's id) is only a hypothesis. We never branch on it blindly: the status line prints `C_Spell.GetSpellName` for every id in the list, an unmatched spell that locks a bag item is offered as a hint, and `/ide de spell <id>` adds ids. `C_SpellBook.ContainsAnyDisenchantSpell` exists (SpellBookDocumentation.lua:33) and says only whether the player knows one.
- Attribution method (D-011): spell cast (SENT) + bag-item lock (ITEM_LOCK_CHANGED) + loot window (LOOT_READY/LOOT_OPENED) inside one cast window. `GetLootSourceInfo` is **not** used for attribution: its return for item-sourced loot (item GUID vs player GUID) is unknown. The loot probe prints it so a future version can cross-check.

## UX
- `/ide start`: resolve every tuple in the input (resumable: already-resolved keys are skipped). Progress prints every 10%.
- `/ide status`: counts (done / pending / in flight / failed), input stamp.
- `/ide stop`: pause. `/ide reset`: clear results (asks for `/ide reset confirm`).
- When done, prints "done, /reload to write SavedVariables".
- `/ide calendar [months]`: months defaults to 13 (current month onward), clamped 1..36. Selects the current month, calls `OpenCalendar()`, waits up to 3 s for `CALENDAR_UPDATE_EVENT_LIST` (the walk starts as soon as it fires), walks every month and day, restores the previously selected month, and prints `calendar: N events over M months walked (E errors). /reload to write SavedVariables.` If nothing is found it waits once more (3 s) and re-walks, then prints `no calendar events returned (...)` and leaves any earlier dump untouched. Refuses re-entry while running.
- `/ide recipes`: dumps the **open** profession window. If none is open it says so; if the window is open but lists no recipes (still loading) it says so and writes nothing. Prints `recipes: <Name> <rank>/<max>: N recipes (L learned, U unlearned, X unreadable); T stored across P professions. /reload to write SavedVariables.` Dump Tailoring, switch the window to Enchanting (right-hand tab), run it again: both accumulate. If the window hides unlearned recipes (`GetShowUnlearned()` false) it says so; tick the filter and rerun.
- `/ide recipes all`: best-effort: for each profession in `GetProfessions()` calls `C_TradeSkillUI.OpenTradeSkill(skillLine)`, waits for `TRADE_SKILL_LIST_UPDATE` (or 2 s), dumps, moves on. A profession that cannot be opened by an addon (or has no window, e.g. Fishing) is reported and skipped. Opening changes which profession the Blizzard window shows. [TODO-INGAME]
- `/ide de on|off|status|spell <id>|clear confirm`: the disenchant logger. Default **on**, persisted in `ItemDataExportDB.disenchants.enabled`. `off` unregisters all its events. `status` (also part of `/ide status`) prints rows, cap, dropped, rows skipped for lack of a source item, the spell ids and their names, and the last unmatched item-locking spell. `spell <id>` adds an id (persisted in `extraSpells`). `clear confirm` deletes the log.
- `/ide reset confirm` does **not** clear the calendar dump, the recipe dump or the disenchant log (it is cheap to regenerate but unrelated to the item results; wiping both with one command would lose hours-old schedule data for no reason). Delete `ItemDataExportDB.calendar` by running `/ide calendar` again (overwrites on success). The recipe dump is only ever merged into; the disenchant log is only cleared by `/ide de clear confirm`.

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
  recipes = {                        -- written by /ide recipes (D-008); absent until run; merged across runs
    dumped = <epoch of the latest dump>, build = "1.60.1", buildNumber = "70862",
    professions = { [197] = { name = "Tailoring", rank = 75, maxRank = 150, modifier = 0, dumped = 1794200000, recipes = 31,
                              childID = nil } },   -- key: skill line id (parentProfessionID or professionID); latest dump wins
    categories = { [11] = { name = "Cloth", parentCategoryID = 1 }, [1] = { name = "Tailoring" } },  -- every scalar field GetCategoryInfo returned
    recipes = {                      -- key: recipe (spell) id; the latest dump of a recipe replaces the row (except skill.obs, which accumulates)
      [2963] = {
        name = "Bolt of Linen Cloth", skillLineID = 197, learned = true, category = 11, abilityID = 555,   -- abilityID = skillLineAbilityID
        hyperlink = "|cffffd000|Henchant:2963|h[Bolt of Linen Cloth]|h|r",   -- may be absent
        outputItemID = 2996, outputMin = 1, outputMax = 1,      -- nil outputItemID: enchants, or recipes the client gives no item for
        recipeType = 0,                                         -- Enum.TradeskillRecipeType number, may be absent
        isEnchantingRecipe = true,                              -- flags are present only when true: isEnchantingRecipe, isSalvageRecipe,
                                                                --   isGatheringRecipe, isRecraft, isDummyRecipe
        reagents = {                                            -- one entry per schematic reagent slot, in slot order
          { itemID = 2589, qty = 2, reagentType = 1 },          -- basic required reagent
          { itemID = 2592, qty = 1, reagentType = 1, alts = { 14047 } },   -- alts: further items accepted in the same slot
          { itemID = 3000, qty = 1, reagentType = 0, optional = true, slotText = "Optional", requiredSkillRank = 100 },
          { currencyID = 77, qty = 4, reagentType = 1 },        -- currency reagent (itemID absent)
        },
        skill = { trivial = 50, difficulty = 1, rank = 75,      -- trivial = gray point; difficulty/rank = at the latest dump (0 orange .. 3 gray)
                  skillUps = 1, canSkillUp = true, itemLevel = 0,
                  obs = { { rank = 40, difficulty = 0 }, { rank = 75, difficulty = 1 } } },   -- distinct (rank, difficulty) pairs, max 12, oldest dropped
        cooldown = { remaining = 86400, isDay = true, charges = 0, maxCharges = 0 },   -- only if on cooldown / has charges; REMAINING seconds at dump time
        info = { ... },                                         -- every scalar field of GetRecipeInfo (raw, undocumented fields included); diagnostic only
      },
    },
  },
  disenchants = {                    -- written by the passive logger (D-011..D-014); created at first login with the addon
    version = 1, enabled = true,     -- enabled: default true
    extraSpells = { },               -- spell ids added with /ide de spell (the built-in list is {13262}, unverified)
    stats = { rows = 7, dropped = 0, noSource = 1 },   -- lifetime counters: rows logged, rows dropped by the cap, loot windows seen without a source item
    rows = {                         -- append-only, oldest first, capped at 5000 rows (oldest dropped)
      { ts = 1794200123, build = "1.60.1", buildNumber = "70862", spellID = 13262,
        itemID = 14000, link = "|cff1eff00|Hitem:14000::::::::::::|h[Green Robe]|h|r",   -- snapshot at lock time
        ilvl = 24, quality = 2, classID = 4, subclassID = 1, equipLoc = "INVTYPE_CHEST",  -- ilvl = effective item level; any field may be nil
        loot = { { itemID = 10940, qty = 2 }, { itemID = 10978, qty = 1 } },   -- one entry per loot slot; currency slots: { currencyID = 77, qty = 4 }; money slots omitted
      },
    },
  },
}
```

Calendar rows come from `CalendarDayEvent` (eventID, title, calendarType, sequenceType, eventType, iconTexture, numSequenceDays, startTime, endTime) plus, for `HOLIDAY` rows, `CalendarHolidayInfo` (description, texture, used as `iconTexture` when the event has none). `CalendarTime` fields used: year, month, monthDay, hour, minute (seconds are written as `00`); weekday is dropped. Kept: every `calendarType` except `PLAYER`, `GUILD_ANNOUNCEMENT`, `GUILD_EVENT`, `COMMUNITY_EVENT` (strings per Blizzard_Calendar.lua:396-423). The importer collapses START/ONGOING/END itself, so `sequenceType` is kept. The `example event` values above are illustrative, not observed.

Recipe notes for the importer: (1) `learned = false` rows are recipes the client lists but the character does not know (trainer/vendor/drop recipes); they are complete rows. (2) Spread = price(`outputItemID`) x `(outputMin+outputMax)/2` minus sum over `reagents` without `optional`, taking the first item (`itemID`) of each slot; `alts` are substitutes. Reagent `qty` is `quantityRequired` of the slot. (3) Levelling demand: a recipe is useful at rank `r` when `skill.obs` brackets it: the last observation with `difficulty <= 1` (orange/yellow) gives an upper bound and `skill.trivial` is where skill-ups stop. The orange/yellow/green interior thresholds are not given by the client; collect dumps at several ranks (the owner is levelling, so just re-run `/ide recipes` now and then) and the importer interpolates. (4) `info` and `categories` are self-verification, not a contract.

Disenchant notes for the importer: a row exists only if a known disenchant spell was SENT, a bag item locked within the cast window and a loot window with at least one item/currency slot opened within 5 s of `UNIT_SPELLCAST_SUCCEEDED` (cast age <= 20 s). The loot window's slots are the yield; `qty` is the slot quantity. The source item is the snapshot taken when it locked, so `link` carries any bonus ids. `ilvl` is the effective level (`GetDetailedItemLevelInfo`), falling back to the base level. Rows from different `spellID`s are not mixed by the addon: group by `spellID` (an id added via `/ide de spell` could be Prospecting or Milling).

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

## Recipe dump: open [TODO-INGAME]
- [ ] Does `GetAllRecipeIDs()` list **unlearned** recipes on Forever, or only learned? (`GetFilteredRecipeIDs` follows the UI filter.) The probe prints both counts.
- [ ] Does `GetRecipeInfo` expose a required-skill / orange number as an undocumented field? (`info` records every scalar; the keys probe lists them.)
- [ ] Does `GetRecipeSchematic(id, false)` give `outputItemID` and a sensible `quantityMin/Max` for vanilla recipes (e.g. Bolt of Linen Cloth, 1/1)? Do chance outputs (e.g. Mooncloth, transmutes) show min ~= max?
- [ ] Do vanilla optional/finishing reagent slots exist at all (expected: no; every slot `reagentType` 1)?
- [ ] Are Enchanting recipe reagents plain `reagentSlotSchematics`? (Enchants also need a target item; not recorded.)
- [ ] Does `C_TradeSkillUI.OpenTradeSkill(skillLine)` work from addon code for `/ide recipes all`, and does `TRADE_SKILL_LIST_UPDATE` fire before the 2 s timeout?
- [ ] Skill line ids: does Forever use one skill line per profession (child/parent profession info empty)? The dump falls back to the base info.
- [ ] Is `GetRecipeCooldown` shaped `cooldown, isDay, charges, maxCharges` (remaining seconds) on Forever?

## Disenchant logger: open [TODO-INGAME]
- [ ] **What is the Disenchant spell id?** (`13262` is Classic's; unverified.) Probe 4.
- [ ] Event order on Forever: `ITEM_LOCK_CHANGED` before or after `UNIT_SPELLCAST_SENT`; `LOOT_READY` before or after `UNIT_SPELLCAST_SUCCEEDED`. The code accepts a lock up to 2 s before SENT and loot any time between SENT and 5 s after SUCCEEDED. Probe 5/6 trace shows the real order.
- [ ] Is `UNIT_SPELLCAST_SENT.target` (an item name for item-targeted spells) readable? We do not read it. Not a blocker.
- [ ] Does `GetLootSourceInfo(1)` return the item GUID, the player GUID, or nothing for disenchant loot? (Probe 6.) Would allow a stronger attribution.
- [ ] Do `GetLootSlotType` Item=1 / Currency=3 and `GetLootSlotLink` behave as in Blizzard's `LootFrame.lua` for DE loot (including with auto-loot on)? The logger reads at `LOOT_READY`, before auto-loot empties the slots; if auto-loot beats it, `noSource`/empty windows show in `/ide de status`.
- [ ] Does the loot window open at all (vs loot going straight to bags) on Forever? (`LOOT_OPENED` with `isFromItem`.)
- [ ] Is the lock for item-targeted casts visible as `ITEM_LOCK_CHANGED` with `isLocked` true in `GetContainerItemInfo`? If not, `noSource` rises and the design needs the bag-diff fallback (not built: D-011).

## Owner in-game verification (recipes and disenchant, one session)
Each `/run` is one self-contained line (<= 255 characters): send each as its own chat message (P-007). `/console scriptErrors 1` first. Probes print labelled lines starting `IDE`. Needs a character with Tailoring and Enchanting and at least 3 disenchantable items (a green and a blue of different item levels, e.g. a green 15-25 armor and a green weapon).
1. **Disenchant id (any time).** Expect `IDEde ... Disenchant ... true`. If the name is not Disenchant, note the real id from step 6:
```
/run print("IDEde spell 13262 is:",C_Spell.GetSpellName(13262),"| knows a disenchant spell:",C_SpellBook.ContainsAnyDisenchantSpell())
```
2. **Trace casts and locks** (stays active until `/reload`). Reports the true event order and arguments:
```
/run local f=CreateFrame("Frame");f:RegisterUnitEvent("UNIT_SPELLCAST_SENT","player");f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED","player");f:RegisterEvent("ITEM_LOCK_CHANGED");f:SetScript("OnEvent",function(_,e,...)print("IDEcast",GetTime(),e,...)end)
```
3. **Trace the loot window** (prints the item count and `GetLootSourceInfo(1)` at `LOOT_READY` and `LOOT_OPENED`):
```
/run local f=CreateFrame("Frame");f:RegisterEvent("LOOT_READY");f:RegisterEvent("LOOT_OPENED");f:SetScript("OnEvent",function(_,e,...)print("IDEloot",GetTime(),e,GetNumLootItems(),GetLootSourceInfo(1))end)
```
4. `/ide de status` (should say ON and list spell ids with names). Disenchant 3 items: Disenchant spell, click the item, wait for the loot. Take screenshots or copy the `IDEcast`/`IDEloot` lines. Then `/ide de status` again: rows should have gone up by 3. If it says `last unmatched spell that locked a bag item: <id> (Disenchant)`, run `/ide de spell <id>`, disenchant once more and repeat.
5. Check the last logged row (shows source item id, item level, number of loot entries, rows and skipped-without-source count):
```
/run local d=ItemDataExportDB.disenchants;local r=d.rows[#d.rows];print("IDEde rows",#d.rows,"noSource",d.stats.noSource,"last",r and r.itemID,r and r.ilvl,r and #r.loot)
```
6. **Recipes.** Open Tailoring (profession window on its crafting page, let the list finish loading). Probe counts and the profession row (expect `all` >= `filtered` and the skill line, rank, max rank):
```
/run local T=C_TradeSkillUI;local a,f,b=T.GetAllRecipeIDs(),T.GetFilteredRecipeIDs(),T.GetBaseProfessionInfo();print("IDEn all",#a,"filtered",#f,b.professionID,b.professionName,b.skillLevel,b.maxSkillLevel)
```
7. First recipe's facts (name, learned, difficulty 0-3, gray point, output item, output quantity, reagent slots):
```
/run local T=C_TradeSkillUI;local a=T.GetAllRecipeIDs()[1];local i,s=T.GetRecipeInfo(a),T.GetRecipeSchematic(a,false);print("IDEinfo",i.name,i.learned,i.relativeDifficulty,i.maxTrivialLevel,s.outputItemID,s.quantityMin,#s.reagentSlotSchematics)
```
8. Field names the client returns for a recipe (looking for a required-skill number):
```
/run local T=C_TradeSkillUI;local a=T.GetAllRecipeIDs()[1];local t={};for k in pairs(T.GetRecipeInfo(a))do t[#t+1]=k end;table.sort(t);print("IDEkeys",table.concat(t,","))
```
9. `/ide recipes` (expect `Tailoring <rank>/<max>: N recipes (L learned, U unlearned, ...)`). Switch the window to Enchanting (right-hand tab, let it load), `/ide recipes` again: the message must say `stored across 2 professions`. Then try `/ide recipes all` and report what it prints (which professions open from addon code).
10. Check the stored total:
```
/run local r=ItemDataExportDB.recipes;local n=0;for _ in pairs(r.recipes)do n=n+1 end;print("IDErecipes stored",n,"dumped",r.dumped)
```
11. `/reload`, then send `ItemDataExport.lua` (SavedVariables) for the `recipes` and `disenchants` tables, plus the pasted `IDE...` lines.

## Decisions
- D-001 (2026-11-09): input is a generated Lua file shipped with the addon (gitignored), not SavedVariables edits. The client only reads SavedVariables at login and overwrites them on logout, so hand-editing them is fragile.
- D-002 (2026-11-09): self-verifying output. Store the built link and the client's canonical link, the link name, `GetItemStats` and the full tooltip for every tuple, and let the offline importer decide which source is trustworthy. One in-game session then answers all of the open questions.
- D-003 (2026-11-09): tooltip lines are stored as every string-valued field of each line, because the `TooltipDataLine` field names aren't in the local docs.
- D-004 (2026-11-09): load throttling: ≤ 20 requests in flight, 10 s timeout, one retry, then the key is marked failed. Items already cached skip the request. Captures from cached items are budgeted at 100 **tuples** per 0.1 s tick, not items (the first real input has 26,583 tuples over 5,498 items, up to 46 per item). Tooltip lines keep string fields only, to bound SavedVariables size.
- D-005 (2026-11-09): not released publicly. A dev tool for one account, so no CHANGELOG/semver release flow until there's a reason.
- D-006 (2026-11-09): the calendar dump lives in ItemDataExport, not a new addon. Same dev-tool pattern: the game client is ground truth, results go through SavedVariables to an offline importer in the private collector, and it is never released publicly (D-005). It shares the slash entry, the SavedVariables table and the review/harness setup, and a one-command, ~100-line dump does not justify another addon directory, TOC and spec. Consequence: the addon is now "client-truth exporter" rather than "item resolver"; if a third export appears, split a common `Export` core instead of growing Core.lua. `/ide reset confirm` leaves the calendar alone. Stored as client-local wall-clock strings (no zone) because `CalendarTime` has none; the importer must attach the realm zone once [TODO-INGAME] settles it. Walk strategy: select each month absolutely, read with offset 0, restore the user's month (global state shared with Blizzard's calendar UI).
- D-007 (2026-11-14): the common Export core exists (`Export.lua`), as D-006 required for a third export. It holds only shared plumbing: `ns.Say`, `ns.Plain` (scalar copy that drops secrets), `ns.IsPlain`, `ns.BuildStamp`, a `/ide` subcommand registry (`ns.RegisterCommand`), status hooks (`ns.RegisterStatus`) and DB-ready callbacks (`ns.OnDBReady`). Core.lua keeps the item resolver, `InitDB`, the slash entry and `/ide reset`; modules (`Calendar.lua`, `Recipes.lua`, `Disenchant.lua`) register themselves. SavedVariables layout of `items`/`results`/`failed`/`meta`/`calendar` is unchanged; `recipes` and `disenchants` are new top-level keys. TOC order: Export, Calendar, Recipes, Disenchant, Core (Core last so every module has registered). Version 0.1.0 -> 0.2.0 (D-005: still no release/CHANGELOG).
- D-008 (2026-11-14): recipe enumeration uses Mainline `C_TradeSkillUI` against the **open** window, because Forever ships the modern Professions UI with only tab/art overrides under `Camelot/` [SRC]. ids from `GetAllRecipeIDs` union `GetFilteredRecipeIDs`; facts from `GetRecipeInfo` + `GetRecipeSchematic(id, false)`. `info` stores every scalar of `GetRecipeInfo` (D-002/D-003 pattern) because the documented struct has no required-skill number and Forever may add one. The dump never changes UI filters (global state; same reasoning as D-006's month selection).
- D-009 (2026-11-14): skill thresholds are stored as `trivial` plus a growing `obs` list of (rank, difficulty) rather than the suggested `req/orange/yellow/green/gray`, because the API does not provide those numbers; inventing them would be false data. Merge key is recipe id, professions keyed by skill line id; `obs` accumulates across runs and the rest of the row is replaced by the latest dump. Unlearned recipes are recorded whenever the client lists them.
- D-010 (2026-11-14): reagent slots keep structure (`alts`, `optional`, `reagentType`, `currencyID`, `slotText`, `requiredSkillRank`) rather than a flat `{itemID, qty}`, so the importer can price the cheapest alternative or skip optional slots. `optional = true` is set for any slot with `reagentType ~= Basic (1)` or `required == false`. Recipes with no output item (enchants) are kept, not dropped. `/ide recipes all` is best-effort and not required for the dump.
- D-011 (2026-11-14): disenchant attribution = player `UNIT_SPELLCAST_SENT` for a known disenchant spell + `ITEM_LOCK_CHANGED` snapshot of the locked bag item (accepted up to 2 s before SENT; a lock after SENT overrides) + `LOOT_READY`/`LOOT_OPENED` with >= 1 item/currency slot, within 20 s of SENT and 5 s of SUCCEEDED; FAILED/INTERRUPTED/FAILED_QUIET before SUCCEEDED cancel. Rejected: bag diffs (higher cost, ambiguous with other bag changes, no timing), `GetLootSourceInfo` (return for item loot unknown), reading `target` (secret-restricted event payload, only a name). Fallback if locks are not observable: a bag-diff snapshot at SENT (not built; [TODO-INGAME]).
- D-012 (2026-11-14): spell id is data, not a constant: default `{13262}` [INFER, Classic id, absent from the local source], extendable at runtime with `/ide de spell <id>` (persisted), id recorded in every row, and an unmatched item-locking cast is surfaced as a hint. Prospecting/Milling can be logged the same way; the importer groups by `spellID`.
- D-013 (2026-11-14): the log is capped at 5000 rows (oldest dropped, counted in `stats.dropped`); a row is ~350 bytes, so the cap bounds SavedVariables to ~2 MB. Rows without a source item are not stored (counted in `stats.noSource`) because a yield with no source is useless for the analysis. Default **on**; toggle persisted; `/ide reset` does not touch the log.
- D-014 (2026-11-14): secrets: the logger registers unit events for `"player"` only and ignores any payload whose unit is secret or whose spell id is not a plain number; it never stores or compares `target`; every loot/container read is pcall'd and type-checked. No secret can reach SavedVariables, and nothing branches on combat state.
