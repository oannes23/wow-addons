"""Offline harness for addons/StraightHook: runs the addon in Lua 5.1 (lupa) against mocked WoW APIs.

  uv run --no-project --with lupa python tools/luatest/straighthook_test.py
Covers:
- sound focus engage/restore, including a crash/reload restore and the off switch;
- one outcome per cast (caught, escaped, missed, early, quick recast);
- the learned catch table with zone fallback;
- price lines;
- the bobber tooltip, by GUID and by learned name;
- the bite probe ranking;
- secret spell IDs ignored.
"""
from pathlib import Path

import lupa.lua51 as lua51

ROOT = Path(__file__).resolve().parents[2] / "addons" / "StraightHook"
FILES = ["Locales/enUS.lua", "Sound.lua", "Log.lua", "Info.lua", "Probe.lua", "Core.lua"]

MOCK = r"""
now = 100; printed = {}; timers = {}
format = string.format
function print(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring(select(i, ...)) end printed[#printed+1] = table.concat(t, " ") end
function said(pat) for _, p in ipairs(printed) do if p:find(pat, 1, true) then return true end end return false end
function GetTime() return now end
EventUtil = { ContinueOnAddOnLoaded = function(_, fn) fn() end }
C_Timer = { After = function(sec, fn) timers[#timers+1] = { at = now + sec, fn = fn } end }
function step(dt)
  local target = now + (dt or 0.1)
  while true do
    local best, bi
    for i, t in ipairs(timers) do if t.at <= target and (not best or t.at < best.at) then best, bi = t, i end end
    if not best then break end
    table.remove(timers, bi); now = best.at; best.fn()
  end
  now = target
end
SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end
PROFESSIONS_FISHING = "Fishing"; ERR_FISH_ESCAPED = "Your fish got away!"; ERR_FISH_NOT_HOOKED = "No fish are hooked."
cvars = { Sound_SFXVolume = "0.6", Sound_MusicVolume = "0.4", Sound_AmbienceVolume = "0.6", Sound_DialogVolume = "1.0",
          Sound_EnableSoundWhenGameIsInBG = "0" }
setCalls = 0
C_CVar = { GetCVar = function(n) return cvars[n] end, SetCVar = function(n, v) cvars[n] = v setCalls = setCalls + 1 return true end }
C_Spell = { GetSpellName = function(id) if id == 7620 then return "Fishing" elseif id == 133 then return "Fireball" end end }
mapID, zoneText, subText = 1434, "Stranglethorn Vale", "Booty Bay"
C_Map = { GetBestMapForUnit = function() return mapID end }
function GetRealZoneText() return zoneText end
function GetSubZoneText() return subText end
function GetProfessions() return 1, 2, nil, 5, 6 end
function GetProfessionInfo(i) if i == 5 then return "Fishing", 136245, 87, 150, 0, 0, 356, 25 end end
C_Item = { GetItemNameByID = function(id) return nil end }
loot = {}; fishingLoot = true
function IsFishingLoot() return fishingLoot end
function GetNumLootItems() return #loot end
function GetLootSlotLink(i) return loot[i].link end
function GetLootSlotInfo(i) local s = loot[i] return 1, s.name, s.qty, nil, 1, false, false, nil, true, s.coin end
-- Frames
frames = {}
local function Region() local r = {} setmetatable(r, { __index = function(t, k) return function() end end }) return r end
function CreateFrame()
  local f = { ev = {}, all = false, shown = true, points = {} }
  function f:RegisterEvent(e) self.ev[e] = true end
  function f:RegisterUnitEvent(e) self.ev[e] = true end
  function f:UnregisterEvent(e) self.ev[e] = nil end
  function f:RegisterAllEvents() self.all = true end
  function f:UnregisterAllEvents() self.all = false self.ev = {} end
  function f:SetScript(name, fn) self[name] = fn end
  function f:Show() self.shown = true end
  function f:Hide() self.shown = false end
  function f:IsShown() return self.shown end
  function f:SetPoint(...) self.points = { ... } end
  function f:GetPoint() return self.points[1], nil, self.points[3], self.points[4], self.points[5] end
  function f:ClearAllPoints() self.points = {} end
  function f:CreateTexture() return Region() end
  function f:CreateFontString()
    local fs = Region() fs.text = "" function fs:SetText(t) self.text = t end
    function fs:GetStringWidth() return 200 end function fs:GetStringHeight() return 60 end
    lastFont = fs return fs end
  setmetatable(f, { __index = function(t, k) return function() end end })
  frames[#frames+1] = f
  return f
end
UIParent = {}
function fire(e, ...) for _, f in ipairs(frames) do if (f.ev[e] or f.all) and f.OnEvent then f.OnEvent(f, e, ...) end end end
SlashCmdList = {}
-- Tooltips
postCalls = {}
Enum = { TooltipDataType = { Item = 0, Unit = 2, Object = 4 } }
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) postCalls[t] = fn end }
GameTooltip = { lines = {} }
function GameTooltip:AddLine(t) self.lines[#self.lines+1] = t end
function tipHas(pat) for _, l in ipairs(GameTooltip.lines) do if l:find(pat, 1, true) then return true end end return false end
-- Helpers
function cast(id) fire("UNIT_SPELLCAST_CHANNEL_START", "player", "guid", id or 7620) end
function stop(id) fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid", id or 7620) end
function catch(items) loot = items fire("LOOT_OPENED", false, false) end
"""

