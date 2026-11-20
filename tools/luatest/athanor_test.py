"""Offline harness for addons/Athanor: runs the addon in Lua 5.1 (lupa) against mocked WoW APIs.

  uv run --no-project --with lupa python tools/luatest/athanor_test.py
Covers:
- planner maths: chance and colour, ladder depth costs, fodder skill filter, vendor-first pricing;
- route choice: per-point argmin, trainer gating (scanned vs estimated learn level), disenchant steps, profit
  handling, and where a route stops;
- shopping: bag counts consumed by earlier steps;
- scans: trainer, merchant, and the craft log with its secret guard;
- panel wiring;
- a smoke run on the generated Data/Ladder.lua when present.
"""
from pathlib import Path

import lupa.lua51 as lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "Athanor"
FILES = ["Locales/enUS.lua", "Planner.lua", "Scan.lua", "Core.lua", "Panel.lua"]

MOCK = r"""
format = string.format
printed = {}
function print(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring(select(i, ...)) end printed[#printed+1] = table.concat(t, " ") end
serverTime = 1795161600 -- 2026-11-20T08:00:00Z
function GetServerTime() return serverTime end
function time() return serverTime end
SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
secretChecks = 0  -- the client errors on comparing a secret; a table can't, so count the checks instead
function issecretvalue(v) secretChecks = secretChecks + 1 return v == SECRET end
loadedCallbacks = {}
selfLoaded = {}  -- our ADDON_LOADED fires after every file of the addon has run (as in the client)
EventUtil = { ContinueOnAddOnLoaded = function(name, fn)
  if name == "Blizzard_Professions" then loadedCallbacks[#loadedCallbacks+1] = fn else selfLoaded[#selfLoaded+1] = fn end end }
function fireSelfLoaded() for _, fn in ipairs(selfLoaded) do fn() end selfLoaded = {} end
bags = {}
C_Item = { GetItemCount = function(id) return bags[id] or 0 end, GetItemNameByID = function() return nil end }
-- profession state
prof = { child = { professionID = 2940, parentProfessionID = 333, skillLevel = 12, maxSkillLevel = 75 },
         base = { professionID = 333, skillLevel = 12, maxSkillLevel = 75 } }
recipes = {}  -- [id] = { learned = bool }
opened = nil
C_TradeSkillUI = {
  GetChildProfessionInfo = function() return prof.child end,
  GetBaseProfessionInfo = function() return prof.base end,
  GetAllRecipeIDs = function() local t = {} for id in pairs(recipes) do t[#t+1] = id end table.sort(t) return t end,
  GetRecipeInfo = function(id) return recipes[id] end,
  OpenRecipe = function(id) opened = id end,
}
professionList = { 1, nil, nil, nil, nil }
function GetProfessions() return 1, nil end
function GetProfessionInfo(i) if i == 1 then return "Enchanting", 1, prof.base.skillLevel, 75, 0, 0, 333 end end
trainer = {}
function GetNumTrainerServices() return #trainer end
function GetTrainerServiceInfo(i) local t = trainer[i] return t.name, "available", nil, t.level end
function GetTrainerServiceSkillReq(i) local t = trainer[i] return t.skill, t.rank, true end
function GetTrainerServiceCost(i) return trainer[i].cost, true end
merchant = {}
function GetMerchantNumItems() return #merchant end
function GetMerchantItemID(i) return merchant[i].id end
C_MerchantFrame = { GetItemInfo = function(i) return merchant[i].info end }
-- Frames
local function Region() local r = { text = "" } function r:SetText(t) self.text = t end
  setmetatable(r, { __index = function() return function() end end }) return r end
function CreateFrame(kind, name)
  local f = { ev = {}, shown = true, scripts = {}, hooks = {} }
  function f:RegisterEvent(e) self.ev[e] = true end
  function f:RegisterUnitEvent(e, u) self.ev[e] = u end
  function f:SetScript(n, fn) self.scripts[n] = fn end
  function f:HookScript(n, fn) self.hooks[n] = fn end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:SetShown(v) self.shown = v and true or false end
  function f:CreateTexture() return Region() end
  function f:CreateFontString() return Region() end
  function f:SetText(t) self.label = t end
  setmetatable(f, { __index = function() return function() end end })
  frames = frames or {}
  frames[#frames+1] = f
  return f
end
UIParent = CreateFrame()
ProfessionsFrame = CreateFrame()
ProfessionsFrame.shown = false
SlashCmdList = {}
"""

