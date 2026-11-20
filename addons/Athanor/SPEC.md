# Athanor: spec (0.1.0, 2026-11-20)

> The athanor is the alchemist's furnace: even, patient heat, fed cheaply, that carries the work to completion. Athanor feeds a profession the cheapest fuel that still raises it.

## Problem
Levelling a profession on Forever means guessing:
- which recipe to craft at each skill point;
- how many crafts the next points will take as recipes go yellow and green;
- whether to buy materials or disenchant fodder;
- which house sells them cheaper.

Levelling guides list one route with fixed shopping lists, priced for some other server's economy. The owner is levelling Enchanting now, buying cheap AH greens as disenchant fodder, by feel.

We already hold what a guide lacks:
- **Live prices at both houses:** the AH archive (`wowf-ah-analysis`).
- **Forever's own game tables:** every recipe with its reagents and skill thresholds (DB2 via wago.tools).
- **An exit-value model:** for any item, the best of disenchant, AH resale and vendor (Wuwei D-052, `transform.Valuer`).

**Athanor** turns these into a **cheapest expected-cost route** from your current skill to your current cap. It shows the route beside the profession window: what to craft, how many times, what to buy and where, and what it will cost.

## Scope
- **In (v0.1):**
  - **Crafting professions:** Enchanting (first), Tailoring, Alchemy, Blacksmithing, Leatherworking, Engineering.
  - **Mining:** smelting is a craft and raises Mining.
  - **Secondaries:** Cooking and First Aid.
  - **Owner choices (2026-11-20):** buy at both houses; value outputs at their best exit (disenchant, AH net of cut with a flooding haircut, or vendor); show the route in a panel docked to the profession window.
