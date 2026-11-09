"""Keyboard-flow harness for addons/Wuwei (Keys.lua, Bindings.xml).

  uv run --no-project --with lupa python tools/luatest/wuwei_keys_test.py
Reuses the Phase 1/2 mocks. Covers the buy state machine (search -> start -> quote -> confirm + ledger), the price guard,
nothing-available, quote expiry, skip, SELL never posting, one purchase call per press, bindings plumbing, and a grep
that confines purchase APIs to the press path.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402
import wuwei_phase2_test as p2  # noqa: E402

ROOT = p1.ROOT

KEYS_EXTRA = r"""
ahCalls = {}; pressNo = 0; quoteLeft = 45; autoQuote = nil; combat = false
LISTINGS = {
  [3357] = { { 10, 3000 }, { 30, 3900 }, { 50, 5000 } },   -- {qty, unit copper}: 40 units at or below buyMax 4000
  [2589] = { { 100, 90 }, { 100, 95 } },                    -- everything above buyMax 35
}
local function rec(name, ...) ahCalls[#ahCalls+1] = { name = name, press = pressNo, args = { ... } } end
C_AuctionHouse.GetItemKeyInfo = function(key) return { isCommodity = commodity } end   -- false = gear
C_AuctionHouse.GetNumCommoditySearchResults = function(id) return LISTINGS[id] and #LISTINGS[id] or 0 end
C_AuctionHouse.GetCommoditySearchResultInfo = function(id, i)
  local r = LISTINGS[id] and LISTINGS[id][i]
  return r and { itemID = id, quantity = r[1], unitPrice = r[2], auctionID = i } or nil
end
C_AuctionHouse.StartCommoditiesPurchase = function(id, q) rec("Start", id, q)
  if autoQuote then fire("COMMODITY_PRICE_UPDATED", autoQuote[1], autoQuote[2]) end end
C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, q) rec("Confirm", id, q) end
C_AuctionHouse.CancelCommoditiesPurchase = function() rec("Cancel") end
C_AuctionHouse.GetQuoteDurationRemaining = function() return quoteLeft end
for _, n in ipairs({ "PostCommodity", "PostItem", "ConfirmPostItem", "ConfirmPostCommodity", "PlaceBid", "CancelAuction" }) do
  C_AuctionHouse[n] = function() rec(n) end
