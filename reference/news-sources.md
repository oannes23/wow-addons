# WoW: Forever news sources (verified 2026-11-16/17 UTC)

How to follow Forever's announcements, hotfixes and builds. A research agent compiled this list, and the main session spot-checked it:
- the TACT `wowf` endpoint and the wow-ui-source Atom feed were re-fetched by hand on 2026-11-17;
- the mirror was synced from 70862 to 70938 the same day.

**Policy:** respect robots.txt and bot challenges. Don't poll sites that block AI crawlers from any automated pipeline whose output feeds Claude sessions:
- Wowhead, Reddit and Icy Veins are excluded;
- warcraft.wiki.gg is for a human RSS reader only.

Never fake a user agent to get past a block.

All checks done with plain GET, UA `feed-research/0.1`, a handful of requests per host.
Wowhead was NOT fetched (robots). Reddit was NOT fetched (robots `Disallow: /` for all agents).

## 0. Local mirror (was stale; synced 2026-11-17)
- Repo: https://github.com/Gethe/wow-ui-source , branch `forever` (only remote branch in our clone; local clone also has Ketho/BlizzardInterfaceResources, branch `forever`).
- Synced 2026-11-17 from `1.60.1 (70862)` to `1.60.1 (70938)`. Only additive API changes affect our addons, e.g. `C_TradeSkillUI.HasNoReagentCost`; ItemDataExport's calls are unchanged.
- Upstream commit history on forever: 70707 (11-02), 70755 (11-03), 70790 (11-04 launch), 70840 (11-06), 70862 (11-07), 70888 (11-10), 70938 (11-13). A bot commit titled "Monitor wowf product" confirms the product code.
- Commit message == build number, so each build = one commit = one tag/release (`1.60.1` tag is moved/updated).

## 1. Ranked table

