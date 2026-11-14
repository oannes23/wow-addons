# Auction house and economy (Forever)

Researched 2026-11-08: three research agents, plus a direct check of the API sources. Confidence key as in [forever-platform.md](forever-platform.md). [REPORTED] = community or press sources, not Blizzard documentation. Source paths are relative to `reference/upstream/wow-ui-source/Interface/AddOns/` unless noted.

## Market structure
| Property | Forever | Evidence |
|---|---|---|
| Engine | Modern Retail `C_AuctionHouse` (86 functions). Commodities are listed per unit and filled cheapest-first; gear is one item per listing; bids exist only on items. | [SRC] `Blizzard_APIDocumentationGenerated/AuctionHouseDocumentation.lua` |
| Partition | No realms. You pick a ruleset (PvP 1, Normal 2, RP 3, RP-PvP 15; KR and TW have 1 and 2 only). No cross-ruleset or cross-faction play. Each region has **15 houses** (IDs 110–121, 123–125): 5 sets × {Alliance, Horde, Blackwater (neutral)}. The set 112/115/118 is empty. | [REPORTED] Blizzard forum thread 60334 (2026-11-05/06) and goldbook issue #67 · CONFIRMED Blizzard news (no cross-ruleset play) |
| Empty house set | Probably reserved for the **Hardcore** ruleset, launching winter 2026. That would mean a market starting from zero that we can observe from day one. | [INFER] |
| Neutral AH | "Blackwater Auction House" exists in the API, which implies Alliance↔Horde trade inside a ruleset. The cut is unknown; it was 15% in Classic. | [REPORTED] house names · cut [TODO-INGAME] |
| Shards | Realm shards such as `CAMWOWEU4Realm6PvP`/`Realm8PvP` showed the same min buyout for 85% of items, so a ruleset is probably one market across shards. | [REPORTED] goldbook #67 |
| Ruleset price spread | Week one: RP prices about 1.63× Normal, RP-PvP about 1.88×. No cross-ruleset trade means no arbitrage, so these spreads can persist. | [REPORTED] timesaver.gg 2026-11-07 · [INFER] |
| WoW Token | The UI code ships (`Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseWoWTokenFrame.lua`), but it's switched off at runtime by `C_WowTokenUI.ShouldDisplayInAuctionHouse()`. Press reports **no Token**, so there's no official gold↔money exchange rate. | [SRC] + [REPORTED] cogconnected 2026-10-19 · [TODO-INGAME] |
| Durations | Conflicting: the strings say 2/8/24 h (Classic), beta reports say 12/24/48 h. Time-left bands: <30m, 30m–2h, 2–12h, >12h. **Player recollection 2026-11-09: max 24 h** (consistent with the 2/8/24 h strings; not yet a deliberate check). AH data shows new listings first seen as MEDIUM/LONG/VERY_LONG, never SHORT. | [SRC] BIR `GlobalStrings/enUS.lua:1172-1174` (build 70532) · [USER, unverified] · [TODO-INGAME] post one item and read the duration dropdown |
| Cancelling | Listings can be cancelled. A commodity listing probably can't be partly cancelled (stacks are posted whole). Whether a listing holding a bid can be cancelled is unknown. | [USER 2026-11-09, unverified] · [TODO-INGAME] |
| Deposit / cut | Not published. Measure with `C_AuctionHouse.CalculateItemDeposit` and sale-invoice mail. | [TODO-INGAME] |
| Camelot UI | Browses by required level (not item level). Vanilla categories (relics, ammo, quivers, soul and profession bags). | [SRC] `Blizzard_AuctionHouseUI/Camelot/Blizzard_AuctionData.lua` |
| Experience preset | Classic/Enhanced is client presentation only. It does **not** split markets. | [SRC] `Blizzard_GlueXML/Mainline/ExperiencePreset.lua` |
| Rules | GDKP banned. Gold *buyers* face permanent bans. Blizzard may link AHs if a ruleset's population dries up, so always store a house key with each record. | [REPORTED] warcrafttavern, playnews |

## Data access
**Addon side** [SRC]:
- No AH API returns secret values. Scan data is plain numbers and strings.
- Full scan: `ReplicateItems()` → `REPLICATE_ITEM_LIST_UPDATE` → `GetReplicateItemInfo(i)`. Community convention is about one scan per 15 minutes.
- Targeted searches are capped at 100/min (doc comment).
- `HasRestrictions` (one hardware event per action): `PostItem`, `PostCommodity`, `Confirm*`, `PlaceBid`, `StartCommoditiesPurchase`, `CancelAuction`. Reading data can be automated; acting on it can't.