- **Out:**
  - Gathering (Herbalism, Skinning, Mining by node) and Fishing: they level by routes, not by gold.
  - Auto-crafting, crafting queues and any protected call: crafting stays your click in Blizzard's UI.
  - An AH shopping panel and tooltip lines (owner chose the profession panel only; Wuwei's tooltip already shows prices).
  - Trainer gold costs: the game tables don't carry them; they're a known constant per tier.

## Design principles
1. **The pipeline prices, the addon plans.** Pricing (AH depth, vendor reagents, disenchant fodder, exit values) needs the archive, so it lives in the pipeline. The *route* depends on your current skill and which recipes you know, which only the client knows. So the addon runs one small, deterministic planner over pipeline numbers (D-001). Wuwei's "no in-game modelling" rule is relaxed here, and only this far.
2. **Expected cost, not a script.** Each skill point costs (net cost of one craft) / (chance that craft gives a point). The route is whichever recipe minimises that at each point, so it follows prices as they move instead of a guide's fixed list.
3. **Show what the number is.** Every figure shows its house and how old its prices are. A guess (yellow and green chances, thin AH depth) is labelled as one.
4. **Quiet.** Athanor appears only with the profession window. No chat spam, no sounds.

## Secret-value viability (build 1.60.1.70959, tools/wowapi.py)
None of the needed data is secret. Professions are a "crafting" archetype: ✅ High in reference/secret-values.md.

| Data needed | API | Secrecy flags | Display-only OK? | Mitigation |
|---|---|---|---|---|
| Professions you have | `GetProfessions()`, `GetProfessionInfo(index)` (C globals, in GlobalAPI.lua; the Camelot ProfessionsFrame calls `GetProfessions` itself) | none documented | n/a | `C_TradeSkillUI.GetProfessionInfoBySkillLineID` as the documented path |
| Skill and cap of the open profession | `C_TradeSkillUI.GetBaseProfessionInfo()`, `GetChildProfessionInfo()` → `ProfessionInfo.skillLevel`, `maxSkillLevel`, `skillModifier` | none (no SecretReturns) | n/a | — |
| Recipes known | `C_TradeSkillUI.GetAllRecipeIDs()` (undocumented, in GlobalAPI.lua, P-009); `GetRecipeInfo(id)` → `learned`, `relativeDifficulty`, `maxTrivialLevel`, `numSkillUps`, `canSkillUp` | SecretArguments=AllowedWhenUntainted (default) | n/a | Blizzard's own list uses `GetFilteredRecipeIDs` (Blizzard_Professions.lua:847); fall back to it if `GetAllRecipeIDs` is missing [TODO-INGAME] |
| Reagents per recipe | `C_TradeSkillUI.GetRecipeSchematic(id, false)` | default | n/a | The pipeline ladder carries reagents too; the client is a cross-check |
| Bag and bank counts | `C_Item.GetItemCount(id, true)` | default | n/a | — |
| Open a recipe in the window | `C_TradeSkillUI.OpenRecipe(id)` | default, no HasRestrictions | n/a | — |
| Trainer learn levels and costs | `GetNumTrainerServices`, `GetTrainerServiceInfo(i)`, `GetTrainerServiceSkillReq(i)`, `GetTrainerServiceCost(i)`; events `TRAINER_SHOW`, `TRAINER_UPDATE` | none | n/a | — |
| What vendors really sell | `GetMerchantNumItems`, `GetMerchantItemID(i)`, `C_MerchantFrame.GetItemInfo(i)` → `price`, `stackCount`, `numAvailable`, `hasExtendedCost`; events `MERCHANT_SHOW`, `MERCHANT_UPDATE` | none | n/a | limited stock and extended-cost items are ignored |
| Craft outcomes (skill-up rate fit) | `TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)`; `UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)` via `RegisterUnitEvent(…, "player")` | UNIT_SPELLCAST_SUCCEEDED: **SecretWhenUnitSpellCastRestricted** | logged only, never displayed | `issecretvalue(unit)`/`(spellID)` tested before any comparison (P-017); a secret cast is dropped |
| Profession window open/close and updates | events `TRADE_SKILL_SHOW`, `TRADE_SKILL_CLOSE`, `TRADE_SKILL_LIST_UPDATE` (UniqueEvent), `SKILL_LINES_CHANGED`; `ProfessionsFrame` OnShow/OnHide hooks | none | n/a | `Blizzard_Professions` is LoadOnDemand: hook via `EventUtil.ContinueOnAddOnLoaded("Blizzard_Professions", …)` |

## Forever-specific considerations (reference/forever-vs-mainline.md)
- The profession window is the Mainline `ProfessionsFrame` with a Camelot override:
  - `Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.lua` sets `professionsFrameWidthOverride = 750`;
  - it builds the right-hand tabs from `GetProfessions()`;
  - the Camelot XML replaces the family XML (`ExcludeLoadGameType camelot`).
- There is no `ProfessionsBookFrame`.
- Athanor anchors its panel to `ProfessionsFrame`'s right edge and writes no Blizzard frame state (no taint into the crafting page).
- Recipe colours come from DB2 `SkillLineAbility` thresholds (reference/professions.md). The yellow/green skill-up chance is the classic prior (grey − s)/(grey − yellow) until the craft log calibrates it (D-004) [TODO-INGAME].

## UX
A panel docked to the right of `ProfessionsFrame`, shown while it is open, for the profession on screen:

```
 Athanor · Enchanting 112 / 150                         prices 3h old
 To 150: ~41 crafts · ~1g 85s expected                     (both houses)
 ───────────────────────────────────────────────────────────────────────
 ■ 112→125  Enchant Bracer - Minor Stamina   ×16  9s/pt   [Open]
            buy 16 Strange Dust (Horde 7s)  · have 4
 ■ 125→140  Lesser Mystic Wand               ×19  12s/pt  [Open]
            buy 19 Lesser Magic Essence (BW 21s) · or DE 9 greens …
 ■ 140→150  Enchant Bracer - Lesser Stamina  ×12  15s/pt  [Learn]
 ───────────────────────────────────────────────────────────────────────
 Next trainer tier at 150 (Expert, level 35)
```

- **Steps:** consecutive skill points with the same best recipe, merged. Each step shows:
  - its colour (orange, yellow, green);
  - the expected crafts;
  - the expected cost per skill point;
  - the shopping line: reagents short of your bags, with the cheapest source and house.
- **Buttons:** **Open** selects the recipe in Blizzard's window (`OpenRecipe`). An unlearned trainer recipe says **Learn** (visit a trainer) and is planned only when `includeTrainer` is on (default on).
- **Slash:**
  - `/athanor`: toggle the panel;
  - `/athanor target N`: plan to skill N instead of the cap;
  - `/athanor house both|horde|blackwater`: which houses to buy from;
  - `/athanor trainer on|off`: plan with unlearned trainer recipes;
  - `/athanor debug`: prints the route's first 12 steps to chat.
- **Learn markers:** `learn at trainer` when a trainer visit recorded the learn skill; `learn at trainer (~level)` when it is estimated (D-003).
- **Disenchant steps** name a cheap fodder item to buy instead of a reagent line.

## Data contract: `Data/Ladder.lua` (generated by `wowf-analysis export-addon`, gitignored)
Flat arrays keep the file small (~630 KB) and fast to load.
```lua
ns.LADDER = {
  generated = "…Z", build = "1.60.1.70959", houses = { 114, 117 },
  prices = { [114] = "…Z", [117] = "…Z" },                -- snapshot time per house
  professions = { [333] = "Enchanting", … },
  de = { [114] = { cum, net, item, skill, … }, … },        -- Disenchant: cumulative fodder count, net copper per cast, item, DE skill
  recipes = {
    [7418] = { p = 333, n = "Enchant Bracer - Inferior Stamina", y = 20, g = 22, gr = 25,  -- yellow / green / grey
               s = "auto" | "trainer" | "item", l = 1,     -- source; l = learn skill when known (item recipes: RequiredSkillRank)
               o = itemID, q = 1,                          -- output and quantity; nil for enchants
               r = { item, qty, item, qty, … },            -- reagents
               t = { "Runed Copper Rod" } },               -- tools
  },
  items = {
    [10940] = { n = "Strange Dust", v = 0,                 -- v: vendor buy price (vendor items are never priced from the AH)
                vs = 0,                                    -- vendor sell price
                [114] = { cum, price, … },                 -- AH depth ladder (cumulative units, unit price)
                f114 = { cum, effPrice, fodderItem, skill, … },  -- buy-and-disenchant ladder
                a114 = 0, c114 = 0,                        -- AH exit: net of cut × 0.85, absorbs c units (3 days of sales)
                d114 = 0 },                                -- disenchant value per unit; absent for no-disenchant items
  },
}
```
All money is integer copper. A missing key means not available there.

## Data model (SavedVariables `AthanorDB`)
`{ version = 1, shown, includeTrainer, house = "both"|114|117, target = { [prof] = N }, trainer = { [spell] = { skill, cost, level, at } }, trainerSeen = { [prof] = skill }, vendor = { [item] = copper }, log = { "time spell skillBefore skillAfter", … } }` (log capped at 5000 lines).

## Open questions / in-game verification
- [ ] [TODO-INGAME] The panel appears beside the profession window, follows tab switches (Enchanting ↔ Tailoring), and hides with it.
- [ ] [TODO-INGAME] `GetAllRecipeIDs()` returns the open profession's recipes (learned and unlearned); `learned` is right.
- [ ] [TODO-INGAME] Enchanting's skill reads from the child line (2940) or the base (333); the header matches the window.
- [ ] [TODO-INGAME] Colours in the panel match the recipe list's colours at your skill (DB2 thresholds hold on Forever).
- [ ] [TODO-INGAME] A trainer visit fills `AthanorDB.trainer` (`/dump AthanorDB.trainerSeen`) and the markers switch from `~level` to exact.
- [ ] [TODO-INGAME] A reagent vendor visit fills `AthanorDB.vendor` with the reagents it sells.
- [ ] [TODO-INGAME] Crafting appends one log line per craft; Create All logs each craft.
- [ ] [TODO-INGAME] Disenchant at skill < 20 gives points (orange) and the DE skill gate on fodder (DB2 says 0; classic bands applied).
- [ ] [TODO-RESEARCH] Fit the yellow/green rate from the craft log after ~200 crafts (D-004).

## Decisions
- D-001 (2026-11-20): **Planner in the addon, prices in the pipeline.** The route depends on your skill and known recipes, which only the client knows, and changes at every skill-up. Exporting your recipe list to the pipeline and back would make the plan a /reload behind. The planner is a per-skill-point argmin over at most a few hundred recipes: deterministic, testable offline, cheap. All pricing judgement (depth, vendor reagents, fodder, exit haircuts) stays in the pipeline.
- D-002 (2026-11-20): **Score and route.** For each skill point the planner picks the eligible recipe minimising expected cost per point: cost / P for a cost, the cost itself for a profit (a profit is earned per craft, not per point, so it isn't divided by P), ties to the higher P. Consecutive points with the same winner merge into one step. P = 1 at orange, (grey − s)/(grey − yellow) at yellow/green, 0 at grey. Reagent prices depend on the quantity bought, so the planner runs twice: the second pass prices each reagent at the quantity the first pass planned. Buying walks one combined order book, cheapest first: each house's AH listings plus, for an enchanter, buy-and-disenchant fodder whose DE skill gate you meet. Vendor-sold reagents are always priced at the vendor (a listed Copper Rod on the AH is a trap).
- D-003 (2026-11-20): **Learn levels.** DB2 doesn't carry trainer learn levels, and recipes with no teaching item can't be told apart from quest or drop recipes. A trainer visit records each service's learn skill and cost (exact: `learn`). Until then, the estimate is yellow − (grey − yellow), floored at 1 (`learn~`). A scanned trainer that listed recipes up to skill S and didn't list a recipe estimated ≤ S rules that recipe out. Without a visit, high-end routes may name drop patterns (e.g. late Tailoring); visit a trainer once per tier.
- D-004 (2026-11-20): **Craft log.** One line per successful craft: time, spell, skill before and after. It is never shown in game; the pipeline fits the real yellow/green skill-up rate from it later. The cast event can carry secrets, so it is tested with issecretvalue first.
- D-005 (2026-11-20): **Exits are demand-capped.** A levelling run makes far more of an output than the AH buys. Each house's AH exit (net of cut × 0.85) covers at most three days of that item's sales. The rest is valued at the floor: disenchant (enchanters only; no-disenchant items such as the enchanting wands have none, ItemSparse Flags_0 & 0x8000) or vendor. Before this, levelling routes showed impossible profits from flooding thin markets.
