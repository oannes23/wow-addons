# Forever vs Mainline (Midnight) vs Classic Era: gameplay-system deltas that affect addons

Source: comments and code in `Camelot/` override folders, build 70790 [SRC]. Full file list: `uv run --no-project python tools/wowapi.py overrides` (cached at `reference/generated/camelot-overrides.md`).

## Matrix

| System | Forever (Camelot) | Mainline 12.x | Classic Era 1.15 | Source |
|---|---|---|---|---|
| API surface | Mainline 12.1.5 `C_*` | same | old globals | [SRC] |
| Secret values / disarmament | **Yes** | Yes | No | [SRC] |
| Specializations | **None** ("Camelot has no specs") | Yes | No | `Blizzard_PersonalResourceDisplay/Camelot` |
| Talents | Mainline talent-tree UI reskinned. "Legacy adventure tree" ranks lower the talent unlock level. `TraitConfigType.CamelotCombat`. | Class/hero trees | 1-point-per-level trees | `Blizzard_PlayerSpells/Camelot`, `Blizzard_MicroMenu/Camelot` |
| Spell ranks | **Yes** (action bar highlights only the highest rank, spell flyouts account for ranks) | No | Yes | `Blizzard_ActionBar/Camelot` |
| Combo points | **Stored on the target**, so the bar follows target changes | On player | On target | `Blizzard_UnitFrame/Camelot/TargetBoundComboPointBar.lua` |
| Achievements | Surfaced as **"Legacy Challenges"** (`Blizzard_LegacySystem`) | Achievements | None | `Blizzard_AchievementUI/Camelot` |
| Professions | `ProfessionsFrame` (Mainline-style). **No `ProfessionsBookFrame`.** | Both | Old tradeskill UI | `Blizzard_MicroMenu/Camelot` |
| Group finder | **Vanilla-style group finder** (`Blizzard_GroupFinder_VanillaStyle`), not PVEFrame | PVEFrame/LFG | LFG tool (era) | `Blizzard_QueueStatusFrame/Camelot` |
| PvP | Old **PvP rank** system (`honorLevel` field = rank). No pvpUI. No prestige. | Honor levels, rated | Ranks | `Blizzard_PVPMatch/Camelot`, `PVPRankFrame.lua` |
| Extra action button | **None** | Yes | No | `Blizzard_ActionBar/Camelot` |
| Pet battles | **None** | Yes | No | `Blizzard_ChatFrame/Camelot` |
| Quest log map | No tabs. Events and map legend hidden. Quest type is text-only (no icon). | Tabs | Old log | `Blizzard_UIPanels_Game/Camelot`, `Blizzard_FrameXMLUtil/Camelot` |
| Item qualities | No Artifact/Heirloom | All | No heirloom | `Blizzard_Settings_Shared/Camelot` |
| Edit Mode | **Yes**, with Camelot presets | Yes | No | `Blizzard_EditMode/Camelot` |
| Damage meter / Cooldown Manager | Built in | Built in | No | [SRC] |
| Experience preset | `ForeverExperiencePreset`: Classic / Enhanced | — | — | GameRules docs |
| Housing, Delves, Plunderstorm code | Present in the tree but probably not loaded/used. **Don't target these.** | Yes | No | [INFER] |

## Implications

- Code assuming `C_SpecializationInfo.GetSpecialization()` (the deprecated global `GetSpecialization` shim is NOT loaded on Forever: `Blizzard_DeprecatedSpecialization` is gated `classic, standard`) returns something meaningful will break. Feature-detect and handle nil/0. [verify in-game]
- Spell-ID-keyed data (aura lists, cooldown tables) must handle **multiple ranks per spell**. Key by spell *name* or base spell (`C_Spell.GetBaseSpell`), or carry rank tables.
- UI that anchors to Blizzard frames: confirm the frame exists in Forever (`rg -n "FrameName" reference/upstream/...`). The Camelot art is sized differently (NineSlice overrides), so offsets copied from Retail addons will drift.