end
function mkAH3()
  local ah = mkAH2()
  function ah:QueryItem(ctx, key) sent[#sent+1] = { ctx = ctx, id = key.itemID } end
  function ah:SelectBrowseResult(r) selected[#selected+1] = r end
  ah.postItem = {}
  function ah:SetPostItem(loc) ah.postItem[#ah.postItem+1] = loc end   -- Blizzard's own method; selects, never posts
  return ah
end
BAGS = { [1] = { [2] = 8153, [5] = 4338 } }
NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
C_Container = {
  GetContainerNumSlots = function(b) return b == 1 and 6 or 0 end,
  GetContainerItemID = function(b, s) return BAGS[b] and BAGS[b][s] end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, b, s) return { bag = b, slot = s, itemID = BAGS[b][s] } end }
function InCombatLockdown() return combat end
bindings = {}
function GetBindingKey(a) local t = {} for k, v in pairs(bindings) do if v == a then t[#t+1] = k end end table.sort(t) return t[1], t[2] end
function GetBindingAction(k) return bindings[k] or "" end
function SetBinding(k, a) bindings[k] = a return true end
saved = 0
function SaveBindings() saved = saved + 1 end
function GetCurrentBindingSet() return 1 end
"""


def boot3(shuttle=True):
    rt, ns = p1.boot(extra=p2.EXTRA + KEYS_EXTRA)
    g = rt.globals()
    g.WuweiDB.shuttle = shuttle  # most flows here exercise the shuttle buy path (toggle on); default is off (D-028)
    g.mkAH3()
    g.fire("AUCTION_HOUSE_SHOW")
    return rt, ns, g


def calls(g):
    return [(c.name, *list(c.args.values())) if c.args else (c.name,) for c in g.ahCalls.values()]


def press(g, key):
    g.pressNo += 1
    (g.Wuwei_Accept if key == "accept" else g.Wuwei_Skip)()


def banner(g):
    f = g.WuweiKeysFrame
    return p1.strip_colors(f.head.text), p1.strip_colors(f.step.text)


def out_since(g, n):
    return "\n".join(p1.strip_colors(x) for x in list(g.printed.values())[n:])


def to_ready(g, item=3357):
    press(g, "accept")
    g.fire("COMMODITY_SEARCH_RESULTS_UPDATED", item)


def test_shuttle_off_queue():
    rt, ns, g = boot3(shuttle=False)
    K = ns.Keys
    assert [p.id for p in K.state.queue.values()] == [8153, 4304, 4338, 2589]   # Liferoot (info only) and HOLD dropped
    assert K.Mode(K.state.queue[2], 114) == "sell"                              # 4304 via its faction-side SELL
    for _ in range(6):
        press(g, "accept"); press(g, "skip")
    assert all(c.name != "StartCommoditiesPurchase" or c.args[1] not in (3357, 4304) for c in g.ahCalls.values())
    g.SlashCmdList["WUWEI"]("shuttle on")
    assert [p.id for p in K.state.queue.values()][:2] == [3357, 4304]           # toggle rebuilds the queue


def test_buy_path():
    rt, ns, g = boot3()
    K = ns.Keys
    assert [p.id for p in K.state.queue.values()] == [3357, 4304, 8153, 4338, 2589]   # HOLD 2772 dropped
    head, step = banner(g)
    assert head == "[1/5] SHUTTLE Liferoot ×20 · → BW ≥ 65s", head
    assert step == "Accept: search · Skip: next (2/5)", step

    press(g, "accept")                                              # step 1: search only
    assert calls(g) == [] and [s.id for s in g.sent.values()] == [3357] and K.state.phase == "searching"
    press(g, "accept")                                              # results not in yet: no server action
    assert calls(g) == [] and len(g.sent) == 1
    g.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 999)                 # someone else's item
    assert K.state.phase == "searching"
    g.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 3357)
    assert banner(g)[1] == "Accept: buy up to 20 at ≤ 40s · Skip: next (2/5)", banner(g)   # min(qtyCap 20, 40 avail)

    press(g, "accept")                                              # step 2: start, qty clamped
    assert calls(g) == [("Start", 3357, 20)] and K.state.phase == "quoting"
    assert len(g.WuweiDB.ledger) == 0
    press(g, "accept")                                              # quote not here yet: nothing
    assert calls(g) == [("Start", 3357, 20)]
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 78000)                  # step 3: quote 39s <= 40s
    assert K.state.phase == "quoted"
    assert banner(g)[1].startswith("Accept: CONFIRM 20 for 7g 80s (39s each, ≤ 40s)"), banner(g)
    n = len(g.ahCalls)
    for ev in ("COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_DATA_LOAD_RESULT"):    # events never call the AH
        g.fire(ev, 3357)
    assert len(g.ahCalls) == n and len(g.WuweiDB.ledger) == 0

    press(g, "accept")                                              # confirm
    assert calls(g) == [("Start", 3357, 20), ("Confirm", 3357, 20)] and K.state.phase == "purchasing"
    g.fire("COMMODITY_PURCHASE_SUCCEEDED")
    e = g.WuweiDB.ledger[1]
    assert (e.kind, e.itemID, e.qty, e.unit, e.total, e.house, e.src) == \
        ("buy", 3357, 20, 3900, 78000, 114, "COMMODITY_PURCHASE_SUCCEEDED") and len(g.WuweiDB.ledger) == 1
    assert K.state.phase == "idle"

    # Synchronous COMMODITY_PRICE_UPDATED (fired inside the Start call) still lands in the right phase
    g.autoQuote = rt.eval("{ 3000, 60000 }")
    to_ready(g); press(g, "accept")
    assert K.state.phase == "quoted" and K.state.unit == 3000
    # Exactly the call count we expect over the whole run, at most one per press
    per = {}
    for c in g.ahCalls.values():
        per[c.press] = per.get(c.press, 0) + 1
    assert max(per.values()) == 1, per


def test_quote_over_max_cancels():
    rt, ns, g = boot3()
    to_ready(g); press(g, "accept")
    g.fire("COMMODITY_PRICE_UPDATED", 4100, 82000)                  # unit 41s > 40s
    assert banner(g)[1].startswith("Quote 41s each is over ≤ 40s: Accept cancels")
    before = len(g.printed)
    press(g, "accept")
    assert calls(g) == [("Start", 3357, 20), ("Cancel",)], calls(g)          # cancel, never confirm
    assert "Cancelled: quote 41s each exceeds your limit 40s." in out_since(g, before)
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 0   # nothing recorded
    assert ns.Keys.state.phase == "idle"
    # Unit within limit but the total is not (tiered price): also cancel
    to_ready(g); press(g, "accept")
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 80100)   # > 20 x 40s
    press(g, "accept")
    assert [c[0] for c in calls(g)] == ["Start", "Cancel", "Start", "Cancel"]


def test_nothing_available():
    rt, ns, g = boot3()
    for _ in range(4): press(g, "skip")                              # -> 2589 BUY, buyMax 35, listings 90+
    assert ns.Keys.state.queue[ns.Keys.state.idx].id == 2589
    to_ready(g, 2589)
    assert banner(g)[1].startswith("Nothing listed at ≤ 35c"), banner(g)
    before = len(g.printed)
    press(g, "accept")
    assert calls(g) == [] and "Nothing listed at ≤ 35c for Linen Cloth; not starting a purchase." in out_since(g, before)
    assert ns.Keys.state.phase == "idle"


def test_quote_expiry_restarts():
    rt, ns, g = boot3()
    to_ready(g); press(g, "accept")
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 78000)
    g.quoteLeft = 0
    before = len(g.printed)
    press(g, "accept")                                               # expired: re-quote, NOT confirm
    assert [c[0] for c in calls(g)] == ["Start", "Start"] and ns.Keys.state.phase == "quoting"
    assert "Quote expired; requesting a new one." in out_since(g, before)
    g.quoteLeft = 45
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 78000); press(g, "accept")
    assert [c[0] for c in calls(g)] == ["Start", "Start", "Confirm"]
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 1
    # A failed/unavailable quote resets without recording
    to_ready(g); press(g, "accept"); g.fire("COMMODITY_PRICE_UNAVAILABLE")
    assert ns.Keys.state.phase == "idle"; g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 1


def test_skip():
    rt, ns, g = boot3()
    K = ns.Keys
    press(g, "skip")                                                 # idle: no server action, advances
    assert calls(g) == [] and K.state.idx == 2
    for _ in range(4): press(g, "skip")                              # wraps 2..5 -> 1
    assert K.state.idx == 1 and calls(g) == []
    to_ready(g); press(g, "accept")                                  # quoting
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 78000)
    press(g, "skip")                                                 # cancels the pending quote and advances
    assert calls(g) == [("Start", 3357, 20), ("Cancel",)] and K.state.idx == 2 and K.state.phase == "idle"
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 0
    assert banner(g)[0].startswith("[2/5] SHUTTLE Thick Leather")
    # Skip while still waiting for the quote also cancels
    for _ in range(4): press(g, "skip")
    to_ready(g); press(g, "accept"); press(g, "skip")
    assert [c[0] for c in calls(g)] == ["Start", "Cancel", "Start", "Cancel"]
    # Skip during a search: nothing to cancel
    press(g, "accept"); n = len(g.ahCalls); press(g, "skip"); assert len(g.ahCalls) == n


def test_sell_never_posts():
    rt, ns, g = boot3()
    K = ns.Keys
    press(g, "skip"); press(g, "skip")                               # 8153 SELL (Wildvine): in bags (bag 1 slot 2)
    assert banner(g)[1].startswith("Accept: open the sell flow (post with Blizzard's Post button, sell ≥ 50s)")
    ah = g.AuctionHouseFrame
    press(g, "accept")                                               # default: bag pick is opt-in (taint check pending)
    assert len(ah.postItem) == 0 and calls(g) == []
    ns.db.keysSellSelect = True                                      # JNS opts in after the in-game taint check
    before = len(g.printed)
    press(g, "accept"); press(g, "accept")
    assert len(ah.postItem) == 2 and ah.postItem[1].itemID == 8153   # selected in Blizzard's sell frame only
    assert calls(g) == [] and len(g.sent) == 0                       # no purchase, post, bid or cancel call; no search
    assert "sell flow opened. Floor ≥ 50s" in out_since(g, before)
    press(g, "skip"); press(g, "accept")                             # 4338 SELL, also in bags
    assert ah.postItem[3].itemID == 4338 and calls(g) == []
    press(g, "skip")                                                 # 2589 BUY; leave via skip back to a SELL
    # Item not in bags: say so, still no calls
    g.BAGS = rt.eval("{}")
    for _ in range(3): press(g, "skip")
    before = len(g.printed); press(g, "accept")
    assert "No Wildvine in your bags." in out_since(g, before) and calls(g) == []
    # SHUTTLE at the destination (Blackwater) is the sell side
    g.zone = "Everlook"
    g.BAGS = rt.eval("{ [1] = { [2] = 8153, [5] = 4338, [3] = 3357 } }")
    g.fire("AUCTION_HOUSE_CLOSED"); g.fire("AUCTION_HOUSE_SHOW")
    assert K.state.house == 117
    q = K.state.queue
    assert [p.id for p in q.values()][0] == 3357 and K.Mode(q[1], 117) == "sell"
    assert "Accept: open the sell flow" in banner(g)[1]
    assert q[K.state.idx].id == 8153                                 # the cursor survives a reopen
    while q[K.state.idx].id != 3357: press(g, "skip")
    press(g, "accept")
    assert calls(g) == [] and len(g.sent) == 0 and ah.postItem[len(ah.postItem)].itemID == 3357


def test_gear_and_misc():
    rt, ns, g = boot3()
    K = ns.Keys
    g.commodity = False                                              # item endpoint: not supported
    press(g, "accept")
    assert calls(g) == [] and len(g.sent) == 0 and K.state.gear
    assert banner(g)[1].startswith("Gear: click in Blizzard UI")
    g.commodity = True
    # AH closed: refuse without touching anything
    g.AuctionHouseFrame.shown = False
    K.Reset(); K.state.gear = None
    before = len(g.printed); press(g, "accept")
    assert "Open the auction house first." in out_since(g, before) and calls(g) == []
    g.AuctionHouseFrame.shown = True
    # Search that never answers is re-sent after the retry window; throttled searches do not advance
    press(g, "accept"); assert K.state.phase == "searching" and len(g.sent) == 1
    g.now += K.SEARCH_RETRY + 1; press(g, "accept"); assert len(g.sent) == 2
    # Closing the AH resets the machine and hides the banner; a stale quote never survives a reopen
    to_ready(g); press(g, "accept"); g.fire("AUCTION_HOUSE_CLOSED")
    assert K.state.phase == "idle" and not g.WuweiKeysFrame.shown
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 0
    g.fire("AUCTION_HOUSE_SHOW"); assert g.WuweiKeysFrame.shown
    # Master switch and keys switch hide the banner
    g.fire("AUCTION_HOUSE_CLOSED"); g.WuweiDB.keys = False; g.fire("AUCTION_HOUSE_SHOW")
    assert not g.WuweiKeysFrame.shown


def test_bindings_and_slash():
    rt, ns, g = boot3()
    xml = (ROOT / "Bindings.xml").read_text()
    names = re.findall(r'<Binding name="(\w+)"[^>]*category="(\w+)"[^>]*>\s*([^<]+?)\s*</Binding>', xml)
    assert names == [("WUWEI_ACCEPT", "BINDING_HEADER_WUWEI", "Wuwei_Accept();"),
                     ("WUWEI_SKIP", "BINDING_HEADER_WUWEI", "Wuwei_Skip();")], names
    assert g.BINDING_HEADER_WUWEI == "Wuwei"
    for n, _, _ in names:
        assert g["BINDING_NAME_" + n]
    # The only globals the addon adds (SavedVariables, slash, compartment aside)
    slash = g.SlashCmdList["WUWEI"]
    before = len(g.printed); slash("keys")
    out = out_since(g, before)
    assert out.count("unbound") == 2 and "WUWEI_ACCEPT" in out and "WUWEI_SKIP" in out, out
    g.bindings["F9"] = "SOMETHING_ELSE"
    g.bindings["["] = "TAKEN"                                        # default for Skip is already used elsewhere
    before = len(g.printed); slash("keys default")
    out = out_since(g, before)
    assert g.bindings["]"] == "WUWEI_ACCEPT" and g.bindings["["] == "TAKEN" and g.saved == 1
    assert "WUWEI_SKIP not set: [ is already bound to TAKEN." in out, out
    before = len(g.printed); slash("keys")
    assert "WUWEI_ACCEPT: ]" in out_since(g, before)
    slash("keys default"); assert g.saved == 1                       # already bound: nothing to save
    rt.execute('bindings["]"] = nil')
    g.combat = True; before = len(g.printed); slash("keys default")
    assert g.bindings["]"] is None and "Not in combat." in out_since(g, before)


BANNED = re.compile(
    r"C_AuctionHouse\s*[.:]\s*(PostItem|PostCommodity|ConfirmPostItem|ConfirmPostCommodity|PlaceBid|CancelAuction|CancelSell)\b|"
    r"[:.]\s*(PostItem|PostCommodity|ConfirmPost|StartPost|Click)\s*\(|hooksecurefunc\s*\(\s*C_AuctionHouse")
PURCHASE = re.compile(r"C_AuctionHouse\s*[.:]\s*(StartCommoditiesPurchase|ConfirmCommoditiesPurchase|CancelCommoditiesPurchase)\b")
WRAPPERS = ("StartQuote", "ConfirmQuote", "CancelQuote")


def code_lines(path):
    return [(n, line.split("--", 1)[0]) for n, line in enumerate(path.read_text().splitlines(), 1)]


def test_grep_safety():
    # 1. No other file calls a purchase API at all.
    for f in p1.toc_files():
        p = ROOT / f
        if not f.endswith(".lua") or not p.exists() or f == "Keys.lua":
            continue
        for n, code in code_lines(p):
            assert not PURCHASE.search(code) and not re.search(r"\b(Start|Confirm|Cancel)Quote\b", code), f"{f}:{n}"
    # 2. In Keys.lua: never a post/bid/cancel-auction call; purchase calls only in the wrapper block, one per wrapper,
    #    each behind Gate().
    keys = ROOT / "Keys.lua"
    text = keys.read_text().splitlines()
    begin = next(i for i, l in enumerate(text, 1) if "PRESS-PATH:" in l and "BEGIN" in l)
    end = next(i for i, l in enumerate(text, 1) if "PRESS-PATH END" in l)
    assert begin < end
    seen = 0
    for n, code in code_lines(keys):
        assert not BANNED.search(code), f"Keys.lua:{n}: {code.strip()}"
        if PURCHASE.search(code):
            seen += 1
            assert begin < n < end, f"Keys.lua:{n}: purchase API outside the press-path block"
            assert "Gate()" in code and re.match(r"\s*local function (Start|Confirm|Cancel)Quote\(", code), code
    assert seen == 3
    # 3. The wrappers are called only from Accept/Skip implementations (before the event handler table), never from events.
    h_start = next(i for i, l in enumerate(text, 1) if l.startswith("local H = {}"))
    for n, code in code_lines(keys):
        if re.search(r"\b(StartQuote|ConfirmQuote|CancelQuote)\(", code) and not re.match(r"\s*local function", code):
            assert end < n < h_start, f"Keys.lua:{n}: wrapper used outside the press path"
        if n > h_start:
            assert not re.search(r"\b(Press|AcceptImpl|SkipImpl|DoStart|DoQuoted|Keys\.Accept|Keys\.Skip|Wuwei_Accept|Wuwei_Skip)\b", code), \
                f"Keys.lua:{n}: event-side code reaches the press path: {code.strip()}"
    # 4. Press-path entry points are reached only by the binding handlers; the handlers only call those.
    assert re.search(r"function Wuwei_Accept\(\) Keys\.Accept\(\) end", keys.read_text())
    assert re.search(r"function Wuwei_Skip\(\) Keys\.Skip\(\) end", keys.read_text())
    for f in p1.toc_files():
        p = ROOT / f
        if f.endswith(".lua") and p.exists() and f != "Keys.lua":
            for n, code in code_lines(p):
                assert not re.search(r"\bKeys\.(Accept|Skip)\b|Wuwei_(Accept|Skip)", code), f"{f}:{n}"
    xml = (ROOT / "Bindings.xml").read_text()
    bodies = re.findall(r">\s*([^<>]+?)\s*</Binding>", xml)
    assert bodies == ["Wuwei_Accept();", "Wuwei_Skip();"]
    # 5. Every chat message goes through ns.L (the only literals allowed are formats/separators).
    for n, code in code_lines(keys):
        if re.search(r"\bSay\(", code) and not re.match(r"\s*local function Say", code):
            assert "L[" in code or "format(" in code and "L[" in code, f"Keys.lua:{n}: message without ns.L: {code.strip()}"
    # 6. Runtime gate exists.
    assert "S.pressing" in keys.read_text() and "S.used" in keys.read_text()
    # 7. TOC lists Keys.lua; Bindings.xml is picked up by name (not listed).
    assert "Keys.lua" in p1.toc_files() and "Bindings.xml" not in (ROOT / "Wuwei_Forever.toc").read_text()


def test_press_flag_and_errors():
    """The press flag drops after every press; an API error resets the machine and drops the ledger context."""
    rt, ns, g = boot3()
    to_ready(g); press(g, "accept")
    g.fire("COMMODITY_PRICE_UPDATED", 3900, 78000)
    press(g, "accept")
    assert [c[0] for c in calls(g)] == ["Start", "Confirm"] and not ns.Keys.state.pressing
    g.fire("COMMODITY_PURCHASE_SUCCEEDED")
    rt.execute('C_AuctionHouse.StartCommoditiesPurchase = function() error("boom") end')
    to_ready(g); before = len(g.printed); press(g, "accept")
    assert "error: " in out_since(g, before) and ns.Keys.state.phase == "idle" and not ns.Keys.state.pressing
    g.fire("COMMODITY_PURCHASE_SUCCEEDED"); assert len(g.WuweiDB.ledger) == 1       # no phantom buy from the failed start


def main():
    test_shuttle_off_queue()
    test_buy_path()
    test_quote_over_max_cancels()
    test_nothing_available()
    test_quote_expiry_restarts()
    test_skip()
    test_sell_never_posts()
    test_gear_and_misc()
    test_bindings_and_slash()
    test_grep_safety()
    test_press_flag_and_errors()
    print("Wuwei keys harness: OK")


if __name__ == "__main__":
    main()