# A tiny ladder: Enchanting 333 (rod, two bracers, a trainer chest, disenchant), Tailoring 197 (one recipe).
LADDER = r"""
local _, ns = ...
ns.LADDER = {
  generated = "g", build = "1.60.1.70959", houses = { 114, 117 },
  prices = { [114] = "2026-11-20T05:00:00Z", [117] = "2026-11-19T08:00:00Z" },
  professions = { [333] = "Enchanting", [197] = "Tailoring" },
  de = { [114] = { 3, 500, 900, 1, 5, 800, 901, 25 }, [117] = { 1, 50, 902, 100 } },
  recipes = {
    [7421] = { p = 333, n = "Runed Copper Rod", y = 5, g = 7, gr = 10, s = "auto", l = 1, o = 6218, q = 1, r = { 6217, 1, 247786, 1 } },
    [7418] = { p = 333, n = "Enchant Bracer - Inferior Stamina", y = 20, g = 22, gr = 25, s = "auto", l = 1, r = { 247786, 1 }, t = { "Runed Copper Rod" } },
    [7420] = { p = 333, n = "Enchant Chest - Inferior Stamina", y = 70, g = 90, gr = 110, s = "trainer", r = { 10940, 1 }, t = { "Runed Copper Rod" } },
    [7428] = { p = 333, n = "Enchant Bracer - Minor Deflect", y = 80, g = 100, gr = 120, s = "auto", l = 1, r = { 10938, 1 } },
    [9999] = { p = 333, n = "Pattern Thing", y = 30, g = 40, gr = 50, s = "item", l = 20, r = { 10940, 1 } },
    [13262] = { p = 333, n = "Disenchant", y = 20, g = 40, gr = 60, s = "auto", l = 1 },
    [2387] = { p = 197, n = "Linen Cloak", y = 15, g = 22, gr = 30, s = "trainer", o = 2569, q = 1, r = { 2996, 1, 2320, 1 } },
  },
  items = {
    [6217] = { n = "Copper Rod", v = 124, [114] = { 1, 60 } },        -- vendor item also on the AH: never buy it there
    [247786] = { n = "Mote of Magic", v = 10 },
    [6218] = { n = "Runed Copper Rod", vs = 25, a114 = 30, c114 = 50 },
    [10940] = { n = "Strange Dust", [114] = { 1, 98, 10, 100, 50, 130 }, [117] = { 1, 240, 100, 250 }, f114 = { 5, 60, 4246, 1, 40, 70, 2584, 25 } },
    [10938] = { n = "Lesser Magic Essence", [114] = { 1, 144, 200, 150 } },
    [2996] = { n = "Bolt of Linen Cloth", [114] = { 1, 30, 100, 40 } },
    [2320] = { n = "Coarse Thread", v = 10 },
    [2569] = { n = "Linen Cloak", vs = 20, a114 = 50, c114 = 100, a117 = 90, c117 = 3, d114 = 35 },
  },
}
"""


def boot(with_ladder=True):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    g = rt.globals()
    ns = rt.table()
    if with_ladder:
        rt.execute("return loadstring(...)", LADDER, "@Ladder.lua")("Athanor", ns)
    for f in FILES:
        src = (ROOT / f).read_text(encoding="utf-8")
        rt.execute("return loadstring(...)", src, "@" + f)("Athanor", ns)
    g.fireSelfLoaded()
    return rt, ns, g


def ctx(rt, **kw):
    base = {"houses": rt.table(114, 117), "learned": rt.table(), "trainer": rt.table(), "vendor": rt.table(),
            "includeTrainer": True}
    base.update(kw)
    return rt.table_from(base)


def steps_of(rt, ns, c, prof, a, b):
    steps, totals = ns.Planner.Plan(c, prof, a, b)
    out = []
    for i in range(1, len(steps) + 1):
        st = steps[i]
        out.append((st.r.n, st.__getitem__("from"), st.to, st.colour, st.how, round(st.crafts, 3), round(st.cost, 2)))
    return out, totals


