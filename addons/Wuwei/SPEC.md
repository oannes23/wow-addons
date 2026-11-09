# Wuwei: spec (draft, 2026-11-09)

> Act without forcing: the market pipeline decides what is worth doing, and the addon keeps out of the way until the moment to act, then makes that act one click.

## Problem
The analysis pipeline (private `wowf-ah-analysis`) produces strategy: what to buy cheap and hold, what to sell now and at what price, which items to shuttle between Horde AH 114 and Blackwater 117, and when the market turns (strategy.md). In game, acting on it today means alt-tabbing to a report, typing searches, remembering targets, and doing fee arithmetic by hand. Every bit of friction costs either a missed trade or a bad one.

Existing addons (survey, 2026-11-09) cover scanning, posting and ledgers well: TSM 4.15, Auctionator, Auctioneer-Forever, AHledger, ProfitProphet, aux and Forever Ledger all support Forever. **None of them takes our signals, handles faction ↔ Blackwater spreads, or prices in real (inflation-adjusted) terms.** Wuwei is that thin layer, plus a ledger that feeds ground truth back to the pipeline.

## Design principles (the wu wei part)
1. **Quiet by default.** Nothing appears outside the AH except one tooltip line. No minimap clutter, no alerts while questing.
2. **Context decides the view.** Open a faction AH and you see that house's plays. Open Blackwater and you see the shuttle *sell* side. Mouse over an item and you see its one-line verdict.
3. **One click = one action** (hardware-event rule). Wuwei prepares the search, the price and the quantity. The player's click buys or posts. No automation, no loops (Blizzard policy; `HasRestrictions` on `PlaceBid`/`StartCommoditiesPurchase`/`Post*`/`CancelAuction`).
4. **The pipeline thinks, the addon acts.** No in-game modelling. Generated data in, events and ledger out.
5. **Show staleness.** Every price shows its age and house. Data is hourly at about :16 and can be a day old.
6. **Don't rebuild what exists.** Scanning, mail and crafting are out. Use Auctionator/TSM alongside.

## Scope
- **Phase 0, no addon (this week):** the pipeline emits an **Auctionator shopping-list import string** for buys (item + max price) and a text sell list. Zero code in game; it proves which signals matter. Auctionator's import format is still to be verified.
- **Phase 1, MVP:**
  1. [x] `Data/Plan.lua` (generated, gitignored) loaded at login and `/reload`.
  2. [x] A tooltip line: reference price (our p25), the signal (`BUY ≤ x` / `SELL ≥ y` / `SHUTTLE → BW y` / `HOLD`), the 24h real trend, and data age.
  3. [x] (max-price over-price warning deferred, D-009) An **AH side panel** attached to `AuctionHouseFrame`: today's plays for *this* house, sorted by expected gold. Each row has a **Search** button (`C_AuctionHouse.SendSearchQuery`; 100/min limit respected) that opens Blizzard's own buy frame for the item. The max price is shown, with an over-price warning.
  4. [x] (map IDs still [TODO-INGAME]) **House detection:** faction AH vs Blackwater, by map (`C_Map.GetBestMapForUnit("player")` → Booty Bay, Gadgetzan, Everlook) with `GetZoneText` as fallback. The map IDs are [TODO-INGAME].
- **Phase 2:**
  - [x] **Post helper** (`Post.lua`): a target price from the plan plus posting protection (block or confirm below vendor price, below the plan floor, or below the cost basis). Deposit via `C_AuctionHouse.CalculateCommodityDeposit`/`CalculateItemDeposit`, the AH cut, and net proceeds shown before the click.
  - [x] **Ledger** (`Ledger.lua`; sales and expiries inferred from owned-auction diffs rather than mail, D-017): purchases (`COMMODITY_PURCHASE_SUCCEEDED`, `AUCTION_HOUSE_PURCHASE_COMPLETED`), posts (`AUCTION_HOUSE_AUCTION_CREATED`), sales and expiries (mail), with cost basis per item and house. Exported to the pipeline as SavedVariables, so we get P&L and **ground truth for the inferred-sales model** (ADR 0003 calibration).
- **Phase 3 (maybe):**
  - A "deal" highlight in Blizzard's browse results: a listing below our `BUY ≤` price is tinted.
  - Shuttle trip planner: carry list for 114 → 117 with depth-capped quantities.
