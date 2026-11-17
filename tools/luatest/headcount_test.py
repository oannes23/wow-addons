"""Offline harness for Headcount (addons/Headcount/SPEC.md): census seeds from units, public chat and /who.

  uv run --no-project --with lupa python tools/luatest/headcount_test.py
"""
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "Headcount"

MOCK = r"""
now = 1795000000
function time() return now end
SECRET = {}
function issecretvalue(v) return v == SECRET end
printed = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end printed[#printed + 1] = table.concat(t, " ") end
UNITS = {
  player = { "Oannes", "Pazuzu", true },
  nameplate1 = { "Gromm", "Hellbark", true, "The Moles" },
  nameplate2 = { "Wolf", nil, false },            -- an NPC
  nameplate3 = { SECRET, SECRET, true },           -- identity restricted
  mouseover = { "Mira", "Dawnsong", true },
}
function UnitIsPlayer(u) return UNITS[u] and UNITS[u][3] or false end
function UnitName(u) local d = UNITS[u] if d then return d[1], d[2] end end
function GetGuildInfo(u) local d = UNITS[u] return d and d[4] end
WHO = {}
C_FriendList = { GetNumWhoResults = function() return #WHO, #WHO end, GetWhoInfo = function(i) return WHO[i] end }
EVENTS = {}
local handler
function CreateFrame() return { SetScript = function(_, _, f) handler = f end, RegisterEvent = function(_, e) EVENTS[e] = true end } end
function fire(e, ...) if EVENTS[e] then handler(nil, e, ...) end end
local loaded, login
EventUtil = { ContinueOnAddOnLoaded = function(_, f) loaded = f end, ContinueOnPlayerLogin = function(f) login = f end }
function boot() loaded() login() end
SlashCmdList = {}
"""


def runtime(sv=None):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    if sv:
        rt.execute(sv)
    ns = rt.table()
    toc = (ROOT / "Headcount_Forever.toc").read_text().replace("\\", "/")
    for f in [l.strip() for l in toc.splitlines() if l.strip() and not l.startswith("#")]:
        rt.execute("return loadstring(...)", (ROOT / f).read_text(), "@" + f)("Headcount", ns)
    rt.globals().boot()
    return rt, rt.globals(), ns


def main():
    rt, g, ns = runtime()
    H, db = ns.Headcount, g.HeadcountDB
    assert H.Full("Oannes", "Pazuzu") == "Oannes Pazuzu" and H.Full("Oannes-Pazuzu") == "Oannes Pazuzu"
    assert H.Full("Oannes Pazuzu") == "Oannes Pazuzu" and H.Full("Lonely") is None and H.Full(g.SECRET) is None
    assert H.me == "Oannes Pazuzu"
    for n in ("nameplate1", "nameplate2", "nameplate3", "player"):
        g.fire("NAME_PLATE_UNIT_ADDED", n)
    g.fire("UPDATE_MOUSEOVER_UNIT")
    names = dict(db.names.items())
    assert set(names) == {"Gromm Hellbark", "Mira Dawnsong"}, set(names)  # no NPC, no secret, not me
    assert names["Gromm Hellbark"].g == "The Moles" and names["Gromm Hellbark"].s == "np" and db.guilds["The Moles"] == g.now
    # Chat: sender only (arg 2); a sender without a surname or a secret one is skipped; the text is never stored.
    g.fire("CHAT_MSG_CHANNEL", "WTS [Linen Cloth]", "Seller Goldsworth")
    g.fire("CHAT_MSG_SAY", "hi", "Plainname")
    g.fire("CHAT_MSG_YELL", "hi", g.SECRET)
    assert db.names["Seller Goldsworth"].s == "ch" and db.names.Plainname is None
    assert "Linen" not in str(list(db.names.keys()))
    # /who rows carry guild, level and class.
    rt.execute('WHO = { { fullName = "Tusk Ironhide", fullGuildName = "Night Shift", level = 23, filename = "WARRIOR" },'
               '        { fullName = "Nosurname", level = 5 } }')
    g.fire("WHO_LIST_UPDATE")
    t = db.names["Tusk Ironhide"]
    assert (t.s, t.g, t.l, t.c) == ("who", "Night Shift", 23, "WARRIOR") and db.guilds["Night Shift"]
    # Pause, status, clear.
    g.SlashCmdList.HEADCOUNT("off")
    g.fire("UPDATE_MOUSEOVER_UNIT")
    g.UNITS.mouseover = rt.table_from({1: "New", 2: "Face", 3: True})
    g.fire("UPDATE_MOUSEOVER_UNIT")
    assert db.names["New Face"] is None and "paused" in g.printed[len(g.printed)]
    g.SlashCmdList.HEADCOUNT("on")
    assert "4 names, 2 guilds (np 1, mo 1, ch 1, who 1)" in g.printed[len(g.printed)], g.printed[len(g.printed)]
    # Cap: trims the oldest tenth when full.
    H.MAX_NAMES = 10
    for i in range(12):
        g.now = g.now + 1
        H.Note(f"Bulk Name{i:02d}", "np")
    n = sum(1 for _ in db.names.keys())
    assert n <= 10 and db.names["Bulk Name11"] and db.names["Gromm Hellbark"] is None, n
    g.SlashCmdList.HEADCOUNT("clear")
    assert next(iter(db.names.keys()), None) is None
    # Reload keeps the SavedVariables.
    rt2, g2, ns2 = runtime('HeadcountDB = { version = 1, enabled = true, names = { ["A B"] = { t = 1, s = "np" } }, guilds = {} }')
    assert "1 names, 0 guilds" in ns2.Headcount.StatusLine()
    print("Headcount harness: OK")


if __name__ == "__main__":
    main()