def test_chance_colour_and_learn_estimate():
    rt, ns, g = boot()
    P = ns.Planner
    r = rt.table_from({"y": 70, "g": 90, "gr": 110})
    assert P.Chance(r, 69) == 1 and P.Chance(r, 70) == 1 and abs(P.Chance(r, 90) - 0.5) < 1e-9 and P.Chance(r, 110) == 0
    assert [P.Colour(r, s) for s in (69, 70, 89, 90, 110)] == ["orange", "yellow", "yellow", "green", "grey"]
    assert P.EstLearn(r) == 30 and P.EstLearn(rt.table_from({"y": 5, "g": 7, "gr": 10})) == 1


def test_ladder_cost_and_filter4():
    rt, ns, g = boot()
    P = ns.Planner
    lad = rt.table(1, 98, 10, 100, 50, 130)
    assert P.LadderCost(lad, 1) == (98, False)
    assert P.LadderCost(lad, 10) == (98 + 900, False)
    assert P.LadderCost(lad, 60) == (98 + 900 + 40 * 130 + 10 * 130, True)  # past depth: dearest price, flagged
    flat = rt.table(5, 60, 4246, 1, 40, 70, 2584, 25)
    l1, first = P.Filter4(flat, 1)
    assert list(l1.values()) == [5, 60] and first == 4246
    l2, first2 = P.Filter4(flat, 25)
    assert list(l2.values()) == [5, 60, 40, 70] and first2 == 4246
    l3, first3 = P.Filter4(rt.table(5, 60, 4246, 30), 1)
    assert len(l3) == 0 and first3 is None


def test_unit_price_vendor_first_then_cheapest_house_and_fodder():
    rt, ns, g = boot()
    P = ns.Planner
    c = ctx(rt)
    assert P.UnitPrice(c, 6217, 5)[:2] == (124, "vendor")  # AH lists it at 60c: still the vendor (trap, D-002)
    unit, src, house = P.UnitPrice(c, 10940, 1)[:3]
    assert (unit, src, house) == (98, "ah", 114)
    # an enchanter: fodder at 60c per dust beats the AH; skill gates the second fodder row
    c2 = ctx(rt, deSkill=1)
    assert P.UnitPrice(c2, 10940, 5)[:4] == (60, "de", 114, 4246)
    # 20 dust: the 5 fodder dust at 60c, then the AH book (98, 9x100, 5x130): one combined book, cheapest first
    unit, src, house, via, short = P.UnitPrice(c2, 10940, 20)
    assert unit == (5 * 60 + 98 + 9 * 100 + 5 * 130) / 20 and src == "ah" and house == 114 and not short
    # deeper than every book together (5 fodder + 50 Horde + 100 Blackwater): the rest at the dearest point, flagged
    unit, src, house, via, short = P.UnitPrice(c2, 10940, 200)
    assert short and src == "ah" and house == 117
    # merchant scan overrides: a vendor seen selling Strange Dust (it doesn't in reality; contract test)
    c3 = ctx(rt, vendor=rt.table_from({10940: 77}))
    assert P.UnitPrice(c3, 10940, 1)[:2] == (77, "vendor")
    # one house only
    c4 = ctx(rt, houses=rt.table(117))
    assert P.UnitPrice(c4, 10940, 1)[:3] == (240, "ah", 117)
    assert P.UnitPrice(c, 424242, 1) is None


def test_craft_cost_exit_and_disenchant():
    rt, ns, g = boot()
    P, Ld = ns.Planner, ns.LADDER
    c = ctx(rt)
    # rod: Copper Rod 124 (vendor) + Mote 10 (vendor) - exit 30 (x114)
    assert P.CraftCost(c, 7421, Ld.recipes[7421], 1) == 104
    # cloak: bolt 30 + thread 10 - best exit across houses (90 at 117)
    assert P.CraftCost(c, 2387, Ld.recipes[2387], 1) == -50
    assert P.CraftCost(c, 13262, Ld.recipes[13262], 1) is None  # not an enchanter
    c2 = ctx(rt, deSkill=1)
    assert P.CraftCost(c2, 13262, Ld.recipes[13262], 3) == 500  # 3 x 500 at Horde (skill-1 rows only)
    c3 = ctx(rt, deSkill=100)
    assert P.CraftCost(c3, 13262, Ld.recipes[13262], 1) == 50  # the Blackwater 100-skill row
    assert P.CraftCost(c, 7428, Ld.recipes[7428], 1) == 144


