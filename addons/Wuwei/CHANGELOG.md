# Changelog

## 0.6.0
- **Uses block on item tooltips** (SPEC D-052). Under the price block, every item now shows:
  - its **vendor price** per unit and for the stack;
  - its **best use**: vendor it, keep it for the AH here, disenchant it, or craft it into something you can make;
  - the gain per unit over just keeping or vendoring it.

  Craft rows list the main recipes that use the item. Each reads like `Leatherworking 30 · Handstitched Leather Belt   vendor −22c · DE +23s`, meaning crafting the belt and vendoring it loses money, while disenchanting it gains.
- **Values flow through the economy.** A recipe's output is valued at *its* best use, so a chain like ore → bar → shot or leather → cheap green → disenchant shows up on the raw material. The next step is named, e.g. `craft Crafted Heavy Shot`.
- **Recipes only count when the item matters.** A recipe only counts when this item is at least a third of its input cost: two leather in a 670g sword don't make the leather worth 300g.
- **Best use only counts crafts you can make**: a known recipe, or a trainer recipe within your skill. A bigger win behind a pattern or more skill shows as a grey `Upside` line.
- Data comes from Blizzard's own Forever game tables (2,300 recipes and true vendor prices) plus your AH archive. Run `wowf-analysis export-addon`; the result stays private in `Data/Uses.lua`. `/wuwei prices short` keeps only the vendor and best-use rows.

## 0.5.0
- **Steals work at Blackwater too** (SPEC D-050). The watchlist is now one list per house. At the Booty Bay AH the scan uses Blackwater's list and thresholds instead of refusing ("The steals list is for house 114"). At a house with no list you get "No steals list for house N." Plans from older exports still work: their one list is used as before.
- **Resale hints.** When the plan says an item sells better at the other house, the chat alert, the panel row and the tooltip add `resell @Horde` (or `@Blackwater`). The gain shown is the expected take-home at the resale house (after the AH cut and expected deposit losses) minus the price, when the plan has it.
- **Falling-floor guard** (SPEC D-051). Five listings at their steal price is a floor dropping, not a steal. If more than the plan's limit (2) are listed, the alert is a quiet `CHECK` row and one chat line (`(5 listed): may be a falling floor; Search to check depth`), with no sound. A lone listing now says `only listing`, since one of something is the likeliest to be a real mispricing.
- **Depth check on your own Search.** When you click Search on a watched item (or search it yourself), Wuwei counts the listings within 10% of the cheapest. Too many: `falling floor, not a steal` and the row goes. Few: `STEAL confirmed, N near X`. It only reads what you already loaded, so it costs no searches, and it says `(partial results)` when the game has not loaded every listing. A seller posting several copies cheaply can look like a falling floor, so treat the verdict as a hint and look at the listings.

## 0.4.1
- **Fix: each auction mail was recorded twice** (SPEC D-049). Taking the gold or the items from a mail, or the game loading the item a moment late, changed what Wuwei read from it, so the same mail was saved again. Seen on the first real mailbox visit: 8 entries for 4 mails, so the harness sale counted twice. A mail is now recognised by its subject, and later reads only fill in details that were missing.
- **Fix: wrong quantity on returned stacks.** The quantity came from the first attached stack, so 10 crates returned in two stacks of 5 read as 5. It now comes from the subject (`Auction expired: Waylaid Crate: Apprentice Ore (10)`), so every mail entry has an exact quantity.
- Money received is still exact when the gold is already taken (sale price + deposit refund - AH cut).
- Ledgers written by 0.4.0 are repaired once on login: duplicates merged, quantities corrected, entries marked `repaired`.

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