def load(rt, ns):
    for f in FILES:
        chunk = rt.execute("return loadstring(...)", (ROOT / f).read_text(), "@" + f)
        assert chunk is not None, f"syntax error in {f}"
        chunk("StraightHook", ns)


def runtime(prepare: str = ""):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(MOCK)
    if prepare:
        rt.execute(prepare)
    ns = rt.table()
    load(rt, ns)
    return rt, rt.globals(), ns


def main() -> None:
    rt, g, ns = runtime()
    db = g.StraightHookDB
    spot = lambda: db.spots["1434:Booty Bay"]  # noqa: E731

    # 1. A cast engages sound focus and shows the panel; the soft-interact GameObject is the bobber.
    g.cast()
    assert g.cvars.Sound_SFXVolume == "1.0" and g.cvars.Sound_MusicVolume == "0" and g.cvars.Sound_EnableSoundWhenGameIsInBG == "1"
    assert db.savedCVars.Sound_MusicVolume == "0.4" and db.savedCVars.Sound_SFXVolume == "0.6"
    assert ns.Info.panel.shown and spot().casts == 1
    bobber = "GameObject-0-3299-0-1434-35591-0000ABCDEF"
    g.fire("PLAYER_SOFT_INTERACT_CHANGED", None, bobber)
    assert ns.S.bobberGUID == bobber and db.bobber.entry == 35591

    # 2. Bite clicked: channel stops, fishing loot opens. Coins are not items.
    g.stop()
    g.catch(rt.eval('{ { link = "|cffffffff|Hitem:13754::::::::35:::::|h[Raw Glossy Mightfish]|h|r", name = "Raw Glossy Mightfish", qty = 1 },'
                    '  { link = nil, name = "2 Copper", qty = 0, coin = true } }'))
    g.step(1.1)
    assert spot().caught == 1 and spot()["items"][13754] == 1 and spot().missed == 0 and spot().loots == 1
    assert db.names[13754] == "Raw Glossy Mightfish"
    assert db.savedCVars is not None  # restore waits 8 s
    g.step(8)
    assert db.savedCVars is None and g.cvars.Sound_MusicVolume == "0.4" and g.cvars.Sound_SFXVolume == "0.6"
    assert g.cvars.Sound_EnableSoundWhenGameIsInBG == "0"
    g.step(20)
    assert not ns.Info.panel.shown  # auto-hide after fishing stops

    # 3. Escape, early click, missed, and a quick recast (the earlier cast settles as missed, no double count).
    g.cast(); g.fire("UI_ERROR_MESSAGE", 51, "No fish are hooked."); g.stop(); g.fire("UI_INFO_MESSAGE", 0, "Your fish got away!"); g.step(1.1)
    assert spot().escaped == 1 and spot().early == 1 and spot().casts == 2
    g.cast(); g.stop(); g.step(1.1)
    assert spot().missed == 1
    g.cast(); g.stop(); g.step(0.3); g.cast()  # recast inside FINISH_DELAY
    assert spot().missed == 2 and spot().casts == 5, (spot().missed, spot().casts)
    g.stop(); g.catch(rt.eval('{ { link = "|Hitem:13754|h", name = "Raw Glossy Mightfish", qty = 2 },'
                              '  { link = "|Hitem:6303|h", name = "Raw Slitherskin Mackerel", qty = 1 } }')); g.step(1.1)
    assert spot().caught == 2 and spot()["items"][13754] == 3 and spot()["items"][6303] == 1 and spot().missed == 2
    assert ns.Log.session.casts == 5 and ns.Log.session.units == 4
    # Sound stayed engaged across the quick recast; restored once fishing stops for good.
    g.step(9)
    assert db.savedCVars is None and g.cvars.Sound_SFXVolume == "0.6"

    # 4. Lines: location, skill, outcome stats, catch table, session.
    lines = list(ns.Info.Lines().values())
    text = "\n".join(lines)
    assert "Stranglethorn Vale – Booty Bay" in lines[0] and "Fishing 87/150 (+25)" in text
    assert "Here: 5 casts · 2 caught · 1 got away (33%) · 2 missed" in text, text
    assert " 75%  Raw Glossy Mightfish (3)" in text and " 25%  Raw Slitherskin Mackerel (1)" in text, text
    assert "Session: 5 casts · 4 fish" in text and "No AH values" in text

    # 5. Prices: per-item values at both houses and the expected value per catch (4 units over 2 loots).
    ns.PRICES = rt.eval('{ generated = "t", houses = { 114, 117 }, items = {'
                        ' [13754] = "105,119,584,47,230,10,24530,-5,2;998,1199,967,68,765,9,3460,40,2",'
                        ' [6303] = "27,35,5000,236,32,9,47440,0,2;24,25,303,32,,,,," } }')
    text = "\n".join(ns.Info.Lines().values())
    assert "Raw Glossy Mightfish (3)   H 2s 30c · B 7s 65c" in text, text
    assert "Raw Slitherskin Mackerel (1)   H 32c · B 25c" in text, text
    # per catch: H (3*230 + 1*32)/2 = 361c; B (3*765 + 1*25)/2 = 1160c
    assert "≈ per catch: H 3s 61c · B 11s 60c" in text, text
    g.SlashCmdList.STRAIGHTHOOK("house 117")
    text = "\n".join(ns.Info.Lines().values())
    assert "≈ per catch: B 11s 60c" in text and "H 3s" not in text
    g.SlashCmdList.STRAIGHTHOOK("house both")

    # 6. Bobber tooltip: by GUID (learns the name), then by the learned name on a later bobber.
    post = g.postCalls[4]
    g.cast(); g.fire("PLAYER_SOFT_INTERACT_CHANGED", None, bobber)
    post(g.GameTooltip, rt.eval('{ guid = "GameObject-0-3299-0-1434-35591-0000ABCDEF", lines = { { leftText = "Fishing Bobber" } } }'))
    assert g.tipHas("Raw Glossy Mightfish") and db.bobber.name == "Fishing Bobber"
    g.stop(); g.step(1.1)
    g.GameTooltip.lines = rt.table()
    post(g.GameTooltip, rt.eval('{ guid = "GameObject-0-1-0-1-35591-0000FFFF", lines = { { leftText = "Fishing Bobber" } } }'))
    assert g.tipHas("got away")
    g.GameTooltip.lines = rt.table()
    post(g.GameTooltip, rt.eval('{ guid = "GameObject-0-1-0-1-1731-0001", lines = { { leftText = "Copper Vein" } } }'))
    assert len(g.GameTooltip.lines) == 0  # other objects untouched
    post(g.GameTooltip, rt.eval('{ guid = SECRET, lines = { { leftText = SECRET } } }'))
    assert len(g.GameTooltip.lines) == 0

    # 7. A new subzone with no catches shows the zone totals.
    g.subText = "The Savage Coast"
    g.cast(); g.stop(); g.step(1.1)
    text = "\n".join(ns.Info.Lines().values())
    assert "Stranglethorn Vale – The Savage Coast" in text and "zone totals" in text and "Raw Glossy Mightfish (3)" in text, text
    assert db.spots["1434:The Savage Coast"].casts == 1
    g.subText = "Booty Bay"
    g.step(10)

    # 8. Not fishing: other channels and secret spell IDs are ignored.
    g.cast(133)
    assert not ns.S.fishing and db.savedCVars is None
    g.cast(g.SECRET)
    assert not ns.S.fishing

    # 9. Sound off: casting changes nothing.
    g.SlashCmdList.STRAIGHTHOOK("sound off")
    n = g.setCalls
    g.cast()
    assert g.setCalls == n and db.savedCVars is None
    g.stop(); g.step(10)
    g.SlashCmdList.STRAIGHTHOOK("sound on")

    # 10. Probe: an event that fires just before every click ranks first; baseline noise ranks low.
    g.SlashCmdList.STRAIGHTHOOK("probe on")
    for _ in range(3):
        g.cast()
        g.step(0.5); g.fire("BAG_UPDATE_DELAYED")         # baseline window
        g.step(4.0); g.fire("FAKE_BOBBER_SPLASH")          # the bite
        g.step(0.5); g.fire("PLAYER_SOFT_TARGET_INTERACTION")  # the click
        g.step(0.05); g.stop(); g.fire("LOOT_READY")
        g.catch(rt.eval('{ { link = "|Hitem:6303|h", name = "Raw Slitherskin Mackerel", qty = 1 } }'))
        g.step(1.1)
    rows, n = ns.Probe.Ranked()
    assert n == 3 and rows[1].name == "FAKE_BOBBER_SPLASH" and rows[1].pre == 1 and rows[1].base == 0, (rows[1].name, n)
    names = [r.name for r in rows.values()]
    assert "LOOT_READY" not in names and "UNIT_SPELLCAST_CHANNEL_STOP" not in names, names  # after the click: excluded
    tl = db.probe.timelines[1]
    evs = list(tl.events.values())
    assert tl.outcome == "caught" and any(e.endswith("FAKE_BOBBER_SPLASH") and e.startswith("-0.5") for e in evs), evs
    g.printed = rt.table()
    g.SlashCmdList.STRAIGHTHOOK("probe report")
    assert g.said("FAKE_BOBBER_SPLASH") and g.said("100% /   0%")
    assert not any(f.all for f in g.frames.values())  # RegisterAllEvents released after each cast
    g.step(10)

    # 11. Crash or /reload mid-cast: the next load restores the saved volumes.
    _, g2, _ = runtime('''StraightHookDB = { sound = true, savedCVars = { Sound_MusicVolume = "0.4", Sound_SFXVolume = "0.6" } }
      cvars.Sound_MusicVolume = "0"; cvars.Sound_SFXVolume = "1.0"''')
    assert g2.cvars.Sound_MusicVolume == "0.4" and g2.cvars.Sound_SFXVolume == "0.6" and g2.StraightHookDB.savedCVars is None

    # 12. Slash status and forget.
    g.printed = rt.table()
    g.SlashCmdList.STRAIGHTHOOK("")
    assert g.said("sound focus on") and g.said("spots logged")
    g.SlashCmdList.STRAIGHTHOOK("forget here")
    assert db.spots["1434:Booty Bay"] is None
    seed_test()
    print("StraightHook harness: OK")