def test_plan_route_switches_and_gates():
    rt, ns, g = boot()
    c = ctx(rt)
    out, totals = steps_of(rt, ns, c, 333, 1, 25)
    # 1-9: the rod (orange to 5, then yellow), 10-24: the bracer (orange until 20, then yellow to grey 25)
    names = [(n, a, b, col) for n, a, b, col, *_ in out]
    assert names[0][0] == "Enchant Bracer - Inferior Stamina" or names[0][0] == "Runed Copper Rod", out
    assert all(s[0] != "Pattern Thing" for s in out)  # item-taught and not learned: never planned
    assert totals.reached == 25
    # costs: bracer is 10c per point while orange; rod is 104c per craft: the bracer wins everywhere it's not grey
    assert out[0][:4] == ("Enchant Bracer - Inferior Stamina", 1, 25, "orange")
    crafts = 19 + sum(1 / ((25 - s) / 5) for s in range(20, 25))
    assert abs(out[0][5] - round(crafts, 3)) < 1e-3


def test_plan_trainer_learn_level_and_known():
    rt, ns, g = boot()
    c = ctx(rt)
    out, totals = steps_of(rt, ns, c, 333, 60, 75)
    # 60-69: the chest is estimated learnable at 30 (70 - 40): learn~; Minor Deflect (auto) costs 144 vs dust 98
    assert out[0][0] == "Enchant Chest - Inferior Stamina" and out[0][4] == "learn~", out
    # a trainer visit recorded learn level 65: 60-64 has nothing else (Minor Deflect is auto: it takes over)
    c2 = ctx(rt, trainer=rt.table_from({7420: rt.table_from({"skill": 65})}))
    out2, _ = steps_of(rt, ns, c2, 333, 60, 75)
    assert out2[0][:3] == ("Enchant Bracer - Minor Deflect", 60, 65) and out2[1][0] == "Enchant Chest - Inferior Stamina"
    assert out2[1][4] == "learn"
    # known recipes say "known"; trainer recipes off -> only known/auto
    c3 = ctx(rt, includeTrainer=False, learned=rt.table_from({7420: True}))
    out3, _ = steps_of(rt, ns, c3, 333, 60, 75)
    assert out3[0][0] == "Enchant Chest - Inferior Stamina" and out3[0][4] == "known"
    c4 = ctx(rt, includeTrainer=False)
    out4, _ = steps_of(rt, ns, c4, 333, 60, 75)
    assert out4[0][0] == "Enchant Bracer - Minor Deflect"


def test_plan_disenchant_and_stop():
    rt, ns, g = boot()
    # skill 30: the cheap disenchants (Horde rows, 5s-8s) lose to Minor Deflect (auto, orange to 80, 1s44c)
    out, _ = steps_of(rt, ns, ctx(rt, deSkill=30), 333, 25, 60)
    assert out[0][0] == "Enchant Bracer - Minor Deflect", out
    # skill 100 unlocks the Blackwater fodder at 50c per disenchant: Disenchant leads until its falling chance makes
    # 50c / P dearer than the chest at orange on fodder dust (~69c): 50 / ((60 - 31) / 40) = 69.0
    out2, _ = steps_of(rt, ns, ctx(rt, deSkill=100), 333, 25, 60)
    assert out2[0][:4] == ("Disenchant", 25, 31, "yellow") and out2[0][4] == "known", out2
    assert out2[1][0] == "Enchant Chest - Inferior Stamina" and out2[1][2] == 60
    # nothing craftable: Tailoring past Linen Cloak's grey (30) -> no steps, reached stays at the start
    out3, totals3 = steps_of(rt, ns, ctx(rt), 197, 30, 40)
    assert out3 == [] and totals3.reached == 30


def test_profit_counts_once_and_prefers_fewer_crafts():
    rt, ns, g = boot()
    c = ctx(rt)
    out, totals = steps_of(rt, ns, c, 197, 15, 30)  # Linen Cloak only: -50 per craft (profit)
    assert out[0][:2] == ("Linen Cloak", 15) and out[0][3] == "yellow"
    assert totals.cost < 0