| # | Source | Tier | Feed URL | Verified? | Newest Forever entry | Filter | Cadence | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | TACT `wowf` versions | DATA | `https://us.version.battle.net/v2/products/wowf/versions` (also `http://us.patch.battle.net:1119/wowf/versions`) | YES, pipe-delimited, 5 regions | 1.60.1.70938 (build config 3627b099...) | none needed (product is Forever only) | on every client build, minutes | Patch-day trigger. Compare `BuildId` / `VersionsName` / `BuildConfig`; `## seqn` changes on any product change. |
| 2 | wago.tools builds API | DATA | `https://wago.tools/api/builds/wowf/latest` (JSON); all products `https://wago.tools/api/builds` | YES | 1.60.1.70938, created_at 2026-11-13 01:36:09 | product key `wowf` | on build, lagging TACT slightly | robots allows `/api/`, `/llms.txt`, DB2 CSV only; blocks HTML. Also useful: `wow_cn_beta` (1.60.1.70450, China Forever beta), `wowt` (12.1.7.70892 Retail PTR). |
| 3 | GitHub wow-ui-source commits | DATA | `https://github.com/Gethe/wow-ui-source/commits/forever.atom` | YES, valid Atom | 2026-11-13T01:46:40Z "1.60.1 (70938)" | branch-specific already | per build (~every 2-4 days) | This is the UI-diff trigger: fetch, `git diff` old..new for Camelot/ overrides, API breaks. Tags: `.../tags.atom`; releases: `.../releases.atom` (both valid). |
| 4 | GitHub BlizzardInterfaceResources commits | DATA | `https://github.com/Ketho/BlizzardInterfaceResources/commits/forever.atom` | YES | 2026-11-14T22:14:08Z | branch-specific | few per week | Generated API data / globals; lags wow-ui-source. |
| 5 | Blizzard news: WoW: Forever Hotfixes (rolling article) | OFFICIAL | No RSS. Poll HTML `https://news.blizzard.com/en-us/article/24315281` (stable ID; 307-redirects to dated slug, currently `.../wow-forever-hotfixes-november-16-2026`) | YES (fetched, parsed) | 2026-11-16 hotfixes (incl. Vampiric Embrace change "with weekly maintenance", Fishing Rack) | n/a: whole article is Forever | hotfixes most days, article updated in place | Diff the text body by hash/section date headers. Article ID is the stable key; slug/title date rolls. |
| 6 | Blizzard news WoW listing | OFFICIAL | No RSS (`/en-us/feed`, `/rss` 404; `/feed/world-of-warcraft` is an HTML page not RSS). Poll `https://news.blizzard.com/en-us/world-of-warcraft`, regex `href="/en-us/article/(\d+)/([^"]+)"` | YES (24 article links, server-rendered) | 2026-11 (article 24317866 purchase upgrades; 24317865 "Forging Forever") | slug contains `forever` | several/week | No robots.txt (returns Next.js 404 page; none exists). Track new article IDs. |
| 7 | Blizzard forums WoW: Forever category (US) | OFFICIAL | `https://us.forums.blizzard.com/en/wow/c/wow-forever/346.rss` (Discourse; includes subcats 347 General, 348 Community, 352 Bug Report) | YES, valid RSS | 2026-11-17T03:46Z | category already Forever; JSON `.../c/wow-forever/346.json` has `pinned` flag, use to catch pinned staff threads | minutes (very noisy, ~5900 topics/week) | Noisy; used for blue/CM threads only. Filter by author list (e.g. `Kaivax` = Forever CM) via `.json` (`last_poster_username`, `posters`). Per-topic `.rss` is robots-disallowed (`/t/*/*.rss`); use `/t/<id>.json`. |
| 8 | Blizzard forums Known Issues thread | OFFICIAL | `https://us.forums.blizzard.com/en/wow/t/2402363.json` | YES | 2026-11-05 (Kaivax, "Updated Nov. 5") | single topic: watch `last_posted_at`/`posts_count` | rare | Goes stale quickly; hotfix article is more current. |
| 9 | Blizzard forums EU Forever category | OFFICIAL | `https://eu.forums.blizzard.com/en/wow/c/wow-forever/359.rss` | YES | 2026-11-17T02:26Z | as above | minutes | Mostly player threads (e.g. "We are watching the economy very closely"). Low priority. |
| 10 | Warcraft Tavern Forever news | PRESS | `https://www.warcrafttavern.com/forever/feed/` | YES, valid RSS (10 items) | 2026-11-17 02:36 UTC "Fishing Rack Adjustments: WoW Forever Hotfixes for November 16" | already Forever-only; guides mixed in, filter title `/hotfix|patch|maintenance|economy|gold|exploit|raid|phase|API|addon|nerf|change/i` | daily+ | Best Forever-specific press feed; mirrors every hotfix day. robots: only wp-admin etc. blocked. `https://www.warcrafttavern.com/feed/` (site-wide) returns just a stub (1 KB), do not use. |
| 11 | mein-mmo.de (EN) | PRESS | `https://mein-mmo.de/en/feed` | YES, valid RSS (10 items, 5 Forever) | 2026-11-16 05:00 UTC | keyword `forever` in title or `<category>`; titles like "WoW Forever: Hotfixes from ..." | several/day | Only 10 items per fetch; polling must be <= hourly. Good for server-down live tickers. Secondary quality (guides/SEO). |
| 12 | warcraft.wiki.gg recent changes | COMMUNITY | `https://warcraft.wiki.gg/index.php?title=Special:RecentChanges&feed=atom&days=7&limit=50` (alias `/wiki/Special:RecentChanges?feed=atom`) | YES, valid Atom (newest 2026-11-17T03:46:54Z) | none native for Forever; filter titles client-side `/Forever|Camelot|1\.60|Patch 1\.60|C_|API changes/` | continuous | Very noisy (everything on wiki). robots allows `*` but disallows ClaudeBot, anthropic-ai, GPTBot and similar. **Human RSS reader only**: not in the automated poll set. |
| 13 | warcraft.wiki.gg per-page histories | COMMUNITY | `https://warcraft.wiki.gg/index.php?title=Patch_1.60.1/API_changes&action=history&feed=atom`; also `...title=World_of_Warcraft:_Forever&action=history&feed=atom` | YES | API changes page: last revisions 2026-10-16/17 (Ketho; "Blue posts" section) ; Forever page: 2026-11-17T03:48Z | per page = perfect filter | page edits | Add `Patch_1.60.x/API_changes` pages as new patches appear (guess pattern; verify each). Wiki `api.php?action=query&list=search&srsearch=...` can discover them. |
| 14 | Icy Veins Forever news | PRESS | none verified. Page `https://www.icy-veins.com/wow-forever/news/` | FAILED: Cloudflare challenge (HTTP 403 "Just a moment") for page and `/rss/news` | n/a | n/a | n/a | Not pollable without bypassing a bot challenge; do not. robots.txt itself allows. |
| 15 | metaforge.app WoW Forever recent changes | PRESS | `https://metaforge.app/wow-forever/recent-changes` | FAILED: Cloudflare 403 | n/a | n/a | n/a | skip |
| 16 | Wowhead news / blue tracker | PRESS | `https://www.wowhead.com/news/rss/forever` and `https://www.wowhead.com/blue-tracker` (from secondary mention only) | not verified (robots) | n/a | n/a | n/a | Do not fetch. Wowhead also hosts per-article mirrors of Blizzard posts (blue-tracker/news/us/<article-id>). |
| 17 | Reddit | COMMUNITY | would be `https://www.reddit.com/r/<sub>/.rss` | not verified (robots: `User-agent: * Disallow: /`) | n/a | n/a | n/a | No dedicated Forever subreddit found in search (only r/wow, r/classicwow). Do not poll. |
| 18 | Blizzard CS / social | OFFICIAL | X: @BlizzardCS, @Warcraft (no official RSS; nitter unreliable) | not verified | n/a | n/a | n/a | Known-issues are posted on the forum instead (row 8). Battle.net launcher news not pollable. |
| 19 | Discords | COMMUNITY | n/a | not pollable | n/a | n/a | n/a | Blizzard has an official Forever Discord (referenced in Blizzard "WoW Weekly" post 24316097); note only. |