- **Out:** full AH scanning (Blizzard's API gives us hourly data already; add `ReplicateItems` only if fresher local data is needed), sniping, mail automation, crafting, bag UI, peer price sharing, multi-account sync.

## Secret-value viability (build 1.60.1.70790, tools/wowapi.py)
| Data / action | API | Flags | OK? | Notes |
|---|---|---|---|---|
| Item search | `C_AuctionHouse.SendSearchQuery`, `SearchForItemKeys`, `MakeItemKey` | SecretArguments=AllowedWhenUntainted; no restrictions | ✓ | 100 calls/min (doc comment) |
| Search results | `GetCommoditySearchResultInfo`, `GetItemSearchResultInfo`, `*_SEARCH_RESULTS_UPDATED` | none on returns | ✓ | |
| Buy | `StartCommoditiesPurchase` → `ConfirmCommoditiesPurchase`; `PlaceBid` | **HasRestrictions** | click-driven only | Prefer handing off to Blizzard's buy frame in Phase 1 |
| Post / cancel | `PostCommodity`, `PostItem`, `CancelAuction` | **HasRestrictions** | click-driven only | Phase 2; the wiki says copper must be 0 on commodity posts (Retail) [TODO-INGAME] |
| Fees | `CalculateCommodityDeposit`, `CalculateItemDeposit`, `GetCancelCost` | none on returns | ✓ | the cut % on Blackwater is unknown [TODO-INGAME] |
| Own auctions | `GetOwnedAuctions`, `OWNED_AUCTIONS_UPDATED` | none | ✓ | |
| Where am I | `C_Map.GetBestMapForUnit("player")`, `GetZoneText` | none on returns | ✓ | |
| Tooltip line | `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, …)` | Blizzard uses it (PTRFeedback) | ✓ | must not touch secret tooltip data (items have none) |
| Item info | `C_Item.GetItemInfo`, etc. | none on returns | ✓ | proven by ItemDataExport |

Nothing here needs to branch on combat or unit secrets. Viable.

## Forever-specific considerations
- Forever uses the **modern AH UI** (`Blizzard_AuctionHouseUI/Shared`). The only Camelot override is `Camelot/Blizzard_AuctionData.lua` (the category list). Anchor to `AuctionHouseFrame` after `AUCTION_HOUSE_SHOW`; don't replace Blizzard frames.
- **SavedVariables work on live:** ItemDataExport wrote and reloaded a 21 MB file on 2026-11-09. The beta read-back bug that AHledger and ForeverForge reported doesn't affect us.
- **No realms:** the market key is ruleset × faction (house id). The plan file carries house ids, and Wuwei picks the rows for the AH it's standing at.

## Data contract: `Data/Plan.lua` (generated by `wowf-analysis export-addon`, gitignored)
```lua
local _, ns = ...
ns.PLAN = {
  generated = "2026-11-09T07:00:00Z", source = "wowf-ah-analysis a002/a003", ruleset = "Normal",
  houses = { [114] = "Horde", [117] = "Blackwater" },
  index = { [114] = { level = 76.5, d24h = -0.23, regime = "deflation" } },  -- regime: deflation | bottoming | inflation
  items = {
    -- [itemID] = { ref = {house: p25 copper}, vendor =, tier =, signal = "BUY"|"SELL"|"SHUTTLE"|"HOLD"|"AVOID",
    --              buyMax =, sellMin =, qtyCap =, gain = expected gold, note = "why", trend24h = real Δ }
    [4304] = { ref = { [114] = 600, [117] = 1450 }, signal = "SHUTTLE", buyMax = 700, sellMin = 1300, qtyCap = 60, gain = 38 },
  },
}
```
Size target: < 500 KB (watchlist and plays only, never raw listings).

## UX sketch
```
┌ Wuwei · Horde AH (114) · data 42m old · market: DEFLATION ─────────┐
│ SELL  Mageweave Cloth   ≥ 7s 60c   you have 120  → +9g    [Search]  │
│ SHUTTLE Liferoot        buy ≤ 4s   carry 60 → BW ≥ 65s    [Search]  │
│ BUY   (none: buying is paused until the index bottoms)              │
└─────────────────────────────────────────────────────────────────────┘
tooltip:  Wuwei: SHUTTLE → BW ≥ 65s · ref 3s60c (114) / 70s (117) · 24h −8% real · 42m
```

## Open questions / in-game verification
- [ ] Auctionator shopping-list import format on Forever (Phase 0).
- [ ] Map IDs for Booty Bay, Gadgetzan and Everlook; whether Blackwater is reachable there on Forever.
- [ ] Blackwater cut and deposit (decides SHUTTLE). Faction cut 5%?
- [ ] `PostCommodity` copper rule; AH durations; deposit 1s vs 1c.
- [x] Do the purchase events carry enough for the ledger? **No**: `COMMODITY_PURCHASE_SUCCEEDED` has no payload and `AUCTION_HOUSE_PURCHASE_COMPLETED` carries only `auctionID`. The quote comes from a hook on `AuctionHouseFrame:StartCommoditiesPurchase` (D-015).
- [ ] Phase 2 in-game items: checklist 11-18 and the [TODO-INGAME] list at the bottom.

## Decisions
- D-001 (2026-11-09): **thin action layer over a pipeline**, not another scanner. The differentiators are our signals, cross-house spreads, real prices, and a ledger that feeds back.
- D-002 (2026-11-09): **Phase 0 before code.** Prove the signals with an Auctionator shopping-list export, then build Phase 1.
- D-003 (2026-11-09): data enters as a generated `Data/Plan.lua` (code files load on every `/reload`; size-bounded; gitignored because it's private). SavedVariables are for the ledger only.
- D-004 (2026-11-09): hand purchases off to Blizzard's buy frame in Phase 1 (search pre-filled, the player clicks Buy) instead of driving `StartCommoditiesPurchase` ourselves. The least surface and the least policy risk.
- D-005 (2026-11-09): **`/wuwei toggle` is the master switch** (tooltip line and panel); `tooltip` in `WuweiDB` can silence only the line. `/wuwei house <id|auto>` overrides detection; `/wuwei probe` prints map/zone/faction, labelled (P-006).
- D-006 (2026-11-09): **House detection order:** manual override, then uiMapID in `House.BLACKWATER_MAPS` (empty until probed), then zone/subzone name (Booty Bay, Gadgetzan, Everlook; in vanilla geography they are subzones, so both `GetZoneText` and `GetSubZoneText` are checked), then faction (Horde 114, Alliance 111). Neutral/unknown gives no house and the panel says so.
- D-007 (2026-11-09): **Search hand-off uses Blizzard's own path.** `AuctionHouseFrame:QueryItem(BuyCommodities|BuyItems, itemKey)` (which calls `C_AuctionHouse.SendSearchQuery` and records the active search so Blizzard refreshes it) followed by `AuctionHouseFrame:SelectBrowseResult({itemKey, minPrice})`, exactly what a browse-row click does (Blizzard_AuctionHouseBrowseResultsFrame.lua:166). If `GetItemKeyInfo` is not cached yet, fall back to `SetSearchText` + `SendBrowseQuery(name, 0, 0, {})`. Never calls a HasRestrictions API.
- D-008 (2026-11-09): **Throttle at 90 searches/min** (sliding 60 s window), not 100, because Blizzard's own AH UI shares the quota. Only our clicks are counted.
- D-009 (2026-11-09): **Over-price warning deferred.** It needs live listing prices (search results events), which is more surface than the MVP wants; revisit with Phase 2/3. The panel shows the rule (`≤ buyMax`, `≥ sellMin`) only.
- D-010 (2026-11-09): **Panel row semantics.** A house's plays are plan items with `ref[house]`, `AVOID` dropped, sorted by `gain` desc (ties by item id), capped at 15. SHUTTLE from a faction house shows `→ BW ≥ sellMin`; at Blackwater it is the sell side (`sell ≥ sellMin`). `ref` for the tooltip falls back to the lowest-numbered house when the current one has none. Data age is computed from `generated` (UTC ISO) vs `GetServerTime()`. Builtin sample data is labelled `SAMPLE DATA` in the header.
- D-011 (2026-11-09): money is formatted as plain text (`3s 60c`), not coin textures, so the same string works in tooltips and FontStrings (`C_CurrencyInfo.GetCoinTextureString` exists but is not needed).
- D-012 (2026-11-09): **Post helper refreshes from a post-hook on the sell frames' `UpdatePostState`** (`hooksecurefunc(AuctionHouseFrame.CommoditiesSellFrame|ItemSellFrame, "UpdatePostState", ...)`). Blizzard calls it on every item, quantity, price and duration change (Blizzard_AuctionHouseSellFrame.lua:289-300 callbacks, :338 definition, :360 `OnDurationUpdated`, `SetItem` :374-394), so the `AUCTION_HOUSE_SHOW` + `BAG_UPDATE`/0.5 s `OnUpdate` fallback is not needed. State is read only through public accessors: `GetItem()` (ItemLocation, :411), `GetDuration()` (:435), `GetQuantity()` (:439), `GetUnitPrice()` (commodities, CommoditiesSellFrame.lua:73), `GetPrice()` -> bid, buyout (items, ItemSellFrame.lua:445). The hook body is `pcall`-wrapped. The info box is `WuweiPostFrame`, anchored under the Wuwei panel (else right of `AuctionHouseFrame`). Silence with `/wuwei post`.
- D-013 (2026-11-09): **Fees.** Deposit comes from our own call to `C_AuctionHouse.CalculateCommodityDeposit(itemID, durationIndex, qty)` / `CalculateItemDeposit(itemLocation, durationIndex, qty)` (AuctionHouseDocumentation: `duration` is a luaIndex, not hours, so the hour mapping is never needed; the label uses `AUCTION_DURATION_ONE/TWO/THREE`). Duration index: `frame:GetDuration()`, else CVar `auctionHouseDurationDropdown` (what Blizzard's dropdown stores, AlignedDuration :177), else 2, labelled `(assumed)`. **Cut: 5% faction, 15% Blackwater, both labelled "assumed"** until measured. Cut = round(total x rate). Net if sold = total - cut; the deposit is assumed refunded on a sale and lost on expiry (shown separately). No price typed: the box falls back to the plan's `sellMin`, labelled.
- D-014 (2026-11-09): **Protection is advisory red text, not a block.** Blizzard's Post button is the only action and we cannot disable it without touching secure frames. Three warnings, only on a price the player typed: `vendor` (unit < vendor sell price; `plan.vendor`, else `C_Item.GetItemInfo` return 11), `plan` (unit < `sellMin`), `basis` (unit < cost basis, or net-of-cut unit < basis).
- D-015 (2026-11-09): **Buys.** Commodities: post-hook on `AuctionHouseFrame:StartCommoditiesPurchase(itemID, quantity, unitPrice, totalPrice)` (Blizzard_AuctionHouseFrame.lua:844) stores the quote; `COMMODITY_PRICE_UPDATED(updatedUnitPrice, updatedTotalPrice)` refines it (Blizzard_AuctionHouseBuyDialog.lua:140); `COMMODITY_PURCHASE_SUCCEEDED` (no payload) records it; `COMMODITY_PURCHASE_FAILED` / `COMMODITY_PRICE_UNAVAILABLE` drop it. Items: post-hook on `AuctionHouseFrame:StartItemBuyout(auctionID, buyout)` (:859) looks the listing up with `C_AuctionHouse.GetAuctionInfoByID`, and `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` records it. This replaces "buyout from the selected browse result": it is exact per auction. Bids are not recorded. A commodity buy's `unit` is total/qty rounded; `total` is the exact amount paid.
- D-016 (2026-11-09): **Posts** are recorded on `AUCTION_HOUSE_AUCTION_CREATED(auctionID)` using details cached by a post-hook on the sell frame's `CachePendingPost(item, duration, quantity, ...)` (Blizzard calls it only after `PostCommodity`/`PostItem` succeeded: CommoditiesSellFrame.lua:141-143, ItemSellFrame.lua:497, 513). Commodity: one entry, qty = stack. Item: Blizzard's `quantity` is taken as the number of auctions (multisell), so one entry of qty 1 per `CREATED` event [TODO-INGAME]. A post with no cached context (another addon) is recorded by the next owned-auction snapshot with `inferred = true`.
- D-017 (2026-11-09): **Sales, expiries and cancels are inferred from owned auctions, not mail.** `GetInboxInvoiceInfo` is a legacy global used by MailFrame.lua:790 but is absent from the generated API docs; it needs the mail opened by the player and sale mail is delayed. Rules, on `OWNED_AUCTIONS_UPDATED` (`GetOwnedAuctions()` -> OwnedAuctionInfo {auctionID, itemKey, quantity, timeLeftSeconds?, buyoutAmount?, status}): `status == Sold` (Enum.AuctionStatus 1) records `sold` once, `inferred` absent. An auction missing from the list is `expired` if `now >= lastSeenExpiry - 120 s`, else `sold`, both `inferred = true`. A sale collected after its expiry time is therefore misread as an expiry. `AUCTION_CANCELED(auctionID)` records `cancel` directly. The diff only judges auctions of the current house. Snapshot state persists in `WuweiDB.ledgerState.owned` so offline sales are seen next login; the first snapshot ever is a baseline (no post entries).
- D-018 (2026-11-09): **Cost basis is average-cost, not FIFO.** Buys add qty and cost to a per-item pool; each `sold` entry removes qty at the pool's current average; posts, cancels and expiries never change it. `CostBasis(itemID)` returns integer copper per unit and the held qty. Sold units without a prior buy cost 0 and are counted in `unbasedSoldQty`. `PnL()` = {spent, grossRevenue, netRevenue (after the assumed cut), cogs, realized, heldQty, heldCost, unbasedSoldQty, counts}.
- D-019 (2026-11-09): **Ledger cap 5000 entries** (`Ledger.MAX_ENTRIES`), oldest dropped first; cost basis replays only what is kept, so trimmed buys are forgotten. At roughly 150 bytes per entry the SavedVariables stay under 1 MB.
- D-020 (2026-11-09): **One `C_AuctionHouse.QueryOwnedAuctions({})` per `AUCTION_HOUSE_SHOW`** (read-only, Blizzard-throttled, `pcall`-wrapped) so sales show up without the player opening the Auctions tab. `WuweiDB.ledgerQuery = false` disables it.

## Ledger export (`WuweiDB.ledger`, schema version 1)
SavedVariables file: `WTF/Account/<acct>/SavedVariables/WuweiDB.lua`, a Lua table assignment `WuweiDB = { ... }`. A pipeline importer reads `ledgerVersion` and `ledger` and ignores every other key (`enabled`, `tooltip`, `post`, `house`, `version`, `ledgerState`, `ledgerQuery`). All money is **integer copper**; all times are **server Unix seconds** (`GetServerTime()`, UTC).

| Key | Type | Notes |
|---|---|---|
| `WuweiDB.ledgerVersion` | integer | `1`. Bumped on any breaking change to the entry fields. |
| `WuweiDB.ledger` | array (1-based), chronological | Oldest first. At most 5000 entries; the oldest are dropped, so successive exports overlap: **dedupe on (`ts`, `kind`, `itemID`, `qty`, `unit`, `auctionID`, `src`)**. |

Entry fields:

| Field | Type | Present | Meaning |
|---|---|---|---|
| `ts` | integer | always | `GetServerTime()` when recorded (for inferred rows: when the addon noticed, not when it happened). |
| `kind` | string | always | One of `"buy"`, `"post"`, `"sold"`, `"cancel"`, `"expired"`. |
| `itemID` | integer | always | Item ID (`itemKey.itemID`; item level and suffix are not stored). |
| `qty` | integer | always | Units. buy: units bought. post: units posted (commodity stack; 1 per auction for items). sold/cancel/expired: units of that auction. |
| `unit` | integer | usually | Copper per unit, before the AH cut: paid (buy), asking (post/cancel/expired), gross sale price (sold). Absent only for an owned auction with neither buyout nor bid. |
| `house` | integer | usually | Auction house id at the time (111 Alliance, 114 Horde, 117 Blackwater; whatever `House.Detect()` returned, so a manual override counts). Absent if undetermined. |
| `src` | string | always | Source event: `COMMODITY_PURCHASE_SUCCEEDED`, `AUCTION_HOUSE_PURCHASE_COMPLETED`, `AUCTION_HOUSE_AUCTION_CREATED`, `AUCTION_CANCELED` or `OWNED_AUCTIONS_UPDATED`. |
| `total` | integer | buy only | Exact copper paid for the whole purchase (`unit` = `round(total / qty)`). |
| `auctionID` | integer | item buys; post, sold, cancel, expired | Blizzard auction id; links a `post` to its later `sold`/`cancel`/`expired`. Absent on commodity buys. Do not treat as globally unique over months. |
| `inferred` | boolean `true`, or absent | post, sold, expired | `true` when derived from a snapshot diff (a guess, D-017); absent when the game stated it (`status == Sold`, `AUCTION_HOUSE_AUCTION_CREATED`, `AUCTION_CANCELED`, purchase events). |

Example:
```lua
WuweiDB = { ledgerVersion = 1, ledger = {
  { ts = 1794210500, kind = "buy",  itemID = 4338, qty = 50, unit = 310, total = 15500, house = 114, src = "COMMODITY_PURCHASE_SUCCEEDED" },
  { ts = 1794211000, kind = "post", itemID = 4338, qty = 30, unit = 400, house = 117, auctionID = 901, src = "AUCTION_HOUSE_AUCTION_CREATED" },
  { ts = 1794215000, kind = "sold", itemID = 4338, qty = 30, unit = 400, house = 117, auctionID = 901, src = "OWNED_AUCTIONS_UPDATED", inferred = true },
} }
```
Caveats for the importer: `sold` `unit` is gross (the cut is not subtracted; Blackwater 15% and faction 5% are unverified assumptions); `sold` vs `expired` is a heuristic (D-017).


## In-game test checklist
Run `/console scriptErrors 1` first (P-006). One surprising result is a [TODO-INGAME], not a finding.
1. **Load:** `/reload`, then `/wuwei status`. Expect `house: <id> (faction ...)`, `plan source: BUILTIN SAMPLE (no Data/Plan.lua)` unless a generated plan exists, `age:` and `items:` counts.
2. **Map IDs (Booty Bay, Gadgetzan, Everlook).** Stand in each town and run `/wuwei probe`. Expected output: `uiMapID: <n> | mapName: <..> | zone: <..> | subzone: <..> | faction: <..>`. Record the three `uiMapID`s, then put them in `House.BLACKWATER_MAPS`. Cross-check with a labelled raw probe:
   `/run local m=C_Map.GetBestMapForUnit("player"); print("uiMapID=",m,"| zone=",GetZoneText(),"| subzone=",GetSubZoneText(),"| faction=",UnitFactionGroup("player"))`
3. **Is the Blackwater AH there?** Open the AH in each town. Panel header should read `Blackwater AH (117)`. If it shows the faction house, the zone names did not match: use the probe output to fix `BLACKWATER_ZONES` or the maps.
4. **Tooltip:** hover an item in your bags that is in the plan (sample: Liferoot 3357, Thick Leather 4304). Expect one `Wuwei: ...` line. Hover an item not in the plan: no line. `/wuwei toggle` removes it.
5. **Panel:** open the AH. The panel appears right of `AuctionHouseFrame`, rows sorted by gain, item names load (briefly `item:<id>`, then names). Close the AH: panel hides. Check with `/fstack` that `WuweiPanelFrame` is not overlapped by UI scale issues; note the anchor on small windows.
6. **Search:** click Search on a commodity row (e.g. Liferoot): Blizzard's commodities buy frame should open with the listings. Repeat on a non-commodity (gear) row to check the `QueryItem` + `SelectBrowseResult` path. Labelled check for the key info path: `/run local k=C_AuctionHouse.MakeItemKey(3357); local i=C_AuctionHouse.GetItemKeyInfo(k); print("itemKeyInfo for 3357 =", i and "ok" or "nil", "| isCommodity =", i and i.isCommodity)`. If `nil` first, the name-search fallback ran: verify that too.
7. **Throttle:** click Search quickly 95 times (or `/run for i=1,95 do WuweiPanelFrame.rows[1].button:Click() end`). Expect `search limit reached; wait Ns` after 90.
8. **Taint:** after several searches and a manual buy, check there is no `ADDON_ACTION_BLOCKED` in the error log (we call only Blizzard methods from a click).
9. **House override:** `/wuwei house 117`, reopen AH: header says Blackwater. `/wuwei house auto` restores.
10. **Real plan:** drop a generated `Data/Plan.lua` in, `/reload`, confirm `plan source:` changes and age is sane.

Phase 2 checks (11-18). Run `/console scriptErrors 1` first and label every probe (P-006); one surprising result is a [TODO-INGAME], not a finding.
11. **Sell frame accessors.** Open the AH, Sell tab, pick a commodity (e.g. Linen Cloth) and a gear item. Expect the Wuwei box under the panel with signal, deposit, cut, net, basis. Labelled accessor probe, one line: `/run local f=AuctionHouseFrame.CommoditiesSellFrame; local l=f:GetItem(); print("commodity sell frame | item:", l and C_Item.GetItemID(l), "| dur:", f:GetDuration(), "| qty:", f:GetQuantity(), "| unit:", f:GetUnitPrice())`. Repeat with `ItemSellFrame` and `f:GetPrice()` (prints bid, buyout).
12. **Box tracks edits.** Change price, quantity and the duration dropdown: the box updates each time (the `UpdatePostState` hook). Deselect the item: the box hides.
13. **Fees vs Blizzard.** The box's deposit must equal the deposit Blizzard shows in the sell frame, for all three durations. Record the hours behind each index and the exact cut: sell one cheap item at each house and read the sale mail's `consignment`/`deposit` ([TODO-INGAME]; decides D-013 and SHUTTLE).
14. **Protection.** Type a price under the vendor price, then under the plan `sellMin`, then under a known cost basis: one red line each. A price just above basis but under it after the 5% cut gives `net of cut below cost basis`.
15. **Buy capture.** Buy 5 of a commodity through Blizzard's dialog; `/wuwei ledger` shows 1 buy. Inspect: `/run local e=WuweiDB.ledger[#WuweiDB.ledger]; print("last ledger entry | kind:", e.kind, "| item:", e.itemID, "| qty:", e.qty, "| unit:", e.unit, "| total:", e.total, "| house:", e.house)`. Compare `total` with the gold actually spent. Repeat with a price-increase notice (Blizzard's "price updated" state) and with a gear buyout.
16. **Post capture.** Post a commodity stack and one gear item (and 2 gear auctions via quantity 2 if offered): `post` entries with the right qty, unit and `auctionID`. Check the item multisell count (qty 1 per auction?). Open the Auctions tab: no duplicate `post` rows.
17. **Owned-auction semantics.** On the Auctions tab with a commodity listing: `/run local a=C_AuctionHouse.GetOwnedAuctions()[1]; print("owned[1] | qty:", a.quantity, "| buyout:", a.buyoutAmount, "| bid:", a.bidAmount, "| timeLeftSeconds:", a.timeLeftSeconds, "| timeLeft:", a.timeLeft, "| status:", a.status)`. Is `buyoutAmount` per unit or per stack for commodities? Is `timeLeftSeconds` set? Do sold auctions stay in the list with `status` 1 until the mail arrives?
18. **Sale / expiry / cancel.** Cancel one listing: a `cancel` entry from `AUCTION_CANCELED`. Let a cheap listing sell and reopen the AH: `sold` (from status, or inferred). Let one expire if feasible. Then `/wuwei ledger clear confirm` and `/reload`: `WuweiDB.ledgerVersion == 1` and an empty `ledger`. Also `/run print("GetInboxInvoiceInfo is a", type(GetInboxInvoiceInfo))` to learn whether the legacy mail API exists (D-017).

Open [TODO-INGAME] from Phase 1: map IDs; whether `QueryItem` before `SelectBrowseResult` double-searches commodities (`ItemList:SetItemID` may search itself); `AuctionHouseFrame` exists at `AUCTION_HOUSE_SHOW` on Forever (the panel assumes so; it silently does nothing otherwise); panel strata and anchoring at low UI scale; Blackwater AH reachability.

Open [TODO-INGAME] from Phase 2: Blackwater and faction cut percentages (assumed 15% / 5%) and whether deposits are refunded on a sale; the hours behind duration indexes 1-3; whether `OwnedAuctionInfo.buyoutAmount` is per unit or per stack for commodities, and whether `timeLeftSeconds` is populated; whether `status == Sold` rows persist until the mail arrives (otherwise sales rely on the inferred diff); item-post `quantity` semantics (auction count vs stack); `QueryOwnedAuctions({})` accepted with an empty sorts table; `GetInboxInvoiceInfo` existence for a future mail-based confirmation; the `StartItemBuyout` hook firing for browse-row buyouts and `GetAuctionInfoByID` resolving the listing at that moment; bids are not recorded.