def test_shopping_uses_bags_once():
    rt, ns, g = boot()
    c = ctx(rt)
    steps, _ = ns.Planner.Plan(c, 333, 60, 75)
    g.bags = rt.table_from({10940: 7})
    used = rt.table()
    have = rt.eval("function(id) return bags[id] or 0 end")
    first = ns.Planner.Shopping(c, steps[1], have, used)
    b = first[1]
    # 60-69 orange (10 crafts) + 70-74 yellow (40/40 + 40/39 + ... = 5.27): 15.27 crafts -> 16 dust, 7 in bags
    assert b.id == 10940 and b.need == 16 and b.buy == 9 and b.src == "ah"
    again = ns.Planner.Shopping(c, steps[1], have, used)
    assert again[1].buy == 16  # the 7 in bags were taken by the first call


def test_trainer_and_merchant_scans():
    rt, ns, g = boot()
    g.trainer = rt.eval("""{ { name = "Enchant Chest - Inferior Stamina", skill = "Enchanting", rank = 70, cost = 500, level = 12 },
                             { name = "Linen Cloak", skill = "Tailoring", rank = 15, cost = 100, level = 5 },
                             { name = "Enchant Chest - Inferior Stamina", skill = "Tailoring", rank = 1, cost = 1, level = 1 },
                             { name = "Something Else", skill = "Enchanting", rank = 1, cost = 1, level = 1 } }""")
    assert ns.Scan.Trainer() == 2
    t = ns.db.trainer
    assert t[7420].skill == 70 and t[7420].cost == 500 and t[2387].skill == 15
    g.merchant = rt.eval("""{ { id = 247786, info = { price = 10, stackCount = 1, numAvailable = -1 } },
                              { id = 2320, info = { price = 50, stackCount = 5, numAvailable = -1 } },
                              { id = 10940, info = { price = 80, stackCount = 1, numAvailable = 3 } },
                              { id = 10938, info = { price = 1, stackCount = 1, numAvailable = -1, hasExtendedCost = true } },
                              { id = 555, info = { price = 9, stackCount = 1, numAvailable = -1 } } }""")
    assert ns.Scan.Merchant() == 2
    v = ns.db.vendor
    assert v[247786] == 10 and v[2320] == 10 and v[10940] is None and v[10938] is None and v[555] is None


def test_craft_log_and_secret_guard():
    rt, ns, g = boot()
    S = ns.Scan
    S.CraftBegin(7418)
    g.prof.child.skillLevel = 13
    S.CraftSucceeded("player", 7418)
    assert list(ns.db.log.values()) == ["1795161600 7418 12 13"]
    before = g.secretChecks
    S.CraftSucceeded(g.SECRET, 7418)  # secret unit: ignored before any comparison
    assert g.secretChecks > before
    S.CraftSucceeded("player", g.SECRET)
    S.CraftSucceeded("player", 9999)  # another spell
    S.CraftSucceeded("party1", 7418)
    assert len(ns.db.log) == 1
    S.CraftSucceeded("player", 7418)  # Create All: the next cast starts from 13
    assert ns.db.log[2] == "1795161600 7418 13 13"


def test_state_and_panel():
    rt, ns, g = boot()
    g.recipes = rt.eval("{ [7418] = { learned = true }, [7420] = { learned = false } }")
    s = ns.Scan.State()
    assert s.prof == 333 and s.skill == 12 and s.max == 75 and s.learned[7418] and not s.learned[7420] and s.enchanting == 12
    # the panel appears with the profession window and hides with it
    for fn in list(g.loadedCallbacks.values()):
        fn()
    pf = g.ProfessionsFrame
    assert pf.hooks.OnShow and pf.hooks.OnHide
    pf.shown = True
    pf.hooks.OnShow()
    f = ns.Panel.frame
    assert f.shown and "Athanor · Enchanting 12 / 75" in f.h1.text, f.h1.text
    assert "To 75" in f.h2.text or "stops at" in f.h2.text, f.h2.text
    assert "Horde 3h" in f.h3.text and "Blackwater 1d" in f.h3.text, f.h3.text
    row = f.steps[1]
    assert "Enchant Bracer - Inferior Stamina" in row.a.text and "Mote of Magic" in row.b.text and "vendor" in row.b.text, (row.a.text, row.b.text)
    assert "needs Runed Copper Rod" in row.b.text
    row.button.scripts.OnClick()
    assert g.opened == 7418
    pf.hooks.OnHide()
    assert not f.shown
    # slash toggles off; reopening keeps it hidden
    g.SlashCmdList.ATHANOR("")
    pf.hooks.OnShow()
    assert not f.shown
    g.SlashCmdList.ATHANOR("")
    assert f.shown
    # target
    g.SlashCmdList.ATHANOR("target 30")
    assert ns.db.target[333] == 30 and "To 30" in f.h2.text, f.h2.text
    g.SlashCmdList.ATHANOR("house blackwater")
    assert ns.db.house == 117 and "Blackwater" in printed_last(g)


