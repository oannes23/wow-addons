# Changelog

## 0.2.0
- **Steals watchlist** (SPEC D-033 to D-040). The pipeline's plan may now carry `steals`: niche, often-mispriced non-commodity items (recipes, pets, mounts, rare/epic BoEs) with a fair value and an alert price.
- **Scan steals** button in the AH panel and `/wuwei steals scan`: one click reads the current minimum listing of every watched item (`C_AuctionHouse.SearchForItemKeys`, falling back to category and name browse if that never answers). At most 40 queries per click, sharing Wuwei's search throttle and leaving room for your own searches. It never starts by itself, and it stops if you search yourself.
- A listing at or below the alert price gives a chat line (item link, price, fair value, % of fair), an optional sound and a `STEAL` row at the top of the panel. Its Search button opens Blizzard's buy frame on that item; you buy with Blizzard's Buyout button. Wuwei never buys or bids on its own.
- Browse results you load yourself are checked against the watchlist too, at no extra queries.
- Tooltip line for watched items: `Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · 42m`. If the item also has a plan line, the plan line is shown instead.
- Settings: `/wuwei steals on|off`, `/wuwei steals sound [on|off]`, `/wuwei steals` for status (`WuweiDB.steals`, `WuweiDB.stealsSound`, both default on). A plan without `steals` turns the feature off without messages.

## 0.1.0
- Unreleased baseline: plan tooltip line, AH side panel with Search hand-off, house detection, post helper, trade ledger, keyboard sign-off flow (Accept/Skip bindings), shuttle toggle.
