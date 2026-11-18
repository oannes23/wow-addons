# Changelog

## 0.1.1
- **Fixes Lua errors inside dungeons** (SPEC D-003). In an instance the game can hide a player's name, guild or chat name as a "secret", and Headcount 0.1.0 compared it before checking, which is an error. Hidden values are now skipped quietly, as intended.

## 0.1.0
- First version. Quietly notes the full names of players your client shows you, and their guilds when the game tells you:
  - nameplates, mouseover and target;
  - the sender of public chat (say, yell, General/Trade), never the message;
  - the results of `/who` searches you run yourself.
- They're census seeds for the private population sampler (wowf-ah-collector ADR 0006). The addon sends nothing itself: `wowf-analysis push-census-seeds` reads the saved list.
- `/headcount` shows counts by source; `/headcount off|on|clear`. The list is capped at 20,000 names and 2,000 guilds, oldest dropped first.
