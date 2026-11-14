"""Steals harness for addons/Wuwei (Steals.lua, SPEC D-033 to D-040).

  uv run --no-project --with lupa python tools/luatest/wuwei_steals_test.py
Reuses the Phase 1/2 mocks and adds a fake browse backend: SearchForItemKeys / SendBrowseQuery answer with
BrowseResultInfo rows built from LIVE listings, synchronously (inside the call, as SynchronousEvent allows), deferred,
or never. Covers: absent `steals` is a no-op, the scan stays inside the shared throttle and its per-scan cap, rotation,
alerts only at or below buyMax, removal of sold/repriced items, keys -> class fallback, paging, stopping when the
player browses, passive harvest, panel rows + Search hand-off, tooltip precedence, slash/settings, and that no
restricted (or whole-house) API is ever called.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402
import wuwei_phase2_test as p2  # noqa: E402

ROOT = p1.ROOT


def strip(s):
    """Colours and hyperlink wrappers off: `|cff..|Hitem:..|h[Name]|h|r` -> `[Name]`."""
    return re.sub(r"\|H[^|]*\|h(.*?)\|h", r"\1", p1.strip_colors(s))

STEALS_EXTRA = r"""
aq = {}; forbidden = {}; sounds = {}
keysWork = true; keysExact = false; respond = "sync"; full = true; ready = true; moreRows = nil; pending = nil
ILVL = { [12784] = 63 }   -- item levels the client has cached (C_Item.GetItemInfo return 4)
browseResults = {}
-- LIVE[itemID] = { {minPrice, itemLevel}, ... } : what the house lists right now. CLASS[itemID] = {classID, subclassID}
LIVE = {}
CLASS = { [13518] = { 9, 2 }, [8485] = { 15, 2 }, [13335] = { 15, 5 }, [12784] = { 2, 1 } }
COMMOD = {}
Enum.AuctionHouseFilter = { None = 0, UncollectedOnly = 1, UsableOnly = 2, PoorQuality = 6, CommonQuality = 7,
  UncommonQuality = 8, RareQuality = 9, EpicQuality = 10, LegendaryQuality = 11, ArtifactQuality = 12 }
Enum.AuctionHouseSortOrder = { Price = 0, Name = 1 }
AuctionHouseSearchContext.AllFavorites = 3; AuctionHouseSearchContext.AllAuctions = 4
local function rowsFor(pred)
  local out = {}
  for id, ls in pairs(LIVE) do
    if pred(id) then
      for _, l in ipairs(ls) do
        out[#out+1] = { itemKey = { itemID = id, itemLevel = l[2] or 0, itemSuffix = 0, battlePetSpeciesID = 0 },
                        minPrice = l[1], totalQuantity = 1, containsOwnerItem = false }
      end
    end
  end
  table.sort(out, function(a, b) return a.minPrice < b.minPrice end)
  return out
end
local function deliver(rows)
  if respond == "sync" then
    browseResults = rows
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); fire("AUCTION_HOUSE_NEW_RESULTS_RECEIVED", nil)
  elseif respond == "defer" then pending = rows
  elseif respond == "fail" then fire("AUCTION_HOUSE_BROWSE_FAILURE") end
