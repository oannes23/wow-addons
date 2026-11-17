# Classic fishing priors (StraightHook seed data)

Vanilla (1.12) fishing loot tables and zone fishing levels, used by StraightHook as a **prior** until the player's own catches at a spot take over (StraightHook SPEC D-006). Forever may differ: Zephras Isle and Forever-only items are missing, and the first spot compared (Orgrimmar, Valley of Honor, 46 catches on 2026-11-17) matched Classic's shares within noise.

| File | Columns | Meaning |
|---|---|---|
| `classic_fishing_loot.csv` | area_id, item_id, pct, group, kind | `group` 1: exactly one item per catch, `pct` is its share (explicit chances, with chance-0 rows splitting the remainder equally). `group` 0: rolled independently at `pct`. `kind`: `seasonal` (Winter Squid / Raw Summer Bass, gated by a seasonal event, 10 %), `quest` (only drops on the quest) |
| `classic_fishing_areas.csv` | area_id, zone_id | Each seed area's parent zone, from a Classic Era 1.15.9 AreaTable export (wago.tools); a subzone without its own base level uses its zone's |
| `classic_fishing_skill.csv` | area_id, base | The area's base fishing level (negative for starter zones). Guides for Forever and Classic agree that fish stop getting away at **base + 95** (Durotar −70 → 25, Stranglethorn 130 → 225) [INFER, guide-consistent] |

- **Lookup:** by AreaTable ID. Subzones without rows use their zone. Names aren't stored: the addon resolves them in game with `C_Map.GetAreaInfo(areaID)`.
- **Regenerate:** `uv run --no-project python tools/fishing_seed.py` writes `addons/StraightHook/Data/Seed.lua`.

## Source and licence
- Derived from **CMaNGOS classic-db** (GPL-3.0), commit `e4825cf48176edff313d78de66b0beb14371c8eb`, `Full_DB/ClassicDB_1_12_1_z2815.sql.gz`.
  - Tables used: `fishing_loot_template` and `reference_loot_template` (flattened per area), `skill_fishing_base_level`, `conditions` 322/323.
  - Project: https://github.com/cmangos/classic-db
  - Its README: "Classic-DB is released under the GPL v3"; it also notes that World of Warcraft content is Blizzard's copyright.
- **Area-to-zone parents** (to flatten subzones) came from a Classic Era 1.15.9 AreaTable export (wago.tools). Only IDs are kept here.
- **Accuracy:** chances are the emulator's reconstruction of 1.12, not Blizzard data; the tiny ones (0.01 %) are estimates. Collected 2026-11-17.
- **Wowhead was not used.** Its robots.txt disallows our crawler.