def test_exit_demand_cap_and_trainer_seen():
    rt, ns, g = boot()
    P = ns.Planner
    # Linen Cloak: Blackwater 90 for 3 units, Horde 50 for 100, vendor 20; DE 35 only for an enchanter
    assert P.Exit(ctx(rt), 2569, 1) == 90
    assert abs(P.Exit(ctx(rt), 2569, 10) - (3 * 90 + 7 * 50) / 10) < 1e-9
    assert abs(P.Exit(ctx(rt), 2569, 200) - (3 * 90 + 100 * 50 + 97 * 20) / 200) < 1e-9
    assert abs(P.Exit(ctx(rt, deSkill=50), 2569, 200) - (3 * 90 + 100 * 50 + 97 * 35) / 200) < 1e-9
    assert P.Exit(ctx(rt, houses=rt.table(117)), 2569, 5) == (3 * 90 + 2 * 20) / 5
    # a trainer seen up to 75 that didn't list the chest (est. learn 30): not a trainer recipe
    c = ctx(rt, trainerSeen=rt.table_from({333: 75}))
    out, _ = steps_of(rt, ns, c, 333, 60, 75)
    assert all(o[0] != "Enchant Chest - Inferior Stamina" for o in out), out
    # seen only to 20: the chest (est. 30) may still come from a higher trainer
    c2 = ctx(rt, trainerSeen=rt.table_from({333: 20}))
    out2, _ = steps_of(rt, ns, c2, 333, 60, 75)
    assert out2[0][0] == "Enchant Chest - Inferior Stamina"
    # the trainer scan records how far it saw
    g.trainer = rt.eval('{ { name = "Linen Cloak", skill = "Tailoring", rank = 15, cost = 100, level = 5 } }')
    ns.Scan.Trainer()
    assert ns.db.trainerSeen[197] == 15


def printed_last(g):
    return g.printed[len(g.printed)]


def test_generated_ladder_smoke():
    path = ROOT / "Data" / "Ladder.lua"
    if not path.exists():
        print("skip: no generated Data/Ladder.lua")
        return
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    ns = rt.table()
    rt.execute("return loadstring(...)", path.read_text(encoding="utf-8"), "@Ladder.lua")("Athanor", ns)
    for f in FILES:
        rt.execute("return loadstring(...)", (ROOT / f).read_text(encoding="utf-8"), "@" + f)("Athanor", ns)
    Ld = ns.LADDER
    report = []
    for prof in (333, 197, 171, 164, 165, 202, 186, 185, 129):
        c = ctx(rt, deSkill=300 if prof == 333 else None)
        steps, totals = ns.Planner.Plan(c, prof, 1, 300)
        assert len(steps) > 0, prof
        report.append(f"{Ld.professions[prof]} reaches {totals.reached} in {len(steps)} steps, ~{int(totals.crafts)} crafts, "
                      f"{ns.Planner.Money(totals.cost)}")
    print("generated ladder:", "; ".join(report))


def main():
    test_chance_colour_and_learn_estimate()
    test_ladder_cost_and_filter4()
    test_unit_price_vendor_first_then_cheapest_house_and_fodder()
    test_craft_cost_exit_and_disenchant()
    test_plan_route_switches_and_gates()
    test_plan_trainer_learn_level_and_known()
    test_plan_disenchant_and_stop()
    test_profit_counts_once_and_prefers_fewer_crafts()
    test_shopping_uses_bags_once()
    test_trainer_and_merchant_scans()
    test_craft_log_and_secret_guard()
    test_state_and_panel()
    test_exit_demand_cap_and_trainer_seen()
    test_generated_ladder_smoke()
    print("Athanor harness: OK")


if __name__ == "__main__":
    main()
