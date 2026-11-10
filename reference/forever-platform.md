# WoW: Forever: platform ground truth

Last verified: **2026-11-06** against source build **1.60.1.70790** (wow-ui-source `forever` branch, commit dated 2026-11-04). In-game checks 2026-11-06 on the live US client: `GetBuildInfo()` → `1.60.1`, `70790`, `Nov 3 2026`, `16001`, the **same build as the source mirror** (no lag).
Mirror re-synced **2026-11-09** to source build **1.60.1.70862** (the build the live client reported that day, per auction-house.md): 9 files changed, `tools/wowapi.py flags` histogram identical to 70790, no `Camelot/`, AH or objective-tracker file touched. [SRC] line numbers cited before this date refer to 70790.
Confidence key: **[SRC]** read directly in the local Blizzard source · **[WIKI]** warcraft.wiki.gg · **[NEWS]** secondary press/fan sites · **[INFER]** our inference · **[TODO-INGAME]** must be confirmed in the client.

## Identity

| Fact | Value | Confidence |
|---|---|---|
| Product | *World of Warcraft: Forever*, the third branch alongside Midnight (Standard) and Classic. Launched 2026-11-04. Level 1–60, a re-imagined Vanilla-era Azeroth in its own continuity. | [NEWS] |
| Internal codename | **Camelot** | [SRC] |
| `WOW_PROJECT_ID` | `18` (= `WOW_PROJECT_CAMELOT`) | [SRC] `Blizzard_ProjectConstants/Camelot/ProjectConstants.lua` + [INGAME 2026-11-06] `/dump WOW_PROJECT_ID` → 18 |
| `WOW_PROJECT_MAINLINE` | `1`. **Not** Forever. Some fan guides wrongly say Forever is 1. | [SRC] |
| Client version | `1.60.1` | [SRC] `version.txt` |
| TOC `## Interface:` | **`16001`** | [INGAME 2026-11-06] `/dump select(4, GetBuildInfo())` → `16001` (the trailing `localizedVersion`/`buildInfo` returns print as `" "`; harmless). Version encoding: 1.60.1 → `1*10000+60*100+1`. |
| TOC filename suffix | `_Forever.toc` or `_Camelot.toc` (aliases). `_Mainline.toc` is a *family* suffix that also loads on Forever. | [WIKI] |
| `AllowLoadGameType` token | `camelot` (used 236× in FrameXML). Wiki says `forever` is an alias. Family token: `mainline`. | [SRC] + [WIKI] |
| Codebase lineage | Forked from **Mainline 12.1.5 (Midnight)**. Shares its UI architecture and "the vast majority of APIs". Forever-specific behavior lives in `Camelot/` override subfolders (61 Blizzard addons have one). | [SRC] + [NEWS] (Blizzard statement via the WoW UI Discord, 2026-09-16) |
| Addon restrictions | **Midnight's addon disarmament is active: secret values, restricted CLEU, combat lockdown on information.** See [secret-values.md](secret-values.md). | [SRC] + [NEWS] |
| Built-in replacements | Blizzard Damage Meter (`Blizzard_DamageMeter`, `C_DamageMeter`) and Cooldown Manager (`Blizzard_CooldownViewer`) ship in Forever. | [SRC] |
| Forever-only API | `ForeverExperiencePreset` enum (`Classic`=0, `Enhanced`=1) with `Get/SetForeverExperiencePreset*` in the GameRules system. `TraitConfigType.CamelotCombat`. `LootConsts_Camelot`, `PetConsts_Camelot`, `LevelConstsExposed_Camelot`. | [SRC] |
| Local install | `/Applications/World of Warcraft/_forever_/` (AddOns at `Interface/AddOns`, SavedVariables at `WTF/Account/<ACCT>/SavedVariables`) | [SRC] (filesystem) |

## What this means (the frame to hold)

**Forever = Mainline engine + Midnight restrictions + Vanilla-era content and art + Camelot overrides.**

| If you are tempted to… | Instead |
|---|---|
| Use a Classic Era API or pattern (`UnitAura` index loops, old `GetSpellInfo` multi-return, CLEU damage parsing) | Look it up with `tools/wowapi.py`. The Mainline `C_*` namespace form is almost always the one that exists. |
| Copy Retail/Midnight addon code verbatim | Mostly fine at the API level, **but** check `Camelot/` overrides: some frames don't exist (e.g. no `ProfessionsBookFrame`; the micro button toggles `ProfessionsFrame`) or behave differently. |
| Read combat data and compute on it in Lua | You can't. Under secret values you **display**, you don't **decide**. See secret-values.md. |
| Branch on `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE` | Forever is `18`. Use `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`, or better, feature-detect (`if C_Foo and C_Foo.Bar then`). |

## Open questions (update as resolved)

- ~~Exact interface number on live realms~~ → 16001 [INGAME 2026-11-06]. Still open: hotfix cadence for TOC bumps.
- ~~In-game build vs source~~ → both 70790 [INGAME 2026-11-06].
- [TODO-INGAME] Whether `_Forever.toc` is preferred over `_Camelot.toc` long-term. The wiki notes Camelot "may be changed to Forever". **Policy: ship `_Forever.toc` only.**
- [TODO-INGAME] The precise runtime trigger for each `SecretWhen*Restricted` flag (combat? instance? encounter?). The source declares the flags but not the predicate. Results so far [INGAME 2026-11-06]: open-world **combat** turns on aura and cooldown secrecy (`C_Secrets.ShouldAurasBeSecret/ShouldCooldownsBeSecret` → true). `UnitHealthMax` is readable for `"player"` and secret for any NPC (friendly or hostile), even out of combat. Test matrix: open world idle ✅ → open-world combat ✅ → dungeon → dungeon boss. **The dungeon rows are deferred until the user's character is high enough level (as of 2026-11-06).**
- Hardcore realms (winter 2026): may add further restrictions. Re-verify then.

## Sources

- Local: `reference/upstream/wow-ui-source` (Gethe, branch `forever`), `reference/upstream/BlizzardInterfaceResources` (Ketho, branch `forever`; lagged at build 70532 when last checked)
- https://warcraft.wiki.gg/wiki/TOC_format
- https://en.wikipedia.org/wiki/World_of_Warcraft:_Forever
- https://wowclassicforever.info/news/addons-api/ (aggregates the Blizzard UI Discord statement, 2026-09-16)
