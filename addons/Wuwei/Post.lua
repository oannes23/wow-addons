-- Post helper: an info box under the Wuwei panel while Blizzard's sell frame holds an item. Shows the plan's floor and
-- signal, deposit, AH cut, net proceeds at the typed price, cost basis, and red protection warnings.
-- Read-only. It never posts, clicks or calls a HasRestrictions API: Blizzard's own Post button is the only action.
-- Refresh trigger: hooksecurefunc post-hook on the sell frames' UpdatePostState, which Blizzard calls on every item,
-- quantity, price and duration change (Blizzard_AuctionHouseSellFrame.lua:338, SetItem, OnDurationUpdated, price
-- callbacks). No taint, and no OnUpdate polling needed.
local _, ns = ...
local L = ns.L

local format, floor, ipairs = string.format, math.floor, ipairs

local Post = {}
ns.Post = Post

-- AH cut. Both rates are ASSUMED (Classic: 5% faction, 15% neutral) until measured in game. [TODO-INGAME]
Post.CUT_FACTION = 0.05
Post.CUT_BLACKWATER = 0.15

-- Returns rate, assumed(bool). An unknown house falls back to the faction rate.
function Post.Cut(house)
  return (house == ns.Plan.BLACKWATER) and Post.CUT_BLACKWATER or Post.CUT_FACTION, true
end

local function Round(x) return floor(x + 0.5) end

