# Quest log, watch list, and the objective tracker (Forever)

Confidence key as in [forever-platform.md](forever-platform.md). Build 1.60.1.70790.

## How the tracker orders quests
| Claim | Evidence |
|---|---|
| The Quests section draws watches in **watch-list index order** (`C_QuestLog.GetQuestIDForQuestWatchIndex(1..n)`). Its sort only lifts Callings and `overridesSortOrder` quests above the rest. | [SRC] `Blizzard_ObjectiveTracker/Blizzard_QuestObjectiveTracker.lua:168-197` · panel order matched index order [INGAME 2026-11-07] |
| **`C_QuestLog.AddQuestWatch(questID)` inserts at index 1 (the top).** This is why "the newest quest is always on top". | [INGAME 2026-11-07]: removing and re-adding the last watch moved it to first place; doing the same to the first watch left the order unchanged |
| There's no API to set watch order directly. The only way to reorder is to remove watches and re-add them, adding in **reverse** of the order you want. | [SRC] (no setter in `QuestLogDocumentation.lua`) + the row above |
| `C_QuestLog.SortQuestWatches()` made no visible change when every watch was Manual (`QuestWatchType` 1). It probably only reorders Automatic watches, or nothing at all. Blizzard calls it on `ZONE_CHANGED_NEW_AREA`, and on `ZONE_CHANGED` when the map ID changes. | [SRC] `Blizzard_ObjectiveTracker.lua:23-31` · no-op observed [INGAME 2026-11-07] · what it does with Automatic watches is untested [TODO-INGAME] |
| Watches the player added by hand, or that auto-watch added on quest accept, came back as `QuestWatchType.Manual` (1). | [INGAME 2026-11-07] |
| Removing and re-adding a watch from addon code: the tracker reacts through its deferred `MarkDirty()`, not synchronously, so taint is unlikely to spread into it. | [SRC] module `events` list → `MarkDirty` · taint-free behavior [INFER] |
| Removing every watch and re-adding them in the same frame gives a **clean reorder**: no fade or fanfare animation. | [INGAME 2026-11-07] (QuestTrackerSort test E) |
| The super-tracked quest survives a remove/re-add rewrite, at least when `SetSuperTrackedQuestID` restores it afterwards. | [INGAME 2026-11-07] (QuestTrackerSort test F). Whether it survives without the restore is untested. |
| Watch cap: `Constants.QuestWatchConsts.MAX_QUEST_WATCHES = 25`. | [SRC] `QuestConstantsDocumentation.lua` |
| Camelot override of the quest tracker: only the timer bar (off) and quest tag text. Ordering isn't changed. | [SRC] `Blizzard_ObjectiveTracker/Camelot/Blizzard_QuestObjectiveTrackerOverride.lua` |

## Anchor points
- `QuestObjectiveTracker.Header`: the "Quests" module header, 260×26, with `MinimizeButton` anchored RIGHT [SRC] `Blizzard_ObjectiveTrackerModule.xml`.
- `ObjectiveTrackerFrame.Header`: the "All Objectives" container header [SRC] `Blizzard_ObjectiveTracker.xml`.
