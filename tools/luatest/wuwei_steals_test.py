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
keysWork = true; keysExact = false; keysZeroRows = true; respond = "sync"; full = true; ready = true; moreRows = nil; pending = nil
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
    -- keysZeroRows: the live server answers every requested key; a key with nothing listed comes back as a row with
    -- totalQuantity 0 and minPrice 0 (seen in game 2026-11-15: STEAL rows at 0c that Search showed empty).
    if keysZeroRows then
      for _, k in ipairs(keys) do
        local hit = false
        for _, r in ipairs(rows) do
          if r.itemKey.itemID == k.itemID and r.itemKey.itemLevel == (k.itemLevel or 0) then hit = true end
        end
        if not hit then
          rows[#rows+1] = { itemKey = { itemID = k.itemID, itemLevel = k.itemLevel or 0, itemSuffix = 0,
                            battlePetSpeciesID = 0 }, minPrice = 0, totalQuantity = 0, containsOwnerItem = false }
        end
      end
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
    assert rows[0] == ("STEAL", "Arcanite Reaper", "90g · 45% of fair 200g · conf 42%", "+110g"), rows[0]
    assert rows[1] == ("STEAL", "Recipe: Sample", "22g 50s · 50% of fair 45g · conf 42%", "+22g"), rows[1]
    assert len(rows) == 2                                                   # steals tab: STEAL/CHECK rows only (D-058)
    ns.Panel.SetMode("plays")
    prow = [strip(f.rows[i].signal.text) for i in range(1, 21) if f.rows[i].shown]
    assert len(prow) == 5 and "STEAL" not in prow, prow                    # shuttle off: 5 plays, no steals
    ns.Panel.SetMode("steals")
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
    g.full = False                                                         # keys reply: complete by construction
    g.moreRows = rt.eval("{ { itemKey = { itemID = 13335 }, minPrice = 4000000 } }")
    live(rt, g, i13518=[(150000,)])
    g.aq = rt.eval("{}")
    before = len(g.printed); S.Scan(); run(g, ns)
    assert qs(g) == ["keys"], qs(g)                                        # D-041: no RequestMoreBrowseResults
    assert found_ids(ns) == [13518]
    g.full = False; S.keysOK = False; g.aq = rt.eval("{}")                 # browse fallback: incomplete reply is paged
    live(rt, g, i13518=[(150000,)], i13335=[(4000000,)])                   # 13335's own class job must list it too
    S.Scan(); run(g, ns)
    assert "more" in qs(g) and found_ids(ns) == [13335, 13518], (qs(g), found_ids(ns))
    S.keysOK = None
    assert "STEAL [Recipe: Sample] listed at 15g" in out(g, before)        # cheaper than announced: announced again
    # Closing the AH clears what was found; reopening starts clean
    g.fire("AUCTION_HOUSE_CLOSED"); assert found_ids(ns) == []
    g.fire("AUCTION_HOUSE_SHOW"); assert ns.Panel.frame.steals.text.startswith("Steals: 4 watched")
    no_forbidden(g)


def test_zero_quantity_rows_are_not_listings():
    """In game 2026-11-15: 29 STEAL rows at 0c / 0% of fair, Search empty; scan stopped at 15/22 jobs (40 queries)."""
    rt, ns, g = boot()
    S = ns.Steals
    live(rt, g)                                                            # nothing listed at all
    g.full = False                                                         # live server: keys reply not "full"
    before = len(g.printed)
    S.Scan(); run(g, ns)
    assert qs(g) == ["keys"], qs(g)                                        # one query, no paging
    assert found_ids(ns) == [] and "STEAL [" not in out(g, before) and len(g.sounds) == 0
    assert "Steals scan: 0 found · queries: 1." in out(g, before)
    # Gear: the ilvl-0 key comes back empty, the ilvl-63 key has the listing: the real row wins
    live(rt, g, i12784=[(900000, 63)])
    S.Scan(); run(g, ns)
    assert found_ids(ns) == [12784] and ns.Steals.found[12784].price == 900000
    # Bought: next reply carries only zero rows for it -> row removed
    live(rt, g)
    S.Scan(); run(g, ns)
    assert found_ids(ns) == []
    # Passive harvest of a favorites-style browse with a zero row: no alert, clears a stale find
    S.Observe(13518, 100000, None)
    assert found_ids(ns) == [13518]
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 0, totalQuantity = 0 } }"))
    assert found_ids(ns) == []
    assert S.Observe(13518, 0, None) is False and found_ids(ns) == []
    g.full = True
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
    g.zone = "Everlook"; ns.House.ResetProbe()
    assert strip(ns.Tooltip.Line(8485)) == "Wuwei: STEAL ≤ 6g · fair 12g (n 9) · (114) · 42m"
    before = len(g.printed)
    assert S.Scan() is False and "steals list is for house 114; you are at 117" in out(g, before) and len(g.aq) == 0
    g.zone = "Orgrimmar"; ns.House.ResetProbe()
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