## 2. Recommended minimal poll set

| Order | Feed | Interval | Trigger / keywords |
|---|---|---|---|
| 1 | TACT `https://us.version.battle.net/v2/products/wowf/versions` | 5 min | any change in `BuildId` or `BuildConfig` = PATCH DAY |
| 2 | `https://github.com/Gethe/wow-ui-source/commits/forever.atom` | 15 min (conditional GET, ETag) | new entry -> `git fetch`, diff; flag changes under `*/Camelot/`, `Blizzard_*/*.toc`, `GlobalStrings`, API documentation dirs |
| 3 | Blizzard hotfix article `news.blizzard.com/en-us/article/24315281` | 30 min (hash the main text; also watch redirect slug date) | alert always; escalate on `/economy|auction|vendor|gold|repair|price|tax|exploit|rollback|compensation|currency|loot/i` and `/interface|addon|API|UI|macro|cooldown/i` |
| 4 | Blizzard WoW news listing `news.blizzard.com/en-us/world-of-warcraft` (new article IDs with `forever` in slug) | 30 min | announcements: roadmap, raid, phase, Hardcore, maintenance, patch notes |
| 5 | `https://us.forums.blizzard.com/en/wow/c/wow-forever/346.json` | 15 min | only topics with pinned=true or `last_poster_username`/creator in a CM allowlist (start: `Kaivax`; extend by inspecting `posters`); or title `/known issues|hotfix|patch notes|maintenance|economy|exploit/i` |
| 6 | `https://www.warcrafttavern.com/forever/feed/` | 30 min | title regex above; dedups against 3, but catches dev notes and numbers earlier/later |
| 7 | (human reader only) wiki.gg `Patch_1.60.1/API_changes` history feed | n/a | read by hand; the API diff from rows 1/2 is ground truth anyway |
| 8 | `https://github.com/Ketho/BlizzardInterfaceResources/commits/forever.atom` | 60 min | optional; API data diff |