**Out of game: Battle.net Game Data API** [REPORTED, undocumented, no Blizzard staff confirmation]:
- Namespaces: `dynamic-forever-{us,eu,kr,tw}`, `static-1.60.1_70399-forever-{region}` (the unversioned static namespace returned 403), `profile-forever-{region}`.
- Endpoints:
  - `/data/wow/ruleset/{id}/auctions/` (index; the trailing-slash rule flipped on Nov 6, and `/auctions/index` was also reported to work)
  - `/data/wow/ruleset/{id}/auctions/{houseId}`
  - `.../{houseId}/commodities` → `{id, item, quantity, unit_price, time_left}`
- Bug: the ruleset ID in the path doesn't filter results, so the same house returns identical data under every ruleset. **De-duplicate by house ID; never sum across rulesets.**
- 43% of item IDs returned 404 from the static namespace [REPORTED]. Snapshot-only (no history). Rate limits assumed to match Retail (36k/h, 100/s) [INFER].
- **Measured by our collector, 2026-11-08** [VERIFIED live API, wowf-ah-collector runs on bob]:
  - Index shape is `{_links, auctions: [{key: {href}, name, id}]}`, and every ruleset lists all 15 houses. Names (all four ruleset indexes are identical): Alliance = 110, 111, 112, 119, 123; Horde = 113, 114, 115, 120, 124; Blackwater = 116, 117, 118, 121, 125. Probable sets [INFER from ID pattern + sizes]: S1 {110,113,116}, S2 {111,114,117}, S3 {112,115,118} (empty), S4 {119,120,121}, S5 {123,124,125}. Sizes: S1/S2 big (A/H ~0.7–0.9 MB zst, BW mid); S4/S5 mid (BW tiny). **House 114 = Horde, Normal ruleset** [VERIFIED 2026-11-08: 5 listings seen in game matched 5/5 on 114, 0 on the other 11 houses]. Hence probably Normal = S2 {111,114,117} [INFER]. Other rulesets are unmapped. Method: record exact buyouts of rare gear listings, then match them against snapshots (wowf-ah-collector `scripts/match_listings.py`). Vanilla item IDs carry over unchanged (869, 870, 873, 867, 1204 verified).
  - House response: `{_links, id, name, commodities: {href}, ruleset: {href}, auctions: [...]}`. Listings are `{id, item: {id, bonus_lists?...}, quantity, buyout, bid?, time_left}`. Every listing with a buyout had quantity 1 (0 of 129k had quantity > 1). Bids are rare (399 of 129k). No `unit_price`.
  - Commodities: `{id, item: {id}, quantity, unit_price, time_left}`. No buyout.
  - House and commodities endpoints are **disjoint**: no shared auction IDs or item IDs (2,980 vs 839 items on house 111). Summing both doesn't double count.
  - Empty set 112/115/118: **200 with an empty listing**, not 404.
  - Size per house varies widely. Four big houses (110/111/113/114): up to 129k item listings + 51k commodity listings, 11.6 + 4.4 MB JSON, ~1.3 MB zstd-9. Mid: 116/117/119/120/123/124. Tiny: 121/125. A full sweep is ~808k rows.
  - `Last-Modified` is per house, all set within ~6 s of each other (18:16:18–24Z), `If-Modified-Since` returns **304**. Refresh is **hourly at ~:16Z**: 18:16 and 19:16 on 2026-11-08, so 2 observations; confirm over a longer window.
  - **Cross-house comparison, first 4 hourly snapshots (2026-11-08 18:16–21:16Z, wowf-ah-collector `scripts/cross_house.py`)** [MEASURED, early]:
    - Size per faction house: S1/S2 167–212k listings (3.8–4.1k items); S4/S5 30–43k (2.0–2.5k items). Blackwater: 9–11k in S1/S2, ~1.3k in S4/S5.
    - Commodity price level vs 114 (median ratio of p50 on shared items): S1 and S2 Alliance/Horde **1.00** (only 6–9% of p50s identical, so not an artifact; IQR ≈ 0.7–1.5); S4/S5 **1.53–1.74**; Blackwater **2.6–3.8** (IQR up to ~9). Gear: S4/S5 1.26–1.34. Blackwater gear numbers rest on 18–234 shared items.
    - Fits press week-one spreads (RP ≈ 1.63× Normal, RP-PvP ≈ 1.88×): S1 = PvP? and S4/S5 = RP/RP-PvP? [INFER, speculative; depends on the inferred sets]. A/H houses within a set have similar levels, which supports the triplet grouping, but S4 and S5 are indistinguishable.
    - Suffix pricing: in S1/S2 faction houses 19–32% of suffixes trade at >1.2× their item's median suffix (114 top: bonus 12761 ×6.7 over 69 items, 12745 ×2.4, 12758 ×2.1, 12722 ×1.8). In S4/S5 only 2–7% do. Blackwater prices every suffix identically (one price per item: thin market or a single reseller).
    - Rank correlation of suffix premia with 114: 0.63–0.75 (S1/S2), 0.28–0.42 (S4/S5), 0.32 (117). Suffix demand looks largely shared across the big markets [INFER]; the lower values in thin markets may be noise attenuation, not a different meta.
    - Hour-to-hour: most commodity p50s don't change between snapshots, so median change is 0. Use trimmed means or diffusion indices for co-movement.
  - House → ruleset mapping can't be read from the API, which ignores the ruleset. Use in-game listing matching: 114 = Horde Normal (see Market structure).
