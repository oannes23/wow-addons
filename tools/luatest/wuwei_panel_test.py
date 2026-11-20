"""Panel modes, instant cancel and the house probe for addons/Wuwei (SPEC D-057, D-058).

  uv run --no-project --with lupa python tools/luatest/wuwei_panel_test.py
Reuses the steals harness (fake browse backend, mkAH4). Covers: a Search click cancels a running scan before its query
goes out, and the scan sends nothing after; Blizzard's own item search (QueryItem) stops it too; the Stop button; a
search the client drops is resent once the throttled queue is ready, at most RETRIES times, never after the wait; scan
order follows the pipeline's rank; the deposit-quote house probe (the Crossroads camp opens Blackwater); and the
Markets view (sector rows, gainers/losers, drill-down, Back, Search with the mover's price).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_steals_test as st  # noqa: E402

strip, boot, live, run, out, qs, found_ids, no_forbidden = (st.strip, st.boot, st.live, st.run, st.out, st.qs,
                                                            st.found_ids, st.no_forbidden)


def ui_rows(ns, n=20):
    ns.Panel.Refresh()
    f = ns.Panel.frame
    return [(strip(f.rows[i].signal.text), strip(f.rows[i].name.text), strip(f.rows[i].rule.text), strip(f.rows[i].gain.text),
             f.rows[i].button.label if f.rows[i].button.shown else None)
            for i in range(1, n + 1) if f.rows[i].shown]


def test_search_cancels_scan_first_d057():
    rt, ns, g = boot()
    S, f, ah = ns.Steals, ns.Panel.frame, g.AuctionHouseFrame
    # QueryItem records whether a scan was still running at the moment the player's search went out
    g.WUWEI_NS = ns
    rt.execute("""function AuctionHouseFrame:QueryItem(ctx, key)
      self.queried[#self.queried+1] = { ctx = ctx, key = key, scanning = WUWEI_NS.Steals.state.active } end""")
    # Replacing the method dropped Wuwei's post-hook: re-hook on the next AH show, as on a fresh frame
    S.hooked = None
    g.fire("AUCTION_HOUSE_SHOW")
    g.respond = "defer"
    S.CHUNK = 2                                                              # several jobs: the scan is still running
    live(rt, g, i8485=[(50000,)], i13518=[(900000,)])
    assert S.Scan() is True and S.state.active and S.state.awaiting
    assert ns.Panel.Mode() == "steals"
    assert strip(f.scan.label) == "Stop scan"                                # the action button turns into Stop
    g.flush(); g.now += 0.6; S.Tick()                                        # first reply: a steal appears mid-scan
    assert found_ids(ns) == [8485]
    rows = ui_rows(ns)
    assert rows[0][0] == "STEAL" and len(rows) == 1                          # steals tab: only the steal
    n_aq = len(g.aq)
    before = len(g.printed)
    f.rows[1].button.scripts.OnClick(f.rows[1].button)                      # Search the steal
    q = ah.queried[len(ah.queried)]
    assert q.key.itemID == 8485 and q.scanning is False, "the scan must stop BEFORE the search is sent"
    assert not S.state.active and S.state.result == "search"
    assert "stopped because you searched" in out(g, before)
    for _ in range(20):                                                      # nothing more from the scan
        g.now += 0.6; S.Tick()
    g.flush()
    assert len(g.aq) == n_aq
    assert "· stopped" in strip(S.StatusText())
    # Blizzard's own item search (a browse-row click) stops a scan too (post-hook on QueryItem)
    S.Scan(); assert S.state.active
    ah.QueryItem(ah, 20, rt.eval("{ itemID = 8485 }"))
    assert not S.state.active and S.state.result == "search"
    # The Stop button cancels; the button reads Scan steals again
    S.Scan(); ns.Panel.Refresh(); assert strip(f.scan.label) == "Stop scan"
    before = len(g.printed)
    f.scan.scripts.OnClick(f.scan)
    assert not S.state.active and S.state.result == "cancel" and "Steals scan cancelled" in out(g, before)
    ns.Panel.Refresh(); assert strip(f.scan.label) == "Scan steals"
    f.scan.scripts.OnClick(f.scan); assert S.state.active                   # and starts a scan again
    S.Cancel("cancel")
    assert S.Cancel("cancel") is False                                       # nothing running: no-op
    before = len(g.printed); g.SlashCmdList["WUWEI"]("steals stop")
    assert "No steals scan running." in out(g, before)
    # A scan started from another tab switches to the steals tab
    ns.Panel.SetMode("markets"); assert ns.Panel.Mode() == "markets"
    S.Scan(); assert ns.Panel.Mode() == "steals"
    S.Cancel()
    no_forbidden(g)


def test_dropped_search_is_resent_d057():
    rt, ns, g = boot()
    P, ah = ns.Panel, g.AuctionHouseFrame
    n0 = len(ah.queried)
    assert P.Search(13518)[0] is True and len(ah.queried) == n0 + 1
    # The client drops it (another throttled message replaced it): resent once the queue is ready
    g.ready = False
    g.now += 1; g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert P.PendingRetry() is not None and P.events.scripts.OnUpdate is not None
    g.now += 0.5; P.events.scripts.OnUpdate(P.events); assert len(ah.queried) == n0 + 1   # not ready: wait
    g.ready = True
    g.now += 0.5; P.events.scripts.OnUpdate(P.events)
    assert len(ah.queried) == n0 + 2 and ah.queried[n0 + 2].key.itemID == 13518 and P.PendingRetry() is None
    P.events.scripts.OnUpdate(P.events); assert P.events.scripts.OnUpdate is None         # ticker stops when idle
    # Dropped again: one more resend (RETRIES = 2), then a message instead of a third
    g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED"); P.events.scripts.OnUpdate(P.events)
    assert len(ah.queried) == n0 + 3
    before = len(g.printed)
    g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert P.PendingRetry() is None and len(ah.queried) == n0 + 3 and "dropped your search" in out(g, before)
    # A drop long after our search is someone else's message: ignored
    P.Search(8485); n1 = len(ah.queried)
    g.now += P.DROP_WINDOW + 1; g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert P.PendingRetry() is None
    # A queue that never becomes ready: give up after RETRY_WAIT with a message, no send
    P.Search(8485); n1 = len(ah.queried)
    g.ready = False; g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    before = len(g.printed)
    g.now += P.RETRY_WAIT + 1; P.events.scripts.OnUpdate(P.events)
    assert P.PendingRetry() is None and len(ah.queried) == n1 and "dropped your search" in out(g, before)
    g.ready = True
    # A new click replaces a waiting resend; closing the AH clears it
    P.Search(8485); g.ready = False; g.fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    assert P.PendingRetry() is not None
    g.fire("AUCTION_HOUSE_CLOSED"); assert P.PendingRetry() is None and P.events.scripts.OnUpdate is None
    no_forbidden(g)


def test_scan_order_follows_rank_d057():
    items = ["[13518] = { fair = 450000, buyMax = 225000, n = 6, classID = 9, subclassID = 2, rank = 3 }",
             "[8485] = { fair = 120000, buyMax = 60000, n = 9, classID = 15, subclassID = 2, rank = 1 }",
             "[12784] = { fair = 2000000, buyMax = 1100000, n = 4, classID = 2, subclassID = 1, rank = 2 }",
             "[13335] = { fair = 9000000, buyMax = 5000000, n = 3, classID = 15, subclassID = 5 }"]       # unranked: last
    rt, ns, g = st.boot2(st.plan_by_house(b114=items), 114)
    order = [int(i) for i in ns.Steals.BuildJobs()[1].ids.values()]
    assert order == [8485, 12784, 13518, 13335], order
    # Unranked plans keep the old order: non-gear by id, then gear
    rt, ns, g = boot()
    assert [int(i) for i in ns.Steals.BuildJobs()[1].ids.values()] == [8485, 13335, 13518, 12784]


def test_house_probe_d057():
    rt, ns, g = boot()
    H = ns.House
    det = lambda: tuple(H.Detect())
    assert det()[0] == 114 and det()[1] == "deposit quote" and det()[2] is True               # Orgrimmar AH
    # The Crossroads camp: a Horde zone, but its auctioneer quotes Blackwater deposits
    g.fire("AUCTION_HOUSE_CLOSED"); g.zone = "Durotar"; g.probeRate = 0.125
    g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert det() == (117, "deposit quote", True)
    assert ns.Steals.Data() is not None                                     # builtin legacy list: guard below
    before = len(g.printed)
    assert ns.Steals.Scan() is False and "steals list is for house 114; you are at 117" in out(g, before)
    # Cached for the visit: the quote isn't asked again on every Detect
    g.probeRate = 0.025; assert det()[0] == 117
    # Closing resets it; outside the AH the location rules apply again
    g.fire("AUCTION_HOUSE_CLOSED"); g.AuctionHouseFrame.shown = False
    assert det()[0] == 114 and det()[2] is False                            # Durotar: faction guess
    # Booty Bay with a faction-rate quote: the quote wins over the zone name
    g.zone, g.subzone = "Stranglethorn Vale", "Booty Bay"
    g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert det()[0] == 114
    # No quote (API missing or item data not loaded): location rules, and it asks again next time
    g.fire("AUCTION_HOUSE_CLOSED"); g.probeRate = None; g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert det() == (117, "zone Booty Bay", True)
    g.probeRate = 0.025; assert det()[0] == 114                             # quote available now
    # The vendor price comes from GetItemInfo when present (here 45c, so a 12.5%/h quote reads as ratio 1.0: faction)
    g.fire("AUCTION_HOUSE_CLOSED"); g.SELL[2318] = 45; g.probeRate = 0.125
    g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert det()[0] == 114                                                  # 0.125*24*15/45 = 1.0 < 1.5: trusts the price
    g.SELL[2318] = None
    # The AH frame hidden without a close event (UI reload, frame torn down): the next visit probes afresh
    g.fire("AUCTION_HOUSE_CLOSED"); g.probeRate = 0.125; g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert det()[0] == 117
    g.AuctionHouseFrame.shown = False; det()                                # seen closed: probe dropped
    g.probeRate = 0.025; g.AuctionHouseFrame.shown = True
    assert det()[0] == 114
    # A manual override still wins
    H.Set("111"); assert det()[0] == 111; H.Set("auto")


MARKETS = """{ generated = "2026-11-09T07:00:00Z", houses = { [114] = 'Horde', [117] = 'Blackwater' }, items = {},
  marketsByHouse = {
    [114] = { generated = "2026-11-09T07:00:00Z", at = "2026-11-09T07:00:00Z", sectors = {
      { key = "herb", name = "Herbs", n = 30, chg24 = 4.25, chg7 = -8.1, up = 18, down = 9, items = {
          { id = 13463, price = 1499, chg24 = 9.1, chg7 = 12.0, perDay = 1100, score = 900 },
          { id = 3357, price = 1200, chg24 = -40.0, chg7 = -2.0, perDay = 300, score = 500 },
          { id = 8153, price = 500, chg24 = 2500.0, chg7 = 150.0, perDay = 20, score = 100 } } },
      { key = "cloth", name = "Cloth", n = 20, chg24 = -0.4, chg7 = 3.7, up = 3, down = 2, items = {
          { id = 4338, price = 300, chg24 = -12.0, chg7 = 1.0, perDay = 12000, score = 800 },
          { id = 2589, price = 10, chg24 = 0.5, chg7 = 0.0, perDay = 5000, score = 10 } } },
      { key = "raid", name = "Raid inputs", n = 2, chg24 = 9.1, chg7 = 1.0, up = 1, down = 0, items = {
          { id = 13463, price = 1499, chg24 = 9.1, chg7 = 12.0, perDay = 1100, score = 900 } } } } } } }"""


def test_markets_view_d058():
    rt, ns, g = boot(MARKETS)
    g.NAMES[13463] = "Dreamfoil"
    M, P, f = ns.Markets, ns.Panel, ns.Panel.frame
    assert [strip(M.Pct(v)) for v in (4.25, -8.1, 0.4, 150.0, -40.0, 2500.0, None)] == \
        ["+4.2%", "-8.1%", "+0.4%", "+150%", "-40.0%", ">+999%", "n/a"]
    assert [M.Volume(v) for v in (20, 1100, 12000)] == ["20/d", "1.1k/d", "12k/d"]
    assert "|cff40e060" in M.Pct(4.25) and "|cffff5050" in M.Pct(-8.1) and "|cffa0a0a0" in M.Pct(0.4)
    P.SetMode("markets")
    assert not f.scan.shown                                                 # no action button on the overview
    assert "Markets · 24h change" in strip(f.steals.text) and "prices 42m old" in strip(f.steals.text)
    rows = ui_rows(ns)
    assert rows[0] == ("+4.2%", "Herbs", "7d -8.1% · 18 up / 9 down", "30 items", "Open"), rows[0]
    assert [r[1] for r in rows[:3]] == ["Herbs", "Cloth", "Raid inputs"]
    assert rows[3][1] == "Top gainers 24h" and rows[3][4] is None           # label row: no button
    gain = [r[1] for r in rows[4:] if r[0].startswith("+") or r[0].startswith(">")]
    assert gain[0] == "Dreamfoil" and gain.count("Dreamfoil") == 1          # counted once across sectors
    assert "Liferoot" in [r[1] for r in rows] and "Top losers 24h" in [r[1] for r in rows]
    assert "Linen Cloth" not in [r[1] for r in rows]                        # flat (+0.5%): neither list
    dream = next(r for r in rows if r[1] == "Dreamfoil")
    assert dream == ("+9.1%", "Dreamfoil", "14s 99c · 7d +12.0% · Herbs", "1.1k/d", "Search"), dream
    # Search on a mover: Blizzard's commodity buy frame with the mover's price; a steals scan would be cancelled
    g.COMMOD[13463] = True
    i = next(k for k in range(1, 21) if f.rows[k].shown and strip(f.rows[k].name.text) == "Dreamfoil")
    f.rows[i].button.scripts.OnClick(f.rows[i].button)
    ah = g.AuctionHouseFrame
    assert ah.queried[len(ah.queried)].ctx == 21 and ah.selected[len(ah.selected)].minPrice == 1499
    # Open a sector: its movers in the pipeline's order, Back returns
    f.rows[1].button.scripts.OnClick(f.rows[1].button)
    assert P.Sector() == "herb" and strip(f.scan.label) == "Back" and f.scan.shown
    rows = ui_rows(ns)
    assert [r[1] for r in rows] == ["Dreamfoil", "Liferoot", "Wildvine"] and rows[2][0] == ">+999%"
    assert strip(f.steals.text).startswith("Herbs · median 24h +4.2% · 7d -8.1% · 18 up / 9 down")
    f.scan.scripts.OnClick(f.scan)
    assert P.Sector() is None and ui_rows(ns)[0][1] == "Herbs"
    # Another tab and back: overview; reopening the AH resets the drill-down
    f.rows[2].button.scripts.OnClick(f.rows[2].button); assert P.Sector() == "cloth"
    g.fire("AUCTION_HOUSE_CLOSED"); g.AuctionHouseFrame.shown = True; g.fire("AUCTION_HOUSE_SHOW")
    assert P.Sector() is None and P.Mode() == "markets"                     # the tab is remembered
    # Tabs show which is active
    labels = [strip(b.label) for b in f.tabs.values()]
    assert labels == ["Steals", "[Markets]", "Plays"], labels
    f.tabs[1].scripts.OnClick(f.tabs[1]); assert P.Mode() == "steals" and strip(f.tabs[1].label) == "[Steals]"
    # A house without a block / a plan without markets: a status line, no rows
    g.WuweiDB.house = 117; P.SetMode("markets")
    assert ui_rows(ns) == [] and "no data" in strip(f.steals.text)
    rt, ns, g = boot()
    ns.Panel.SetMode("markets")
    assert ui_rows(ns) == [] and "Markets: no data" in strip(ns.Panel.frame.steals.text)
    no_forbidden(g)


def test_markets_row_budget_d058():
    """Rows split between gainers and losers; a side with fewer movers gives its rows to the other."""
    its = ", ".join("{ id = %d, price = 100, chg24 = %s, chg7 = 0, perDay = 100, score = %d }" % (i, c, s)
                    for i, c, s in [(1, 10, 50), (2, 20, 40), (3, 30, 30), (4, 40, 20), (5, -10, 10)])
    plan = ('{ generated = "2026-11-09T07:00:00Z", houses = { [114] = "Horde" }, items = {}, marketsByHouse = { [114] = {'
            ' generated = "x", at = "2026-11-09T07:00:00Z", sectors = { { key = "herb", name = "Herbs", n = 5, chg24 = 1,'
            ' chg7 = 0, up = 4, down = 1, items = { %s } } } } } }' % its)
    rt, ns, g = boot(plan)
    rows = list(ns.Markets.Rows(114, None, 7).values())                     # 1 sector + 2 labels + room 4
    ids = [r.id for r in rows if r.id]
    assert ids == [1, 2, 3, 5], ids                                          # 3 gainers (by score) + the 1 loser
    rows = list(ns.Markets.Rows(114, None, 4).values())                     # room 1 < 2: sectors only
    assert len(rows) == 1


def test_steals_tab_empty_texts():
    rt, ns, g = boot()
    f = ns.Panel.frame
    ns.Panel.Refresh()
    assert strip(f.empty.text) == "No steals found this visit."
    g.respond = "defer"; ns.Steals.Scan(); ns.Panel.Refresh()
    assert strip(f.empty.text).startswith("Scanning...")
    ns.Steals.Cancel()
    g.WuweiDB.steals = False; ns.Panel.Refresh()
    assert "No steals list" in strip(f.empty.text) and not f.scan.shown


def test_confidence_d059():
    items = ["[13518] = { fair = 450000, buyMax = 225000, n = 25, perDay = 4, kind = 'recipe', classID = 9, subclassID = 2 }",
             "[8485] = { fair = 120000, buyMax = 60000, n = 9, perDay = 0.5, kind = 'pet', classID = 15, subclassID = 2, sell = 117 }"]
    rt, ns, g = st.boot2(st.plan_by_house(b114=items), 114)
    S = ns.Steals
    C = lambda **kw: tuple(S.Confidence(rt.table_from({"price": 100000, "fair": 450000, **kw}), 114))[:2]
    # gap before a search: listing count; after: second-lowest vs fair (>= 80% of fair = full support, floor 0.3)
    assert C(qty=1, n=25, perDay=4) == (80, "high")
    assert C(qty=2, n=25, perDay=4) == (60, "high") and C(qty=5, n=25, perDay=4) == (40, "med")
    assert C(searched=True, second=400000, n=25, perDay=4) == (100, "high")
    assert C(searched=True, second=180000, n=25, perDay=4) == (50, "med")         # next listing at 40% of fair
    assert C(searched=True, second=50000, n=25, perDay=4) == (30, "low")          # floor 0.3: fair looks stale
    assert C(searched=True, n=25, perDay=4) == (85, "high")                       # the only listing
    # fair evidence and resale speed
    assert C(qty=1, n=8, perDay=4)[0] == 68 and C(qty=1, n=3, perDay=4)[0] == 56 and C(qty=1, n=2, perDay=4)[0] == 40
    assert C(qty=1, n=25, perDay=1)[0] == 68 and C(qty=1, n=25, perDay=0.3)[0] == 56 and C(qty=1, n=25, perDay=0.1)[0] == 40
    assert C(qty=1)[0] == 42                                                     # old plan: n, perDay unknown 0.7 x 0.75
    assert C(qty=1, n=25, perDay=4, sell=117)[0] == 72                            # haul to Blackwater
    # Live: the alert carries it; the depth check adds the next price and re-rates
    live(rt, g, i13518=[(200000,)])
    before = len(g.printed)
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 1 } }"))
    o = out(g, before)
    assert o.rstrip().endswith("· only listing · confidence 80% (high)"), o
    assert "conf 80%" in ui_rows(ns)[0][2]
    st.set_isr(rt, g, i13518=[(200000,), (420000,)])
    before = len(g.printed)
    st.search_event(rt, g, 13518)
    o = out(g, before)
    assert "STEAL confirmed, 1 near 20g · next 42g (2.1x) · confidence 100% (high)" in o, o
    assert "conf 100%" in ui_rows(ns)[0][2]
    # A later browse showing the same listing keeps what the search learned; a new price forgets it
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 200000, totalQuantity = 2 } }"))
    assert "conf 100%" in ui_rows(ns)[0][2]
    S.Harvest(rt.eval("{ { itemKey = { itemID = 13518 }, minPrice = 190000, totalQuantity = 2 } }"))
    assert "conf 60%" in ui_rows(ns)[0][2]
    # The cheapest row holding 2 units: the next price is the same price (no gap): a falling floor within near.max?
    st.set_isr(rt, g, i8485=[(50000, 2), (110000,)])
    before = len(g.printed)
    st.search_event(rt, g, 8485)
    o = out(g, before)
    assert "STEAL confirmed, 2 near 5g · next 5g (1.0x)" in o, o                 # 0.52 gap x 0.85 x 0.7 x 0.9 haul
    assert "confidence 28% (low)" in o, o


def main():
    test_search_cancels_scan_first_d057()
    test_dropped_search_is_resent_d057()
    test_scan_order_follows_rank_d057()
    test_house_probe_d057()
    test_markets_view_d058()
    test_markets_row_budget_d058()
    test_steals_tab_empty_texts()
    test_confidence_d059()
    print("Wuwei panel harness: OK")


if __name__ == "__main__":
    main()