def seed_test() -> None:
    """Classic prior (SPEC D-006): lookup by the client's area names, skill threshold, prior table, divergence flags."""
    rt, g, ns = runtime('''
      C_Map.GetAreaInfo = function(id) return ({ [1637] = "Orgrimmar", [14] = "Durotar" })[id] end
      ITEMNAMES = { [6289] = "Raw Longjaw Mud Snapper", [6308] = "Raw Bristle Whisker Catfish", [6291] = "Raw Brilliant Smallfish",
                    [13755] = "Winter Squid" }
      C_Item.GetItemNameByID = function(id) return ITEMNAMES[id] end
      mapID, zoneText, subText = 1454, "Orgrimmar", "Valley of Honor"''')
    ns.SEED = rt.eval('{ areas = { [1637] = { base = -20, loot = { {6289, 49.95, 1}, {6308, 30, 1}, {6291, 18, 1},'
                      ' {13755, 10, 0, "seasonal"} } }, [14] = { base = -70, loot = { {6303, 98, 1} } } } }')
    assert ns.Info.Differs(0, 15, 0.3) and not ns.Info.Differs(3, 15, 0.3) and not ns.Info.Differs(0, 5, 0.3)
    assert ns.Info.Differs(10, 100, 0.3) and not ns.Info.Differs(28, 100, 0.3)
    pr = ns.Info.Prior("Orgrimmar", "Valley of Honor")
    assert pr.area == 1637 and pr.base == -20
    text = "\n".join(ns.Info.Lines().values())
    assert "Fishing 87/150 (+25) · no getaways at 75 (Classic)" in text, text
    assert "Classic table (vanilla; Forever may differ)" in text and " 50%  Raw Longjaw Mud Snapper" in text, text
    assert "Winter Squid |cff999999(seasonal)" in text
    # 15 catches: 13 snapper, 2 smallfish, no catfish -> own table leads, catfish flagged.
    for i in range(15):
        g.cast(); g.stop()
        item = "6291" if i < 2 else "6289"
        g.catch(rt.eval('{ { link = "|Hitem:%s|h", name = ITEMNAMES[%s], qty = 1 } }' % (item, item)))
        g.step(1.1)
    text = "\n".join(ns.Info.Lines().values())
    assert " 87%  Raw Longjaw Mud Snapper (13) · Classic 50% |cffffcc00≠" in text, text
    assert "Raw Brilliant Smallfish (2) · Classic 18%" in text
    assert "0%  Raw Bristle Whisker Catfish · Classic 30%" in text and "none in 15" in text, text
    assert "Classic table" not in text  # own data leads now
    g.subText, g.zoneText = "", "Durotar"
    text = "\n".join(ns.Info.Lines().values())
    assert "no getaways at 25" in text and "item 6303" in text, text


if __name__ == "__main__":
    main()
