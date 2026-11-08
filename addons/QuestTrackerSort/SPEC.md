# QuestTrackerSort: spec

## Problem
The Quests section of the objective tracker puts the most recently accepted quest at the top. That's rarely the quest you're working on. When you finish a cluster of quests, there's also no quick way to see what comes next by level.

## Scope
- In:
  - Two sort modes with a toggle button on the Quests header:
    - **Distance:** closest → furthest. Distances are rounded into 50-yard buckets; ties within a bucket go to lowest level, then questID.
    - **Level:** lowest → highest (`GetQuestDifficultyLevel`). Ties go to closest distance, then questID.
  - A **Refresh** button (icon) that re-sorts now and clears the "unsupported" latch.
  - The mode toggle is **locked during combat**: greyed out, the tooltip explains why, and slash/compartment mode changes are refused.
  - No sorting in combat. A sort requested in combat runs on `PLAYER_REGEN_ENABLED`.
  - Distance mode re-checks on a slow timer (default 60s, configurable) and rewrites only when the order actually changed. It also re-sorts on zone/map changes and whenever the watch list changes (e.g. a new quest is accepted).
- Out:
  - Sorting quests that aren't watched. The tracker never shows those. The watch cap is 25 (`Constants.QuestWatchConsts.MAX_QUEST_WATCHES`) [SRC].
  - Replacing or re-skinning the tracker (approach C).
  - World quests, bonus objectives, campaign module.

## Approach (decided; see D-001)
The tracker shows quests in **watch-list index order**. `BuildQuestWatchInfos` walks `GetQuestIDForQuestWatchIndex(1..n)`, and its sort only lifts Callings and `overridesSortOrder` quests (`Blizzard_QuestObjectiveTracker.lua:168-197`) [SRC]. There's no setter for watch order, so we **rewrite the watch list**: remove all watches, then add them back in the order we want. Then we read the list back to check.
- If the read-back comes out exactly reversed, `AddQuestWatch` puts quests at the top. We flip `db.insertMode` and rewrite again. The setting persists.
- If the read-back is in some other order, the client re-sorts the list itself. We print one warning and stop auto-sorting until the user presses Refresh.

## Secret-value viability (required; see reference/secret-values.md)
| Data needed | API | Secrecy flags (tools/wowapi.py) | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Watched quest IDs | `C_QuestLog.GetNumQuestWatches`, `GetQuestIDForQuestWatchIndex` | returns not secret; args `AllowedWhenUntainted` | n/a: we branch on them | none needed |
| Distance to quest | `C_QuestLog.GetDistanceSqToQuest` → `distanceSq, onContinent` | returns not secret; `MayReturnNothing` | n/a | nil or off-continent → sorted last |
| Quest level | `C_QuestLog.GetQuestDifficultyLevel` | returns not secret | n/a | nil → 0 |
| Rewrite watches | `C_QuestLog.RemoveQuestWatch`, `AddQuestWatch` | no `HasRestrictions`; args `AllowedWhenUntainted` | n/a | out of combat only (our policy) |
| Super-track restore | `C_SuperTrack.GetSuperTrackedQuestID` / `SetSuperTrackedQuestID` | none | n/a | restore after rewrite |
| Combat state | `InCombatLockdown` | none | n/a | none |

Verdict: **fully viable.** Nothing here is secret. Quest and map APIs are rated ✅ High in `reference/secret-values.md`.

## Forever-specific considerations (reference/forever-vs-mainline.md)
- Frames touched: `QuestObjectiveTracker.Header` (our child buttons are anchored left of its `MinimizeButton`) [SRC `Blizzard_ObjectiveTrackerModule.xml`]. Nothing of Blizzard's is written, hooked, or re-parented.
- Camelot override `Blizzard_ObjectiveTracker/Camelot/Blizzard_QuestObjectiveTrackerOverride.lua` only changes the timer bar and tag text. Ordering isn't affected [SRC].
- Blizzard calls `C_QuestLog.SortQuestWatches()` on `ZONE_CHANGED_NEW_AREA`, and on `ZONE_CHANGED` when the map ID changes (`Blizzard_ObjectiveTracker.lua:23-31`) [SRC]. We re-apply our order after those events with a short delay.
- Refresh icon: `Interface\Buttons\UI-RefreshButton`, the same texture used by `Blizzard_GroupFinder_VanillaStyle`, which loads on Forever [SRC].