- Paths changed within 24 hours of going live, so pin your client and log schema drift.

## Tooling status (2026-11-08)
| Tool | Forever | Analysis value |
|---|---|---|
| TSM 4.15 + new Desktop App | Supported since launch [CONFIRMED tradeskillmaster.com news, about Nov 1] | Price sources incl. new DBNumAuctions/DBAlt*. Web Forever dashboard. No public Forever API. |
| Auctionator | Works [REPORTED CurseForge, Interface 16001] | Local DB only |
| Auctioneer-Forever (fork) | Beta [CONFIRMED GitHub README] | Reported **SavedVariables-not-reloaded** beta bug. Check persistence for all our addons. |
| ForeverForge Auction | Works, 2.1.7 on Nov 8 | Scans about every 15 min. All Rights Reserved. |
| Journalator | Listed for Forever [REPORTED] | Personal P&L ledger with export |
| Undermine Exchange, Saddlebag, Oribos Exchange, wowauction | **Retail only** | The Undermine/Shatari collector is open source (erorus): a schema to copy |
| goldbook (jkc-be) | Forever polling added on Nov 6 | Hourly-snapshot prior art |
| Public Forever history dataset | **None exists** | History exists only if someone collects it now |

## Prior art for macro analysis
- EVE Monthly Economic Reports: CPI, faucets/sinks, money supply. A dashboard template, but they rely on telemetry we don't have.
- Castronova 2001 (EverQuest GNP and exchange rate).
- arXiv 2210.07970 (OSRS Grand Exchange: tax and sink interventions as natural experiments).
- arXiv 1905.06721 (OSRS price-series statistics).
- VŠE thesis on WoW Token and AH econometrics (day-of-week effects).
- Gaps: no published Classic-style launch-economy time series, no tested phase-event study, no published WoW AH backtest.

## Random suffixes on Forever [INGAME 2026-11-09, client 1.60.1.70862]
- A random suffix is one `bonus_lists` id on the listing. The client resolves `item:<id>::::::::::::1:<bonus>` to the suffixed name and the suffix stats (`C_Item.GetItemInfo` / `GetItemStats` / `C_TooltipInfo.GetHyperlink`). Tool: `addons/ItemDataExport`.
- 71 bonus ids map to 44 suffix names. Several ids share a name ("of Magic" ×4, "of the Sorcerer" ×3, …), so key analysis on name + stats, not id. The full map lives in the private collector repo (`dim/suffixes.csv`).
- `modifiers` type 28 (values ~5244–5256) changes no visible item property.
- The client build observed was 70862, while the local source mirror is 70790: run `scripts/sync-reference.sh` when convenient.

## AH addon landscape on Forever (survey 2026-11-09; CurseForge pages fetched that day)
| Addon | Forever | Strength | External data |
|---|---|---|---|
| TradeSkillMaster 4.15.x | yes (official post) | groups/operations, price sources, accounting | Desktop app → `TSM_AppHelper` |
| Auctionator | yes | shopping lists, undercut/cancel, posting protection | local scans; shopping-list import text `Name^"Item";;…;maxGold;;` [SRC, Auctionator source snapshot 2023] |
| Auctioneer (Forever fork) | yes | classic suite (Appraiser, BeanCounter…) | local scans |
| AHledger | yes | tooltips, watchlist, deals | `/ahl import`; sync app uploads scans by default |
| ProfitProphet, aux (auxForever), Hammerprice, Grimlight, ForeverForge, Forever Ledger, Journalator | yes | sniping, posting, ledgers | mostly own or shared scans |
| Saddlebag Exchange, Oribos Exchange | Retail only / not found | | |