-- Pure. s = { itemID, qty, unit (typed per-unit price, copper, 0/nil = none), deposit, house, duration, vendor }.
-- Returns { price, priceSource, total, cut, rate, net, netUnit, deposit, basis, basisQty, planItem, warnings }.
function Post.Compute(s)
  local Plan = ns.Plan
  local it = Plan.Item(s.itemID)
  local floorMin = Plan.SellFloor(it, s.house)
  local typed = s.unit and s.unit > 0
  local unit = typed and s.unit or floorMin or nil
  local c = { planItem = it, deposit = s.deposit, qty = s.qty or 1, house = s.house, duration = s.duration,
    priceSource = typed and "typed" or (unit and "plan sellMin" or nil), price = unit, warnings = {} }
  c.rate, c.rateAssumed = Post.Cut(s.house)
  c.basis, c.basisQty = ns.Ledger.CostBasis(s.itemID)
  if unit then
    c.total = unit * c.qty
    c.cut = Round(c.total * c.rate)
    c.net = c.total - c.cut -- deposit is refunded on a sale (assumed) and lost if the auction expires
    c.netUnit = c.net / c.qty
  end
  if typed then -- protection warnings only judge a price the player actually typed
    local W = c.warnings
    if s.vendor and s.vendor > 0 and unit < s.vendor then
      W[#W + 1] = { code = "vendor", text = format(L["price below vendor sell price (%s)"], Plan.Money(s.vendor)) }
    end
    if floorMin and unit < floorMin then
      W[#W + 1] = { code = "plan", text = format(L["price below plan floor (%s)"], Plan.Money(floorMin)) }
    end
    if c.basis then
      if unit < c.basis then
        W[#W + 1] = { code = "basis", text = format(L["price below cost basis (%s)"], Plan.Money(c.basis)) }
      elseif c.netUnit < c.basis then
        W[#W + 1] = { code = "basis", text = format(L["net of cut below cost basis (%s)"], Plan.Money(c.basis)) }
      end
    end
  end
  return c
end

local DURATION_KEYS = { "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }

local function DurationText(index, assumed)
  local label = index and _G[DURATION_KEYS[index] or ""] or (index and ("#" .. index)) or "?"
  return label .. (assumed and " (assumed)" or "")
end

local RED = "|cffff4040"

-- Pure: display lines for a Compute result.
function Post.Lines(c)
  local Plan = ns.Plan
  local Money = Plan.Money
  local lines = {}
  local it = c.planItem
  if it then
    local rule = Plan.Rule(it, c.house)
    local floor_ = it.sellMin and not rule:find(Money(it.sellMin), 1, true) and (" · plan floor " .. Money(it.sellMin)) or ""
    lines[#lines + 1] = Plan.Colorize(it.signal, Plan.Label(it.signal) .. (rule ~= "" and (" " .. rule) or "")) .. floor_
  else
    lines[#lines + 1] = L["not in the plan"]
  end
  lines[#lines + 1] = format(L["deposit %s · duration %s"], c.deposit and Money(c.deposit) or "?",
    DurationText(c.duration, c.durationAssumed))
  if c.price then
    lines[#lines + 1] = format(L["price %s x%d (%s) = %s"], Money(c.price), c.qty, c.priceSource, Money(c.total))
    lines[#lines + 1] = format(L["AH cut %d%% (assumed) -%s · net if sold %s"], Round(c.rate * 100), Money(c.cut), Money(c.net))
  else
    lines[#lines + 1] = L["no price yet"]
  end
  lines[#lines + 1] = c.basis and format(L["cost basis %s/unit (%d held)"], Money(c.basis), c.basisQty) or L["cost basis: none on record"]
  for _, w in ipairs(c.warnings) do lines[#lines + 1] = RED .. "! " .. w.text .. "|r" end
  return lines
end

----------------------------------------------------------------------------------------------------
-- Reading Blizzard's sell frames (public accessors, all verified in Blizzard_AuctionHouseSellFrame.lua /
-- CommoditiesSellFrame / ItemSellFrame): GetItem() -> ItemLocation, GetDuration(), GetQuantity(), and the price:
-- commodities GetUnitPrice(), items GetPrice() -> bid, buyout.
----------------------------------------------------------------------------------------------------
local function ActiveFrame()
  local ahf = _G.AuctionHouseFrame
  if not ahf then return nil end
  for _, key in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
    local f = ahf[key]
    if f and f:IsShown() and f.GetItem then
      local loc = f:GetItem()
      if loc and (not loc.IsValid or loc:IsValid()) then return f, loc, key == "CommoditiesSellFrame" end
    end
  end
  return nil
end

local function VendorPrice(itemID, it)
  if it and it.vendor then return it.vendor end
  local sell = select(11, C_Item.GetItemInfo(itemID))
  return sell
end

-- Returns the Compute input read from the live sell frame, or nil when no item is selected.
function Post.Read()
  local f, loc, isCommodity = ActiveFrame()
  if not f then return nil end
  local itemID = C_Item.GetItemID(loc)
  if not itemID then return nil end
  local duration, assumed = f.GetDuration and f:GetDuration() or nil, false
  if not duration then
    duration, assumed = tonumber(GetCVar and GetCVar("auctionHouseDurationDropdown")), false
  end
  if not duration then duration, assumed = 2, true end -- assume the middle option (24h on Retail); labelled
  local qty = f.GetQuantity and f:GetQuantity() or 1
  if not qty or qty < 1 then qty = 1 end
  local unit
  if isCommodity then
    unit = f:GetUnitPrice()
  elseif f.GetPrice then
    local _, buyout = f:GetPrice()
    unit = buyout
  end
  local deposit
  if isCommodity then
    deposit = C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, qty)
  else
    deposit = C_AuctionHouse.CalculateItemDeposit(loc, duration, qty)
  end
  local house = ns.House.Detect()
  return { itemID = itemID, qty = qty, unit = unit, deposit = deposit, house = house, duration = duration,
    durationAssumed = assumed, vendor = VendorPrice(itemID, ns.Plan.Item(itemID)) }
end

local function Build()
  local f = CreateFrame("Frame", "WuweiPostFrame", UIParent) -- named for /fstack; not an API surface
  f:SetSize(380, 112)
  f:SetFrameStrata("HIGH")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.8)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.text:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  f.text:SetWidth(364)
  f.text:SetJustifyH("LEFT")
  f:Hide()
  return f
end

local function Place(f)
  local ahf, panel = _G.AuctionHouseFrame, ns.Panel and ns.Panel.frame
  f:ClearAllPoints()
  if panel and panel:IsShown() then
    f:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -4)
  elseif ahf then
    f:SetPoint("TOPLEFT", ahf, "TOPRIGHT", 4, 0)
  end
end

function Post.Hide()
  if Post.frame then Post.frame:Hide() end
end

function Post.Update()
  if not (ns.db and ns.db.enabled and ns.db.post) then return Post.Hide() end
  local s = Post.Read()
  if not s then return Post.Hide() end
  local c = Post.Compute(s)
  c.durationAssumed = s.durationAssumed
  if not Post.frame then Post.frame = Build() end
  Place(Post.frame)
  Post.frame.text:SetText(table.concat(Post.Lines(c), "\n"))
  Post.frame:Show()
  Post.last = c
end

local function SafeUpdate() pcall(Post.Update) end

function Post.Hook()
  local ahf = _G.AuctionHouseFrame
  if not ahf or Post.hooked == ahf then return end
  Post.hooked = ahf
  for _, key in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
    local f = ahf[key]
    if f and type(f.UpdatePostState) == "function" then hooksecurefunc(f, "UpdatePostState", SafeUpdate) end
  end
end

function Post.Init()
  if Post.events then return end
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("AUCTION_HOUSE_SHOW")
  ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
  ev:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then Post.Hook() else Post.Hide() end
  end)
  Post.events = ev
end
