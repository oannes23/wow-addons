# QuestTrackerSort

A **World of Warcraft: Forever** addon that reorders the Quests section of the objective tracker. By default the game puts your newest quest on top. This puts the quests you can actually work on there instead.

## Modes
| Mode | Order | Tiebreak |
|---|---|---|
| **Dist** (default) | Closest → furthest | Lowest level (quests within the same ~50 yards count as tied) |
| **Lvl** | Lowest level → highest | Closest |

Two buttons sit on the **Quests** header, next to the minimize button:
- **Dist / Lvl** switches mode. It's locked during combat.
- **⟳** re-sorts now.

Distance mode re-checks once a minute. It also re-sorts when you change zone or map, accept a quest, or change which quests are tracked, and it only touches the tracker when the order actually changed. **Nothing is sorted during combat.** A sort requested mid-fight runs when combat ends.

## Install
Download `QuestTrackerSort-<version>.zip` from the [Releases](https://github.com/oannes23/wow-addons/releases) page. Unzip it into
`World of Warcraft/_forever_/Interface/AddOns/` so you end up with `AddOns/QuestTrackerSort/QuestTrackerSort_Forever.toc`. Then restart the game.

## Commands
`/qts` (or `/questtrackersort`)
| Command | Effect |
|---|---|
| `/qts` or `/qts toggle` | Switch between Dist and Lvl |
| `/qts distance` · `/qts level` | Set the mode |
| `/qts refresh` | Re-sort now |
| `/qts interval <sec>` | Distance re-check interval (default 60, minimum 10) |
| `/qts status` · `/qts debug` | Show state · print each re-sort |

Clicking the addon-compartment (minimap) entry also switches mode.

## How it works
The tracker shows quests in the order of the client's quest watch list, and the game inserts each new watch at the top. There's no API to reorder that list, so QuestTrackerSort removes every watch and adds them back in the order it wants. It then reads the list back to confirm the result. It doesn't hook or replace any Blizzard tracker code, so the tracker's quest-item buttons stay untainted and keep working in combat. Design notes and test log: [SPEC.md](SPEC.md).

**Limits:** only *tracked* quests appear in the tracker (game cap: 25), so only tracked quests get sorted. Quests with no map location go last.

## License
GPL-3.0-or-later. See [LICENSE](LICENSE). Author: [oannes23](https://github.com/oannes23).
