-- Trade ledger: purchases, posts, sales, cancels and expiries, stored in WuweiDB.ledger (schema: SPEC "Ledger export").
-- Everything here is event- or hook-driven and read-only: no PostItem/PostCommodity/PlaceBid/Start*Purchase/CancelAuction
-- calls (all HasRestrictions). Hooks are hooksecurefunc post-hooks on Blizzard's own methods, so nothing is tainted.
local addonName, ns = ...

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

-- Append one entry. `extra` may carry total, auctionID, inferred.
function Ledger.Add(kind, itemID, qty, unit, src, extra)
  local db = ns.db
  if not (db and db.ledger and itemID) then return nil end
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
local function Replay()
  if cache then return cache end
  local pools = {}
  local r = { spent = 0, grossRevenue = 0, netRevenue = 0, cogs = 0, realized = 0, unbasedSoldQty = 0,
    counts = { buy = 0, post = 0, sold = 0, cancel = 0, expired = 0 }, items = pools }
  for _, e in ipairs(Ledger.Entries()) do
    local c = r.counts
    c[e.kind] = (c[e.kind] or 0) + 1
    local p = pools[e.itemID]
    if not p then p = { qty = 0, cost = 0 } pools[e.itemID] = p end
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
    string.format("entries: %d (cap %d) | buy %d, post %d, sold %d, cancel %d, expired %d",
      #Ledger.Entries(), Ledger.MAX_ENTRIES, c.buy, c.post, c.sold, c.cancel, c.expired),
    string.format("spent: %s | sales gross %s, net of cut %s", Money(r.spent), Money(r.grossRevenue), Money(r.netRevenue)),
    string.format("cost of goods sold: %s | realized P&L: %s%s", Money(r.cogs), r.realized < 0 and "-" or "",
      Money(math.abs(r.realized))),
    string.format("held (bought, unsold): %d units, cost %s | sold without a buy on record: %d units",
      r.heldQty, Money(r.heldCost), r.unbasedSoldQty),
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

function Ledger.OnOwnedUpdated()
  if not (ns.db and C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions) then return end
  local st = State()
  local owned = st.owned
  local house = ns.House.Detect()
  local now = GetServerTime()
  local seen = {}
  for _, info in ipairs(C_AuctionHouse.GetOwnedAuctions() or {}) do
    local id = info.auctionID
    seen[id] = true
    local rec = owned[id]
    local unit = info.buyoutAmount or info.bidAmount -- [TODO-INGAME] per-unit for commodities? (Retail: yes)
    if not rec then
      rec = { itemID = info.itemKey and info.itemKey.itemID, qty = info.quantity or 1, unit = unit, house = house }
      owned[id] = rec
      if st.baselined and rec.itemID then
        Ledger.Add("post", rec.itemID, rec.qty, rec.unit, "OWNED_AUCTIONS_UPDATED", { auctionID = id, inferred = true })
      end
    end
    rec.expires = info.timeLeftSeconds and (now + info.timeLeftSeconds) or rec.expires
    if info.status == SOLD and not rec.sold and rec.itemID then
      rec.sold = true
      Ledger.Add("sold", rec.itemID, rec.qty, rec.unit, "OWNED_AUCTIONS_UPDATED", { auctionID = id })
    end
  end
  -- Vanished auctions (only those of the house we are looking at: the owned list is per house).
  local gone = {}
  for id, rec in pairs(owned) do
    if not seen[id] and (house == nil or rec.house == nil or rec.house == house) then gone[#gone + 1] = id end
  end
  sort(gone)
  for _, id in ipairs(gone) do
    local rec = owned[id]
    owned[id] = nil
    if not rec.sold and rec.itemID then
      -- Gone before its expiry time (or expiry unknown) = sold; gone after it = expired. Inherently a guess:
      -- a sale picked up after the expiry time looks like an expiry. SPEC D-017.
      local expired = rec.expires and now >= rec.expires - Ledger.EXPIRY_SLACK
      Ledger.Add(expired and "expired" or "sold", rec.itemID, rec.qty, rec.unit, "OWNED_AUCTIONS_UPDATED",
        { auctionID = id, inferred = true })
    end
  end
  st.baselined = true
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

function H.AUCTION_CANCELED(auctionID)
  local owned = State().owned
  local rec = owned[auctionID]
  if rec and rec.itemID then
    Ledger.Add("cancel", rec.itemID, rec.qty, rec.unit, "AUCTION_CANCELED", { auctionID = auctionID })
  end
  owned[auctionID] = nil
end

H.OWNED_AUCTIONS_UPDATED = function() Ledger.OnOwnedUpdated() end

function H.AUCTION_HOUSE_CLOSED() pendingBuy = nil pendingPost = nil end

function H.AUCTION_HOUSE_SHOW()
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
    SafeHook(f, "CachePendingPost", function(self, item, duration, qty, a, b)
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
