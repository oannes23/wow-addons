"""Offline harness for Wuwei's two-house price block (Prices.lua, SPEC D-042 to D-046).

  uv run --no-project --with lupa python tools/luatest/wuwei_prices_test.py
Reuses the Phase 1 mocks (wuwei_test.boot) with a fabricated ns.PRICES in the Data/Prices.lua contract (D-043).
Covers: decoding (empty, partial, malformed parts; cache), full/short lines, ordering by house, haul/vendor/stack
lines, stale data, tooltip context (stack count, sell price line), post-call wiring and the slash command.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402

ROOT = p1.ROOT
strip = p1.strip_colors

# Mock server time is 2026-11-09T07:42:00Z: listings 3h old, sales 1d old.
FIXTURE = r'''
return function(ns)
  ns.PRICES = {
    generated = "2026-11-09T05:00:00Z", window = 7, houses = { 114, 117 },
    snap = { [114] = "2026-11-09T04:42:00Z", [117] = "2026-11-09T04:41:00Z" },
    sales = { [114] = "2026-11-08T07:42:00Z", [117] = "2026-11-08T07:41:00Z" },
    items = {
      [2589] = "18,27,28496,21197,20,412,852,-8,2;22,30,4100,2600,25,96,220,-3,7",
      [4304] = "600,650,120,40,700,3,15,1;",
      [4338] = ",,0,0,360,20,50,;,,,,,,,",
      [2772] = "900,950,50,10,,,,30;",
      [9999] = "garbage;x,y",
      [3357] = "100,120,10,5,200,50,100,0;5000,5200,7,7,9000,30,40,12",
      [12784] = "2550000,2600000,2,2,2549600,8,3,-20;1,1,1,1,1,1,1,1,7",
    },
  }
end
'''


def boot():
    rt, ns = p1.boot()
    rt.execute(FIXTURE)(ns)
    return rt, ns


def rows(r):
    return [tuple(strip(x) for x in row.values()) for row in r.values()] if r else None


def lines(rt, ns, id_, **opts):
    o = {"mode": "full", "house": 114, "confident": True, "now": rt.globals().server}
    o.update(opts)
    return rows(ns.Prices.Lines(id_, rt.table_from(o)))


def test_decode():
    rt, ns = boot()
    D = ns.Prices.Decode
    d = D(2589)
    assert d[114].floor == 18 and d[114].perDay10 == 852 and d[114].trend == -8 and d[117].sells == 25
    assert d[114].sellsDays == 2 and D(4304)[114].sellsDays is None                 # 8-field parts still decode
    d = D(4338)
    assert d[114].floor is None and d[114].sells == 360 and d[117] is None   # all-empty part = no data
    assert D(4304)[117] is None                                             # empty part
    assert D(9999) is None and D(123456) is None                            # malformed / absent
    assert D(2589) is d or D(2589)[114].floor == 18                         # cached, same answer
    ns.PRICES = None
    assert D(2589) is None                                                  # no data file: off


def test_full_lines_at_orgrimmar():
    rt, ns = boot()
    got = lines(rt, ns, 2589)
    assert got == [
        ("Horde (here)", "sells 20c · floor 18c · 85/d"),
        ("   median 27c · 28.5k listed, 21.2k near floor · 7d -8% · 412 sales (2d)",),
        ("Blackwater", "sells 25c · floor 22c · 22/d"),
        ("   median 30c · 4100 listed, 2600 near floor · 7d -3% · 96 sales (7d)",),
        ("Haul → Blackwater: +3c/u net of 15% cut (+18%)",),     # 25 x 0.85 - 18 = 3.25c, 18% of the floor
        ("Prices: listings 3h old · sales 1d old",),
    ], got
    assert lines(rt, ns, 4304) == [
        ("Horde (here)", "sells 7s thin · floor 6s · 1.5/d"),
        ("   median 6s 50c · 120 listed, 40 near floor · 7d flat · 3 sales",),
        ("Blackwater", "no data"),
        ("Prices: listings 3h old · sales 1d old",),
    ]
    assert lines(rt, ns, 4338)[:2] == [("Horde (here)", "sells 3s 60c · none listed · 5.0/d"), ("   0 listed · 20 sales",)]
    assert lines(rt, ns, 2772)[:2] == [("Horde (here)", "no sales 7d · floor 9s"),
                                       ("   median 9s 50c · 50 listed, 10 near floor · 7d +30%",)]
    assert lines(rt, ns, 12784)[0] == ("Horde (here)", "sells 254g 96s · floor 255g · 0.3/d")
    assert lines(rt, ns, 12784)[3] == ("   median 1c · 1 listed, 1 near floor · 7d flat · 1 sale (7d)",)  # singular
    assert lines(rt, ns, 3357)[4] == ("Haul → Blackwater: +75s 50c/u net of 15% cut (+7550%)",)
    assert lines(rt, ns, 9999) is None and lines(rt, ns, 1) is None
    assert lines(rt, ns, 2589, confident=False)[0][0] == "Horde"            # "(here)" only when detection is sure


def test_order_and_haul_from_blackwater():
    rt, ns = boot()
    got = lines(rt, ns, 2589, house=117)
    assert got[0] == ("Blackwater (here)", "sells 25c · floor 22c · 22/d") and got[2][0] == "Horde"
    assert not any("Haul" in r[0] for r in got)                             # 20 x 0.95 - 22 < 0: no haul
    assert lines(rt, ns, 2589, house=None)[0][0] == "Horde"                 # unknown house: export order
    assert lines(rt, ns, 2589, house=111)[0][0] == "Horde"


def test_short_mode_and_staleness():
    rt, ns = boot()
    got = lines(rt, ns, 2589, mode="short")
    assert got == [("Horde (here)", "sells 20c · floor 18c · 85/d"), ("Blackwater", "sells 25c · floor 22c · 22/d"),
                   ("Haul → Blackwater: +3c/u net of 15% cut (+18%)",)], got
    stale = lines(rt, ns, 2589, mode="short", now=rt.globals().server + 2 * 86400)
    assert stale[-1] == ("Prices: listings 2d old · sales 3d old",)
    assert "|cffffa030" in ns.Prices.Lines(2589, rt.table_from({"mode": "short", "house": 114,
                                                                "now": rt.globals().server + 2 * 86400}))[4][1]
    assert lines(rt, ns, 2589, mode="off") is None


def test_vendor_and_stack():
    rt, ns = boot()
    got = lines(rt, ns, 2589, vendorUnit=19)
    assert ("Vendor flip: floor 18c < vendor 19c",) in got and not any("beats" in r[0] for r in got)
    got = lines(rt, ns, 2589, vendorUnit=30)
    assert ("Vendor flip: floor 18c < vendor 30c",) in got and ("Vendor 30c beats the AH (best net 21c)",) in got
    got = lines(rt, ns, 2589, count=20)
    assert ("Stack x20: 3s 80c Horde · 4s 25c Blackwater (net of cut)",) in got
    assert not any("Stack" in r[0] for r in lines(rt, ns, 2589, count=20, mode="short"))
    assert not any("Stack" in r[0] for r in lines(rt, ns, 2589, count=1))


def test_context():
    rt, ns = boot()
    g = rt.globals()
    ctx = lambda src: tuple(ns.Prices.Context(rt.eval(src)))
    g.C_Item.GetItemLocation = rt.eval("function(guid) return { guid = guid } end")
    g.C_Item.GetStackCount = rt.eval("function(loc) return 20 end")
    assert ctx("{ id = 2589, guid = 'G1', lines = { { type = 0 }, { type = 11, price = 360 } } }") == (20, 18)
    assert ctx("{ id = 2589, lines = { { type = 11, price = 15 } } }") == (1, 15)          # link: one unit
    assert ctx("{ id = 2589 }") == (1, None)                                                # no sell price line
    g.C_Item.GetItemLocation = rt.eval("function() error('bad guid') end")
    assert ctx("{ id = 2589, guid = 'G1', lines = { { type = 11, price = 360 } } }") == (None, None)  # unknown count
    g.Enum.TooltipDataLineType = rt.eval("{ SellPrice = 42 }")
    assert ctx("{ id = 2589, lines = { { type = 42, price = 7 }, { type = 11, price = 99 } } }") == (1, 7)


def test_post_call_wiring():
    rt, ns = boot()
    g = rt.globals()
    post = g.postCalls[1][2]
    tip = rt.eval("""{ out = {},
      AddLine = function(self, t) self.out[#self.out+1] = { t } end,
      AddDoubleLine = function(self, l, r) self.out[#self.out+1] = { l, r } end }""")

    def run(data, **flags):
        tip.out = rt.table()
        for k, v in flags.items():
            tip[k] = v
        post(tip, rt.eval(data))
        return [tuple(strip(x) for x in r.values()) for r in tip.out.values()]

    out = run("{ id = 2589, lines = { { type = 11, price = 10 } } }")
    assert out[0] == ("Horde (here)", "sells 20c · floor 18c · 85/d") and len(out) == 7, out
    assert out[-1] == ("Wuwei: BUY ≤ 35c · ref 40c · 42m",)                      # plan line stays last
    assert run("{ id = 2589 }", isShopping=True) == [("Wuwei: BUY ≤ 35c · ref 40c · 42m",)]
    tip.isShopping = None
    g.WuweiDB.prices = "short"
    assert len(run("{ id = 2589 }")) == 4                                      # 2 headlines + haul + plan line
    g.WuweiDB.prices = "off"
    assert run("{ id = 2589 }") == [("Wuwei: BUY ≤ 35c · ref 40c · 42m",)]
    g.WuweiDB.prices = "full"
    assert run("{ id = 4304 }")[0][0] == "Horde (here)"                         # price block for any priced item
    assert len(run("{ id = 123456 }")) == 0                                    # neither priced nor planned
    g.WuweiDB.tooltip = False
    assert run("{ id = 2589 }") == []
    g.WuweiDB.tooltip = True
    ns.PRICES = None
    assert run("{ id = 2589 }") == [("Wuwei: BUY ≤ 35c · ref 40c · 42m",)]       # no Data/Prices.lua: block off


def test_slash():
    rt, ns = boot()
    g = rt.globals()
    assert g.WuweiDB.prices == "full"                                          # default (D-044)
    slash = g.SlashCmdList.WUWEI
    slash("prices short"); assert g.WuweiDB.prices == "short"
    slash("prices"); assert g.WuweiDB.prices == "off"                          # cycles full -> short -> off
    slash("prices"); assert g.WuweiDB.prices == "full"
    slash("prices banana"); assert g.WuweiDB.prices == "full"
    printed = list(g.printed.values())
    assert any("usage: /wuwei prices" in x for x in printed)
    assert any("prices: short · 7 items · listings 3h old" in strip(x) for x in printed), printed
    slash("status")
    assert any("prices: full" in strip(x) for x in g.printed.values())
    ns.PRICES = None
    slash("prices full")
    assert "no Data/Prices.lua" in list(g.printed.values())[-1]


def smoke_generated_prices():
    """If the pipeline has exported a real Data/Prices.lua, it must load, decode and render without errors."""
    if not (ROOT / "Data/Prices.lua").exists():
        return "skipped (no generated prices)"
    rt, ns = p1.boot(use_generated_prices=True)
    n = ns.Prices.Count()
    assert n > 0 and ns.Prices.Decode(2589) and ns.Prices.Decode(2589)[114]
    bad = 0
    for item in list(ns.PRICES["items"].keys())[:2000]:
        r = ns.Prices.Lines(item, rt.table_from({"mode": "full", "house": 114, "confident": True,
                                                  "now": rt.globals().server, "count": 5, "vendorUnit": 3}))
        bad += r is None
    return f"generated prices OK: {n} items, {bad} of the first 2000 render nothing"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("Wuwei prices harness: OK")
    print(smoke_generated_prices())