Ground truth for "what changed in the API" is always the diff of rows 1/2 + our tools/wowapi.py regeneration, not the press.
Dedup key: build number (from commit title / VersionsName) and Blizzard article ID.

## 3. Detecting a new Forever client build (patch-day trigger)
- Product code: **`wowf`** (NOT `wow_classic_titan`, which is 3.80.x Titan; `wow_cn_beta` is 1.60.1 China-side beta; `wow` is Retail 12.1.5.70783).
- Primary: `GET https://us.version.battle.net/v2/products/wowf/versions` (same data at `http://us.patch.battle.net:1119/wowf/versions`). Format: `Region|BuildConfig|CDNConfig|KeyRing|BuildId|VersionsName|ProductConfig`. Current: BuildId 70938, VersionsName `1.60.1.70938`, same in us/eu/cn/kr/tw. Hotfix-only changes do not bump this; client builds do.
- Secondary: `https://wago.tools/api/builds/wowf/latest` -> JSON {version, created_at, build_config, cdn_config, product_config}. Build timestamps so far: 70938 created 2026-11-13 01:36 UTC; GitHub commit 10 minutes later.
- Confirm: wow-ui-source commit "1.60.1 (<build>)" arrives within minutes to hours after TACT changes.
- Detect pre-release: compare `wow_cn_beta` / `wowt` entries in `/api/builds` (a new `1.6x` product build before `wowf` would be a PTR/beta of the next patch).
- Per-build cadence observed: 7 builds in 12 days (11-02 .. 11-13); expect weekly maintenance (Blizzard hotfix text: "[With scheduled weekly maintenance]"; the in-game weekly reset day not verified here).

## 4. Upcoming dates found
| Date | Item | Source |
|---|---|---|
| 2026-12-09 | New raids unlock (reported: Barrow Deeps 10p, Hyjal Summit 20p, Onyxia's Lair 40p) | Date: OFFICIAL, https://news.blizzard.com/en-us/article/24303862 ("New raids unlock on December 9"). Raid names: PRESS (wowguide.net, method.gg, warcrafttavern) |
| "Sometime after launch" (winter 2026-27) | Hardcore ruleset, no date | OFFICIAL, article 24303862 and starter guide 24315280 ("Hardcore planned to follow a little after launch") |
| Spring 2027 | two more new raids (per press roadmap summaries) | PRESS (wowguide.net, hardcorehelper.com); official wording not seen |
| Summer 2027 | revamped iconic raid plus another new raid; Molten Core is speculation | PRESS; "revamped iconic raid" is in official article 24303862, season from press |
| Weekly | scheduled weekly maintenance (hotfix articles reference it) | OFFICIAL hotfix article |
Past reference: launch 2026-11-04 3pm PST (23:00 UTC), beta from 2026-09-17 (OFFICIAL, article 24303862).

## 5. Economy/news items seen (context, not dates)
- Active forum mega-threads on a gold exploit ("Streamers used a Gold Exploit", "Mega Thread on the Gold Exploit", EU "We are watching the economy very closely") as of 2026-11-17: check hotfix article for rollbacks/compensation.
- Hotfixes 11-14 to 11-16: dungeon XP reduced twice, Fishing Rack lures, Vampiric Embrace halved "with scheduled weekly maintenance".

## 6. Constraints / terms
- Blizzard news: no robots.txt (404 page). Be gentle; HTML scrape is the only route. No RSS exists.
- Blizzard forums: robots disallows `/t/*/*.rss`, `/search`, `/tag/*/l`; category `.rss`/`.json` and `/t/<id>.json` were fetched OK.
- warcraft.wiki.gg: AI-crawler UAs blocked; `*` allowed. We treat that as a block for automated use. wago.tools: only `/api/`, `/llms.txt`, `/apis`, `/db2/*/csv`.
- GitHub: use conditional GET (If-None-Match); atom feeds fine.
- Reddit: robots blocks all; Wowhead: robots blocks us; Icy Veins/metaforge: Cloudflare challenge (do not circumvent).
