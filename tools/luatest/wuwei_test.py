"""Offline harness for addons/Wuwei: runs the addon in Lua 5.1 (lupa) against mocked WoW APIs and frames.

  uv run --no-project --with lupa python tools/luatest/wuwei_test.py
Covers: tooltip text, row ordering, house selection, search throttle, empty-house behaviour, AH show/hide.
"""
import re
from pathlib import Path

import lupa.lua51 as lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "Wuwei"

MOCK = r"""
now = 0; server = 1794210120; printed = {}; zone, subzone, faction, mapID = "Orgrimmar", "", "Horde", 85
function print(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring(select(i, ...)) end printed[#printed+1] = table.concat(t, " ") end
function GetTime() return now end
function GetServerTime() return server end   -- 2026-11-09T07:42:00Z, i.e. plan age 42m
function GetZoneText() return zone end
function GetSubZoneText() return subzone end
function UnitFactionGroup() return faction end
C_Map = { GetBestMapForUnit = function() return mapID end, GetMapInfo = function(id) return { name = "Map" .. id } end }
EventUtil = { ContinueOnAddOnLoaded = function(_, fn) fn() end }
SlashCmdList = {}
Enum = { TooltipDataType = { Item = 0 } }
postCalls = {}
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) postCalls[#postCalls+1] = { t, fn } end }

-- Frames: records text, shown state, anchors, scripts.
frames = {}
local function newFS() local f = { text = "" } function f:SetText(t) self.text = t end function f:SetPoint() end
  function f:SetWidth() end function f:SetJustifyH() end return f end
local FRAME = {}
function FRAME:RegisterEvent(e) self.ev[e] = true end
function FRAME:SetScript(n, fn) self.scripts[n] = fn end
function FRAME:Show() self.shown = true end
function FRAME:Hide() self.shown = false end
function FRAME:IsShown() return self.shown end
function FRAME:SetSize() end function FRAME:SetFrameStrata() end function FRAME:SetText() end
function FRAME:SetAllPoints() end function FRAME:SetColorTexture() end function FRAME:ClearAllPoints() self.points = {} end
function FRAME:SetPoint(...) self.points = self.points or {} self.points[#self.points+1] = { ... } end
function FRAME:CreateFontString() return newFS() end
function FRAME:CreateTexture() return setmetatable({ ev = {}, scripts = {} }, { __index = FRAME }) end
function CreateFrame(kind, name, parent)
  local f = setmetatable({ ev = {}, scripts = {}, shown = false, kind = kind, name = name }, { __index = FRAME })
  frames[#frames+1] = f
  if name then _G[name] = f end
  return f
end
function fire(e, ...) for _, f in ipairs(frames) do if f.ev[e] and f.scripts.OnEvent then f.scripts.OnEvent(f, e, ...) end end end

-- Fake Blizzard AH frame.
AuctionHouseSearchContext = { BuyItems = 20, BuyCommodities = 21 }
sent = {}; selected = {}; browse = {}
function mkAH()
  local ah = CreateFrame("Frame", "AuctionHouseFrame")
  function ah:QueryItem(ctx, key) sent[#sent+1] = { ctx = ctx, id = key.itemID } end
  function ah:SelectBrowseResult(r) selected[#selected+1] = r end
  function ah:SendBrowseQuery(s) browse[#browse+1] = s end
  function ah:SetSearchText() end
  return ah
end
commodity = true
C_AuctionHouse = {
  MakeItemKey = function(id) return { itemID = id } end,
  GetItemKeyInfo = function(key) return commodity and { isCommodity = true } or nil end,
}
NAMES = { [4304] = "Thick Leather", [4338] = "Mageweave Cloth", [3357] = "Liferoot", [2772] = "Iron Ore", [8153] = "Wildvine", [2589] = "Linen Cloth" }
loadReq = {}
C_Item = { GetItemNameByID = function(id) return NAMES[id] end, RequestLoadItemDataByID = function(id) loadReq[#loadReq+1] = id end }
"""

TOC_LUA = ["Locales/enUS.lua", "Data/Builtin.lua", "Data/Plan.lua", "Plan.lua", "House.lua", "Ledger.lua", "Post.lua", "Tooltip.lua", "Panel.lua", "Core.lua"]


def toc_files():
    toc = (ROOT / "Wuwei_Forever.toc").read_text().replace("\\", "/")
    return [l.strip() for l in toc.splitlines() if l.strip() and not l.startswith("#")]


def strip_colors(s: str) -> str:
    return re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s)


def boot(use_generated_plan: bool = False, extra: str = ""):
    """Load the addon in TOC order. The generated Data/Plan.lua (private, gitignored) is skipped unless asked for, so
    assertions run against Data/Builtin.lua regardless of what the pipeline last exported."""
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    if extra:
        rt.execute(extra)
    ns = rt.table()
    files = toc_files()
    assert files == TOC_LUA, files  # TOC order is what we test
    for f in files:
        p = ROOT / f
        if f == "Data/Plan.lua" and not use_generated_plan:
            continue
        if not p.exists():
            assert f == "Data/Plan.lua", f"missing {f}"  # generated + gitignored; client tolerates it
            continue
        chunk = rt.execute("return loadstring(...)", p.read_text(), "@" + f)
        assert chunk is not None, f"syntax error in {f}"
        chunk("Wuwei", ns)
    return rt, ns


