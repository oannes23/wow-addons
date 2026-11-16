-- Trade ledger: purchases, posts, sales, cancels and expiries, stored in WuweiDB.ledger (schema: SPEC "Ledger export").
-- Everything here is event- or hook-driven and read-only: no PostItem/PostCommodity/PlaceBid/Start*Purchase/CancelAuction
-- calls (all HasRestrictions). Hooks are hooksecurefunc post-hooks on Blizzard's own methods, so nothing is tainted.
local _, ns = ...

local floor, min, ipairs, pairs, sort, tremove = math.floor, math.min, ipairs, pairs, table.sort, table.remove

local Ledger = {}
ns.Ledger = Ledger

Ledger.VERSION = 1
Ledger.MAX_ENTRIES = 5000 -- oldest entries are dropped beyond this (cost basis only replays what is kept)
Ledger.EXPIRY_SLACK = 120 -- s: a vanished auction whose last-seen expiry is within this window counts as expired

local pendingBuy        -- commodity quote: { itemID, qty, unit, total }
local itemBuys = {}     -- [auctionID] = { itemID, qty, buyout }
local pendingPost       -- from Blizzard's CachePendingPost: { itemID, qty, unit, isCommodity, left }
local cache             -- replay result; nil = dirty

local function Round(x) return floor(x + 0.5) end

function Ledger.Entries()
  return ns.db and ns.db.ledger or {}
end