end
function flush() if pending then browseResults = pending; pending = nil; fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end end
-- keysExact: a server that matches gear only on the exact item level (an ilvl-0 key then misses ilvl'd listings).
C_AuctionHouse.SearchForItemKeys = function(keys, sorts)
  local set, ids = {}, {}
  for _, k in ipairs(keys) do
    set[k.itemID] = set[k.itemID] or {}
    set[k.itemID][k.itemLevel or 0] = true
    if not ids[k.itemID] then ids[k.itemID] = true; ids[#ids+1] = k.itemID end
  end
  aq[#aq+1] = { kind = "keys", n = #keys, nitems = #ids, first = keys[1].itemID, sentKeys = keys, sorts = sorts, t = now }
  if keysWork then
    local rows = rowsFor(function(id) return set[id] ~= nil end)
    if keysExact then
      local keep = {}
      for _, r in ipairs(rows) do if set[r.itemKey.itemID][r.itemKey.itemLevel] then keep[#keep+1] = r end end
      rows = keep
    end
    deliver(rows)
  end
end
C_AuctionHouse.SendBrowseQuery = function(q)
  local f = q.itemClassFilters and q.itemClassFilters[1]
  aq[#aq+1] = { kind = q.searchString ~= "" and "name" or "class", q = q, t = now }
  deliver(rowsFor(function(id)
    local c = CLASS[id]
    if f and not (c and c[1] == f.classID and (f.subClassID == nil or c[2] == f.subClassID)) then return false end
    return q.searchString == "" or (NAMES[id] and NAMES[id]:find(q.searchString, 1, true) ~= nil)
  end))
end
C_AuctionHouse.GetBrowseResults = function() return browseResults end
C_AuctionHouse.HasFullBrowseResults = function() return full end
C_AuctionHouse.RequestMoreBrowseResults = function()
  aq[#aq+1] = { kind = "more", t = now }
  full = true
  if moreRows then fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", moreRows) end
end
C_AuctionHouse.IsThrottledMessageSystemReady = function() return ready end
C_AuctionHouse.GetItemKeyInfo = function(key) return { isCommodity = COMMOD[key.itemID] or false } end
C_AuctionHouse.MakeItemKey = function(id, ilvl, suffix, species)
  return { itemID = id, itemLevel = ilvl or 0, itemSuffix = suffix or 0, battlePetSpeciesID = species or 0 }
end
for _, n in ipairs({ "PostItem", "PostCommodity", "ConfirmPostItem", "ConfirmPostCommodity", "PlaceBid", "CancelAuction",
    "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase", "SendSearchQuery",
    "SendSellSearchQuery", "ReplicateItems", "StartItemBuyout" }) do
  C_AuctionHouse[n] = function() forbidden[#forbidden+1] = n end
end
C_Sound = { PlaySound = function(k) sounds[#sounds+1] = k end }
SOUNDKIT = { MAP_PING = 3175 }
C_Item.GetItemInfo = function(id)
  local n = NAMES[id]
  return n, n and ("|cffa335ee|Hitem:" .. id .. "::::::::60:::::|h[" .. n .. "]|h|r"), 1, ILVL[id] or 0, 1, "t", "s", 20, "", 0,
    SELL and SELL[id]
end
function mkAH4()
  local ah = mkAH2()
  ah.queried, ah.selected, ah.browsed = {}, {}, {}
  function ah:QueryItem(ctx, key) self.queried[#self.queried+1] = { ctx = ctx, key = key } end
  function ah:SelectBrowseResult(r) self.selected[#self.selected+1] = r end
  function ah:SendBrowseQuery(s) self:SendBrowseQueryInternal(0, s) end
  function ah:SendBrowseQueryInternal(ctx, s) self.browsed[#self.browsed+1] = s end
  function ah:QueryAll(ctx) end
  function ah:SetSearchText() end
  return ah
end
"""


def boot(plan_lua=None):
    rt, ns = p1.boot(extra=p2.EXTRA + STEALS_EXTRA)
    g = rt.globals()
    if plan_lua:
        ns.PLAN = rt.eval(plan_lua)
    g.mkAH4()
    g.fire("AUCTION_HOUSE_SHOW")
    return rt, ns, g


def live(rt, g, **kw):
    """live(rt, g, i13518=[(200000,)], ...) sets LIVE listings."""
    t = rt.eval("{}")
    for k, rows in kw.items():
        t[int(k[1:])] = rt.eval("{" + ",".join("{%d,%d}" % (r[0], r[1] if len(r) > 1 else 0) for r in rows) + "}")
    g.LIVE = t


def qs(g):
    return [q.kind for q in g.aq.values()]


def out(g, since=0):
    return "\n".join(strip(x) for x in list(g.printed.values())[since:])


def run(g, ns, step=0.6, limit=2000):
    """Drive the ticker until the scan ends (the real client calls Tick from OnUpdate)."""
    n = 0
    while ns.Steals.state.active and n < limit:
        g.now += step
        ns.Steals.Tick()
        n += 1
    assert not ns.Steals.state.active, "scan never ended"


def found_ids(ns):
    return sorted(int(k) for k in ns.Steals.found.keys())


def no_forbidden(g):
    assert len(g.forbidden) == 0, list(g.forbidden.values())


def test_absent_steals_is_noop():
    # An older generated plan without `steals`: the feature is silently off even though the builtin sample has one.
    rt, ns, g = boot('{ generated = "2026-11-09T07:00:00Z", houses = { [114] = "Horde" }, items = {} }')
    S = ns.Steals
    assert S.Data() is None and not S.On() and S.Count() == 0
    f = ns.Panel.frame
    assert f.steals.text == "" and not f.scan.shown
    before = len(g.printed)
    assert S.Scan() is False and "No steals list in the current plan." in out(g, before)
    live(rt, g, i13518=[(1,)])
    g.browseResults = rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 1 } }")
    g.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")                    # passive harvest: nothing to match
    assert found_ids(ns) == [] and len(g.sounds) == 0 and len(g.aq) == 0
    assert ns.Tooltip.Line(13518) is None
    assert len(list(S.Rows().values())) == 0
    g.SlashCmdList["WUWEI"]("status")
    assert "steals: no list in the current plan" in out(g)
    no_forbidden(g)


def test_scan_keys_path_alerts_and_panel():
    rt, ns, g = boot()
    S = ns.Steals
    f = ns.Panel.frame
    assert S.Count() == 4 and f.scan.shown and f.steals.text == "Steals: 4 watched · Scan steals to check"
    # 13518 at exactly buyMax (alert), 8485 one copper over (no alert), 13335 not listed, 12784 (gear) under buyMax at ilvl 63
    live(rt, g, i13518=[(225000,), (300000,)], i8485=[(60001,)], i12784=[(900000, 63)])
    before = len(g.printed)
    stamps0 = len(ns.Throttle.stamps)
    assert S.Scan() is True
    # One keys query inside the click, answered synchronously: 4 items, 5 keys (the gear item adds its ilvl-63 key)
    assert qs(g) == ["keys"] and g.aq[1].nitems == 4 and g.aq[1].n == 5 and g.aq[1].sorts[1].sortOrder == 0
    gk = [(k.itemID, k.itemLevel or 0) for k in g.aq[1].sentKeys.values() if k.itemID == 12784]
    assert gk == [(12784, 0), (12784, 63)], gk
    run(g, ns)
    assert qs(g) == ["keys"], qs(g)
    assert len(ns.Throttle.stamps) == stamps0 + 1                          # took a shared throttle token
    assert found_ids(ns) == [12784, 13518] and S.keysOK is True
    o = out(g, before)
    assert "STEAL [Recipe: Sample] listed at 22g 50s · fair 45g (50%) · alert ≤ 22g 50s" in o, o
    assert "STEAL [Arcanite Reaper] listed at 90g · fair 200g (45%) · alert ≤ 110g" in o
    assert "Cat Carrier" not in o                                          # 1c over buyMax: silent
    assert "Steals scan: 2 found · queries: 1." in o
    assert S.state.result == "done" and S.cursor is None                  # whole list covered: next scan starts at the top
    assert list(g.sounds.values()) == [3175]                               # one sound for both (10 s gap)
    # Panel: two STEAL rows on top (deepest discount first), then the plays; status line updated
    assert strip(f.steals.text) == "Steals: 2 found · scanned 0m ago · queries: 1", f.steals.text
    rows = [(strip(f.rows[i].signal.text), strip(f.rows[i].name.text), strip(f.rows[i].rule.text), strip(f.rows[i].gain.text))
            for i in range(1, 16) if f.rows[i].shown]
    assert rows[0] == ("STEAL", "Arcanite Reaper", "90g · 45% of fair 200g", "+110g"), rows[0]
    assert rows[1] == ("STEAL", "Recipe: Sample", "22g 50s · 50% of fair 45g", "+22g"), rows[1]
    assert rows[2][0] != "STEAL" and len(rows) == 2 + 5                     # shuttle off: 5 plays below
    # Search hand-off with the reply's item key (ilvl 63) and the live price; buying stays in Blizzard's UI
    ah = g.AuctionHouseFrame
    f.rows[1].button.scripts.OnClick(f.rows[1].button)
    assert ah.queried[1].key.itemID == 12784 and ah.queried[1].key.itemLevel == 63 and ah.queried[1].ctx == 20
    assert ah.selected[1].minPrice == 900000
    # Tooltip shows the live price for a found watched item
    assert strip(ns.Tooltip.Line(13518)) == "Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · live 22g 50s · 42m"
    # A rescan sees no change: no repeat announcement, no second sound inside 10 s
    before = len(g.printed)
    S.Scan(); run(g, ns)
    assert "STEAL [" not in out(g, before) and len(g.sounds) == 1
    # A server that matches gear only on the exact item level: found while the ilvl is cached, missed without it
    g.keysExact = True
    S.Scan(); run(g, ns); assert 12784 in found_ids(ns)
    g.ILVL[12784] = None
    S.Scan(); run(g, ns); assert 12784 not in found_ids(ns)                # [TODO-INGAME] checklist 30
    no_forbidden(g)


def test_threshold_and_removal():
    rt, ns, g = boot()
    S = ns.Steals
    live(rt, g, i13518=[(225001,)])
    S.Scan(); run(g, ns)
    assert found_ids(ns) == []                                             # 1c over: not a steal
    live(rt, g, i13518=[(200000,)])
    before = len(g.printed); S.Scan(); run(g, ns)
    assert found_ids(ns) == [13518] and out(g, before).count("STEAL [Recipe: Sample]") == 1
    live(rt, g, i13518=[(230000,)])                                        # repriced above buyMax: row goes
    S.Scan(); run(g, ns)
    assert found_ids(ns) == []
    live(rt, g, i13518=[(210000,)])                                        # back, but dearer than announced: no repeat
    before = len(g.printed); S.Scan(); run(g, ns)
    assert found_ids(ns) == [13518] and "STEAL [" not in out(g, before)
    live(rt, g)                                                            # bought: complete reply lacks it -> removed
    S.Scan(); run(g, ns)
    assert found_ids(ns) == []
    g.full = False                                                         # incomplete reply: unknown, but paged
    g.moreRows = rt.eval("{ { itemKey = { itemID = 13335 }, minPrice = 4000000 } }")
    live(rt, g, i13518=[(150000,)])
    before = len(g.printed); S.Scan(); run(g, ns)
    assert "more" in qs(g) and found_ids(ns) == [13335, 13518], (qs(g), found_ids(ns))
    assert "STEAL [Recipe: Sample] listed at 15g" in out(g, before)        # cheaper than announced: announced again
    # Closing the AH clears what was found; reopening starts clean
    g.fire("AUCTION_HOUSE_CLOSED"); assert found_ids(ns) == []
    g.fire("AUCTION_HOUSE_SHOW"); assert ns.Panel.frame.steals.text.startswith("Steals: 4 watched")
    no_forbidden(g)


def big_plan(n_plain=300, n_gear=60):
    items = []
    for i in range(n_plain):
        items.append("[%d] = { fair = 100000, buyMax = 50000, n = 5, kind = 'recipe', classID = 9, subclassID = %d }" % (300000 + i, i % 12))
    for i in range(n_gear):
        items.append("[%d] = { fair = 900000, buyMax = 400000, n = 4, kind = 'rare', classID = 4, subclassID = %d }" % (400000 + i, 1 + i % 4))
    return ('{ generated = "2026-11-09T07:00:00Z", houses = { [114] = "Horde" }, items = {}, steals = { generated = '
            '"2026-11-09T07:00:00Z", house = 114, items = { ' + ", ".join(items) + " } } }")


def max_in_window(times, window=60.0):
    times = sorted(times)
    best, j = 0, 0
    for i, t in enumerate(times):
        while t - times[j] >= window:
            j += 1
        best = max(best, i - j + 1)
    return best


def test_budget_rotation_and_throttle():
    rt, ns, g = boot(big_plan())
    for i in range(60):
        g.NAMES[400000 + i] = "Gear Item %02d" % i
    S = ns.Steals
    # Keys mode: 300 plain + 60 gear (no ilvl cached: one key each) = 360 keys in chunks of 25, one scan
    jobs = list(S.BuildJobs().values())
    assert len(jobs) == 15 and all(len(j["keys"]) <= 25 for j in jobs), len(jobs)
    S.Scan(); run(g, ns)
    assert qs(g) == ["keys"] * 15 and S.state.result == "done"
    for i in range(60):
        g.ILVL[400000 + i] = 40                                             # ilvl cached: gear contributes 2 keys
    assert len(list(S.BuildJobs().values())) == 12 + 5                  # gear pairs: 12 items (24 keys) per chunk
    # Fallback mode (keys mute this session): 12 class groups + 60 gear name searches = 72 jobs, over several clicks
    g.now += 61; g.aq = rt.eval("{}")
    S.keysOK = False
    jobs = list(S.BuildJobs().values())
    assert len(jobs) == 12 + 60 and [j.kind for j in jobs][:13] == ["class"] * 12 + ["name"]
    before = len(g.printed)
    S.Scan(); run(g, ns)
    assert S.state.sent == 40 and len(g.aq) == 40 and S.state.result == "budget"   # per-scan cap
    assert "partial: search budget" in out(g, before)
    first_scan_last = g.aq[40]
    assert first_scan_last.kind == "name" and first_scan_last.q.searchString == "Gear Item 27"
    # Immediately again: limited by the reserve, not the cap (90 - 40 = 50 free; stops below 30)
    S.Scan(); run(g, ns)
    assert len(g.aq) == 40 + 21, len(g.aq)
    assert g.aq[41].q.searchString == "Gear Item 28"                          # rotation: resumes where it stopped
    assert ns.Throttle.Free() == 29
    times = [q.t for q in g.aq.values()]
    assert max_in_window(times) <= 90 - 29 and max_in_window(times) <= 100
    # The player's own Search still has room inside the shared quota
    ok, how = ns.Panel.Search(4338)
    assert ok, how
    # A minute later: the rest of the list (11 jobs), then it wraps to the top until the cap; the cursor marks job 30
    g.now += 61
    S.Scan(); run(g, ns)
    assert len(g.aq) == 61 + 40 and g.aq[62].q.searchString == "Gear Item 49" and g.aq[73].kind == "class"
    assert S.state.result == "budget" and S.cursor == "name:400017", (S.state.result, S.cursor)
    covered = set()
    for q in g.aq.values():
        covered.add(q.q.searchString if q.kind == "name" else ("class", q.q.itemClassFilters[1].subClassID))
    assert len([c for c in covered if isinstance(c, str) and c.startswith("Gear")]) == 60
    assert len([c for c in covered if isinstance(c, tuple)]) == 12
    nq = next(q.q for q in g.aq.values() if q.kind == "name")
    assert nq.itemClassFilters[1].classID == 4 and list(nq.filters.values()) == [6, 7, 8, 9, 10, 11, 12]  # default filters
    assert max_in_window([q.t for q in g.aq.values()]) <= 90
    # Throttle already busy (player clicked Search a lot): the scan sends nothing and says so
    g.now += 61
    for _ in range(65):
        ns.Throttle.Take()
    n = len(g.aq); before = len(g.printed)
    S.Scan(); run(g, ns)
    assert len(g.aq) == n and "partial: search budget" in out(g, before)
    # Not ready (Blizzard's throttled-message system busy): waits, then gives up without sending
    g.now += 61; g.ready = False; n = len(g.aq)
    S.Scan(); run(g, ns)
    assert len(g.aq) == n and S.state.result == "budget"
    no_forbidden(g)


def test_keys_fallback_to_class_browse():
    rt, ns, g = boot()
    S = ns.Steals
    g.keysWork = False                                                     # SearchForItemKeys never answers on this client
    live(rt, g, i13518=[(100000,)], i13335=[(4500000,)])
    before = len(g.printed)
    S.Scan()
    assert qs(g) == ["keys"]
    g.now += S.TIMEOUT - 1; S.Tick(); assert qs(g) == ["keys"]              # still waiting
    run(g, ns)
    assert S.keysOK is False and "using category and name browse" in out(g, before)
    assert qs(g) == ["keys", "class", "class", "class", "name"], qs(g)
    cls = sorted((q.q.itemClassFilters[1].classID, q.q.itemClassFilters[1].subClassID) for q in g.aq.values() if q.kind == "class")
    assert cls == [(9, 2), (15, 2), (15, 5)]
    nq = g.aq[5].q
    assert nq.searchString == "Arcanite Reaper" and nq.itemClassFilters[1].classID == 2 and nq.itemClassFilters[1].subClassID == 1
    assert found_ids(ns) == [13335, 13518]
    S.Scan(); run(g, ns)                                                   # the session remembers: no keys query again
    assert qs(g)[5:] == ["class", "class", "class", "name"]
    no_forbidden(g)


def test_deferred_replies_and_player_browse_stops():
    rt, ns, g = boot()
    S = ns.Steals
    g.respond = "defer"
    live(rt, g, i13518=[(100000,)])
    S.Scan()
    assert S.state.awaiting and qs(g) == ["keys"]
    g.now += 1; S.Tick(); assert qs(g) == ["keys"]                         # one in flight, nothing more
    g.flush(); g.now += 1; S.Tick()
    assert qs(g) == ["keys"] and found_ids(ns) == [13518] and not S.state.active
    # The player searches mid-scan: we stop and leave their results alone
    ah = g.AuctionHouseFrame
    S.Scan(); assert S.state.active and S.state.awaiting
    before = len(g.printed)
    ah.SendBrowseQueryInternal(ah, 1, "Linen")
    assert not S.state.active and "stopped because you searched" in out(g, before)
    n = len(g.aq); g.flush(); g.now += 10; S.Tick(); assert len(g.aq) == n
    # Favorites search stops a scan too; owned-auctions QueryAll doesn't
    S.Scan(); ah.QueryAll(ah, 4); assert S.state.active
    ah.QueryAll(ah, 3); assert not S.state.active
    # Closing the AH stops it
    S.Scan(); g.fire("AUCTION_HOUSE_CLOSED"); assert not S.state.active
    no_forbidden(g)


def test_passive_harvest_and_sound_toggle():
    rt, ns, g = boot()
    rows = rt.eval("{ { itemKey = { itemID = 8485 }, minPrice = 50000 }, { itemKey = { itemID = 2589 }, minPrice = 1 } }")
    n = len(g.aq); before = len(g.printed)
    g.browseResults = rows
    g.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")                         # the player browsed Companion Pets
    assert found_ids(ns) == [8485] and len(g.aq) == n                       # no query from an event
    assert out(g, before).count("STEAL [Cat Carrier (Bombay)] listed at 5g") == 1 and len(g.sounds) == 1
    g.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert out(g, before).count("STEAL [") == 1 and len(g.sounds) == 1
    g.SlashCmdList["WUWEI"]("steals sound off")
    assert g.WuweiDB.stealsSound is False
    g.now += 30
    g.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 1000 } }"))
    assert found_ids(ns) == [8485, 13518] and len(g.sounds) == 1           # announced, silently
    g.SlashCmdList["WUWEI"]("steals sound"); assert g.WuweiDB.stealsSound is True
    no_forbidden(g)


def test_tooltip_precedence_house_and_slash():
    rt, ns, g = boot()
    S, slash = ns.Steals, g.SlashCmdList["WUWEI"]
    assert strip(ns.Tooltip.Line(13518)) == "Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · 42m"
    assert "|cffff66cc" in ns.Tooltip.Line(13518)
    # Plan line wins when an item is in both
    ns.PLAN = rt.eval('{ generated = "2026-11-09T07:00:00Z", items = { [13518] = { ref = { [114] = 400000 }, signal = "HOLD" } },'
                      ' steals = { generated = "2026-11-09T07:00:00Z", house = 114, items = {'
                      ' [13518] = { fair = 450000, buyMax = 225000, n = 6, classID = 9, subclassID = 2 },'
                      ' [8485] = { fair = 120000, buyMax = 60000, n = 9, classID = 15, subclassID = 2 } } } }')
    assert strip(ns.Tooltip.Line(13518)) == "Wuwei: HOLD ref 40g · 42m"
    assert strip(ns.Tooltip.Line(8485)).startswith("Wuwei: STEAL ≤ 6g")
    # At another house: the line says whose fair value it is, and the scan refuses
    g.zone = "Everlook"
    assert strip(ns.Tooltip.Line(8485)) == "Wuwei: STEAL ≤ 6g · fair 12g (n 9) · (114) · 42m"
    before = len(g.printed)
    assert S.Scan() is False and "steals list is for house 114; you are at 117" in out(g, before) and len(g.aq) == 0
    g.zone = "Orgrimmar"
    # Settings
    assert g.WuweiDB.steals is True and g.WuweiDB.stealsSound is True
    slash("steals off")
    assert g.WuweiDB.steals is False and ns.Tooltip.Line(8485) is None
    assert ns.Panel.frame.steals.text == "" and not ns.Panel.frame.scan.shown
    before = len(g.printed)
    assert S.Scan() is False and "Steals are off" in out(g, before)
    slash("steals on"); assert g.WuweiDB.steals is True and ns.Panel.frame.scan.shown
    before = len(g.printed); slash("steals")
    assert "steals: on · 2 watched (house 114, 42m old) · sound on" in out(g, before), out(g, before)
    before = len(g.printed); slash("steals bogus"); assert "usage: /wuwei steals" in out(g, before)
    slash("steals scan"); assert len(g.aq) == 1                             # scan via slash
    run(g, ns)
    slash("toggle")                                                        # master switch stops a scan and hides it all
    assert not S.On() and ns.Tooltip.Line(8485) is None
    slash("toggle")
    g.AuctionHouseFrame.shown = False
    before = len(g.printed); slash("steals scan"); assert "Open the auction house first." in out(g, before)
    before = len(g.printed); slash("bogus"); assert "steals [on|off|scan|sound]" in out(g, before)
    before = len(g.printed); slash("status"); assert "steals: on · 2 watched" in out(g, before)
    no_forbidden(g)


def test_api_errors_do_not_break():
    rt, ns, g = boot()
    S = ns.Steals
    rt.execute('C_AuctionHouse.SearchForItemKeys = function() error("nope") end')
    S.Scan(); run(g, ns)                                                   # error on keys -> class fallback, no Lua error
    assert S.keysOK is False and S.state.errors >= 1 and "class" in qs(g)
    g.fire("AUCTION_HOUSE_BROWSE_FAILURE")                                 # stray failure: harmless
    # A failed reply never removes what an earlier reply found, and the scan still ends
    live(rt, g, i13518=[(100000,)])
    S.Scan(); run(g, ns); assert 13518 in found_ids(ns)
    g.respond = "fail"
    S.Scan(); run(g, ns)
    assert 13518 in found_ids(ns) and S.state.result == "done" and "more" not in qs(g)
    no_forbidden(g)


FORBIDDEN = re.compile(
    r"C_AuctionHouse\s*[.:]\s*(PostItem|PostCommodity|ConfirmPost\w*|PlaceBid|StartCommoditiesPurchase|ConfirmCommoditiesPurchase|"
    r"CancelCommoditiesPurchase|CancelAuction|CancelSell|StartItemBuyout|SendSearchQuery|SendSellSearchQuery|ReplicateItems)\b|"
    r"[:.]\s*(PostItem|PostCommodity|ConfirmPost|StartPost|StartItemBuyout|Click)\s*\(|HasRestrictions|hooksecurefunc\s*\(\s*C_AuctionHouse")


def test_grep_safety():
    src = (ROOT / "Steals.lua").read_text().splitlines()
    for n, line in enumerate(src, 1):
        code = line.split("--", 1)[0]
        assert not FORBIDDEN.search(code), f"Steals.lua:{n}: {line.strip()}"
    # Event handlers never send: after `local H = {}` nothing reaches Send/Tick/Scan or the query APIs.
    h = next(i for i, l in enumerate(src, 1) if l.startswith("local H = {}"))
    for n, line in enumerate(src[h:], h + 1):
        code = line.split("--", 1)[0]
        assert not re.search(r"\b(Send|Steals\.Tick|Steals\.Scan|SearchForItemKeys|SendBrowseQuery|RequestMoreBrowseResults)\s*\(", code), \
            f"Steals.lua:{n}: event-side code sends a query: {line.strip()}"
    # Keys.lua gained nothing for steals (D-038), and Bindings.xml is unchanged
    assert "Steals" not in (ROOT / "Keys.lua").read_text()
    assert (ROOT / "Bindings.xml").read_text().count("<Binding ") == 2
    # Every chat message goes through ns.L
    for n, line in enumerate(src, 1):
        code = line.split("--", 1)[0]
        if re.search(r"\bSay\(", code) and not re.match(r"\s*local function Say", code):
            assert "L[" in code or "StatusLine()" in code or "st)" in code, f"Steals.lua:{n}: message without ns.L"
    assert "Steals.lua" in p1.toc_files()


def smoke_generated_plan():
    if not (ROOT / "Data/Plan.lua").exists():
        return "generated plan: skipped (none)"
    rt, ns = p1.boot(use_generated_plan=True, extra=p2.EXTRA + STEALS_EXTRA)
    S = ns.Steals
    if S.Data() is None:
        return "generated plan: no steals block (feature off)"
    jobs = list(S.BuildJobs().values())
    kinds = {}
    for j in jobs:
        kinds[j.kind] = kinds.get(j.kind, 0) + 1
    return f"generated plan: {S.Count()} steals, {len(jobs)} jobs {kinds}, house {S.Data().house}"


def main():
    test_absent_steals_is_noop()
    test_scan_keys_path_alerts_and_panel()
    test_threshold_and_removal()
    test_budget_rotation_and_throttle()
    test_keys_fallback_to_class_browse()
    test_deferred_replies_and_player_browse_stops()
    test_passive_harvest_and_sound_toggle()
    test_tooltip_precedence_house_and_slash()
    test_api_errors_do_not_break()
    test_grep_safety()
    print("Wuwei steals harness: OK")
    print(smoke_generated_plan())


if __name__ == "__main__":
    main()