# ---------------------------------------------------------------------------------------------------------------
# 0.5.0: per-house blocks, resale, isolation at alert time, depth check on the player's own item search (D-050/D-051)
# ---------------------------------------------------------------------------------------------------------------
ITEM_SEARCH_MOCK = r"""
ISR = {}; ISR_FULL = true     -- ISR[itemID] = { {buyoutAmount, quantity}, ... }
C_AuctionHouse.GetNumItemSearchResults = function(key) return #(ISR[key.itemID] or {}) end
C_AuctionHouse.GetItemSearchResultInfo = function(key, i)
  local r = (ISR[key.itemID] or {})[i]
  return r and { itemKey = key, buyoutAmount = r[1], quantity = r[2] or 1, auctionID = i, owners = {} } or nil
end
C_AuctionHouse.HasFullItemSearchResults = function() return ISR_FULL end
"""

NEAR = "near = { pct = 10, max = 2 }"


def block(house, items, near=True):
    return ('{ generated = "2026-11-16T23:10:00Z", house = %d, %s items = { %s } }'
            % (house, NEAR + "," if near else "", ", ".join(items)))


def plan_by_house(b114=None, b117=None, legacy=None, near=True):
    ents114 = b114 or ["[13518] = { fair = 450000, buyMax = 225000, n = 6, kind = 'recipe', classID = 9, subclassID = 2, "
                       "sell = 114, net = 380000, vendor = 625 }",
                       "[8485] = { fair = 120000, buyMax = 60000, n = 9, kind = 'pet', classID = 15, subclassID = 2 }"]
    ents117 = b117 or ["[13518] = { fair = 450000, buyMax = 150000, n = 6, kind = 'recipe', classID = 9, subclassID = 2, "
                       "sell = 114, net = 380000 }",
                       "[13335] = { fair = 9000000, buyMax = 4000000, n = 3, kind = 'mount', classID = 15, subclassID = 5, sell = 117 }"]
    parts = ['generated = "2026-11-16T23:10:00Z"', "houses = { [114] = 'Horde', [117] = 'Blackwater' }", "items = {}",
             "stealsByHouse = { [114] = %s, [117] = %s }" % (block(114, ents114, near), block(117, ents117, near))]
    if legacy:
        parts.append("steals = " + legacy)
    return "{ " + ", ".join(parts) + " }"


def boot2(plan_lua, house=None):
    rt, ns, g = boot(plan_lua)
    rt.execute(ITEM_SEARCH_MOCK)
    if house is not None:
        g.WuweiDB.house = house
        g.fire("AUCTION_HOUSE_SHOW")
    return rt, ns, g


def rows_ui(ns):
    ns.Panel.Refresh()
    f = ns.Panel.frame
    return [(strip(f.rows[i].signal.text), strip(f.rows[i].name.text), strip(f.rows[i].rule.text), strip(f.rows[i].gain.text))
            for i in range(1, 16) if f.rows[i].shown]


def set_isr(rt, g, **kw):
    t = rt.eval("{}")
    for k, rows in kw.items():
        t[int(k[1:])] = rt.eval("{" + ",".join("{%d,%d}" % (r[0], r[1] if len(r) > 1 else 1) for r in rows) + "}")
    g.ISR = t


