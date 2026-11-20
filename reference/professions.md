# Professions on Forever: skill-up mechanics, data sources, traps

Build 1.60.1.70959. This page was researched on 2026-11-20 for Athanor (`addons/Athanor/SPEC.md`).
- `U` = `reference/upstream/wow-ui-source/Interface/AddOns`.
- DB2 tables come from the wago.tools CSV exports for product `wowf` (`wowf-ah-analysis/src/wowf_analysis/db2.py`).

## Forever's ladders are not Classic's [DB2]
Enchanting was reworked. A Classic levelling guide is wrong here.
- **New starter recipes:**
  - Dust to Motes: 1 Strange Dust makes 3 Mote of Magic.
  - Novice's Practice Wand.
  - Enchanted Lute.
- **Spell 7418 changed.** Classic "Enchant Bracer - Minor Health" is now **Enchant Bracer - Inferior Stamina**: yellow 20, grey 25, reagent 1 Mote of Magic.
- **Moved thresholds:** Lesser Magic Wand is 75/115 (Classic 70/110); Runed Silver Rod goes yellow at 130.
- **New mid and high-end recipes:** staves, orbs, librams/idols/totems, necklace enchants, Arcane Salvager, Arcane Forge.

Rule: derive routes from the DB2 tables. Use community routes only as a sanity baseline.

## Recipe colours [DB2/INFER; flips TODO-INGAME]
| Colour | Range | Source |
|---|---|---|
| orange | learn level → yellow | learn level: see below |
| yellow | `SkillLineAbility.TrivialSkillLineRankLow` | [DB2] |
| green | yellow + ⌊(grey − yellow) / 2⌋ | [INFER]; reproduces Classic values, e.g. Runed Copper Rod 5/7/10 |
| grey | `TrivialSkillLineRankHigh` (= `TradeSkillRecipeInfo.maxTrivialLevel`) | [DB2] |

- **`MinSkillLineRank` is no learn gate.** It is 1 on all 7,858 rows. [DB2]
- **Learn levels:**
  - Item-taught recipes: the recipe item's `ItemSparse.RequiredSkillRank`. [DB2]
  - Trainer recipes: server-side, readable only at the trainer with `GetTrainerServiceSkillReq(i)`, alongside `GetTrainerServiceCost(i)` and `GetTrainerServiceLevelReq(i)`. These are C globals, called by `U/Blizzard_TrainerUI/Mainline/Blizzard_TrainerUI.lua:637,692`; Forever loads that file plus a cosmetic Camelot file. [SRC]
- **`AcquireMethod`** [INFER from row patterns]:
  - 0 = learned explicitly (trainer, recipe item or quest);
  - **1 = auto-learned with the profession** (Runed Copper Rod, Dust to Motes, Practice Wand, Bracer - Inferior Stamina, Bracer - Minor Deflect, Disenchant);
  - 2 = granted with the skill line;
  - 3 = retired.
  - Trainer and drop recipes can't be told apart this way. A recipe with a teaching item is item-taught; the rest are trainer recipes.
- **Wuwei's learn-level estimate is wrong for auto-learned recipes.** `transform.py` uses `req = lo − (hi − lo)`, which gives 40 for Bracer - Minor Deflect; it is learned at 1.
- **One skill point per success.** `NumSkillUps` is 1 on every recipe row. [DB2] The UI shows "Guaranteed chance of gaining %d skill ups" only at Optimal (`U/Blizzard_ProfessionsTemplates/Blizzard_ProfessionsRecipeList.lua:292-330`). [SRC]
- **No first-craft bonus (likely).** The Camelot recipe-list override keeps only the SkillUp, Makeable and Slots filters and drops First Craft and Sources (`U/Blizzard_ProfessionsTemplates/Camelot/Blizzard_Professions.lua:1-14`). [SRC/INFER]
- **Skill-up chance at yellow and green: no primary source.** warcraft.wiki.gg "Skill up" says the exact chances are unknown. [WIKI] The planner's prior is (grey − skill) / (grey − yellow), for yellow ≤ skill < grey. [INFER] Athanor logs your crafts so the rate can be fitted.
- **Disenchanting gives skill-ups.** Spell 13262 has yellow 20, grey 60, NumSkillUps 1. [DB2] The wiki says up to 70 (Mainline text). [WIKI] [TODO-INGAME]
- **Child skill line.**
  - Recipes point `SkillupSkillLineID` at a child line, e.g. **2940 "Enchanting"** under parent 333.
  - New rank spells (1240946/57/68/81) grant the child line.
  - Read skill with `C_TradeSkillUI.GetChildProfessionInfo()`, falling back to `GetBaseProfessionInfo()`. [DB2/INFER] [TODO-INGAME]

