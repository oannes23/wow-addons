# Changelog

## 1.0.0
- First release for WoW: Forever (Interface 16001).
- Sorts the Quests tracker by **distance** (closest first, level tiebreak) or **level** (lowest first, distance tiebreak).
- Header buttons: Dist/Lvl toggle (locked in combat) and ⟳ refresh.
- Distance mode re-checks every 60s (configurable) and on zone change, quest accept, or tracking change. It only rewrites when the order changed.
- No sorting during combat; queued sorts run when combat ends.
- Checks its own work: detects how the client inserts watches, and pauses with a warning if the client re-orders the list by itself.
