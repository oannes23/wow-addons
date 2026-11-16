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
          """{ sender = "Horde Auction House", subject = "Auction expired: Iron Ore", daysLeft = 29.9, itemCount = 1,
               firstQty = 40, firstLink = "|cffffffff|Hitem:2772::::::::60:::::|h[Iron Ore]|h|r" }""",
          """{ sender = "Blackwater Auction House", subject = "Auction canceled: Wildvine", daysLeft = 29.9, itemCount = 1,
               firstQty = 3, firstLink = "|Hitem:8153::::|h[Wildvine]|h" }""",
          """{ sender = "Horde Auction House", subject = "Sale Pending: Linen Cloth", daysLeft = 29.9,
               invoice = { type = "seller_temp_invoice", item = "Linen Cloth", bid = 1000 } }""",
          """{ sender = "Horde Auction House", subject = "Auction won: Thick Leather", daysLeft = 29.9,
               invoice = { type = "buyer", item = "Thick Leather", bid = 500 } }""",
          """{ sender = "Thrall", subject = "hi", money = 100, daysLeft = 3 }""")
    g.fire("MAIL_SHOW")
    got = [(e.outcome, e.itemID, e.itemName, e.qty, e.net, e.house, e.qtyUnknown) for e in invoices(g)]
    assert got == [("sold", None, "Linen Cloth", 1, 950, 114, True),       # no Linen Cloth seen before: name only
                   ("expired", 2772, "Iron Ore", 40, None, 114, None),       # item from the attached link
                   ("canceled", 8153, "Wildvine", 3, None, 117, None)], got
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


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("Wuwei mail harness: OK")
