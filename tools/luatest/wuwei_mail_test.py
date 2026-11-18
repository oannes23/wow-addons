"""Offline harness for Wuwei's mail invoices (Mail.lua, SPEC D-048).

  uv run --no-project --with lupa python tools/luatest/wuwei_mail_test.py
Reuses the Phase 1 mocks (wuwei_test.boot) with a mocked inbox: GetInboxNumItems / GetInboxHeaderInfo /
GetInboxInvoiceInfo in MailFrame.lua's return order, and the enUS auction mail subjects.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wuwei_test as p1  # noqa: E402

EXTRA = r"""
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction canceled: %s"
inbox = {}
function GetInboxNumItems() return #inbox, #inbox end
function GetInboxHeaderInfo(i)
  local m = inbox[i]
  return "icon", nil, m.sender, m.subject, m.money or 0, 0, m.daysLeft, m.itemCount, false, nil, nil, true, false,
    m.firstQty, m.firstLink
end
function GetInboxInvoiceInfo(i)
  local v = inbox[i].invoice
  if not v then return nil end
  return v.type, v.item, "SomeBuyer", v.bid, 0, v.deposit, v.cut, 0, nil, nil, v.count
end
"""

SOLD_FISH = """{ sender = "Blackwater Auction House", subject = "Auction successful: Cooked Glossy Mightfish", money = 32400,
  daysLeft = 29.98, invoice = { type = "seller", item = "Cooked Glossy Mightfish", bid = 38000, deposit = 100, cut = 5700,
  count = 20 } }"""


def boot():
    rt, ns = p1.boot(extra=EXTRA)
    g = rt.globals()
    g.NAMES[13927] = "Cooked Glossy Mightfish"
    return rt, ns, g


def inbox(rt, g, *mails):
    g.inbox = rt.eval("{" + ",".join(mails) + "}")


def invoices(g):
    return [e for e in g.WuweiDB.ledger.values() if e.kind == "invoice"]


def test_seller_invoice_and_dedupe():
    rt, ns, g = boot()
    ns.Ledger.Add("buy", 13927, 20, 379, "test")                   # gives the name resolver an item ID to match
    inbox(rt, g, SOLD_FISH)
    g.fire("MAIL_SHOW")
    (e,) = invoices(g)
    assert (e.outcome, e.itemID, e.qty, e.unit, e.gross, e.deposit, e.cut, e.net, e.house, e.src) == \
        ("sold", 13927, 20, 1900, 38000, 100, 5700, 32400, 117, "MAIL")
    assert e.sender == "Blackwater Auction House" and abs(e.at - (g.server - int(0.02 * 86400))) <= 1
    g.fire("MAIL_INBOX_UPDATE"); g.server += 120; g.fire("MAIL_SHOW")      # seen again (daysLeft unchanged = drift)
    assert len(invoices(g)) == 1
    # Two identical sales are two entries (multiset match)
    inbox(rt, g, SOLD_FISH, SOLD_FISH); g.fire("MAIL_INBOX_UPDATE")
    assert len(invoices(g)) == 2
    # Taking the gold deletes the mail: nothing new, nothing removed
    inbox(rt, g); g.fire("MAIL_INBOX_UPDATE"); assert len(invoices(g)) == 2
    # Summary prints the exact mail line; invoices stay out of the cost-basis pool
    r = ns.Ledger.PnL()
    assert (r.mail.sold, r.mail.soldQty, r.mail.net, r.mail.cut) == (2, 40, 64800, 11400)
    assert r.grossRevenue == 0 and tuple(ns.Ledger.CostBasis(13927)) == (379, 20)
    assert any("mail (exact): 2 sales, 40 units" in p1.strip_colors(x) for x in ns.Ledger.Summary().values())


def test_subject_fallback_returns_and_skips():
    rt, ns, g = boot()
    inbox(rt, g,
          # invoice data unavailable: the subject still gives an exact net, item by name only
          """{ sender = "Horde Auction House", subject = "Auction successful: Linen Cloth", money = 950, daysLeft = 29.5 }""",
          """{ sender = "Horde Auction House", subject = "Auction expired: Iron Ore (40)", daysLeft = 29.9, itemCount = 1,
               firstQty = 40, firstLink = "|cffffffff|Hitem:2772::::::::60:::::|h[Iron Ore]|h|r" }""",
          """{ sender = "Blackwater Auction House", subject = "Auction canceled: Wildvine (3)", daysLeft = 29.9, itemCount = 1,
               firstQty = 3, firstLink = "|Hitem:8153::::|h[Wildvine]|h" }""",
          """{ sender = "Horde Auction House", subject = "Sale Pending: Linen Cloth", daysLeft = 29.9,
               invoice = { type = "seller_temp_invoice", item = "Linen Cloth", bid = 1000 } }""",
          """{ sender = "Horde Auction House", subject = "Auction won: Thick Leather", daysLeft = 29.9,
               invoice = { type = "buyer", item = "Thick Leather", bid = 500 } }""",
          """{ sender = "Thrall", subject = "hi", money = 100, daysLeft = 3 }""")
    g.fire("MAIL_SHOW")
    got = [(e.outcome, e.itemID, e.itemName, e.qty, e.net, e.house) for e in invoices(g)]
    assert got == [("sold", None, "Linen Cloth", 1, 950, 114),             # no Linen Cloth seen before: name only
                   ("expired", 2772, "Iron Ore", 40, None, 114),             # qty from the subject, item from the link
                   ("canceled", 8153, "Wildvine", 3, None, 117)], got
    # The client's own name lookup is the last resort
    g.C_Item.GetItemInfoInstant = rt.eval("function(n) if n == 'Linen Cloth' then return 2589 end end")
    assert ns.Mail.ResolveName("Linen Cloth") == 2589 and ns.Mail.ResolveName("Nope") is None
    g.WuweiDB.mail = False
    inbox(rt, g, SOLD_FISH); g.fire("MAIL_SHOW"); assert len(invoices(g)) == 3   # switched off


def test_unresolved_name_and_missing_api():
    rt, ns, g = boot()
    inbox(rt, g, """{ sender = "Horde Auction House", subject = "Auction successful: Mystery Thing", money = 5, daysLeft = 29 }""")
    g.fire("MAIL_SHOW")
    (e,) = invoices(g)
    assert e.itemID is None and e.itemName == "Mystery Thing"
    assert ns.Ledger.PnL().counts.invoice == 1                     # no itemID: counted, never pooled, no error
    g.GetInboxInvoiceInfo = None                                   # legacy global absent: subject path only
    inbox(rt, g, SOLD_FISH); g.fire("MAIL_INBOX_UPDATE")
    e = invoices(g)[-1]
    assert (e.outcome, e.net, e.gross) == ("sold", 32400, None)
    g.GetInboxHeaderInfo = rt.eval("function() error('boom') end")  # a failing getter never breaks the scan
    g.fire("MAIL_INBOX_UPDATE")


CRATES = """{ sender = "Blackwater Auction House", subject = "Auction expired: Waylaid Crate: Apprentice Ore (10)",
  daysLeft = 29.9, itemCount = 2, firstQty = %s, firstLink = %s }"""
LINK = '"|Hitem:248683::::|h[Waylaid Crate: Apprentice Ore]|h"'
HARNESS = """{ sender = "Horde Auction House", subject = "Auction successful: Pattern: Raptor Hide Harness", money = %d,
  daysLeft = 29.95, invoice = { type = "seller", item = "Pattern: Raptor Hide Harness", bid = 89900, deposit = 375,
  cut = 4495, count = 1 } }"""


def test_same_mail_changing_in_the_inbox_d049():
    """In-game 2026-11-16: taking the gold, taking the items or a late item link recorded the same mail twice."""
    rt, ns, g = boot()
    g.NAMES[248683] = "Waylaid Crate: Apprentice Ore"
    g.NAMES[13287] = "Pattern: Raptor Hide Harness"
    ns.Ledger.Add("buy", 13287, 1, 3500, "test")
    inbox(rt, g, HARNESS % 85780, CRATES % ("nil", "nil"))             # crate link not loaded yet
    g.fire("MAIL_SHOW")
    inbox(rt, g, HARNESS % 0, CRATES % ("5", LINK)); g.fire("MAIL_INBOX_UPDATE")   # gold taken; link loaded
    g.server += 200
    inbox(rt, g, CRATES % ("nil", "nil")); g.fire("MAIL_INBOX_UPDATE")              # first stack taken
    got = [(e.outcome, e.itemID, e.itemName, e.qty, e.unit, e.gross, e.cut, e.net, e.house) for e in invoices(g)]
    assert got == [("sold", 13287, "Pattern: Raptor Hide Harness", 1, 89900, 89900, 4495, 85780, 114),
                   ("expired", 248683, "Waylaid Crate: Apprentice Ore", 10, None, None, None, None, 117)], got
    # net comes from the invoice even when the gold is already gone at the first read
    rt2, ns2, g2 = boot()
    inbox(rt2, g2, HARNESS % 0); g2.fire("MAIL_SHOW")
    assert invoices(g2)[0].net == 85780
    # Two really separate identical returns in one inbox stay two entries (multiset)
    inbox(rt, g, CRATES % ("5", LINK), CRATES % ("5", LINK)); g.fire("MAIL_INBOX_UPDATE")
    assert len(invoices(g)) == 3


def test_repair_d049():
    """The one-time repair collapses the duplicates 0.4.0 wrote (the owner's real 2026-11-16 mail, abridged)."""
    old = """{
      { kind = "buy", ts = 1, itemID = 248683, qty = 10, unit = 261, house = 114, src = "x" },
      { kind = "invoice", ts = 9, itemName = "Waylaid Crate: Apprentice Ore (10)", qtyUnknown = true, qty = 1, house = 117,
        src = "MAIL", outcome = "expired", at = 1794857992, sender = "Blackwater Auction House" },
      { kind = "invoice", ts = 9, itemName = "Cooked Glossy Mightfish (20)", itemID = 13927, qty = 20, house = 117,
        src = "MAIL", outcome = "expired", at = 1794864153, sender = "Blackwater Auction House" },
      { kind = "invoice", ts = 9, itemName = "Pattern: Raptor Hide Harness", itemID = 13287, qty = 1, unit = 89900,
        gross = 89900, deposit = 375, cut = 4495, net = 85780, house = 114, src = "MAIL", outcome = "sold",
        at = 1794848853, sender = "Horde Auction House" },
      { kind = "invoice", ts = 9, itemName = "Pattern: Raptor Hide Harness", itemID = 13287, qty = 1, unit = 89900,
        gross = 89900, deposit = 375, cut = 4495, house = 114, src = "MAIL", outcome = "sold", at = 1794848858,
        sender = "Horde Auction House" },
      { kind = "invoice", ts = 9, itemName = "Waylaid Crate: Apprentice Ore (10)", itemID = 248683, qty = 5, house = 117,
        src = "MAIL", outcome = "expired", at = 1794858003, sender = "Blackwater Auction House" },
      { kind = "invoice", ts = 9, itemName = "Cooked Glossy Mightfish (20)", qtyUnknown = true, qty = 1, house = 117,
        src = "MAIL", outcome = "expired", at = 1794864171, sender = "Blackwater Auction House" },
    }"""
    rt, ns, g = boot()
    g.NAMES[248683] = "Waylaid Crate: Apprentice Ore"
    g.WuweiDB.ledger = rt.eval(old)
    g.WuweiDB.mailRepair = None
    assert ns.Mail.Repair() == 7                       # 4 renamed / resized, 3 dropped
    got = [(e.outcome, e.itemID, e.itemName, e.qty, e.net, e.qtyUnknown) for e in invoices(g)]
    assert got == [("expired", 248683, "Waylaid Crate: Apprentice Ore", 10, None, None),
                   ("expired", 13927, "Cooked Glossy Mightfish", 20, None, None),
                   ("sold", 13287, "Pattern: Raptor Hide Harness", 1, 85780, None)], got
    assert len(g.WuweiDB.ledgerState.mail) == 3 and ns.Ledger.PnL().mail.sold == 1
    assert ns.Mail.Repair() == 0 and g.WuweiDB.mailRepair == 1             # once only
    # The same mails still in the inbox after the upgrade match the rekeyed records: nothing new
    g.server = 1794868400
    g.NAMES[13927] = "Cooked Glossy Mightfish"
    inbox(rt, g, """{ sender = "Blackwater Auction House", subject = "Auction expired: Cooked Glossy Mightfish (20)",
                      daysLeft = %r }""" % (30 - (1794868400 - 1794864160) / 86400))
    g.fire("MAIL_SHOW")
    assert len(invoices(g)) == 3


BAND = """{ sender = "Horde Auction House", subject = "Auction expired: Assault Band", daysLeft = %r, itemCount = 1 }"""
PLANS = """{ sender = "Horde Auction House", subject = "Auction expired: Plans: Searing Golden Blade", daysLeft = %r,
  itemCount = 1 }"""


def dl(g, at):
    """daysLeft that makes the estimate read `at` at the current server time."""
    return 30 - (g.server - at) / 86400


def test_drifted_estimate_d053():
    """In game 2026-11-18: two expired mails left in the inbox read at 01:51Z with arrival = their expiry, and at 03:20Z
    with arrival +2937 s for both. 0.6.0 recorded each twice."""
    rt, ns, g = boot()
    g.NAMES[13095], g.NAMES[12261] = "Assault Band", "Plans: Searing Golden Blade"
    g.server = 1794966700                                              # 01:51:40Z
    inbox(rt, g, BAND % dl(g, 1794964766), PLANS % dl(g, 1794964797)); g.fire("MAIL_SHOW")
    assert len(invoices(g)) == 2
    g.server = 1794972043                                              # 03:20:43Z, both estimates +2937 s
    inbox(rt, g, BAND % dl(g, 1794967703), PLANS % dl(g, 1794967734)); g.fire("MAIL_SHOW")
    assert len(invoices(g)) == 2, [(e.itemName, e.at) for e in invoices(g)]
    # A new identical return beside the old one (relisted from bags, expired again): only the newest is new
    g.server += 7200
    inbox(rt, g, BAND % dl(g, 1794967703), BAND % dl(g, g.server - 60), PLANS % dl(g, 1794967734))
    g.fire("MAIL_INBOX_UPDATE")
    assert [e.itemName for e in invoices(g)] == ["Assault Band", "Plans: Searing Golden Blade", "Assault Band"]
    # Taken: the records leave the inbox. A later identical mail is new even when its estimate lands next to a
    # taken one's, and a drifted read of it later is still the same mail.
    inbox(rt, g); g.fire("MAIL_INBOX_UPDATE")
    assert all(s.p is False for s in g.WuweiDB.ledgerState.mail.values())
    g.server += 3000
    inbox(rt, g, BAND % dl(g, g.server - 3000 + 400)); g.fire("MAIL_SHOW")    # arrived 400 s after the last one taken
    assert len(invoices(g)) == 4
    g.server += 5000
    inbox(rt, g, BAND % dl(g, g.server - 5000 + 400 + 2500)); g.fire("MAIL_SHOW")
    assert len(invoices(g)) == 4


def test_incomplete_scan_keeps_presence_d053():
    rt, ns, g = boot()
    g.NAMES[13095] = "Assault Band"
    inbox(rt, g, BAND % 29.9); g.fire("MAIL_SHOW")
    rt.execute("GetInboxNumItems = function() return #inbox, #inbox + 60 end")   # more mail than the client shows
    inbox(rt, g); g.fire("MAIL_INBOX_UPDATE")
    assert all(s.p is True for s in g.WuweiDB.ledgerState.mail.values())  # unseen is not gone
    g.server += 4000
    inbox(rt, g, BAND % 29.9); g.fire("MAIL_SHOW")                      # drifted 4000 s: still the same mail
    assert len(invoices(g)) == 1
    # MAIL_SHOW can read an unloaded cache (empty inbox): that proves nothing is gone
    rt.execute("GetInboxNumItems = function() return #inbox, #inbox end")
    inbox(rt, g); g.fire("MAIL_SHOW")
    g.server += 4000
    inbox(rt, g, BAND % 29.9); g.fire("MAIL_INBOX_UPDATE")
    assert len(invoices(g)) == 1


def test_settle_d054():
    """In game 2026-11-17/18: 14 Cooked Mightfish sold while away (invoice read 18:56Z); at the next AH visit the
    auction was gone after its expiry, so D-017 guessed expired."""
    rt, ns, g = boot()
    L = ns.Ledger
    # Older entries that must not take the invoice: a confirmed expiry, another house, a partial sale
    conf = L.Add("expired", 13927, 14, 800, "AUCTION_HOUSE_AUCTIONS_EXPIRED", rt.eval("{ auctionID = 6, house = 117 }"))
    other = L.Add("expired", 13927, 14, 800, "OWNED_AUCTIONS_UPDATED", rt.eval("{ auctionID = 7, inferred = true, house = 114 }"))
    part = L.Add("sold", 13927, 14, 800, "OWNED_AUCTIONS_UPDATED", rt.eval("{ auctionID = 8, inferred = true, partial = true, house = 117 }"))
    guess = L.Add("expired", 13927, 14, 800, "OWNED_AUCTIONS_UPDATED", rt.eval("{ auctionID = 101623502, inferred = true, house = 117 }"))
    twin = L.Add("expired", 13927, 14, 800, "OWNED_AUCTIONS_UPDATED", rt.eval("{ auctionID = 10, inferred = true, house = 117 }"))
    cheap = L.Add("invoice", 13927, 14, 700, "MAIL", rt.eval('{ outcome = "sold", house = 117, at = 5 }'))
    assert L.Settle() == 0 and guess.kind == "expired"                  # wrong unit price: not this auction
    inv = L.Add("invoice", 13927, 14, 800, "MAIL", rt.eval('{ outcome = "sold", house = 117, at = 9 }'))
    assert L.Settle() == 1
    assert (guess.kind, guess.inferred, guess.settled, guess.wasKind, inv.settles) == ("sold", None, True, "expired", 101623502)
    assert other.kind == "expired" and other.inferred and part.inferred and cheap.settles is None
    assert conf.kind == "expired" and conf.settled is None
    assert (twin.kind, twin.inferred) == ("expired", True)                 # one invoice settles one auction
    assert L.Settle() == 0                                               # idempotent: one invoice, one entry
    # P&L counts the corrected sale
    assert L.PnL().grossRevenue == 2 * 14 * 800                          # the partial sale plus the corrected one
    # A return mail confirms a guessed sale as an expiry
    s = L.Add("sold", 2772, 40, 50, "OWNED_AUCTIONS_UPDATED", rt.eval("{ auctionID = 9, inferred = true, house = 114 }"))
    L.Add("invoice", 2772, 40, None, "MAIL", rt.eval('{ outcome = "expired", house = 114, at = 11 }'))
    assert L.Settle() == 1 and (s.kind, s.wasKind) == ("expired", "sold")


def test_settle_from_mail_scan_d054():
    """The invoice read after the guess settles it from Mail.Scan."""
    rt, ns, g = boot()
    guess = ns.Ledger.Add("expired", 13927, 20, 1900, "OWNED_AUCTIONS_UPDATED",
                          rt.eval("{ auctionID = 1, inferred = true, house = 117 }"))
    inbox(rt, g, SOLD_FISH); g.fire("MAIL_SHOW")
    assert (guess.kind, guess.wasKind) == ("sold", "expired")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("Wuwei mail harness: OK")
