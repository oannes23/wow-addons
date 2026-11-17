"""Offline harness for Wuwei's uses block (Exits.lua, SPEC D-052).

  uv run --no-project --with lupa python tools/luatest/wuwei_exits_test.py
Fabricated ns.USES in the Data/Uses.lua contract: decoding, vendor row, best use, craft rows with skill colouring,
pattern flag, disenchant, short mode, profession ranks via GetProfessions/GetProfessionInfo, and tooltip wiring.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402

strip = p1.strip_colors
GREEN, GREY = "|cff40e060", "|cffa0a0a0"

# sell|keep114,keep117|de114,de117|prof,req,out,perInput*1000,vendorRoute,v114,t114,v117,t117,pattern;...
FIXTURE = r'''
return function(ns)
  ns.USES = { generated = "x", build = "1.60.1.70938", houses = { 114, 117 },
    profs = { [185] = "Cooking", [165] = "Leatherworking", [197] = "Tailoring", [186] = "Mining" },
    items = {
      [6289] = "4|7,4|,|185,50,4592,1000,25,25,v,38,a,6328,7753",
      [2318] = "15|30,23|,|165,30,4237,250,8,2400,d,20,v,;165,1,2304,1000,15,15,v,76,a,;165,50,276999,250,-10,513,a,9,d,276935",
      [4237] = "30|,|2500,|",
      [9999] = "0|,|,|",
      [2770] = "5|117,131|,|186,1,2840,1000,10,335,c2868,404,c2868,",
    },
  }
end
'''
NAMES = r'''NAMES = NAMES or {}; NAMES[4592] = "Longjaw Mud Snapper"; NAMES[4237] = "Handstitched Leather Belt"; NAMES[2304] = "Light Armor Kit"; NAMES[276999] = "Cloudy Gustwoven Bracers"; NAMES[2840] = "Copper Bar"; NAMES[2868] = "Copper Tube"
C_SpellBook = { IsSpellKnown = function(id) return id == 7753 end }  -- knows the Longjaw recipe (a pattern)
GetProfessions = function() return 1, 2, nil, 4, 5, nil, nil end
local P = { [1] = {"Leatherworking", 2945, 40, 0}, [2] = {"Tailoring", 197, 10, 0}, [4] = {"Fishing", 356, 80, 0}, [5] = {"Cooking", 2939, 45, 10} }
GetProfessionInfo = function(i) local p = P[i]; return p[1], 0, p[3], 300, 0, 0, p[2], p[4] end
'''


def boot():
    rt, ns = p1.boot(extra=NAMES)
    rt.execute(FIXTURE)(ns)
    return rt, ns


def lines(rt, ns, id_, raw=False, **opts):
    o = {"mode": "full", "house": 114, "ranks": ns.Exits.Ranks(), "known": ns.Exits.Known}
    o.update(opts)
    r = ns.Exits.Lines(id_, rt.table_from(o))
    if not r:
        return None
    out = [tuple(x for x in row.values()) for row in r.values()]
    return out if raw else [tuple(strip(x) for x in row) for row in out]


def test_ranks_and_decode():
    rt, ns = boot()
    r = ns.Exits.Ranks()
    assert r[165] == 40 and r[197] == 10 and r[185] == 55 and r[356] == 80  # child lines folded, modifier added
    d = ns.Exits.Decode(2318)
    assert d.sell == 15 and d.keep[114] == 30 and d.keep[117] == 23 and d.de[114] is None
    assert len(d.recipes) == 3 and d.recipes[1].v[114] == 2400 and d.recipes[1].t[114] == "d"
    assert ns.Exits.Decode(6289).recipes[1].spell == 7753 and d.recipes[1].spell is None
    assert d.recipes[1].perInput == 0.25 and d.recipes[3].pattern == 276935 and d.recipes[1].pattern is None
    assert ns.Exits.Decode(4237).de[114] == 2500 and ns.Exits.Decode(12345) is None


def test_cook_fish():
    rt, ns = boot()
    L = lines(rt, ns, 6289, count=20)
    assert L[0] == ("Vendor", "4c/u · x20 80c"), L[0]
    # Cooking 50 needed, player has 45+10: can make it. Cooked vendors for 25 vs 7 kept: +18c.
    assert L[1] == ("Best use", "Cooking → Longjaw Mud Snapper → vendor +18c/u"), L[1]
    assert L[2][0].startswith("   Cooking 50 · Longjaw Mud Snapper") and "(pattern)" in L[2][0]
    assert L[2][1] == "vendor +18c", L[2]


def test_leather_to_green_to_disenchant():
    rt, ns = boot()
    raw = lines(rt, ns, 2318, raw=True)
    L = [tuple(strip(x) for x in r) for r in raw]
    # Best: belt -> disenchant, 24s per leather over 30c kept. Player LW 40 >= 30: green.
    assert L[1] == ("Best use", "Leatherworking → Handstitched Leather Belt → DE +23s 70c/u"), L[1]
    assert GREEN in raw[1][1]
    assert L[2] == ("   Leatherworking 30 · Handstitched Leather Belt", "vendor −22c · DE +23s 70c"), L[2]
    # Pattern recipe needs 50: whole row greyed; at Blackwater the same recipe reads differently.
    assert raw[4][0].startswith(GREY) and "(pattern)" in L[4][0]
    L117 = lines(rt, ns, 2318, house=117)
    assert L117[1][1] == "Leatherworking → Light Armor Kit → AH +53c/u", L117[1]
    # A pattern craft worth more than the best you can do now: grey Upside line, never the Best use.
    ns.USES["items"][2318] = "15|30,23|,|165,1,2304,1000,15,15,v,76,a,;165,50,276999,250,-10,513,a,9,d,276935"
    ns.USES["houses"] = ns.USES["houses"]  # same table; bust the decode cache via a new USES table below
    rt.execute("return function(ns) local u = ns.USES; ns.USES = { houses = u.houses, profs = u.profs, items = u.items } end")(ns)
    L = lines(rt, ns, 2318)
    assert L[1] == ("Best use", "AH here 30c/u"), L[1]
    assert L[2] == ("Upside", "Leatherworking → Cloudy Gustwoven Bracers → AH +4s 83c/u (pattern)"), L[2]


def test_craft_chain_names_the_next_craft():
    rt, ns = boot()
    L = lines(rt, ns, 2770, ranks=rt.table_from({186: 1}))
    assert L[1] == ("Best use", "Mining → Copper Bar → craft Copper Tube +2s 18c/u"), L[1]
    assert L[2][1] == "vendor −1s 7c · craft Copper Tube +2s 18c", L[2]


def test_disenchant_row_short_mode_and_empty():
    rt, ns = boot()
    L = lines(rt, ns, 4237)
    assert L[1] == ("Best use", "disenchant 25s/u") and L[-1] == ("   Disenchant", "+24s 70c")
    S = lines(rt, ns, 2318, mode="short")
    assert len(S) == 2 and S[0][0] == "Vendor"
    assert lines(rt, ns, 9999)[0] == ("Vendor", "can't be sold")
    assert lines(rt, ns, 2318, mode="off") is None
    assert lines(rt, ns, 6289, house=999)[1][1].startswith("Cooking")  # unknown house falls back to the first


def test_tooltip_wiring():
    rt, ns = boot()
    ns.db = rt.table_from({"enabled": True, "tooltip": True, "prices": "full"})
    ns.PRICES = None  # no AH block: the uses block still shows
    r = ns.Tooltip.PriceRows(6289, None)
    got = [strip(x[1]) for x in r.values()]
    assert got[0] == "Vendor" and got[1] == "Best use", got


def main():
    for t in (test_ranks_and_decode, test_cook_fish, test_leather_to_green_to_disenchant, test_craft_chain_names_the_next_craft,
              test_disenchant_row_short_mode_and_empty, test_tooltip_wiring):
        t()
        print("ok", t.__name__)


if __name__ == "__main__":
    main()