def main() -> None:
    rt, ns = boot()
    g = rt.globals()
    det = lambda: tuple(ns.House.Detect())[0]

    # --- Core init / db
    assert g.WuweiDB.enabled is True and g.WuweiDB.house is None
    assert len(g.postCalls) == 1 and g.postCalls[1][1] == 0  # Item tooltip post-call registered

    # --- Plan helpers
    P = ns.Plan
    assert P.Money(0) == "0c" and P.Money(360) == "3s 60c" and P.Money(1300) == "13s" and P.Money(10002) == "1g 2c" and P.Money(10203) == "1g 2s 3c"
    assert P.AgeText() == "42m", P.AgeText()
    assert P.ParseTime("1970-01-02T00:00:00Z") == 86400 and P.ParseTime("2000-03-01T00:00:00Z") == 951868800

    # --- House selection: faction, zone (and subzone), map, override
    assert tuple(ns.House.Detect())[0] == 114                                    # Horde
    g.faction = "Alliance"; assert det() == 111                       # Alliance
    g.faction = "Horde"
    g.zone, g.subzone = "Stranglethorn Vale", "Booty Bay"; assert det() == 117   # subzone -> Blackwater
    g.zone, g.subzone = "Gadgetzan", ""; assert det() == 117
    g.zone, g.subzone = "Orgrimmar", ""
    ns.House.BLACKWATER_MAPS[999] = True; g.mapID = 999; assert det() == 117
    g.mapID = 85; assert det() == 114
    assert ns.House.Set("111") and det() == 111                       # manual override wins
    assert ns.House.Set("auto") and det() == 114
    assert not ns.House.Set("banana")
    g.faction = None; h, why = ns.House.Detect(); assert h is None and "unknown" in why; g.faction = "Horde"

    # --- Tooltip text (at Horde AH 114, plan 42m old)
    line = strip_colors(ns.Tooltip.Line(4304))
    assert line == "Wuwei: SHUTTLE → BW ≥ 13s · ref 6s · 42m", line
    assert strip_colors(ns.Tooltip.Line(4338)) == "Wuwei: SELL ≥ 4s 20c · ref 3s 60c · 42m"
    assert strip_colors(ns.Tooltip.Line(2589)) == "Wuwei: BUY ≤ 35c · ref 40c · 42m"
    assert strip_colors(ns.Tooltip.Line(2772)) == "Wuwei: HOLD ref 9s · 42m"
    assert ns.Tooltip.Line(12345) is None                                         # not in plan: no line
    g.zone = "Everlook"                                                           # at Blackwater: shuttle = sell side
    assert strip_colors(ns.Tooltip.Line(4304)) == "Wuwei: SHUTTLE sell ≥ 13s · ref 14s 50c · 42m"
    g.zone = "Orgrimmar"
    assert "|cffffa030" in ns.Tooltip.Line(4304)                                  # coloured by signal
    # Post-call wiring: adds exactly one line for plan items, none otherwise, none when disabled.
    tip = rt.eval("{ lines = {}, AddLine = function(self, t) self.lines[#self.lines+1] = t end }")
    post = g.postCalls[1][2]
    post(tip, rt.eval("{ id = 4304 }")); post(tip, rt.eval("{ id = 1 }")); post(tip, rt.eval("{}"))
    assert len(list(tip.lines.values())) == 1
    g.WuweiDB.enabled = False; post(tip, rt.eval("{ id = 4338 }")); assert len(list(tip.lines.values())) == 1
    g.WuweiDB.enabled = True

    # --- Row ordering by gain (desc), AVOID dropped, house filtering
    ids = [p.id for p in P.Plays(114).values()]
    assert ids == [3357, 4304, 8153, 4338, 2589, 2772], ids                       # gains 52,38,27,9,4,0
    assert [p.id for p in P.Plays(114, 3).values()] == [3357, 4304, 8153]
    assert P.Plays(111) and len(list(P.Plays(111).values())) == 0                 # no plan rows for Alliance

    # --- Panel: not shown until AUCTION_HOUSE_SHOW; anchors to AuctionHouseFrame; hides on close
    ah = g.mkAH(); ah.shown = True
    assert ns.Panel.frame is None
    g.fire("AUCTION_HOUSE_SHOW")
    f = ns.Panel.frame
    assert f.shown and f.points[1][1] == "TOPLEFT" and f.points[1][2].name == "AuctionHouseFrame" and f.points[1][3] == "TOPRIGHT"
    head = strip_colors(f.header.text)
    assert head == "Horde AH (114) · data 42m old · SAMPLE DATA · market: DEFLATION", head
    texts = [(strip_colors(f.rows[i].name.text), strip_colors(f.rows[i].gain.text), strip_colors(f.rows[i].signal.text))
             for i in range(1, 16) if f.rows[i].shown]
    assert texts[0] == ("Liferoot", "+52g", "SHUTTLE") and texts[1][0] == "Thick Leather" and len(texts) == 6, texts
    assert not f.rows[7].shown
    g.fire("AUCTION_HOUSE_CLOSED"); assert not f.shown
    g.WuweiDB.enabled = False; g.fire("AUCTION_HOUSE_SHOW"); assert not f.shown; g.WuweiDB.enabled = True  # toggled off

    # --- Name fallback + async load refresh
    g.NAMES[3357] = None
    g.fire("AUCTION_HOUSE_SHOW")
    assert f.rows[1].name.text == "item:3357" and 3357 in list(g.loadReq.values())
    g.NAMES[3357] = "Liferoot"; g.fire("ITEM_DATA_LOAD_RESULT", 3357, True)
    assert f.rows[1].name.text == "Liferoot"

    # --- Graceful with no plays for a house (Alliance) and with an unknown house
    g.faction = "Alliance"; g.fire("AUCTION_HOUSE_SHOW")
    assert f.shown and not f.rows[1].shown and "No plays" in f.empty.text, f.empty.text
    g.faction = None; g.fire("AUCTION_HOUSE_SHOW")
    assert f.shown and "House unknown" in f.empty.text and "unknown AH" in f.header.text
    g.faction = "Horde"; g.fire("AUCTION_HOUSE_SHOW")
    # Empty plan items and a missing plan entirely must not error either.
    ns.PLAN = rt.eval('{ generated = "bad", items = {} }'); g.fire("AUCTION_HOUSE_SHOW")
    assert not f.rows[1].shown and "?" in f.header.text
    assert ns.Tooltip.Line(4304) is None
    ns.PLAN = None; ns.BUILTIN_PLAN = None; g.fire("AUCTION_HOUSE_SHOW"); assert not f.rows[1].shown
    ns.PLAN = None; rt.execute("return nil")

    # --- Search hand-off: QueryItem + SelectBrowseResult; item-info fallback to name search
    rt2, ns2 = boot(); g2 = rt2.globals()
    ah2 = g2.mkAH(); ah2.shown = True; g2.fire("AUCTION_HOUSE_SHOW")
    ok, how = ns2.Panel.Search(4304)
    assert ok and how == "itemkey" and g2.sent[1].ctx == 21 and g2.sent[1].id == 4304 and g2.selected[1].itemKey.itemID == 4304
    g2.commodity = False
    ok, how = ns2.Panel.Search(4304)
    assert ok and how == "name" and g2.browse[1] == "Thick Leather"
    ah2.shown = False
    ok, why = ns2.Panel.Search(4304); assert not ok and "not open" in why

    # --- Throttle: never more than 100 searches in any 60 s window; recovers afterwards
    rt3, ns3 = boot(); g3 = rt3.globals()
    ah3 = g3.mkAH(); ah3.shown = True; g3.fire("AUCTION_HOUSE_SHOW")
    done = 0
    for i in range(150):
        g3.now = i * 0.1                                  # 150 clicks inside 15 s
        ok, _ = ns3.Panel.Search(4304)
        done += 1 if ok else 0
    assert done <= 100 and len(list(g3.sent.values())) == done, done
    assert done == 90, done                               # margin below Blizzard's 100/min
    g3.now = 59.0; assert not ns3.Panel.Search(4304)[0]   # still inside the window of the first call
    g3.now = 60.5; assert ns3.Panel.Search(4304)[0]       # window slid; allowed again
    assert any("search limit" in p for p in g3.printed.values())

    # --- Slash commands
    rt4, ns4 = boot(); g4 = rt4.globals(); slash = g4.SlashCmdList["WUWEI"]
    slash("house 117"); assert g4.WuweiDB.house == 117
    slash("house auto"); assert g4.WuweiDB.house is None
    slash("toggle"); assert g4.WuweiDB.enabled is False
    slash("toggle"); assert g4.WuweiDB.enabled is True
    slash("status"); slash("probe"); slash("house nope"); slash("bogus")
    out = "\n".join(strip_colors(p) for p in g4.printed.values())
    assert "house: 114 (faction Horde)" in out and "BUILTIN SAMPLE" in out and "uiMapID: 85" in out and "usage:" in out, out
    print("Wuwei harness: OK")


def smoke_generated_plan():
    """If the pipeline has exported a real Plan.lua, it must load and yield plays and tooltips without errors."""
    if not (ROOT / "Data/Plan.lua").exists():
        return "skipped (no generated plan)"
    rt, ns = boot(use_generated_plan=True)
    assert ns.PLAN is not None and not ns.Plan.IsBuiltin()
    n114 = len(list(ns.Plan.Plays(114, 15).values()))
    n117 = len(list(ns.Plan.Plays(117, 15).values()))
    assert n114 > 0, "generated plan has no plays for 114"
    return f"generated plan OK: {n114} plays at 114, {n117} at 117, regime {ns.Plan.Regime(114)}"


if __name__ == "__main__":
    main()
    print(smoke_generated_plan())
