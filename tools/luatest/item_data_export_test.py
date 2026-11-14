"""Offline harness for addons/ItemDataExport: runs the addon in Lua 5.1 (lupa) against mocked WoW APIs.

  uv run --no-project --with lupa python tools/luatest/item_data_export_test.py
Covers: link building, async load + timeout + retry, failed loads, resumability, SavedVariables shape.
"""
from pathlib import Path

import lupa.lua51 as lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "ItemDataExport"

MOCK = r"""
now = 0; server = 1794200000; printed = {}; events = {}; ticker = nil
function print(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring(select(i, ...)) end printed[#printed+1] = table.concat(t, " ") end
function GetTime() return now end
function GetServerTime() return server end
function GetBuildInfo() return "1.60.1", "70790", "Nov 4 2026", 16001 end
function GetLocale() return "enUS" end
EventUtil = { ContinueOnAddOnLoaded = function(_, fn) fn() end }
C_Timer = { NewTicker = function(_, fn) ticker = { fn = fn, Cancel = function(self) ticker = nil end } return ticker end }
local frames = {}
function CreateFrame() local f = { ev = {} } function f:RegisterEvent(e) self.ev[e] = true end
  function f:UnregisterEvent(e) self.ev[e] = nil end
  function f:UnregisterAllEvents() self.ev = {} end
  function f:RegisterUnitEvent(e) self.ev[e] = true end
  function f:SetScript(_, fn) self.fn = fn end frames[#frames+1] = f return f end
function fire(e, ...) for _, f in ipairs(frames) do if f.ev[e] then f.fn(f, e, ...) end end end
SlashCmdList = {}
-- Server model: cached set; pending loads resolve on the next pump. 404 = nonexistent, 999 = never answers.
cached = { [2589] = true }; pendingLoads = {}; requests = {}
local NAMES = { [869] = "Dazzling Longsword", [2589] = "Linen Cloth", [3195] = "Barbaric Battle Axe" }
local SUFFIX = { [12918] = "of the Eagle", [12719] = "of the Bear" }
C_Item = {}
function C_Item.IsItemDataCachedByID(id) return cached[id] == true end
function C_Item.RequestLoadItemDataByID(id) requests[#requests+1] = id; if id ~= 999 then pendingLoads[#pendingLoads+1] = id end end
local function parse(info)
  if type(info) == "number" then return info end
  local id = tonumber(info:match("^item:(%d+)")); local f = {}
  for v in (info .. ":"):gmatch("([^:]*):") do f[#f+1] = v end
  -- f[1]="item", f[2]=id, f[3..13]=11 empty, f[14]=numBonus, f[15]=bonus
  local nb = tonumber(f[14] or "") or 0
  return id, (nb > 0) and tonumber(f[15]) or nil, f
end
function C_Item.GetItemInfo(info)
  local id, bonus = parse(info)
  if not cached[id] or not NAMES[id] then return nil end
  local name = NAMES[id] .. (bonus and SUFFIX[bonus] and (" " .. SUFFIX[bonus]) or "")
  return name, "|Hitem:" .. id .. "|h[" .. name .. "]|h", 2, 20, 15, "Weapon", "Axes", 1, "INVTYPE_2HWEAPON", 1, 500,
    2, 1, 2, 0, nil, false, ""
end
function C_Item.GetItemStats(info) local _, bonus = parse(info) if bonus == 12918 then return { ITEM_MOD_AGILITY_SHORT = 5, ITEM_MOD_INTELLECT_SHORT = 5 } end return {} end
function C_Item.GetDetailedItemLevelInfo() return 20, false, 20 end
C_TooltipInfo = { GetHyperlink = function(link) local n = C_Item.GetItemInfo(link)
  return { lines = { { leftText = n, leftColor = { r = 1 } }, { leftText = "Two-Hand", rightText = "Axe", type = 0 } } } end }
function pump() local p = pendingLoads; pendingLoads = {} for _, id in ipairs(p) do
  if id == 404 then fire("ITEM_DATA_LOAD_RESULT", id, false) else cached[id] = true fire("ITEM_DATA_LOAD_RESULT", id, true) end end end
function step(dt) now = now + (dt or 0.1) if ticker then ticker.fn() end pump() end
"""


def load(rt, ns, files):
    for f in files:
        chunk = rt.execute("return loadstring(...)", (ROOT / f).read_text(), "@" + f)
        assert chunk is not None, f"syntax error in {f}"
        chunk("ItemDataExport", ns)


def main() -> None:
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    g = rt.globals()
    ns = rt.table()
    load(rt, ns, ["Locales/enUS.lua", "Data/Builtin.lua", "Export.lua"])
    # Replace the builtin set with one covering every path.
    ns.INPUT = rt.eval("""{ generated = "test", source = "harness", tuples = {
      {869}, {2589}, {3195}, {3195, 12918}, {3195, 12719}, {3195, 12918, 28, 5254}, {404}, {999} } }""")
    load(rt, ns, ["Core.lua"])
    slash = g.SlashCmdList["ITEMDATAEXPORT"]
    slash("start")
    for _ in range(400):  # 40 s of game time: covers the 10 s timeout x 2 tries
        g.step(0.1)
        if g.ticker is None:
            break
    db = g.ItemDataExportDB
    res, failed = db.results, db.failed
    # Links: plain id, bonus, bonus + modifier (11 empty fields after the id).
    assert res["869"].link == "item:869"
    assert res["3195:12918"].link == "item:3195::::::::::::1:12918", res["3195:12918"].link
    assert res["3195:12918:28:5254"].link == "item:3195::::::::::::1:12918:1:28:5254"
    assert res["3195:12918"].name == "Barbaric Battle Axe of the Eagle"
    assert res["3195:12719"].name == "Barbaric Battle Axe of the Bear"
    assert res["3195:12918"].stats.ITEM_MOD_AGILITY_SHORT == 5
    tip = res["3195:12918"].tip
    assert tip[1].leftText == "Barbaric Battle Axe of the Eagle" and tip[1].leftColor is None  # tables dropped
    assert tip[2].rightText == "Axe" and tip[2].type is None  # tooltip lines keep strings only
    assert db["items"][3195].name == "Barbaric Battle Axe" and db["items"][3195].equipLoc == "INVTYPE_2HWEAPON"
    assert failed["404"].startswith("load failed") and failed["999"] == "load timeout", dict(failed)
    assert list(g.requests.values()).count(999) == 2, list(g.requests.values())  # one retry after the timeout
    assert 2589 not in list(g.requests.values())  # cached: no request
    assert db.meta.build == "1.60.1" and db.meta.input.n == 8 and db.meta.finished == 1794200000
    assert any("done: 6 resolved, 2 failed of 8" in p for p in g.printed.values()), list(g.printed.values())
    # Resumable: a second start has nothing to do.
    n_req = len(g.requests)
    slash("start")
    assert len(g.requests) == n_req and any("nothing to do" in p for p in g.printed.values())
    slash("reset confirm")
    assert len(list(g.ItemDataExportDB.results.keys())) == 0
    print("ItemDataExport harness: OK")


if __name__ == "__main__":
    main()
