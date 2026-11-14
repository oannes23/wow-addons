"""Offline harness for addons/ItemDataExport Recipes.lua (/ide recipes, /ide recipes all).

  uv run --no-project --with lupa python tools/luatest/item_data_export_recipes_test.py
Mocks C_TradeSkillUI with two professions (Tailoring, Enchanting) behind an "open window" switch. Covers: no window,
empty list (not loaded yet), full dump shape (output, reagents incl. optional slot and alternates, difficulty
observations, cooldown, enchant recipe without an output item, categories), merge across professions and across
reruns, secret / nil / erroring returns, and /ide recipes all (open, timeout path, unopenable profession).
"""
import lupa.lua51 as lua51

import item_data_export_test as base

MOCK = r"""
function GetBuildInfo() return "1.60.1", "70862", "Nov 4 2026", 16001 end
timers = {}
C_Timer.After = function(sec, fn) timers[#timers+1] = { at = now + sec, fn = fn } end
function step(dt)
  now = now + (dt or 0.1)
  local due = {}
  for i = #timers, 1, -1 do if timers[i].at <= now then due[#due+1] = table.remove(timers, i) end end
  for i = #due, 1, -1 do due[i].fn() end
end
secretValue = {}
function issecretvalue(v) return v == secretValue end
open = nil -- skill line currently open
rank = { [197] = 75, [333] = 12 }
LINES = { [197] = "Tailoring", [333] = "Enchanting" }
IDS = {
  [197] = { 2963, 2964, 5000 },   -- 2964 unlearned; 5000 has no info and no schematic (unreadable)
  [333] = { 7418, 7420 },         -- enchants: no output item
}
INFO = {
  [2963] = { name = "Bolt of Linen Cloth", categoryID = 11, learned = true, relativeDifficulty = 1, maxTrivialLevel = 50,
             numSkillUps = 1, canSkillUp = true, skillLineAbilityID = 555, hyperlink = "|Henchant:2963|h[x]|h", itemLevel = 0,
             craftable = true, someTable = { 1 }, secretField = secretValue },
  [2964] = { name = "Linen Bandage", categoryID = 12, learned = false, relativeDifficulty = 2, maxTrivialLevel = 90,
             numSkillUps = 0, canSkillUp = false, skillLineAbilityID = 556 },
  [7418] = { name = "Enchant Bracer - Minor Health", categoryID = 21, learned = true, relativeDifficulty = 0, maxTrivialLevel = 90,
             numSkillUps = 1, canSkillUp = true, skillLineAbilityID = 700, isEnchantingRecipe = true },
  [7420] = { name = "Enchant Chest - Minor Health", categoryID = 21, learned = true, relativeDifficulty = 3, maxTrivialLevel = 70,
             numSkillUps = 0, canSkillUp = false, skillLineAbilityID = 701, isEnchantingRecipe = true },
}
SCHEM = {
  [2963] = { name = "Bolt of Linen Cloth", quantityMin = 1, quantityMax = 1, outputItemID = 2996, recipeType = 0, reagentSlotSchematics = {
      { reagentType = 1, quantityRequired = 2, required = true, reagents = { { itemID = 2589 }, { itemID = 9999 } } },
      { reagentType = 0, quantityRequired = 1, required = false, reagents = { { itemID = 3000 } },
        slotInfo = { mcrSlotID = 1, requiredSkillRank = 100, slotText = "Optional" } } } },
  [2964] = { name = "Linen Bandage", quantityMin = 1, quantityMax = 3, outputItemID = 1251, recipeType = 0, reagentSlotSchematics = {
      { reagentType = 1, quantityRequired = 1, required = true, reagents = { { itemID = 2996 } } } } },
  [7418] = { name = "Enchant Bracer - Minor Health", quantityMin = 1, quantityMax = 1, recipeType = 3, reagentSlotSchematics = {
      { reagentType = 1, quantityRequired = 1, required = true, reagents = { { itemID = 10940 } } } } },
  [7420] = { name = "Enchant Chest - Minor Health", quantityMin = 1, quantityMax = 1, recipeType = 3, reagentSlotSchematics = {
      { reagentType = 1, quantityRequired = 1, required = true, reagents = { { itemID = 10940 } } },
      { reagentType = 1, quantityRequired = 1, required = true, reagents = { { currencyID = 77 } } } } },
}
CD = { [2963] = { 86400, true, 0, 0 } }
CATS = { [11] = { name = "Cloth", parentCategoryID = 1 }, [1] = { name = "Tailoring" }, [12] = { name = "Bandages", parentCategoryID = 1 },
         [21] = { name = "Bracers", parentCategoryID = 2 }, [2] = { name = "Enchanting" } }
openable = { [197] = true, [333] = true }
openCalls = {}
C_TradeSkillUI = {
  GetChildProfessionInfo = function() return { professionID = 0 } end,
  GetBaseProfessionInfo = function()
    if not open then return { professionID = 0 } end
    return { professionID = open, professionName = LINES[open], skillLevel = rank[open], maxSkillLevel = 150, skillModifier = 0 }
  end,
  GetAllRecipeIDs = function() return open and IDS[open] or {} end,
  GetFilteredRecipeIDs = function() return open and { IDS[open][1] } or {} end,
  GetRecipeInfo = function(id) return INFO[id] end,
  GetRecipeSchematic = function(id, isRecraft) assert(isRecraft == false) return SCHEM[id] end,
  GetRecipeOutputItemData = function(id) return nil end,
  GetRecipeCooldown = function(id) local c = CD[id] if c then return c[1], c[2], c[3], c[4] end return nil end,
  GetCategoryInfo = function(id) return CATS[id] end,
  GetShowUnlearned = function() return false end,
  OpenTradeSkill = function(line) openCalls[#openCalls+1] = line
    if openable[line] then open = line; return true end return false end,
}
function GetProfessions() return 1, 2, 3 end
function GetProfessionInfo(i) local lines = { 197, 333, 356 } return "n", 0, 0, 0, 0, 0, lines[i] end
function said(pat) for _, p in ipairs(printed) do if p:find(pat, 1, true) then return true end end return false end
"""


