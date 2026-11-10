# Reference: WoW: Forever addon knowledge base

Target: **World of Warcraft: Forever** (codename Camelot, `WOW_PROJECT_ID` 18, client 1.60.x, TOC Interface 16001).
**Not Retail/Midnight. Not Classic Era.** Forever is the Mainline engine running Vanilla-era content under Midnight's addon restrictions.

## Map

| File | Read when |
|---|---|
| [forever-platform.md](forever-platform.md) | Always first. Identity facts, confidence tags, open questions |
| [secret-values.md](secret-values.md) | Designing anything that touches combat, units, auras, cooldowns, chat |
| [forever-vs-mainline.md](forever-vs-mainline.md) | Porting Retail code or anchoring to Blizzard frames. Spec/rank/talent assumptions |
| [spatial-apis.md](spatial-apis.md) | Anything involving positions, distance, facing, map/minimap drawing |
| [auction-house.md](auction-house.md) | AH market structure, addon/API data access, tooling status, economic prior art |
| [quest-tracker.md](quest-tracker.md) | Quest log, watch list, objective tracker ordering and anchors |
| [calendar.md](calendar.md) | Reading the in-game calendar (holidays, raid resets): global month state, event types |
| [toc-and-loading.md](toc-and-loading.md) | Creating an addon. TOC, lifecycle, SavedVariables, settings |
| [lookup-recipes.md](lookup-recipes.md) | Answering "does API X exist / what does it return" |
| [pitfalls.md](pitfalls.md) | Before starting any addon work. Append when a mistake costs >1 iteration |
| [decisions/](decisions/) | ADRs for repo-wide decisions |
| `generated/` (gitignored) | `api-index.json`, `camelot-overrides.md`. Rebuilt by `scripts/sync-reference.sh` |
| `upstream/` (gitignored) | Blizzard UI source mirrors (`forever` branches). Ground truth |

## Confidence tags

| Tag | Meaning | Trust |
|---|---|---|
| [SRC] | Read in the local Blizzard source | High (true for that build) |
| [WIKI] | warcraft.wiki.gg | Medium-high |
| [NEWS] | Press, fan sites, relayed Discord quotes | Medium. Verify |
| [INFER] | Our reasoning | Low until tested |
| [TODO-INGAME] | Needs a `/dump` or in-game test | Unknown |

After each Forever patch, run `scripts/sync-reference.sh`, diff `tools/wowapi.py flags`, and re-verify the [SRC] claims whose files changed.