## Trainer tiers [NEWS warcrafttavern Forever guide; WIKI Classic_proficiency]
| Tier | Cap | Character level | Skill to train |
|---|---|---|---|
| Apprentice | 75 | 5 (1 for gathering) | — |
| Journeyman | 150 | 10 | 50 |
| Expert | 225 | 20 | 125 |
| Artisan | 300 | 35 | 200 |

- **Costs:** unverified. One unidentified source says about 10c / 1s / 50s / 5g.
- **Artisan Enchanting:** Annora in Uldaman, for both factions. [NEWS]
- **Cap and slots:** the cap is 300; two primary professions; the secondaries are Cooking, First Aid and Fishing. [NEWS]
- **Hotfixes** (worldofwarcraft.blizzard.com/news/24315281) [OFFICIAL]:
  - Coarse Grinding Stone gives skill-ups to 90.
  - Tanning Rack requires 125.
  - Arcane Salvager's tool is now Runed Golden Rod.
  - Hotfixes are server-side, so the DB2 can lag them.

## Disenchanting
- **No-disenchant flag.** `ItemSparse.Flags_0 & 0x8000` (ITEM_FLAG_NO_DISENCHANT) marks items that can't be disenchanted. The owner confirmed it in game on 2026-11-20: enchanting-made wands (Lesser/Greater Magic Wand, Lesser Mystic Wand) can't be disenchanted, and all three carry the flag. [INGAME + DB2] 2,053 green+ items carry it: the wands, PvP rank gear, some quest rewards. `transform.Valuer` and `skillup.de_of` honour it. Before this, Wuwei's tooltip offered "disenchant" as the wands' best use.
- **`ItemDisenchantLoot`** (client DB2) has bands by class (2 weapon, 4 armor), quality and item level (5-15, 16-20, 21-25, then 5-level steps, 61-99).
- **`SkillRequired` is 0 on every row.** [DB2] On Mainline that would mean no skill gate; on Forever it's [TODO-INGAME]. Until checked, Athanor applies the Classic bands [WIKI]:
  - item level ≤20 needs skill 1;
  - 21-25 needs 25;
  - +25 per 5 item levels after that;
  - 61+ needs 225;
  - rares of level 10-25 need 25.
- **Yields:** Wuwei's `de_table` reads `wowf-ah-collector/dim/disenchant.csv`. All 81 of its rows are Classic seeds. It disagrees with warcraft.wiki.gg's disenchanting tables (pre-BfA page) on:
  - green weapon 21-25: dust 15% 4-6, Lesser Astral 75% 1-2, shard 10%;
  - green weapon 51-65: dust 22%, shard 3%;
  - rare 56-65: 0.5% Nexus Crystal;
  - epics, which are missing entirely.

  Forever's real yields are server-side. [TODO-INGAME]

## Vendor reagents (never buy these on the AH)
| Item | Vendor price | Confidence |
|---|---|---|
| Mote of Magic | 10c | [DB2]: the item description says "Available from enchanting vendors" |
| Copper Rod | 1s24c | [WIKI] |
| Simple Wood | 38c | [WIKI] |
| Crystal Vial | 5s | [WIKI] |
| Empty Vial | 4c | [INFER] |
| Leaded Vial | 40c | [INFER] |
| Imbued Vial | 60s | [INFER] |
| Star Wood | 45s per DB2 | [TODO-INGAME] |

- `ItemSparse.BuyPrice` is per `VendorStackCount`, and Copper Rod's matches the wiki. But BuyPrice is set on non-vendor items too (dust, essences), so it does not prove an item is vendor-sold.
- Vendor stock is server-side. Athanor's merchant scan records what vendors you visit actually sell.

## Tools and enchant scrolls
- **Tools:** required tools (rods, Blacksmith Hammer, Mining Pick) live in DB2 `SpellTotems` (`RequiredTotemCategoryID_0/1`), named in `TotemCategory`.
- **Enchant scrolls:** 179 of 180 enchant recipes have an "Enchant X" scroll item (class 0/6, BoE, stack 20). None has been seen on the AH. Whether an enchant cast with no target makes a scroll is [TODO-INGAME]; it decides whether enchants have a resale exit.

## Optimiser notes (Athanor D-002)
- **Cost per skill point:** e(s) = net cost of one craft / P(s). Net cost = reagents at their cheapest source − the output's best exit.
- **Greedy per point is optimal** when a success gives one point and there are no fixed costs. Fixed costs break separability:
  - recipe purchases, trainer fees and tools;
  - level gates.

  Handle those as unlock decisions on top of the greedy plan.
- **Traps:**
  - vendor items listed on the AH;
  - thin AH depth: price the whole quantity, not one unit;
  - output flooding: haircut AH resale;
  - disenchant loops: wands disenchanted back into mats.
