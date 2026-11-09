# ItemDataExport: spec

## Problem
The AH archive (private `wowf-ah-collector`) identifies items only by `item_id` plus a random-suffix `bonus_lists` id (64 ids, 12688–12761 and 12911–12920). Names, stats and classes are needed to answer "which variants sell best" (collector SPEC D-009/D-010). The static Game Data API 404s on ~43% of Forever item ids, and community databases' Forever coverage is unknown. The game client is ground truth for the build players actually see.

## Scope
- In: a **developer tool**. Takes a generated list of `(item_id[, bonus_id[, modifier_type, modifier_value]])` tuples, loads each item from the server, and records base item info, the resolved link name, item level, stats and every tooltip line, per tuple, into SavedVariables. The collector's importer turns that into `dim/*.csv`.
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

No API used returns secret values, and nothing branches on combat or unit state. Viable everywhere, though it's meant to run in a city.

## Forever-specific considerations (reference/forever-vs-mainline.md)
- No Blizzard frames are touched or hooked. `EventUtil` (template default) only.
- **Item string layout with bonus ids is [WIKI]-only** (not in the local source): `item:<id>:<enchant>:<gem1-4>:<suffix>:<unique>:<linkLevel>:<spec>:<modMask>:<context>:<numBonus>:<bonus...>:<numMods>:<type>:<value>...`. Self-verified (D-002): the client's canonical `itemLink` is stored next to the link we built, and the importer checks that the bonus id survived and that the name differs from the base name.

## UX
- `/ide start`: resolve every tuple in the input (resumable: already-resolved keys are skipped). Progress prints every 10%.
- `/ide status`: counts (done / pending / in flight / failed), input stamp.
- `/ide stop`: pause. `/ide reset`: clear results (asks for `/ide reset confirm`).
- When done, prints "done, /reload to write SavedVariables".

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
}
```

## Input (generated, gitignored)
`Data/Pairs.lua` is written by the collector's `scripts/export_pairs.py`, which runs on bob read-only:
```lua
local _, ns = ...
ns.INPUT = { generated = "2026-11-09T...", source = "item_snapshot/v1 all houses",
  tuples = { {869}, {3195, 12918}, {3195, 12918, 28, 5254}, ... } }
```
If it's missing, `Data/Builtin.lua` provides a ~10-tuple smoke set (items verified on house 114). The client logs the missing file and continues [INFER, verify].

## Open questions / in-game verification
- [ ] Does the client resolve a bonus-list item string to the suffixed name ("… of the Eagle")? Check `/ide start` on the builtin set, then `/dump ItemDataExportDB.results["3195:12918"].name`.
- [ ] Does `GetItemStats(link)` reflect the bonus id (suffix stats), or only base stats? Compare `3195` with `3195:12918`.
- [ ] What does modifier type 28 change (value ~5244–5256)? Compare `3195:12918` with `3195:12918:28:5254`: ilvl, stats, tooltip.
- [ ] Does a missing `Data/Pairs.lua` cause a visible error?
- [ ] Throughput: how many item loads per second before the server throttles?

## Decisions
- D-001 (2026-11-09): input is a generated Lua file shipped with the addon (gitignored), not SavedVariables edits. The client only reads SavedVariables at login and overwrites them on logout, so hand-editing them is fragile.
- D-002 (2026-11-09): self-verifying output. Store the built link and the client's canonical link, the link name, `GetItemStats` and the full tooltip for every tuple, and let the offline importer decide which source is trustworthy. One in-game session then answers all of the open questions.
- D-003 (2026-11-09): tooltip lines are stored as every string-valued field of each line, because the `TooltipDataLine` field names aren't in the local docs.
- D-004 (2026-11-09): load throttling: ≤ 20 requests in flight, 10 s timeout, one retry, then the key is marked failed. Items already cached skip the request. Captures from cached items are budgeted at 100 **tuples** per 0.1 s tick, not items (the first real input has 26,583 tuples over 5,498 items, up to 46 per item). Tooltip lines keep string fields only, to bound SavedVariables size.
- D-005 (2026-11-09): not released publicly. A dev tool for one account, so no CHANGELOG/semver release flow until there's a reason.