## UX
- The Quests header gets `[Dist|Lvl] [⟳]`, just left of the minimize button. Tooltips explain both.
- Slash `/qts`: `toggle` · `distance` · `level` · `refresh` · `interval <sec>` · `debug` · `status`.
- Clicking the addon-compartment entry toggles the mode.

## Data model (SavedVariables)
`QuestTrackerSortDB` (account-wide):
| Key | Default | Meaning |
|---|---|---|
| `mode` | `"distance"` | `"distance"` or `"level"` |
| `interval` | `60` | seconds between distance re-checks (min 10) |
| `bucketYards` | `50` | distance bucket size used for the level tiebreak |
| `insertMode` | `"prepend"` | `"append"` or `"prepend"`; the default comes from T2, and the runtime check corrects it if the client ever changes |
| `debug` | `false` | print each rewrite |

## Open questions / in-game verification
- [x] T1: Panel order matches `GetQuestIDForQuestWatchIndex` order. [INGAME 2026-11-07]
- [x] T2: `AddQuestWatch` inserts at the **top** (index 1). This is the root cause of "newest quest on top". [INGAME 2026-11-07]
- [~] T3: `SortQuestWatches()` made no visible change with all-Manual watches, so Blizzard's zone-change sorts shouldn't undo ours. What it does with Automatic watches is untested. [INGAME 2026-11-07]
- [x] T4: `GetDistanceSqToQuest` returned `onContinent = true` for all tracked Vanilla-era quests. [INGAME 2026-11-07]
- [x] T5: Clean reorder, no animations. [INGAME 2026-11-07]
- [~] T6: Every observed watch was already Manual (type 1), so there was nothing to lose here. [INGAME 2026-11-07]
- [ ] T7: Does `GetQuestDifficultyLevel` differ from `GetInfo().level` on Forever? Which one matches the log colors?
- [x] T8: The super-tracked quest survives a rewrite (with our restore). [INGAME 2026-11-07]

## Decisions
- **D-001 Watch-list rewrite (approach A)** over replacing `BuildQuestWatchInfos` (B) or a custom tracker (C).
  - Why: the tracker holds secure quest-item buttons. Overriding its mixin from addon code taints them and risks `ADDON_ACTION_BLOCKED` in combat. Rewriting the watch list only changes client-side state, and Blizzard redraws through its own deferred `MarkDirty()`.
  - Cost: watch-type changes may be lost (T6), and the approach fails if the client re-sorts the list itself (detected at runtime).
- **D-002 No hooks.** We don't `hooksecurefunc` `C_QuestLog.SortQuestWatches`. We re-apply after zone events and `QUEST_WATCH_LIST_CHANGED` instead. Smaller taint surface, and it works even if API tables are read-only.
- **D-003 Slow timer + "write only if the order changed"** instead of constant re-sorting. The 60s default follows the user's suggestion; map changes act as a natural threshold. 50-yard buckets make quests clustered at one hub tie, and those ties then go to level as the user specified. The bucketing also adds hysteresis.
- **D-004 Distance timer runs only in distance mode.** In level mode, order changes only on a mode switch, Refresh, a watch-list change, or a zone change.
- **D-005 Combat:** never rewrite while `InCombatLockdown()`. Set `pending` and flush on `PLAYER_REGEN_ENABLED`.
- **D-006 Verify after write.** Read the list back after each rewrite. Learn `insertMode` from an exact reversal. Latch `unsupported` on any other mismatch so a failing rewrite doesn't repeat every tick.
- **D-007 Default `insertMode = "prepend"`** (from T2). Rewrite re-adds quests in reverse order. The runtime read-back still flips the setting if a later patch changes insertion behavior.
- **D-008 Lock the mode toggle in combat** (user request after v1 testing). `SetMode` refuses changes during `InCombatLockdown()`. The button is disabled on `PLAYER_REGEN_DISABLED` and re-enabled on `PLAYER_REGEN_ENABLED`. Refresh stays clickable and queues the sort as before.
- **D-009 Release 1.0.0 (2026-11-07)**: in-game tests A–F passed. License GPL-3.0-or-later, author `oannes23`. Distributed as a GitHub release zip from the public monorepo (ADR 0002).