None of them consumes an external analysis pipeline's signals or handles faction ↔ Blackwater spreads, which is the niche `addons/Wuwei` fills.

## AH API constraints on Forever [SRC build 1.60.1.70790, `tools/wowapi.py`]
- Forever uses the **modern AH UI** (`Blizzard_AuctionHouseUI/Shared`). Its only Camelot override is `Camelot/Blizzard_AuctionData.lua` (categories). `C_AuctionHouse` is the modern API.
- **No AH API returns secret values.** Arguments are `SecretArguments=AllowedWhenUntainted`.
- **`HasRestrictions`** (hardware event: one click = one action): `PlaceBid`, `StartCommoditiesPurchase`, `PostItem`, `PostCommodity`, `ConfirmPostItem`, `ConfirmPostCommodity`, `CancelAuction`. Reading, searching and fee calculation are unrestricted.
- `SendSearchQuery`/`SendSellSearchQuery`: **100 calls/min** (doc comment). Use `ReplicateItems` for a whole-AH scan (community convention: at most one per 15 min).
- Events used by pipeline-fed addons: `AUCTION_HOUSE_SHOW`/`CLOSED`, `COMMODITY_PURCHASE_SUCCEEDED`, `AUCTION_HOUSE_PURCHASE_COMPLETED`, `AUCTION_HOUSE_AUCTION_CREATED`, `OWNED_AUCTIONS_UPDATED`, `*_SEARCH_RESULTS_UPDATED`, `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`.
- SavedVariables work on live: ItemDataExport wrote and reloaded 21 MB on 2026-11-09 [INGAME]. Some addon authors reported a beta-client read-back bug. It doesn't reproduce on live.
- Unverified on Forever: the Blackwater cut (15% in Classic), deposit (1s minimum reported, 1c announced), `PostCommodity` copper rule (Retail wiki: whole silver only).

## Browse results are one shared, global list [SRC build 1.60.1.70862; researched for Wuwei steals, SPEC D-034/D-035]
- Every `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` makes Blizzard's `AuctionHouseBrowseResultsFrameMixin` replace its list with `C_AuctionHouse.GetBrowseResults()`; `..._ADDED(addedBrowseResults)` appends. The frame registers these in `OnLoad`, so a hidden Buy tab is repainted too (`Shared/Blizzard_AuctionHouseBrowseResultsFrame.lua:73-130`). **Any addon browse query (`SendBrowseQuery`, `SearchForItemKeys`, `SearchForFavorites`) overwrites what the player sees.** Run them only on an explicit player action.
- `AuctionHouseFrameMixin:OnShow` runs `QueryAll(AllFavorites)` (`SearchForFavorites`) when the player has favorites (`Shared/Blizzard_AuctionHouseFrame.lua:398-400`): an addon query on `AUCTION_HOUSE_SHOW` races it.
- Every player-started browse (search bar, category click, re-sort) goes through `AuctionHouseFrame:SendBrowseQueryInternal` (:794-823), which builds the `AuctionHouseBrowseQuery` from the selected category's `itemClassFilters` and calls `C_AuctionHouse.SendBrowseQuery`. A post-hook there detects player browsing.
- `C_AuctionHouse.SearchForItemKeys(itemKeys, sorts)` exists but has **no caller in Blizzard's UI**; by analogy with `SearchForFavorites` its reply is assumed to be browse results [INFER; TODO-INGAME, Wuwei checklist 30].
- `AUCTION_HOUSE_NEW_RESULTS_RECEIVED(itemKey?)`: doc comment "not used in the base UI ... Payload is nil for browse queries", so it tells browse replies from item-search replies. Browse events are `SynchronousEvent`: a reply can arrive inside the send call.
- Blizzard's default browse filters (Mainline `AUCTION_HOUSE_DEFAULT_FILTERS`, `Blizzard_AuctionHouseUtil.lua:21`) are all `Enum.AuctionHouseFilter` quality values on, usable/uncollected/upgrade filters off. The player's own choices persist in `g_auctionHouseFilters` (per character), so an addon query should pass its own filter list.
- Rate limit: only `SendSearchQuery`/`SendSellSearchQuery` carry the "100 calls per minute" comment; whether browse queries share that quota is undocumented [TODO-INGAME]. `C_AuctionHouse.IsThrottledMessageSystemReady()` gates Blizzard's posts (SellFrame.lua:487).
- `SOUNDKIT` and the `PlaySound = C_Sound.PlaySound` alias load on Forever from `Blizzard_SharedXML/Mainline/` via `[Family]` (Forever's family is mainline).