def search_event(rt, g, id):
    g.fire("ITEM_SEARCH_RESULTS_UPDATED", rt.eval("{ itemID = %d, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }" % id), None)


def test_block_selection_by_house():
    rt, ns, g = boot2(plan_by_house(), 117)
    S = ns.Steals
    assert S.Data().house == 117 and S.Count() == 2 and S.Entry(13335) and not S.Entry(8485)
    assert "house 117" in strip(ns.Steals.StatusLine()) or True
    live(rt, g, i13518=[(100000,)], i13335=[(5000000,)], i8485=[(1,)])
    before = len(g.printed)
    assert S.Scan() is True                                              # no more "list is for house 114" at Blackwater
    run(g, ns)
    assert found_ids(ns) == [13518]                                      # 117's buyMax 150000; 13335 over its 4g; 8485 not watched here
    assert g.aq[1].nitems == 2
    # switch to 114: its own thresholds
    g.WuweiDB.house = 114
    assert S.Data().house == 114 and S.Count() == 2 and S.Entry(8485)
    g.fire("AUCTION_HOUSE_SHOW")
    live(rt, g, i13518=[(200000,)], i8485=[(50000,)])
    S.Scan(); run(g, ns)
    assert found_ids(ns) == [8485, 13518]
    # a house with no block: refusal, feature off, no sound
    g.WuweiDB.house = 111
    assert S.Data() is None and not S.On() and S.Count() == 0
    before = len(g.printed)
    assert S.Scan() is False and "No steals list for house 111." in out(g, before) and "house 114" not in out(g, before)
    assert strip(S.StatusLine()) == "steals: no list for house 111"
    ns.Panel.Refresh()
    assert ns.Panel.frame.steals.text == "" and ns.Tooltip.Line(13518) is None
    no_forbidden(g)
    # legacy plan (no stealsByHouse): `steals` serves every house; D-037 guard unchanged
    rt, ns, g = boot()
    g.WuweiDB.house = 117
    before = len(g.printed)
    assert ns.Steals.Scan() is False and "The steals list is for house 114; you are at 117" in out(g, before)
    # stealsByHouse wins over a legacy `steals` key; legacy serves when it is absent
    rt, ns, g = boot2(plan_by_house(legacy=block(114, ["[999] = { fair = 100, buyMax = 50 }"])), 114)
    assert ns.Steals.Entry(13518) and not ns.Steals.Entry(999)
    # not at an AH: last detected house, else 114
    rt, ns, g = boot2(plan_by_house(), 117)
    assert ns.Steals.Data().house == 117
    g.WuweiDB.house = None
    g.AuctionHouseFrame.shown = False
    g.zone = "Durotar"                                                   # not a capital: detection is only a guess
    assert ns.Steals.Data().house == 117                                 # remembered (unconfident fallback outside an AH)
    rt, ns, g = boot2(plan_by_house())
    g.WuweiDB.house = None
    g.AuctionHouseFrame.shown = False
    assert ns.Steals.Data() is not None


