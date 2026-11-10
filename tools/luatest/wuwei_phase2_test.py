"""Phase 2 harness for addons/Wuwei: post helper (fees, protection warnings) and trade ledger.

  uv run --no-project --with lupa python tools/luatest/wuwei_phase2_test.py
Reuses the Phase 1 mocks (wuwei_test.boot) plus the sell-frame / owned-auction mocks below.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402

ROOT = p1.ROOT

EXTRA = r"""
function hooksecurefunc(tbl, name, fn)
  local orig = tbl[name]
  tbl[name] = function(...) local r = orig(...) fn(...) return r end
end
cvars = { auctionHouseDurationDropdown = "3" }
function GetCVar(n) return cvars[n] end
SELL = { [4338] = 100, [2589] = 5, [4304] = 300 }          -- vendor sell prices (copper)
function mkLoc(id) return { itemID = id, IsValid = function() return true end } end
C_Item.GetItemID = function(loc) return loc.itemID end
C_Item.GetItemInfo = function(id) return "n", "l", 1, 1, 1, "t", "s", 20, "", 0, SELL[id] end
depositCalls = {}
C_AuctionHouse.CalculateCommodityDeposit = function(id, dur, qty) depositCalls[#depositCalls+1] = { "c", id, dur, qty } return 100 * qty * dur end
C_AuctionHouse.CalculateItemDeposit = function(loc, dur, qty) depositCalls[#depositCalls+1] = { "i", loc.itemID, dur, qty } return 50 * qty * dur end
owned = {}
C_AuctionHouse.GetOwnedAuctions = function() return owned end
queried = 0
C_AuctionHouse.QueryOwnedAuctions = function() queried = queried + 1 end
auctionInfo = {}
C_AuctionHouse.GetAuctionInfoByID = function(id) return auctionInfo[id] end

local function sellFrame(isCommodity)
  local f = CreateFrame("Frame")
  f.shown = false; f.item = nil; f.dur = 2; f.qty = 1; f.price = 0; f.updates = 0
  function f:GetItem() return self.item end
  function f:GetDuration() return self.dur end
  function f:GetQuantity() return self.qty end
  function f:UpdatePostState() self.updates = self.updates + 1 end
  function f:CachePendingPost() end
  if isCommodity then function f:GetUnitPrice() return self.price end
  else function f:GetPrice() return nil, self.price ~= 0 and self.price or nil end end
  return f
end
function mkAH2()
  local ah = CreateFrame("Frame", "AuctionHouseFrame")
  ah.shown = true
  ah.CommoditiesSellFrame = sellFrame(true)
  ah.ItemSellFrame = sellFrame(false)
  function ah:StartCommoditiesPurchase() end
  function ah:StartItemBuyout() end
  return ah
end
"""


def boot2():
    rt, ns = p1.boot(extra=EXTRA)
    g = rt.globals()
    ah = g.mkAH2()
    g.fire("AUCTION_HOUSE_SHOW")
    return rt, ns, g, ah


def strip(s):
    return p1.strip_colors(s)


def ledger_kinds(g):
    return [(e.kind, e.itemID, e.qty, e.unit) for e in g.WuweiDB.ledger.values()]


def test_fees_and_post_helper():
    rt, ns, g, ah = boot2()
    Post = ns.Post
    assert Post.Cut(114)[0] == 0.05 and Post.Cut(111)[0] == 0.05 and Post.Cut(117)[0] == 0.15
    assert tuple(Post.Cut(117))[1] is True                          # labelled assumed
    # Compute: cut and net (pure)
    c = Post.Compute(rt.eval("{ itemID = 4338, qty = 10, unit = 1000, deposit = 700, house = 114 }"))
    assert (c.total, c.cut, c.net, c.netUnit) == (10000, 500, 9500, 950), (c.total, c.cut, c.net)
    c = Post.Compute(rt.eval("{ itemID = 4338, qty = 10, unit = 1000, deposit = 700, house = 117 }"))
    assert (c.cut, c.net) == (1500, 8500)
    # No typed price: falls back to plan sellMin, labelled, no warnings.
    c = Post.Compute(rt.eval("{ itemID = 4338, qty = 5, unit = 0, house = 114 }"))
    assert c.price == 420 and c.priceSource == "plan sellMin" and len(c.warnings) == 0 and c.net == 2100 - 105

    # Live read through the commodity sell frame (hooked UpdatePostState drives the box)
    cf = ah.CommoditiesSellFrame
    cf.shown = True; cf.item = g.mkLoc(4338); cf.dur = 3; cf.qty = 20; cf.price = 500
    cf.UpdatePostState(cf)
    box = g.WuweiPostFrame
    assert box.shown
    txt = strip(box.text.text)
    last = [d for d in g.depositCalls.values()][-1]
    assert (last[1], last[2], last[3], last[4]) == ("c", 4338, 3, 20), list(last.values())  # commodity deposit API
    assert "deposit 60s" in txt, txt                                                  # 100*20*3 = 6000c = 60s
    assert txt.startswith("SELL ≥ 4s 20c\n"), txt
    assert "price 5s x20 (typed) = 1g" in txt and "AH cut 5% (assumed) -5s · net if sold 95s" in txt, txt
    assert "cost basis: none on record" in txt and "!" not in txt, txt
    # Item frame path: buyout from GetPrice, CalculateItemDeposit
    cf.shown = False
    itf = ah.ItemSellFrame
    itf.shown = True; itf.item = g.mkLoc(4304); itf.dur = 1; itf.qty = 2; itf.price = 1200
    itf.UpdatePostState(itf)
    last = [d for d in g.depositCalls.values()][-1]
    assert (last[1], last[2], last[3], last[4]) == ("i", 4304, 1, 2)
    assert "price 12s x2" in strip(box.text.text)
    # Duration fallback chain: frame -> CVar -> assumed 2 (labelled)
    rt.execute("AuctionHouseFrame.ItemSellFrame.GetDuration = function() return nil end")
    itf.UpdatePostState(itf)
    assert "duration 3" in strip(box.text.text) or "duration #3" in strip(box.text.text)   # CVar "3"
    g.cvars["auctionHouseDurationDropdown"] = None
    itf.UpdatePostState(itf)
    assert "(assumed)" in strip(box.text.text) and ns.Post.last.duration == 2
    rt.execute("AuctionHouseFrame.ItemSellFrame.GetDuration = function(self) return self.dur end")
    # Cleared selection / AH closed hides the box; disabled hides it
    itf.item = None; itf.UpdatePostState(itf); assert not box.shown
    cf.shown = True; cf.UpdatePostState(cf); assert box.shown
    g.fire("AUCTION_HOUSE_CLOSED"); assert not box.shown
    cf.UpdatePostState(cf); assert box.shown
    g.WuweiDB.post = False; cf.UpdatePostState(cf); assert not box.shown
    g.WuweiDB.post = True
    # Anchors under the Wuwei panel when it is shown
    g.fire("AUCTION_HOUSE_SHOW"); cf.UpdatePostState(cf)
    assert box.points[1][1] == "TOPLEFT" and box.points[1][2].name == "WuweiPanelFrame" and box.points[1][3] == "BOTTOMLEFT"


def test_protection_warnings():
    rt, ns, g, ah = boot2()
    cf = ah.CommoditiesSellFrame
    cf.shown = True; cf.item = g.mkLoc(4338); cf.qty = 10    # plan sellMin 420, vendor 100
    codes = lambda: [w.code for w in ns.Post.last.warnings.values()]

    cf.price = 500; cf.UpdatePostState(cf); assert codes() == []                       # fine
    cf.price = 300; cf.UpdatePostState(cf); assert codes() == ["plan"]                 # below plan floor
    cf.price = 90; cf.UpdatePostState(cf); assert codes() == ["vendor", "plan"]        # below vendor too
    txt = box_text = g.WuweiPostFrame.text.text
    assert txt.count("|cffff4040") == 2 and "price below vendor sell price (1s)" in strip(txt)   # red text
    # Cost basis: 100 bought at 450 each
    ns.Ledger.Add("buy", 4338, 100, 450, "test", rt.eval("{ total = 45000 }"))
    cf.price = 410; cf.UpdatePostState(cf); assert codes() == ["plan", "basis"]
    assert "price below cost basis (4s 50c)" in strip(g.WuweiPostFrame.text.text)
    cf.price = 460; cf.UpdatePostState(cf)               # 460 gross -> 437 net after the 5% cut, under the 450 basis
    assert codes() == ["basis"] and "net of cut below cost basis (4s 50c)" in strip(g.WuweiPostFrame.text.text)
    cf.price = 500; cf.UpdatePostState(cf); assert codes() == []   # 475 net: clear of every floor
    cf.price = 0; cf.UpdatePostState(cf); assert codes() == []     # warnings judge only a typed price

    # SHUTTLE item posted at the faction house: the floor is its faction verdict (alt 650), not the BW exit (1300).
    P = ns.Plan
    g.WuweiDB.shuttle = True
    assert P.SellFloor(P.Item(4304), 114) == 650 and P.SellFloor(P.Item(4304), 117) == 1300
    assert P.SellFloor(P.Item(3357), 114) is None                  # no faction verdict: no plan floor at 114
    c = ns.Post.Compute(rt.eval("{ itemID = 4304, qty = 1, unit = 700, house = 114 }"))
    assert [w.code for w in c.warnings.values()] == []
    c = ns.Post.Compute(rt.eval("{ itemID = 4304, qty = 1, unit = 1200, house = 117 }"))
    assert [w.code for w in c.warnings.values()] == ["plan"]
    g.WuweiDB.shuttle = False                                      # off: viewed as SELL ≥ 650 everywhere
    c = ns.Post.Compute(rt.eval("{ itemID = 4304, qty = 1, unit = 600, house = 114 }"))
    assert [w.code for w in c.warnings.values()] == ["plan"] and c.planItem.signal == "SELL"


def snap(rt, g, *items):
    g.owned = rt.eval("{" + ",".join(items) + "}")


def A(i, item, q, price, left, status=0):
    return ("{ auctionID = %d, itemKey = { itemID = %d }, quantity = %d, buyoutAmount = %d, timeLeftSeconds = %d, status = %d }"
            % (i, item, q, price, left, status))


def test_ledger_events():
    rt, ns, g, ah = boot2()
    cf, itf = ah.CommoditiesSellFrame, ah.ItemSellFrame
    L = lambda: g.WuweiDB.ledger
    tail = lambda n: list(L().values())[n:]
    assert g.WuweiDB.ledgerVersion == 1 and len(L()) == 0

    # Commodity buy: quote at StartCommoditiesPurchase, refined by COMMODITY_PRICE_UPDATED, recorded on SUCCEEDED
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(L()) == 0           # no quote context: nothing invented
    ah.StartCommoditiesPurchase(ah, 4338, 50, 300, 15000)
    g.fire("COMMODITY_PRICE_UPDATED", 310, 15500)
    assert len(L()) == 0                                                  # nothing until success
    g.fire("COMMODITY_PURCHASE_SUCCEEDED")
    e = L()[1]
    assert (e.kind, e.itemID, e.qty, e.unit, e.total, e.house, e.src, e.ts) == \
        ("buy", 4338, 50, 310, 15500, 114, "COMMODITY_PURCHASE_SUCCEEDED", g.server)
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(L()) == 1           # context was consumed
    ah.StartCommoditiesPurchase(ah, 4338, 5, 300, 1500); g.fire("COMMODITY_PURCHASE_FAILED")
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(L()) == 1           # failed quote is dropped

    # Item buyout: listing looked up when the buyout starts; recorded on AUCTION_HOUSE_PURCHASE_COMPLETED
    g.auctionInfo[777] = rt.eval("{ itemKey = { itemID = 4304 }, quantity = 1, buyoutAmount = 5000 }")
    ah.StartItemBuyout(ah, 777, 5000)
    g.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 999); assert len(L()) == 1  # other auction: ignored
    g.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 777)
    e = L()[2]
    assert (e.kind, e.itemID, e.qty, e.unit, e.total, e.auctionID, e.src) == \
        ("buy", 4304, 1, 5000, 5000, 777, "AUCTION_HOUSE_PURCHASE_COMPLETED")

    # Post (commodity): details cached by Blizzard's CachePendingPost, recorded on AUCTION_HOUSE_AUCTION_CREATED
    cf.CachePendingPost(cf, g.mkLoc(4338), 2, 30, 400)
    g.fire("AUCTION_HOUSE_AUCTION_CREATED", 901)
    e = L()[3]
    assert (e.kind, e.itemID, e.qty, e.unit, e.auctionID, e.src) == ("post", 4338, 30, 400, 901, "AUCTION_HOUSE_AUCTION_CREATED")
    assert g.WuweiDB.ledgerState.owned[901].itemID == 4338
    # Post (item, multisell of 2 auctions): one entry per created auction, qty 1 each, buyout as the price
    itf.CachePendingPost(itf, g.mkLoc(4304), 1, 2, None, 8000)
    g.fire("AUCTION_HOUSE_AUCTION_CREATED", 910); g.fire("AUCTION_HOUSE_AUCTION_CREATED", 911)
    g.fire("AUCTION_HOUSE_AUCTION_CREATED", 912)                          # not ours: no context left
    assert [(x.kind, x.qty, x.unit, x.auctionID) for x in tail(3)] == [("post", 1, 8000, 910), ("post", 1, 8000, 911)]
    n = len(L())

    # Owned-auction snapshots: known auctions first, then inferred expired / sold, status Sold, cancel, foreign post
    snap(rt, g, A(901, 4338, 30, 400, 7200), A(910, 4304, 1, 8000, 600), A(911, 4304, 1, 8000, 40000))
    g.fire("OWNED_AUCTIONS_UPDATED"); assert len(L()) == n                # all known: nothing new
    g.server += 1800                                                      # 910 ran out (600s); 901, 911 still up
    snap(rt, g, A(901, 4338, 30, 400, 5400), A(911, 4304, 1, 8000, 38200))
    g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[n + 1]
    assert (e.kind, e.itemID, e.auctionID, e.inferred) == ("expired", 4304, 910, True) and len(L()) == n + 1
    g.server += 600                                                       # 901 vanishes with ~4800s left: sold
    snap(rt, g, A(911, 4304, 1, 8000, 37600))
    g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[n + 2]
    assert (e.kind, e.itemID, e.qty, e.unit, e.auctionID, e.inferred) == ("sold", 4338, 30, 400, 901, True)
    snap(rt, g, A(911, 4304, 1, 8000, 37000, 1))                          # status Sold seen: recorded once, from the API
    g.fire("OWNED_AUCTIONS_UPDATED"); g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[n + 3]
    assert (e.kind, e.auctionID, e.inferred) == ("sold", 911, None) and len(L()) == n + 3
    snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED"); assert len(L()) == n + 3   # vanishing after status Sold: no second entry
    # Cancel via AUCTION_CANCELED (known from a post); unknown ids ignored
    cf.CachePendingPost(cf, g.mkLoc(2589), 2, 100, 40); g.fire("AUCTION_HOUSE_AUCTION_CREATED", 950)
    g.fire("AUCTION_CANCELED", 950); g.fire("AUCTION_CANCELED", 123)
    assert [x.kind for x in tail(n + 3)] == ["post", "cancel"]
    # A post made elsewhere is seen by snapshot only (inferred)
    snap(rt, g, A(960, 2772, 5, 900, 43000)); g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[n + 6]
    assert (e.kind, e.itemID, e.auctionID, e.src, e.inferred) == ("post", 2772, 960, "OWNED_AUCTIONS_UPDATED", True)
    # Another house's list is not judged against this house's auctions
    ns.House.Set("117"); snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED"); ns.House.Set("auto")
    assert len(L()) == n + 6 and g.WuweiDB.ledgerState.owned[960] is not None
    # A fresh DB's first snapshot is a baseline: no post entries
    rt2, ns2, g2, ah2 = boot2()
    snap(rt2, g2, A(5, 4338, 1, 400, 9000))
    g2.fire("OWNED_AUCTIONS_UPDATED"); assert len(g2.WuweiDB.ledger) == 0
    # AH open: one read-only owned-auction query each
    assert g.queried == 1 and g2.queried == 1


def test_cost_basis_pnl_cap_slash():
    rt, ns, g, ah = boot2()
    Lg = ns.Ledger

    def add(kind, item, qty, unit, total=None):
        Lg.Add(kind, item, qty, unit, "test", rt.eval("{ total = %s }" % (total if total else "nil")))

    assert Lg.CostBasis(4338) is None
    add("buy", 4338, 100, 300, 30000); add("buy", 4338, 100, 500, 50000)
    assert tuple(Lg.CostBasis(4338)) == (400, 200)                           # weighted AVERAGE: 80000 / 200
    add("post", 4338, 100, 700); add("cancel", 4338, 100, 700)               # posts/cancels never move the pool
    assert tuple(Lg.CostBasis(4338)) == (400, 200)
    add("sold", 4338, 50, 700)                                               # gross 35000, 5% cut 1750, cost 20000
    r = Lg.PnL()
    assert (r.spent, r.grossRevenue, r.netRevenue, r.cogs, r.realized) == (80000, 35000, 33250, 20000, 13250)
    assert tuple(Lg.CostBasis(4338)) == (400, 150) and (r.heldQty, r.heldCost) == (150, 60000)
    add("sold", 2589, 10, 100)                                               # sold with no buy on record: cost 0, flagged
    r = Lg.PnL(); assert r.unbasedSoldQty == 10 and r.realized == 13250 + 950
    assert {k: v for k, v in r.counts.items()} == {"buy": 2, "post": 1, "sold": 2, "cancel": 1, "expired": 0}
    g.zone = "Gadgetzan"                                                     # Blackwater: assumed 15% cut
    add("sold", 4338, 10, 1000); r = Lg.PnL()
    assert r.netRevenue == 33250 + 950 + 8500
    g.zone = "Orgrimmar"
    # CostBasis feeds the post helper
    cf = ah.CommoditiesSellFrame; cf.shown = True; cf.item = g.mkLoc(4338); cf.qty = 1; cf.price = 450
    cf.UpdatePostState(cf)
    assert "cost basis 4s/unit (140 held)" in strip(g.WuweiPostFrame.text.text), strip(g.WuweiPostFrame.text.text)

    # Size cap: oldest dropped first
    assert Lg.MAX_ENTRIES == 5000
    rt2, ns2, g2, _ = boot2()
    ns2.Ledger.MAX_ENTRIES = 50
    for i in range(1, 81):
        ns2.Ledger.Add("buy", 100, i, 10, "test")
    led = g2.WuweiDB.ledger
    assert len(led) == 50 and led[1].qty == 31 and led[50].qty == 80

    # Slash: summary and guarded clear
    slash = g.SlashCmdList["WUWEI"]; before = len(g.printed)
    slash("ledger")
    out = "\n".join(strip(x) for x in list(g.printed.values())[before:])
    assert "entries: 7 (cap 5000)" in out and "realized P&L" in out and "held (bought, unsold)" in out, out
    slash("ledger clear"); assert len(g.WuweiDB.ledger) == 7
    slash("ledger clear confirm"); assert len(g.WuweiDB.ledger) == 0 and Lg.CostBasis(4338) is None
    slash("post"); assert g.WuweiDB.post is False; slash("post"); assert g.WuweiDB.post is True


def test_partial_sales():
    """D-029: a shrinking quantity on a still-listed auction records the difference as a partial sold entry."""
    rt, ns, g, ah = boot2()
    L = lambda: g.WuweiDB.ledger
    snap(rt, g, A(1, 3357, 99, 400, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")        # baseline: known, no entries
    snap(rt, g, A(901, 4338, 30, 400, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")      # new auction after the baseline
    assert [(e.kind, e.qty) for e in L().values()] == [("post", 30), ("sold", 99)]   # 99 vanished early
    n = len(L())
    snap(rt, g, A(901, 4338, 30, 400, 8000)); g.fire("OWNED_AUCTIONS_UPDATED"); assert len(L()) == n    # unchanged
    snap(rt, g, A(901, 4338, 20, 400, 7000)); g.fire("OWNED_AUCTIONS_UPDATED")                           # 10 filled
    e = L()[n + 1]
    assert (e.kind, e.itemID, e.qty, e.unit, e.auctionID, e.inferred, e.partial, e.src) == \
        ("sold", 4338, 10, 400, 901, True, True, "OWNED_AUCTIONS_UPDATED") and len(L()) == n + 1
    assert g.WuweiDB.ledgerState.owned[901].qty == 20
    g.fire("OWNED_AUCTIONS_UPDATED"); assert len(L()) == n + 1                                          # idempotent
    snap(rt, g, A(901, 4338, 25, 400, 6000)); g.fire("OWNED_AUCTIONS_UPDATED")                           # grew: silent
    assert len(L()) == n + 1 and g.WuweiDB.ledgerState.owned[901].qty == 25
    snap(rt, g, A(901, 4338, 5, 400, 5000)); g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[n + 2]; assert (e.kind, e.qty, e.partial) == ("sold", 20, True)
    g.server += 100; snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED")                                       # remainder vanishes
    e = L()[n + 3]
    assert (e.kind, e.qty, e.partial, e.inferred) == ("sold", 5, None, True) and len(L()) == n + 3
    # Same remainder logic for expiry: the expired entry covers only what is left
    snap(rt, g, A(902, 2589, 100, 40, 300)); g.fire("OWNED_AUCTIONS_UPDATED")
    snap(rt, g, A(902, 2589, 60, 40, 200)); g.fire("OWNED_AUCTIONS_UPDATED")
    g.server += 300; snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED")
    tail = [(x.kind, x.qty, x.partial) for x in list(L().values())[-3:]]
    assert tail == [("post", 100, None), ("sold", 40, True), ("expired", 60, None)], tail
    # status Sold with a smaller quantity is the API's own sale record: no partial entry, one sold entry for rec.qty
    snap(rt, g, A(903, 4304, 10, 500, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")
    m = len(L())
    snap(rt, g, A(903, 4304, 4, 500, 9000, 1)); g.fire("OWNED_AUCTIONS_UPDATED")
    e = L()[m + 1]; assert (e.kind, e.qty, e.partial) == ("sold", 10, None) and len(L()) == m + 1


def test_house_confidence_guard():
    """D-030: Detect returns a confidence flag; an unconfident house never drives the owned-auction diff."""
    rt, ns, g, ah = boot2()
    H = ns.House
    conf = lambda: bool(tuple(H.Detect())[2])
    assert conf()                                                    # Orgrimmar, Horde
    g.zone = "Thunder Bluff"; assert conf()
    g.zone = "Undercity"; assert conf()
    g.zone = "Stranglethorn Vale"; assert not conf() and tuple(H.Detect())[0] == 114   # faction fallback, not a capital
    g.zone = "Stormwind City"; assert not conf()                     # Alliance capital while Horde: not a match
    g.faction = "Alliance"; assert conf() and tuple(H.Detect())[0] == 111
    g.zone = "Ironforge"; assert conf(); g.zone = "Darnassus"; assert conf()
    g.faction = None; assert not conf(); g.faction = "Horde"
    g.zone, g.subzone = "Stranglethorn Vale", "Booty Bay"; assert conf()   # Blackwater zone match
    g.zone, g.subzone = "Orgrimmar", ""
    H.BLACKWATER_MAPS[999] = True; g.mapID = 999; assert conf(); g.mapID = 85
    g.zone = "Ratchet"; assert not conf(); H.Set("114"); assert conf(); H.Set("auto")   # override is confident
    g.zone = "Orgrimmar"
    # Guard: standing at an unrecognised AH, a snapshot that lacks every stored auction changes nothing
    snap(rt, g, A(1, 4338, 5, 400, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")             # baseline at 114, confident
    snap(rt, g, A(2, 4304, 1, 8000, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")            # 'post' entry for 2, 1 is gone
    n = len(g.WuweiDB.ledger)
    owned_before = sorted(k for k in g.WuweiDB.ledgerState.owned.keys())
    g.zone = "Ratchet"
    snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED")
    snap(rt, g, A(77, 2589, 3, 40, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")
    assert len(g.WuweiDB.ledger) == n and sorted(g.WuweiDB.ledgerState.owned.keys()) == owned_before
    ns.Ledger.OnOwnedUpdated()                                        # direct call too
    assert len(g.WuweiDB.ledger) == n
    g.zone = "Orgrimmar"; snap(rt, g, A(2, 4304, 1, 8000, 9000)); g.fire("OWNED_AUCTIONS_UPDATED")   # confident again: works
    assert len(g.WuweiDB.ledger) == n and 2 in list(g.WuweiDB.ledgerState.owned.keys())
    snap(rt, g); g.fire("OWNED_AUCTIONS_UPDATED"); assert len(g.WuweiDB.ledger) == n + 1
    # A fresh DB does not baseline while unconfident
    rt2, ns2, g2, _ = boot2(); g2.zone = "Ratchet"
    snap(rt2, g2, A(5, 4338, 1, 400, 9000)); g2.fire("OWNED_AUCTIONS_UPDATED")
    assert not g2.WuweiDB.ledgerState.baselined and len(list(g2.WuweiDB.ledgerState.owned.keys())) == 0
    # /wuwei status says so and names the fix; a confident house does not
    before = len(g2.printed); g2.SlashCmdList["WUWEI"]("status")
    out = "\n".join(strip(x) for x in list(g2.printed.values())[before:])
    assert "NOT confident" in out and "/wuwei house <id>" in out, out
    g2.zone = "Orgrimmar"; before = len(g2.printed); g2.SlashCmdList["WUWEI"]("status")
    assert "NOT confident" not in "\n".join(strip(x) for x in list(g2.printed.values())[before:])


FORBIDDEN = re.compile(
    r"C_AuctionHouse\s*[.:]\s*(PostItem|PostCommodity|ConfirmPostItem|ConfirmPostCommodity|PlaceBid|"
    r"StartCommoditiesPurchase|ConfirmCommoditiesPurchase|CancelAuction|CancelSell)\b|"
    r"[:.]\s*(PostItem|PostCommodity|ConfirmPost|StartPost|Click)\s*\(|hooksecurefunc\s*\(\s*C_AuctionHouse|HasRestrictions")


def test_no_restricted_calls():
    """Every addon Lua file (comments stripped): no HasRestrictions API calls, no programmatic clicks. Hooks name
    Blizzard frame methods as strings only, and are post-hooks (hooksecurefunc)."""
    checked = 0
    for f in p1.toc_files():
        p = ROOT / f
        if not f.endswith(".lua") or not p.exists():
            continue
        if f == "Keys.lua":  # the keyboard flow is the one sanctioned caller; wuwei_keys_test.py polices it
            checked += 1
            continue
        checked += 1
        for n, line in enumerate(p.read_text().splitlines(), 1):
            code = line.split("--", 1)[0]
            assert not FORBIDDEN.search(code), f"{f}:{n}: {line.strip()}"
    assert checked >= 9
    for f in ("Post.lua", "Ledger.lua"):
        src = (ROOT / f).read_text()
        assert not re.search(r"(AuctionHouseFrame|SellFrame)\s*\.\w+\s*=\s*function", src), f


def main():
    test_fees_and_post_helper()
    test_protection_warnings()
    test_ledger_events()
    test_cost_basis_pnl_cap_slash()
    test_partial_sales()
    test_house_confidence_guard()
    test_no_restricted_calls()
    print("Wuwei phase 2 harness: OK")


if __name__ == "__main__":
    main()
