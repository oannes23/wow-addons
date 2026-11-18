"""Offline harness for Headcount (addons/Headcount/SPEC.md): census seeds from units, public chat and /who.

  uv run --no-project --with lupa python tools/luatest/headcount_test.py
"""
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "Headcount"

MOCK = r"""
now = 1795000000
function time() return now end
-- A secret string: type() says "string" (as in game, so type checks don't shield it) and any use other than holding,
-- storing or issecretvalue() is an error. Lua 5.1 can't trap `secret == ""` (no __eq across types): the static check
-- in secret_order() covers comparisons.
SECRET = newproxy(true)
do
  local mt = getmetatable(SECRET)
  local function boom() error("attempt to use a secret value", 2) end
  for _, k in ipairs({ "__index", "__newindex", "__concat", "__len", "__lt", "__le", "__call", "__unm", "__add", "__sub",
                       "__mul", "__div", "__mod", "__pow", "__tostring" }) do mt[k] = boom end
end
local rawtype = type
function type(v) if rawequal(v, SECRET) then return "string" end return rawtype(v) end
function issecretvalue(v) return rawequal(v, SECRET) end
printed = {}
function print(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end printed[#printed + 1] = table.concat(t, " ") end
UNITS = {
  player = { "Oannes", "Pazuzu", true },
  nameplate1 = { "Gromm", "Hellbark", true, "The Moles" },
  nameplate2 = { "Wolf", nil, false },            -- an NPC
  nameplate3 = { SECRET, SECRET, true },           -- identity restricted
  nameplate4 = { "Kade", SECRET, true, SECRET },   -- surname and guild restricted
  nameplate5 = { "Tomas", "Reed", true, SECRET },  -- guild restricted only
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
    for n in ("nameplate1", "nameplate2", "nameplate3", "nameplate4", "player", g.SECRET):
        g.fire("NAME_PLATE_UNIT_ADDED", n)
    g.fire("UPDATE_MOUSEOVER_UNIT")
    names = dict(db.names.items())
    assert set(names) == {"Gromm Hellbark", "Mira Dawnsong"}, set(names)  # no NPC, no secret, not me
    assert names["Gromm Hellbark"].g == "The Moles" and names["Gromm Hellbark"].s == "np" and db.guilds["The Moles"] == g.now
    # Chat: sender only (arg 2); a sender without a surname or a secret one is skipped; the text is never stored.
    g.fire("CHAT_MSG_CHANNEL", "WTS [Linen Cloth]", "Seller Goldsworth")
    g.fire("CHAT_MSG_SAY", "hi", "Plainname")
    g.fire("CHAT_MSG_YELL", "hi", g.SECRET)
    g.fire("CHAT_MSG_SAY", g.SECRET, g.SECRET)
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
    secret_cases()
    secret_order()
    print("Headcount harness: OK")


def secret_cases():
    """Instance restrictions (Wailing Caverns, 2026-11-18): any field may be secret. Skip it, never error."""
    rt, g, ns = runtime()
    H, db = ns.Headcount, g.HeadcountDB
    g.fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
    assert db.names["Tomas Reed"].g is None                                     # name kept, secret guild dropped
    H.Note("Ann Lee", "who", g.SECRET, g.SECRET, g.SECRET)
    assert (db.names["Ann Lee"].g, db.names["Ann Lee"].l, db.names["Ann Lee"].c) == (None, None, None)
    H.NoteGuild(g.SECRET)
    assert next(iter(db.guilds.keys()), None) is None
    rt.execute("C_FriendList.GetNumWhoResults = function() return SECRET end"); g.fire("WHO_LIST_UPDATE")
    rt.execute('C_FriendList.GetNumWhoResults = function() return 2 end; WHO = { SECRET, '
               '{ fullName = SECRET, fullGuildName = SECRET, level = SECRET, filename = SECRET } }')
    g.fire("WHO_LIST_UPDATE")
    assert sorted(db.names.keys()) == ["Ann Lee", "Tomas Reed"]


def secret_order():
    """Static: the only comparisons with "" are the Str helper's (after its secret test) and the slash command's
    (typed text). 0.1.0 compared names before testing them and errored in Wailing Caverns."""
    src = (ROOT / "Core.lua").read_text().splitlines()
    bad = [(i + 1, l.strip()) for i, l in enumerate(src)
           if ('== ""' in l or '~= ""' in l) and not l.lstrip().startswith("--")
           and "if Secret(v) or type(v)" not in l and "msg ~= \"\"" not in l]
    assert not bad, bad


if __name__ == "__main__":
    main()