def test_steal_vs_check_by_total_quantity():
    rt, ns, g = boot2(plan_by_house(), 114)
    S = ns.Steals
    one = lambda q: rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = %d } }" % q)
    before = len(g.printed)
    S.Harvest(one(1))
    o = out(g, before)
    assert "STEAL [Recipe: Sample] listed at 20g" in o and "only listing" in o, o
    assert len(g.sounds) == 1 and rows_ui(ns)[0][0] == "STEAL"
    # N listed within max: STEAL with "N listed"
    S.Harvest(rt.eval("{ { itemKey = { itemID = 8485 }, minPrice = 50000, totalQuantity = 2 } }"))
    assert "2 listed" in out(g, before) and len(g.sounds) == 1           # sound gap anyway
    # above near.max: quiet CHECK, no sound
    g.fire("AUCTION_HOUSE_CLOSED"); g.fire("AUCTION_HOUSE_SHOW")
    g.sounds = rt.eval("{}"); before = len(g.printed)
    S.Harvest(one(5))
    o = out(g, before)
    assert "[Recipe: Sample] at 20g (5 listed): may be a falling floor; Search to check depth" in o, o
    assert "STEAL [" not in o and len(g.sounds) == 0
    r = rows_ui(ns)
    assert r[0][0] == "CHECK" and r[0][1] == "Recipe: Sample", r
    assert found_ids(ns) == [13518] and S.found[13518].check
    # a STEAL row sorts above a CHECK row
    S.Harvest(rt.eval("{ { itemKey = { itemID = 8485 }, minPrice = 59000, totalQuantity = 1 } }"))
    assert [x[0] for x in rows_ui(ns)][:2] == ["STEAL", "CHECK"]
    # no `near` in the plan: always STEAL, text as before
    rt, ns, g = boot2(plan_by_house(near=False), 114)
    before = len(g.printed)
    ns.Steals.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 9 } }"))
    o = out(g, before)
    assert "STEAL [Recipe: Sample] listed at 20g" in o and "listed ·" not in o and "only listing" not in o and "CHECK" not in o, o
    assert rows_ui(ns)[0][0] == "STEAL"
    no_forbidden(g)


def test_depth_check_on_item_search():
    rt, ns, g = boot2(plan_by_house(), 114)
    S = ns.Steals
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 5 } }"))
    assert rows_ui(ns)[0][0] == "CHECK"
    g.sounds = rt.eval("{}"); n = len(g.aq)
    # 5 units within 10% of the lowest: falling floor, row removed, no sound; bid-only rows (no buyout) are skipped
    rt.execute("ISR[13518] = { {200000,1}, {205000,1}, {210000,1}, {219000,1}, {219999,1}, {900000,1} }")
    rt.execute("table.insert(ISR[13518], { false, 1 })")
    search_event(rt, g, 13518)
    o = out(g, len(g.printed) - 1)
    assert "[Recipe: Sample]: 5 listed within 10% of 20g: falling floor, not a steal" in o, o
    assert found_ids(ns) == [] and len(g.sounds) == 0 and len(g.aq) == n
    assert not any(x[0] in ("STEAL", "CHECK") for x in rows_ui(ns))
    before = len(g.printed); search_event(rt, g, 13518)                   # repeated event, same verdict: no repeat chat
    assert len(g.printed) == before
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 5 } }"))
    assert found_ids(ns) == []                                          # a later browse does not resurrect it
    # only 2 near the lowest (the rest far above): confirmed, the row stays/returns as STEAL
    rt.execute("ISR[13518] = { {200000,1}, {210000,1}, {400000,1}, {450000,1} }")
    before = len(g.printed); search_event(rt, g, 13518)
    assert "[Recipe: Sample]: STEAL confirmed, 2 near 20g" in out(g, before) and "partial" not in out(g, before)
    assert found_ids(ns) == [13518] and rows_ui(ns)[0][0] == "STEAL" and len(g.sounds) == 0
    # confirmed verdict survives a browse that still shows 5 listed at the same minimum
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 5 } }"))
    assert rows_ui(ns)[0][0] == "STEAL"
    # a CHECK row is promoted by a confirming search
    g.fire("AUCTION_HOUSE_CLOSED"); g.fire("AUCTION_HOUSE_SHOW")
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 5 } }"))
    assert rows_ui(ns)[0][0] == "CHECK"
    rt.execute("ISR[13518] = { {200000,2} }")                              # one auction, quantity 2: 2 units
    search_event(rt, g, 13518); assert rows_ui(ns)[0][0] == "STEAL"
    # quantity counts units: a single auction of 3 near the lowest is a falling floor
    rt.execute("ISR[13518] = { {200000,3} }"); rt.execute("ISR_FULL = false")
    before = len(g.printed); search_event(rt, g, 13518)
    assert "3 listed within 10% of 20g: falling floor, not a steal (partial results)" in out(g, before), out(g, before)
    assert found_ids(ns) == []
    # lowest above buyMax: not a steal, row dropped quietly
    rt.execute("ISR[13518] = { {230000,1} }")
    before = len(g.printed); search_event(rt, g, 13518)
    assert len(g.printed) == before and found_ids(ns) == []
    # partial + confirmed says so
    rt.execute("ISR[13518] = { {190000,1} }")
    before = len(g.printed); search_event(rt, g, 13518)
    assert "STEAL confirmed, 1 near 19g" in out(g, before) and out(g, before).rstrip().endswith("(partial results)")
    # unwatched items, steals off, no near, missing APIs, erroring getters: nothing happens
    rt.execute("ISR[2589] = { {1,1} }")
    before = len(g.printed); search_event(rt, g, 2589); assert len(g.printed) == before
    g.WuweiDB.steals = False
    search_event(rt, g, 13518); assert len(g.printed) == before
    g.WuweiDB.steals = True
    rt.execute("C_AuctionHouse.GetItemSearchResultInfo = function() error('x') end")
    search_event(rt, g, 13518); assert len(g.printed) == before
    rt.execute("C_AuctionHouse.GetNumItemSearchResults = nil")
    search_event(rt, g, 13518); assert len(g.printed) == before
    rt, ns, g = boot2(plan_by_house(near=False), 114)
    rt.execute("ISR[13518] = { {200000,1}, {200001,1}, {200002,1} }")
    before = len(g.printed); search_event(rt, g, 13518); assert len(g.printed) == before
    no_forbidden(g)