-- Append one entry. `extra` may carry total, auctionID, inferred, and the invoice fields (D-048; an invoice may
-- carry itemName instead of itemID, and its own house).
function Ledger.Add(kind, itemID, qty, unit, src, extra)
  local db = ns.db
  if not (db and db.ledger and (itemID or (extra and extra.itemName))) then return nil end
  local e = {
    ts = GetServerTime(), kind = kind, itemID = itemID, qty = qty or 1,
    unit = unit and Round(unit) or nil, house = (ns.House.Detect()), src = src,
  }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  local l = db.ledger
  l[#l + 1] = e
  while #l > Ledger.MAX_ENTRIES do tremove(l, 1) end
  cache = nil
  return e
end

----------------------------------------------------------------------------------------------------
-- Cost basis and P&L: one chronological replay over the kept entries. AVERAGE-cost method (not FIFO):
-- every buy adds qty and total cost to the item's pool; every sold entry removes qty at the pool's current
-- average unit cost. Posts, cancels and expiries never change the pool (the goods are still ours).
----------------------------------------------------------------------------------------------------
-- Exact mail record (D-048). Kept out of the pools: it duplicates the owned-diff sold/expired/cancel rows.
local function AddMail(m, e)
  if e.outcome == "sold" then
    m.sold, m.soldQty = m.sold + 1, m.soldQty + (e.qty or 0)
    m.gross, m.cut, m.net = m.gross + (e.gross or 0), m.cut + (e.cut or 0), m.net + (e.net or 0)
  elseif e.outcome == "expired" or e.outcome == "canceled" then
    m[e.outcome] = m[e.outcome] + 1
  end
end

local function AddPool(r, p, e)
  local qty, unit = e.qty or 0, e.unit or 0
  if e.kind == "buy" then
    local total = e.total or qty * unit
    p.qty, p.cost = p.qty + qty, p.cost + total
    r.spent = r.spent + total
  elseif e.kind == "sold" then
    local gross = qty * unit
    local net = gross - Round(gross * (ns.Post and ns.Post.Cut(e.house) or 0.05))
    local take = min(qty, p.qty)
    local avg = p.qty > 0 and p.cost / p.qty or 0
    local cogs = avg * take
    p.qty, p.cost = p.qty - take, p.cost - cogs
    if p.qty <= 0 then p.qty, p.cost = 0, 0 end
    r.grossRevenue, r.netRevenue, r.cogs = r.grossRevenue + gross, r.netRevenue + net, r.cogs + cogs
    r.unbasedSoldQty = r.unbasedSoldQty + (qty - take)
  end
end

local function Replay()
  if cache then return cache end
  local pools = {}
  local r = { spent = 0, grossRevenue = 0, netRevenue = 0, cogs = 0, realized = 0, unbasedSoldQty = 0,
    counts = { buy = 0, post = 0, sold = 0, cancel = 0, expired = 0, invoice = 0 }, items = pools,
    mail = { sold = 0, soldQty = 0, gross = 0, cut = 0, net = 0, expired = 0, canceled = 0 } }
  for _, e in ipairs(Ledger.Entries()) do
    r.counts[e.kind] = (r.counts[e.kind] or 0) + 1
    if e.kind == "invoice" then
      AddMail(r.mail, e)
    elseif e.itemID then
      local p = pools[e.itemID]
      if not p then p = { qty = 0, cost = 0 } pools[e.itemID] = p end
      AddPool(r, p, e)
    end
  end
  r.realized = r.netRevenue - r.cogs
  r.heldQty, r.heldCost = 0, 0
  for _, p in pairs(pools) do r.heldQty, r.heldCost = r.heldQty + p.qty, r.heldCost + p.cost end
  cache = r
  return r
end

-- Weighted-average unit cost (integer copper) of the bought-and-unsold quantity, plus that quantity; nil if none.
function Ledger.CostBasis(itemID)
  local p = Replay().items[itemID]
  if not p or p.qty <= 0 then return nil end
  return Round(p.cost / p.qty), p.qty
end

function Ledger.PnL() return Replay() end

function Ledger.Clear()
  if ns.db then ns.db.ledger = {} end
  cache = nil
end

function Ledger.Summary()
  local Money = ns.Plan.Money
  local r = Replay()
  local c = r.counts
  return {
    string.format("entries: %d (cap %d) | buy %d, post %d, sold %d, cancel %d, expired %d, invoice %d",
      #Ledger.Entries(), Ledger.MAX_ENTRIES, c.buy, c.post, c.sold, c.cancel, c.expired, c.invoice),
    string.format("spent: %s | sales gross %s, net of cut %s", Money(r.spent), Money(r.grossRevenue), Money(r.netRevenue)),
    string.format("cost of goods sold: %s | realized P&L: %s%s", Money(r.cogs), r.realized < 0 and "-" or "",
      Money(math.abs(r.realized))),
    string.format("held (bought, unsold): %d units, cost %s | sold without a buy on record: %d units",
      r.heldQty, Money(r.heldCost), r.unbasedSoldQty),
    string.format("mail (exact): %d sales, %d units, gross %s, cut %s, net %s | %d expired, %d canceled",
      r.mail.sold, r.mail.soldQty, Money(r.mail.gross), Money(r.mail.cut), Money(r.mail.net), r.mail.expired,
      r.mail.canceled),
  }
end

----------------------------------------------------------------------------------------------------
-- Owned-auction snapshot diff. State persists in WuweiDB.ledgerState.owned[auctionID] so sales that happen
-- while logged out are still seen at the next login. The first snapshot ever is a baseline (no post entries).
----------------------------------------------------------------------------------------------------
local function State()
  local db = ns.db
  db.ledgerState = db.ledgerState or { owned = {} }
  db.ledgerState.owned = db.ledgerState.owned or {}
  return db.ledgerState
end

local SOLD = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1
local sessionUpdates = 0 -- OWNED_AUCTIONS_UPDATED count since the last AUCTION_HOUSE_SHOW

-- The unsold remainder of an auction that has left the owned list: confirmed cancel, expiry or (inferred) sale.
local function Resolve(id, rec, now)
  local q = rec.qty or 0
  rec.qty, rec.done = 0, true
  if q <= 0 or not rec.itemID then return end
  if rec.cancelPending then
    Ledger.Add("cancel", rec.itemID, q, rec.unit, "AUCTION_CANCELED", { auctionID = id })
  elseif rec.expiredEvent then
    Ledger.Add("expired", rec.itemID, q, rec.unit, "AUCTION_HOUSE_AUCTIONS_EXPIRED", { auctionID = id })
  else
    -- Gone before its expiry time (or expiry unknown) = sold; gone after it = expired. Inherently a guess:
    -- a sale picked up after the expiry time looks like an expiry. SPEC D-017.
    local expired = rec.expires and now >= rec.expires - Ledger.EXPIRY_SLACK
    Ledger.Add(expired and "expired" or "sold", rec.itemID, q, rec.unit, "OWNED_AUCTIONS_UPDATED",
      { auctionID = id, inferred = true })
  end
end

-- Group the owned list by auctionID: one live row plus any Sold rows. A partly sold commodity auction lists its sold
-- part as a separate Sold row under the same id, priced as a total (SPEC D-047).
local function Group(list)
  local groups, order = {}, {}
  for _, info in ipairs(list) do
    local id = info.auctionID
    if id then
      local g = groups[id]
      if not g then
        g = { soldQty = 0, soldGross = 0 }
        groups[id], order[#order + 1] = g, id
      end
      g.itemID = g.itemID or (info.itemKey and info.itemKey.itemID)
      if info.status == SOLD then
        g.soldQty = g.soldQty + (info.quantity or 1)
        g.soldGross = g.soldGross + (info.buyoutAmount or info.bidAmount or 0)
      else
        g.live = info
      end
    end
  end
  return groups, order
end

function Ledger.OnOwnedUpdated()
  if not (ns.db and C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions) then return end
  -- An unconfident house guess (unrecognised AH, faction fallback) would make every stored auction of the guessed
  -- house look vanished: touch nothing. SPEC D-030.
  local house, _, confident = ns.House.Detect()
  if not confident then return end
  sessionUpdates = sessionUpdates + 1
  local st = State()
  local owned = st.owned
  local now = GetServerTime()
  local list = C_AuctionHouse.GetOwnedAuctions() or {}
  local groups, order = Group(list)
  for _, id in ipairs(order) do
    local g = groups[id]
    local live = g.live
    local rec = owned[id]
    if rec and rec.sold then rec.done, rec.sold = true, nil end -- record from before D-047
    if not rec then
      local qty = (live and live.quantity or 0) + g.soldQty
      local unit = live and (live.buyoutAmount or live.bidAmount)
      if not unit and g.soldQty > 0 then unit = g.soldGross / g.soldQty end
      rec = { itemID = g.itemID, qty = qty, unit = unit and Round(unit), house = house }
      owned[id] = rec
      if st.baselined and rec.itemID then
        Ledger.Add("post", rec.itemID, qty, rec.unit, "OWNED_AUCTIONS_UPDATED", { auctionID = id, inferred = true })
      end
    end
    local base = rec.soldRowBase or 0
    if live then
      rec.cancelPending = nil -- still listed: whatever AUCTION_CANCELED said, this auction was not cancelled
      rec.done = nil          -- a live remainder (e.g. a pre-D-047 record flagged sold by its Sold row)
      local q = live.quantity or rec.qty
      local shrink = (rec.qty or 0) - q
      if shrink > 0 and rec.itemID then
        local stated = g.soldQty - base >= shrink
        Ledger.Add("sold", rec.itemID, shrink, rec.unit, "OWNED_AUCTIONS_UPDATED",
          { auctionID = id, partial = true, inferred = (not stated) or nil })
      end
      rec.qty = q
      rec.soldRowBase = g.soldQty
      rec.expires = live.timeLeftSeconds and (now + live.timeLeftSeconds) or rec.expires
    elseif g.soldQty > base and not rec.done then
      local n = min(g.soldQty - base, rec.qty or 0)
      if n > 0 and rec.itemID then
        Ledger.Add("sold", rec.itemID, n, rec.unit, "OWNED_AUCTIONS_UPDATED", { auctionID = id })
      end
      rec.qty = (rec.qty or 0) - n
      rec.soldRowBase = g.soldQty
      if rec.qty <= 0 then rec.done = true end
    end
  end
  -- Vanished auctions (only those of the house we are looking at: the owned list is per house). The first list of
  -- a visit can arrive empty before the server answers: never resolve anything from it. SPEC D-047.
  if #list == 0 and sessionUpdates == 1 then return end
  local gone = {}
  for id, rec in pairs(owned) do
    if not groups[id] and (house == nil or rec.house == nil or rec.house == house) then gone[#gone + 1] = id end
  end
  sort(gone)
  for _, id in ipairs(gone) do
    local rec = owned[id]
    owned[id] = nil
    if not (rec.done or rec.sold) then Resolve(id, rec, now) end
  end
  st.baselined = true
end

----------------------------------------------------------------------------------------------------
-- One-time repair of ledgers written before D-047 (spurious cancel, re-recorded posts, Sold-row totals as units).
----------------------------------------------------------------------------------------------------
function Ledger.Repair()
  local db = ns.db
  if not db or (db.ledgerRepair or 0) >= 1 then return 0 end
  local l = db.ledger or {}
  local lastIndex, firstPost = {}, {}
  for i, e in ipairs(l) do
    if e.auctionID then
      lastIndex[e.auctionID] = i
      if e.kind == "post" and not firstPost[e.auctionID] then firstPost[e.auctionID] = e end
    end
  end
  local keep, changed = {}, 0
  for i, e in ipairs(l) do
    local id, drop = e.auctionID, false
    if id then
      local fp = firstPost[id]
      if e.kind == "cancel" and lastIndex[id] > i then
        drop = true                                    -- the auction carried on after this "cancel"
      elseif e.kind == "post" and fp and fp ~= e then
        drop = true                                    -- the same auction recorded as a new post again
      elseif (e.kind == "sold" or e.kind == "post") and fp and fp.unit and (e.qty or 0) > 1
          and e.unit == fp.unit * e.qty then
        e.unit, e.repaired = fp.unit, true             -- a Sold row's total taken as the unit price
        changed = changed + 1
      end
    end
    if drop then changed = changed + 1 else keep[#keep + 1] = e end
  end
  db.ledger = keep
  db.ledgerRepair = 1
  cache = nil
  return changed
end

----------------------------------------------------------------------------------------------------
-- Event handlers
----------------------------------------------------------------------------------------------------
local H = {}

function H.COMMODITY_PRICE_UPDATED(unit, total)
  if pendingBuy then
    pendingBuy.unit, pendingBuy.total = unit, total
  end
end

function H.COMMODITY_PURCHASE_SUCCEEDED()
  local b = pendingBuy
  pendingBuy = nil
  if not b then return end
  local total = b.total or (b.unit and b.unit * b.qty)
  local unit = b.qty > 0 and total and total / b.qty or b.unit
  Ledger.Add("buy", b.itemID, b.qty, unit, "COMMODITY_PURCHASE_SUCCEEDED", { total = total })
end

function H.COMMODITY_PURCHASE_FAILED() pendingBuy = nil end
H.COMMODITY_PRICE_UNAVAILABLE = H.COMMODITY_PURCHASE_FAILED

function H.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  local b = itemBuys[auctionID]
  itemBuys[auctionID] = nil
  if not (b and b.itemID) then return end
  Ledger.Add("buy", b.itemID, b.qty, b.buyout / b.qty, "AUCTION_HOUSE_PURCHASE_COMPLETED",
    { total = b.buyout, auctionID = auctionID })
end

function H.AUCTION_HOUSE_AUCTION_CREATED(auctionID)
  local p = pendingPost
  local owned = State().owned
  if p then
    local qty = p.isCommodity and p.qty or 1 -- non-commodity: Blizzard's "quantity" is the number of auctions
    Ledger.Add("post", p.itemID, qty, p.unit, "AUCTION_HOUSE_AUCTION_CREATED", { auctionID = auctionID })
    owned[auctionID] = { itemID = p.itemID, qty = qty, unit = p.unit, house = (ns.House.Detect()) }
    p.left = p.left - 1
    if p.isCommodity or p.left <= 0 then pendingPost = nil end
  end
  -- No pending post (posted by another addon): the next owned-auction snapshot records it, inferred.
end

-- Only a pending mark: the event also fires when part of a commodity auction sells (D-047). The next owned list
-- confirms it (auction gone: cancel) or clears it (still listed).
function H.AUCTION_CANCELED(auctionID)
  local rec = State().owned[auctionID]
  if rec then rec.cancelPending = true end
end

function H.AUCTION_HOUSE_AUCTIONS_EXPIRED(auctionID)
  local rec = State().owned[auctionID]
  if rec then rec.expiredEvent = true end
end

H.OWNED_AUCTIONS_UPDATED = function() Ledger.OnOwnedUpdated() end

function H.AUCTION_HOUSE_CLOSED() pendingBuy = nil pendingPost = nil end

function H.AUCTION_HOUSE_SHOW()
  sessionUpdates = 0
  Ledger.Hook()
  -- One read-only refresh of our own listings (Blizzard throttles it). Without it, sales only show up once the
  -- player opens the Auctions tab. Switch off with WuweiDB.ledgerQuery = false. [TODO-INGAME] sorts argument.
  if ns.db.ledgerQuery ~= false and C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
    pcall(C_AuctionHouse.QueryOwnedAuctions, {})
  end
end

----------------------------------------------------------------------------------------------------
-- Hooks on Blizzard's AH frame (post-hooks only; they run after Blizzard's code and cannot taint it)
----------------------------------------------------------------------------------------------------
local function SafeHook(tbl, name, fn)
  if tbl and type(tbl[name]) == "function" then
    hooksecurefunc(tbl, name, function(...) pcall(fn, ...) end)
  end
end

function Ledger.Hook()
  local ahf = _G.AuctionHouseFrame
  if not ahf or Ledger.hooked == ahf then return end
  Ledger.hooked = ahf
  -- (self, itemID, quantity, unitPrice, totalPrice): the quote the player is about to confirm.
  SafeHook(ahf, "StartCommoditiesPurchase", function(_, itemID, qty, unit, total)
    pendingBuy = { itemID = itemID, qty = qty, unit = unit, total = total }
  end)
  -- (self, auctionID, buyout): look the listing up for item and stack size.
  SafeHook(ahf, "StartItemBuyout", function(_, auctionID, buyout)
    local info = C_AuctionHouse.GetAuctionInfoByID(auctionID)
    itemBuys[auctionID] = { itemID = info and info.itemKey and info.itemKey.itemID, qty = info and info.quantity or 1,
      buyout = buyout }
  end)
  -- Called by Blizzard only after PostCommodity/PostItem succeeded: (self, item, duration, quantity, ...).
  for _, key in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
    local f = ahf[key]
    SafeHook(f, "CachePendingPost", function(_, item, _, qty, a, b)
      local isCommodity = key == "CommoditiesSellFrame"
      pendingPost = { itemID = C_Item.GetItemID(item), qty = qty, unit = isCommodity and a or (b or a),
        isCommodity = isCommodity, left = qty }
    end)
  end
end

function Ledger.Init()
  local db = ns.db
  db.ledger = db.ledger or {}
  db.ledgerVersion = db.ledgerVersion or Ledger.VERSION
  State()
  Ledger.Repair()
  if Ledger.events then return end
  local ev = CreateFrame("Frame")
  for name in pairs(H) do ev:RegisterEvent(name) end
  ev:SetScript("OnEvent", function(_, event, ...)
    if ns.db and H[event] then H[event](...) end
  end)
  Ledger.events = ev
end

-- Keyboard flow (Keys.lua) calls C_AuctionHouse.StartCommoditiesPurchase directly, bypassing Blizzard's
-- AuctionHouseFrame:StartCommoditiesPurchase that the hook above listens to, so it registers the quote context itself.
-- COMMODITY_PRICE_UPDATED then refines unit/total and COMMODITY_PURCHASE_SUCCEEDED records, exactly as for a click.
function Ledger.BeginBuy(itemID, qty, unit, total)
  pendingBuy = { itemID = itemID, qty = qty, unit = unit, total = total }
end

-- Drop the in-flight quote (cancelled by the player or us); SUCCEEDED without context records nothing.
function Ledger.EndBuy() pendingBuy = nil end

-- Test seam: drop in-flight purchase/post context.
function Ledger.ResetPending() pendingBuy, pendingPost, itemBuys = nil, nil, {} end
