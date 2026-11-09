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
  1. `Data/Plan.lua` (generated, gitignored) loaded at login and `/reload`.
  2. A tooltip line: reference price (our p25), the signal (`BUY ≤ x` / `SELL ≥ y` / `SHUTTLE → BW y` / `HOLD`), the 24h real trend, and data age.
  3. An **AH side panel** attached to `AuctionHouseFrame`: today's plays for *this* house, sorted by expected gold. Each row has a **Search** button (`C_AuctionHouse.SendSearchQuery`; 100/min limit respected) that opens Blizzard's own buy frame for the item. The max price is shown, with an over-price warning.
  4. **House detection:** faction AH vs Blackwater, by map (`C_Map.GetBestMapForUnit("player")` → Booty Bay, Gadgetzan, Everlook) with `GetZoneText` as fallback. The map IDs are [TODO-INGAME].
- **Phase 2:**
  - **Post helper:** a target price from the plan plus posting protection (block or confirm below vendor price, below the plan floor, or below the cost basis). Deposit via `C_AuctionHouse.CalculateCommodityDeposit`/`CalculateItemDeposit`, the AH cut, and net proceeds shown before the click.
  - **Ledger:** purchases (`COMMODITY_PURCHASE_SUCCEEDED`, `AUCTION_HOUSE_PURCHASE_COMPLETED`), posts (`AUCTION_HOUSE_AUCTION_CREATED`), sales and expiries (mail), with cost basis per item and house. Exported to the pipeline as SavedVariables, so we get P&L and **ground truth for the inferred-sales model** (ADR 0003 calibration).
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
- [ ] Do the purchase events carry enough (item, quantity, price) for the ledger, or does it need the buy-frame quote?

## Decisions
- D-001 (2026-11-09): **thin action layer over a pipeline**, not another scanner. The differentiators are our signals, cross-house spreads, real prices, and a ledger that feeds back.
- D-002 (2026-11-09): **Phase 0 before code.** Prove the signals with an Auctionator shopping-list export, then build Phase 1.
- D-003 (2026-11-09): data enters as a generated `Data/Plan.lua` (code files load on every `/reload`; size-bounded; gitignored because it's private). SavedVariables are for the ledger only.
- D-004 (2026-11-09): hand purchases off to Blizzard's buy frame in Phase 1 (search pre-filled, the player clicks Buy) instead of driving `StartCommoditiesPurchase` ourselves. The least surface and the least policy risk.