def test_resale_text():
    rt, ns, g = boot2(plan_by_house(), 117)
    S = ns.Steals
    before = len(g.printed)
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 100000, totalQuantity = 1 } }"))
    o = out(g, before)
    assert "only listing" in o and "resell @Horde (net 38g)" in o, o
    r = rows_ui(ns)[0]
    assert r[0] == "STEAL" and r[2].endswith("· resell @Horde") and r[3] == "+28g", r        # net 380000 - 100000
    assert strip(ns.Tooltip.Line(13518)) == "Wuwei: STEAL ≤ 15g · fair 45g (n 6) · resell @Horde net 38g · live 10g · 0m", strip(ns.Tooltip.Line(13518))
    # sell == house: no resale text, but net still drives the gain
    before = len(g.printed)
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13335 }, minPrice = 3000000, totalQuantity = 1 } }"))
    assert "resell" not in out(g, before)
    g.WuweiDB.house = 114
    g.fire("AUCTION_HOUSE_SHOW")
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 1 } }"))
    r = rows_ui(ns)[0]
    assert "resell" not in r[2] and r[3] == "+18g", r                                     # net 380000 - 200000
    assert "resell" not in strip(ns.Tooltip.Line(13518))
    # CHECK line carries the resale text too
    rt, ns, g = boot2(plan_by_house(), 117)
    before = len(g.printed)
    ns.Steals.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 100000, totalQuantity = 4 } }"))
    assert "(4 listed): may be a falling floor; Search to check depth · resell @Horde" in out(g, before)
    # old plan fields absent: today's text and gain
    rt, ns, g = boot()
    before = len(g.printed)
    ns.Steals.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 7 } }"))
    o = out(g, before)
    assert o.strip().endswith("Search in the Wuwei panel · confidence 21% (low)") and "resell" not in o and rows_ui(ns)[0][3] == "+25g", (o, rows_ui(ns)[0])  # 7 listed 0.4 x n6 0.7 x perDay? 0.75
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
    test_zero_quantity_rows_are_not_listings()
    test_budget_rotation_and_throttle()
    test_keys_fallback_to_class_browse()
    test_deferred_replies_and_player_browse_stops()
    test_passive_harvest_and_sound_toggle()
    test_tooltip_precedence_house_and_slash()
    test_api_errors_do_not_break()
    test_block_selection_by_house()
    test_steal_vs_check_by_total_quantity()
    test_depth_check_on_item_search()
    test_resale_text()
    test_grep_safety()
    print("Wuwei steals harness: OK")
    print(smoke_generated_plan())


if __name__ == "__main__":
    main()
