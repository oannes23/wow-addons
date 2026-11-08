# Spatial APIs: positions, distance, facing, map drawing (Forever)

Confidence key as in [forever-platform.md](forever-platform.md).

| API | Docs say | In game | Notes |
|---|---|---|---|
| `UnitPosition(unit)` → x, y, z, mapID | no secrecy flags, non-nilable (**the docs are wrong for addon callers**) [SRC] | **Hostile NPC (target and `nameplate1`), out of combat: `nil, nil, nil, 1`.** Only the map ID comes back [INGAME 2026-11-06] | **Retail's restriction holds: no coordinates for non-group units.** An earlier `/dump` showing `-3048, -1079, 0, 1` was not the mob's position, most likely the player's own or a different unit. Don't use it. `z` is reportedly always 0 [WIKI/common knowledge], so a zero height means nothing. |
| `UnitDistanceSquared(unit)` → distSq, checked | no secrecy flags [SRC] | Hostile NPC target, out of combat: `1385, true` and `5390, true`. `"nameplate1"` (= the target) gave the same value [INGAME 2026-11-06] | **Exact distance to a non-group NPC works**, even though its position is withheld. Untested: a nameplate that *isn't* your target, and in-combat behavior [TODO-INGAME]. |
| `GetPlayerFacing()` → radians? | nilable, no flags [SRC] | open world: `4.7677` [INGAME 2026-11-06] | Works in the open world. 0 = north, counter-clockwise [WIKI]. Instances untested. |
| `C_QuestLog.GetDistanceSqToQuest(questID)` → distSq, onContinent | `MayReturnNothing`, no secrecy flags [SRC] | Several tracked Vanilla-era quests, open world: all returned `onContinent = true` with plausible yard values [INGAME 2026-11-07, build 1.60.1] | Distance to the quest's POI. Used by QuestTrackerSort. When it returns nothing (quest with no POI) is untested [TODO-INGAME]. |
| `C_Map.GetPlayerMapPosition(mapID, unit)` | "Only works for the player and party members." [SRC] | — | |
| `C_Map.GetWorldPosFromMapPos` / `GetMapPosFromWorldPos` | no flags [SRC] | — | World ↔ map coordinate conversion |
| `C_Spell.IsSpellInRange(spell, unit)` | sink (`AllowedWhenTainted`) [SRC] | — | Coarse range bands |
| `CheckInteractDistance(unit, idx)` | no flags [SRC] | — | Historically restricted in combat [WIKI] |
| World-to-screen projection, ground decals | **do not exist** [SRC] | — | No 3D drawing |
| Map/minimap pins | `Blizzard_MapCanvas`, `Blizzard_SharedMapDataProviders` [SRC] | — | World map: data-provider pins. Minimap: manual offset math (the HereBeDragons approach) |

## Implication: multilateration (the only route to NPC positions)
Your own position (`UnitPosition("player")`) plus exact distance to an NPC (`UnitDistanceSquared`) from **three or more non-collinear points** pins down a stationary NPC's 2D position. Two readings leave a mirror ambiguity, which a third reading or the nameplate's screen side (left/right) resolves. This **reconstructs data Blizzard deliberately withholds** (`UnitPosition` for non-group units). Treat anything built on it as fragile: it could stop working in any hotfix, and it's against the spirit of the restriction. Decide via ADR before building on it.
