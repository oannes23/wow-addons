# Changelog

## 0.4.0
- **Fix: ledger misread a partly sold commodity auction** (SPEC D-047). Seen on 77 Deviate Scales with 21 bought: the ledger recorded a cancel you never made, booked the 21 at the whole sale's total (1g 21s each instead of 5s 78c) and recorded the remaining 56 as a second post. Now:
  - a partial sale is one `sold` entry at your listing price;
  - a cancel counts only once the auction is really gone (the game also fires its cancel event when part of an auction sells);
  - the game's own expiry event is used when it fires;
  - a visit's first, possibly empty, auction list no longer drops records.
  - Existing ledgers are repaired once on login (entries marked `repaired`).
- **Mail invoices** (SPEC D-048). Opening a mailbox records each "Auction successful" mail with the exact sale price, deposit refund, AH cut and money received, plus expired and canceled returns. Mail is never opened, taken or deleted for you. `/wuwei ledger` prints an exact `mail` line next to the estimate. `/run WuweiDB.mail = false` turns it off.

## 0.3.0
- **Two-house prices on every item tooltip** (SPEC D-042 to D-046). Below Blizzard's sell price, every item you hover shows Horde and Blackwater, with the house you stand at on top:
  - a headline line per house: what it sells for (median of recent inferred sales), the cheapest listing now, and units sold per day;
  - a detail line: median listing, units listed and near the floor, 7-day price change, and the number of sales behind the price;
  - when they apply: a haul line (profit per unit buying here and selling at the other house, after its cut), vendor flags (floor below vendor price; vendor beats the AH), stack totals, and the data age.
- `/wuwei prices full|short|off` (default full; no argument cycles). Short keeps one line per house plus the haul and vendor flags.
- Needs `Data/Prices.lua`, which `wowf-analysis export-addon` now writes next to `Plan.lua` (private, gitignored). Without it the block stays off.
- **Fix: fake steals at 0c.** The item-key search returns a row for every watched item, including items with nothing listed (quantity 0, price 0). Those were announced as `STEAL ... listed at 0c (0%)` and Search came up empty. They're now ignored, and such a row clears an old find (SPEC D-041).
- **Fix: scan stopping partway (about 15 of 22 steps, "partial").** Item-key replies were being paged twice each, spending the 40-query budget. They're complete in one reply now, so a full scan takes about 22 queries and finishes in one click.

## 0.2.0
- **Steals watchlist** (SPEC D-033 to D-040). The pipeline's plan may now carry `steals`: niche, often-mispriced non-commodity items (recipes, pets, mounts, rare/epic BoEs) with a fair value and an alert price.
- **Scan steals** button in the AH panel and `/wuwei steals scan`: one click reads the current minimum listing of every watched item (`C_AuctionHouse.SearchForItemKeys`, falling back to category and name browse if that never answers). At most 40 queries per click, sharing Wuwei's search throttle and leaving room for your own searches. It never starts by itself, and it stops if you search yourself.
- A listing at or below the alert price gives a chat line (item link, price, fair value, % of fair), an optional sound and a `STEAL` row at the top of the panel. Its Search button opens Blizzard's buy frame on that item; you buy with Blizzard's Buyout button. Wuwei never buys or bids on its own.
- Browse results you load yourself are checked against the watchlist too, at no extra queries.
- Tooltip line for watched items: `Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · 42m`. If the item also has a plan line, the plan line is shown instead.
- Settings: `/wuwei steals on|off`, `/wuwei steals sound [on|off]`, `/wuwei steals` for status (`WuweiDB.steals`, `WuweiDB.stealsSound`, both default on). A plan without `steals` turns the feature off without messages.

## 0.1.0
- Unreleased baseline: plan tooltip line, AH side panel with Search hand-off, house detection, post helper, trade ledger, keyboard sign-off flow (Accept/Skip bindings), shuttle toggle.