def main() -> None:
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(base.MOCK)
    rt.execute(MOCK)
    g = rt.globals()
    ns = rt.table()
    base.load(rt, ns, ["Locales/enUS.lua", "Data/Builtin.lua", "Export.lua", "Recipes.lua", "Core.lua"])
    slash = g.SlashCmdList["ITEMDATAEXPORT"]

    # 1. No window open.
    slash("recipes")
    assert g.said("no profession window open") and g.ItemDataExportDB.recipes is None

    # 2. Window open but list empty (not loaded yet).
    g.open = 197
    saved = g.IDS[197]
    g.IDS[197] = rt.eval("{}")
    g.C_TradeSkillUI.GetFilteredRecipeIDs = rt.eval("function() return {} end")
    slash("recipes")
    assert g.said("lists no recipes yet") and g.ItemDataExportDB.recipes is None
    g.IDS[197] = saved
    g.C_TradeSkillUI.GetFilteredRecipeIDs = rt.eval("function() return open and { IDS[open][1] } or {} end")

    # 3. Tailoring dump.
    slash("recipes")
    r = g.ItemDataExportDB.recipes
    assert r.build == "1.60.1" and r.buildNumber == "70862" and r.dumped == 1794200000
    p = r.professions[197]
    assert (p.name, p.rank, p.maxRank, p.recipes) == ("Tailoring", 75, 150, 2), dict(p)
    bolt = r.recipes[2963]
    assert bolt.name == "Bolt of Linen Cloth" and bolt.skillLineID == 197 and bolt.learned is True
    assert (bolt.outputItemID, bolt.outputMin, bolt.outputMax, bolt.category, bolt.abilityID) == (2996, 1, 1, 11, 555)
    assert len(bolt.reagents) == 2
    r1, r2 = bolt.reagents[1], bolt.reagents[2]
    assert (r1.itemID, r1.qty, r1.optional) == (2589, 2, None) and list(r1.alts.values()) == [9999]
    assert (r2.itemID, r2.qty, r2.optional, r2.requiredSkillRank, r2.slotText) == (3000, 1, True, 100, "Optional")
    assert (bolt.skill.trivial, bolt.skill.difficulty, bolt.skill.rank, bolt.skill.skillUps, bolt.skill.canSkillUp) == (50, 1, 75, 1, True)
    assert [(o.rank, o.difficulty) for o in bolt.skill.obs.values()] == [(75, 1)]
    assert (bolt.cooldown.remaining, bolt.cooldown.isDay, bolt.cooldown.charges) == (86400, True, 0)
    assert bolt.info.craftable is True and bolt.info.someTable is None and bolt.info.secretField is None  # scalars only, secrets dropped
    band = r.recipes[2964]
    assert band.learned is False and band.outputMax == 3 and band.cooldown is None  # unlearned is recorded
    assert r.recipes[5000] is None  # unreadable recipe skipped, not fatal
    assert g.said("Tailoring 75/150: 2 recipes (1 learned, 1 unlearned, 1 unreadable)") and g.said("/reload to write SavedVariables")
    assert r.categories[11].name == "Cloth" and r.categories[1].name == "Tailoring"  # parent chain followed

    # 4. Enchanting merges; Tailoring survives; enchant recipes have no output item; currency reagent kept.
    g.open = 333
    slash("recipes")
    r = g.ItemDataExportDB.recipes
    assert r.recipes[2963].name == "Bolt of Linen Cloth" and r.recipes[7418].skillLineID == 333
    assert r.professions[197].rank == 75 and r.professions[333].rank == 12 and r.professions[333].name == "Enchanting"
    e = r.recipes[7418]
    assert e.outputItemID is None and e.isEnchantingRecipe is True and e.reagents[1].itemID == 10940
    assert r.recipes[7420].reagents[2].currencyID == 77
    assert g.said("4 stored across 2 professions")

    # 5. Rerun at a higher rank: difficulty observations accumulate, duplicates are not repeated.
    g.open = 197
    g.rank[197] = 100
    g.INFO[2963].relativeDifficulty = 2
    slash("recipes")
    slash("recipes")
    bolt = g.ItemDataExportDB.recipes.recipes[2963]
    assert [(o.rank, o.difficulty) for o in bolt.skill.obs.values()] == [(75, 1), (100, 2)]
    assert bolt.skill.rank == 100 and bolt.skill.difficulty == 2

    # 6. Secret / erroring / nil returns do not crash.
    g.INFO[2963].name = g.secretValue
    g.INFO[2964] = rt.eval("setmetatable({}, { __index = function() error('boom') end })")
    g.SCHEM[2964] = None
    g.C_TradeSkillUI.GetRecipeCooldown = rt.eval("function() error('boom') end")
    g.C_TradeSkillUI.GetCategoryInfo = rt.eval("function() return nil end")
    slash("recipes")  # must not raise
    bolt = g.ItemDataExportDB.recipes.recipes[2963]
    assert bolt.name == "Bolt of Linen Cloth"  # secret info.name -> falls back to the schematic name
    assert bolt.cooldown is None

    # 7. /ide recipes all: opens each profession; 356 is unopenable; second run refused while running.
    g.ItemDataExportDB.recipes = None
    g.open = None
    g.openCalls = rt.eval("{}")
    g.printed = rt.eval("{}")
    g.INFO[2964] = rt.eval("{ name = 'Linen Bandage', categoryID = 12, learned = false }")
    g.SCHEM[2964] = rt.eval("{ name = 'Linen Bandage', quantityMin = 1, quantityMax = 1, outputItemID = 1251, reagentSlotSchematics = {} }")
    g.C_TradeSkillUI.GetRecipeCooldown = rt.eval("function() return nil end")
    g.C_TradeSkillUI.GetCategoryInfo = rt.eval("function(id) return CATS[id] end")
    g.INFO[2963].name = "Bolt of Linen Cloth"
    slash("recipes all")
    slash("recipes all")
    assert g.said("already running")
    g.fire("TRADE_SKILL_LIST_UPDATE")  # Tailoring dumps on the event
    g.step(3)  # Enchanting dumps on the 2 s timeout; Tailoring's pending timer is a no-op
    g.step(3)
    r = g.ItemDataExportDB.recipes
    assert list(g.openCalls.values()) == [197, 333, 356], list(g.openCalls.values())
    assert r.professions[197] is not None and r.professions[333] is not None and r.professions[356] is None
    assert g.said("356 could not be opened") and g.said("finished (2 dumped, 1 could not be opened)")

    # 8. Status line.
    slash("status")
    assert g.said("recipes: 4 stored, 2 professions")
    print("ItemDataExport recipes harness: OK")


if __name__ == "__main__":
    main()
