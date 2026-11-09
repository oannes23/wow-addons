-- Keyboard sign-off flow: a play queue, a focus banner, and two key bindings (Bindings.xml): WUWEI_ACCEPT, WUWEI_SKIP.
-- Accept advances the current play by exactly ONE step per press (one key press = one server action):
--   BUY / SHUTTLE at the source house, commodities:  search -> StartCommoditiesPurchase -> (quote arrives) -> Confirm
--   SELL / SHUTTLE at the destination:               open Blizzard's sell flow (post helper shows fees); posting stays
--                                                    Blizzard's Post button (SPEC D-025)
-- Safety (SPEC D-022): the HasRestrictions purchase calls live ONLY in the PRESS-PATH block below, are reachable only
-- from Keys.Accept / Keys.Skip (called by the binding handlers), and a runtime gate refuses them outside a press and
-- after the first one in a press. Event handlers only read state and update the banner. tools/luatest/wuwei_keys_test.py
-- greps for all of this.
local addonName, ns = ...
local L = ns.L

local format, floor, min, ipairs = string.format, math.floor, math.min, ipairs
local GetTime = GetTime

local Keys = {}
ns.Keys = Keys

Keys.DEFAULTS = { WUWEI_ACCEPT = "]", WUWEI_SKIP = "[" } -- offered by `/wuwei keys default`, never forced (D-023)
Keys.SEARCH_RETRY = 5 -- s: a search that never produced COMMODITY_SEARCH_RESULTS_UPDATED may be re-sent after this

-- phase: idle -> searching -> ready -> quoting -> quoted -> purchasing -> idle
local S = { queue = {}, idx = 1, phase = "idle" }
Keys.state = S

local function Say(msg) print("|cff00ccffWuwei|r " .. msg) end

----------------------------------------------------------------------------------------------------
-- Queue
----------------------------------------------------------------------------------------------------
local ACTIONABLE = { BUY = true, SELL = true, SHUTTLE = true }

-- "buy" (search/quote/confirm) or "sell" (open the sell flow). SHUTTLE buys at the source, sells at the destination.
function Keys.Mode(play, house)
  local sig = play.item.signal
  if sig == "BUY" then return "buy" end
  if sig == "SELL" then return "sell" end
  if sig == "SHUTTLE" then return (house == ns.Plan.BLACKWATER) and "sell" or "buy" end
end

function Keys.Rebuild()
  local house = ns.House.Detect()
  local keepID = S.queue[S.idx] and S.queue[S.idx].id
  local q = {}
  for _, p in ipairs(ns.Plan.Plays(house)) do
    if ACTIONABLE[p.item.signal] then q[#q + 1] = p end
  end
  S.queue, S.house, S.idx = q, house, 1
  for i, p in ipairs(q) do if p.id == keepID then S.idx = i end end
  local cur = q[S.idx]
  if not (cur and cur.id == keepID) then Keys.Reset() end
end

local function Current()
  if #S.queue == 0 then Keys.Rebuild() end
  return S.queue[S.idx]
end

function Keys.Reset()
  S.phase, S.qty, S.unit, S.total, S.searchAt, S.note = "idle", nil, nil, nil, nil, nil
end

local function AHOpen()
  local ahf = _G.AuctionHouseFrame
  return ahf and ahf:IsShown() and ahf or nil
end

-- true commodity, false gear (item endpoint), nil unknown (item key not cached yet).
local function IsCommodity(id)
  local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(id))
  if not info then return nil end
  return info.isCommodity and true or false
end

-- Units listed at or below `limit` (copper per unit), across the cached commodity search results.
local function Available(id, limit)
  local avail = 0
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(id) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
    if r and r.unitPrice <= limit then avail = avail + r.quantity end
  end
  return avail
end

local function ItemName(id)
  return C_Item.GetItemNameByID(id) or ("item:" .. id)
end

----------------------------------------------------------------------------------------------------
-- Banner
----------------------------------------------------------------------------------------------------
local Banner = {}
Keys.Banner = Banner

-- Pure: the two banner lines for the current state.
function Keys.BannerText()
  local Plan = ns.Plan
  local play = S.queue[S.idx]
  if not play then
    return L["Wuwei keys: no actionable plays for this house."], ""
  end
  local it, house = play.item, S.house
  local mode = Keys.Mode(play, house)
  local n = #S.queue
  local head = format("[%d/%d] %s %s%s · %s", S.idx, n, Plan.Colorize(it.signal, it.signal), ItemName(play.id),
    it.qtyCap and (" ×" .. it.qtyCap) or "", Plan.Rule(it, house))
  local skip = format(L["Skip: next (%d/%d)"], S.idx % n + 1, n)
  local step
  if mode == "sell" then
    step = format(L["Accept: open the sell flow (post with Blizzard's Post button, sell ≥ %s)"], Plan.Money(it.sellMin))
  elseif S.gear then
    step = L["Gear: click in Blizzard UI (keyboard buy supports commodities only)"]
  elseif not it.buyMax then
    step = L["No buy limit in the plan; nothing to accept"]
  elseif S.phase == "idle" then
    step = L["Accept: search"]
  elseif S.phase == "searching" then
    step = L["Searching... (Accept re-sends after a few seconds)"]
  elseif S.phase == "ready" then
    local avail = Available(play.id, it.buyMax)
    if avail > 0 then
      step = format(L["Accept: buy up to %d at ≤ %s"], min(it.qtyCap or avail, avail), Plan.Money(it.buyMax))
    else
      step = format(L["Nothing listed at ≤ %s; Accept searches again"], Plan.Money(it.buyMax))
    end
  elseif S.phase == "quoting" then
    step = L["Waiting for the price quote..."]
  elseif S.phase == "quoted" then
    if S.unit and S.unit <= it.buyMax and S.total <= it.buyMax * S.qty then
      step = format(L["Accept: CONFIRM %d for %s (%s each, ≤ %s)"], S.qty, Plan.Money(S.total), Plan.Money(S.unit),
        Plan.Money(it.buyMax))
    else
      step = format(L["Quote %s each is over ≤ %s: Accept cancels"], Plan.Money(S.unit or 0), Plan.Money(it.buyMax))
    end
  else -- purchasing
    step = L["Purchase sent; waiting for the server..."]
  end
  return head, step .. " · " .. skip .. (S.note and ("\n" .. S.note) or "")
end

local function BuildBanner()
  local f = CreateFrame("Frame", "WuweiKeysFrame", UIParent)
  f:SetSize(520, 54)
  f:SetFrameStrata("HIGH")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.85)
  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.head:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
  f.step = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.step:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
  f.step:SetWidth(504)
  f:Hide()
  return f
end

function Banner.Refresh()
  local f = Banner.frame
  if not (f and f:IsShown()) then return end
  local head, step = Keys.BannerText()
  f.head:SetText(head)
  f.step:SetText(step)
end

function Banner.Show()
  if not (ns.db and ns.db.enabled and ns.db.keys ~= false) then return end
  local ahf = _G.AuctionHouseFrame
  if not ahf then return end
  if not Banner.frame then Banner.frame = BuildBanner() end
  local f = Banner.frame
  f:ClearAllPoints()
  local panel = ns.Panel.frame
  if panel then f:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 0, 4) else f:SetPoint("TOPLEFT", ahf, "TOPRIGHT", 4, 0) end
  f:Show()
  Banner.Refresh()
end

function Banner.Hide() if Banner.frame then Banner.frame:Hide() end end

----------------------------------------------------------------------------------------------------
-- PRESS-PATH: the only code in the addon allowed to call purchase APIs. BEGIN
-- Runtime gate: S.pressing is true only while Keys.Accept / Keys.Skip run; S.used allows one gated call per press.
----------------------------------------------------------------------------------------------------
local function Gate()
  if not S.pressing then error("Wuwei: purchase API outside a key press") end
  if S.used then error("Wuwei: second purchase API call in one key press") end
  S.used = true
end

local function StartQuote(id, qty) Gate() C_AuctionHouse.StartCommoditiesPurchase(id, qty) end
local function ConfirmQuote(id, qty) Gate() C_AuctionHouse.ConfirmCommoditiesPurchase(id, qty) end
local function CancelQuote() Gate() C_AuctionHouse.CancelCommoditiesPurchase() end
-- PRESS-PATH END

-- One press = at most one gated call. Never reached from events.
local function Press(fn, ...)
  S.pressing, S.used = true, false
  local ok, err = pcall(fn, ...)
  S.pressing = false
  if not ok then -- e.g. the gate refused: drop any half-made state so the next press starts clean
    Keys.Reset()
    ns.Ledger.EndBuy()
    Say(L["error: "] .. tostring(err))
  end
  Banner.Refresh()
end

----------------------------------------------------------------------------------------------------
-- Accept: one step
----------------------------------------------------------------------------------------------------
local function OpenSell(play)
  local ahf = _G.AuctionHouseFrame
  local it = play.item
  -- Select the first matching stack from the bags so Blizzard's sell frame (and our post helper) show it. Posting
  -- stays Blizzard's Post button: no PostCommodity/PostItem call exists in this addon.
  if ns.db.keysSellSelect ~= false and ahf.SetPostItem then
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 4 do
      for slot = 1, C_Container.GetContainerNumSlots(bag) do
        if C_Container.GetContainerItemID(bag, slot) == play.id then
          local ok = pcall(ahf.SetPostItem, ahf, ItemLocation:CreateFromBagAndSlot(bag, slot))
          Say(format(L["%s: sell flow opened. Floor ≥ %s; check the Wuwei box for fees, then use Blizzard's Post button."],
            ItemName(play.id), ns.Plan.Money(it.sellMin)))
          if not ok then Say(L["Could not select the item automatically; pick it in the Sell tab."]) end
          return
        end
      end
    end
    Say(format(L["No %s in your bags."], ItemName(play.id)))
    return
  end
  Say(format(L["Open the Sell tab and pick %s (floor ≥ %s)."], ItemName(play.id), ns.Plan.Money(it.sellMin)))
end

local function DoSearch(play)
  local ok, how = ns.Panel.Search(play.id)
  if not ok then
    if how ~= "throttled" then Say(L["Search not sent: "] .. tostring(how)) end
    return
  end
  if how ~= "itemkey" then
    Say(L["Item data was not cached, so only a name search ran. Press Accept again."])
    return
  end
  S.phase, S.searchAt, S.note = "searching", GetTime(), nil
end

local function DoStart(play)
  local it = play.item
  local avail = Available(play.id, it.buyMax)
  if avail <= 0 then
    S.phase = "idle"
    Say(format(L["Nothing listed at ≤ %s for %s; not starting a purchase."], ns.Plan.Money(it.buyMax), ItemName(play.id)))
    return
  end
  local qty = min(it.qtyCap or avail, avail)
  ns.Ledger.BeginBuy(play.id, qty) -- direct API call bypasses Blizzard's frame method the ledger hooks (D-024)
  S.qty, S.unit, S.total, S.phase = qty, nil, nil, "quoting"
  StartQuote(play.id, qty)
end

local function DoQuoted(play)
  local it = play.item
  local left = C_AuctionHouse.GetQuoteDurationRemaining()
  if not left or left <= 0 then
    Say(L["Quote expired; requesting a new one."])
    ns.Ledger.EndBuy()
    return DoStart(play) -- restart from step 2 (one purchase call this press)
  end
  if S.unit and S.unit <= it.buyMax and S.total <= it.buyMax * S.qty then
    S.phase = "purchasing"
    ConfirmQuote(play.id, S.qty)
    Say(format(L["Confirming %d × %s for %s."], S.qty, ItemName(play.id), ns.Plan.Money(S.total)))
  else
    local unit = S.unit or 0
    CancelQuote()
    ns.Ledger.EndBuy()
    Keys.Reset()
    Say(format(L["Cancelled: quote %s each exceeds your limit %s."], ns.Plan.Money(unit), ns.Plan.Money(it.buyMax)))
  end
end

local function AcceptImpl()
  if not AHOpen() then Say(L["Open the auction house first."]) return end
  local play = Current()
  if not play then Say(L["No actionable plays for this house."]) return end
  local it = play.item
  if Keys.Mode(play, S.house) == "sell" then return OpenSell(play) end
  if not it.buyMax then Say(L["No buy limit in the plan; nothing to accept"]) return end
  if S.phase == "idle" then
    if IsCommodity(play.id) == false then
      S.gear = true
      Say(L["Gear: click in Blizzard UI (keyboard buy supports commodities only)"])
      return
    end
    S.gear = nil
    return DoSearch(play)
  elseif S.phase == "searching" then
    if S.searchAt and GetTime() - S.searchAt > Keys.SEARCH_RETRY then return DoSearch(play) end
    Say(L["Still searching; wait for the results."])
  elseif S.phase == "ready" then
    return DoStart(play)
  elseif S.phase == "quoting" then
    Say(L["Waiting for the price quote."])
  elseif S.phase == "quoted" then
    return DoQuoted(play)
  else
    Say(L["Purchase already sent; waiting for the server."])
  end
end

local function SkipImpl()
  local n = #S.queue
  if n == 0 then Keys.Rebuild() n = #S.queue end
  if S.phase == "quoting" or S.phase == "quoted" then
    CancelQuote()
    Say(L["Skipped: pending quote cancelled."])
  end
  ns.Ledger.EndBuy()
  Keys.Reset()
  S.gear = nil
  if n > 0 then S.idx = S.idx % n + 1 end
end

function Keys.Accept() Press(AcceptImpl) end
function Keys.Skip() Press(SkipImpl) end

-- The names Bindings.xml calls (SPEC D-023: the only addon-specific globals besides the compartment function).
function Wuwei_Accept() Keys.Accept() end
function Wuwei_Skip() Keys.Skip() end

----------------------------------------------------------------------------------------------------
-- Events: read-only. They move the state machine's phase and the banner; they never call an AH action.
----------------------------------------------------------------------------------------------------
local H = {}

function H.AUCTION_HOUSE_SHOW()
  Keys.Rebuild()
  Banner.Show()
end

function H.AUCTION_HOUSE_CLOSED()
  Keys.Reset()
  S.gear = nil
  Banner.Hide()
end

function H.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
  local play = S.queue[S.idx]
  if play and play.id == itemID and S.phase == "searching" then S.phase = "ready" end
end

function H.COMMODITY_PRICE_UPDATED(unit, total)
  if S.phase == "quoting" then S.unit, S.total, S.phase = unit, total, "quoted" end
end

function H.COMMODITY_PURCHASE_SUCCEEDED()
  if S.phase == "purchasing" or S.phase == "quoted" then
    Say(L["Purchase complete. Accept searches again; Skip moves on."])
    Keys.Reset()
  end
end

function H.COMMODITY_PURCHASE_FAILED()
  if S.phase ~= "idle" then Say(L["Purchase failed or the price is no longer available."]) end
  Keys.Reset()
end
H.COMMODITY_PRICE_UNAVAILABLE = H.COMMODITY_PURCHASE_FAILED

function H.ITEM_DATA_LOAD_RESULT() end

----------------------------------------------------------------------------------------------------
-- /wuwei keys [default]
----------------------------------------------------------------------------------------------------
local ACTIONS = { "WUWEI_ACCEPT", "WUWEI_SKIP" }

function Keys.Slash(arg)
  if arg == "default" then
    if InCombatLockdown() then Say(L["Not in combat."]) return end
    local changed
    for _, action in ipairs(ACTIONS) do
      local key = Keys.DEFAULTS[action]
      local k1, k2 = GetBindingKey(action)
      local owner = GetBindingAction(key)
      if k1 or k2 then
        Say(format(L["%s already bound (%s); left alone."], action, tostring(k1 or k2)))
      elseif owner and owner ~= "" then
        Say(format(L["%s not set: %s is already bound to %s."], action, key, owner))
      elseif SetBinding(key, action) then
        changed = true
        Say(format(L["%s bound to %s."], action, key))
      end
    end
    if changed then SaveBindings(GetCurrentBindingSet()) end
    return
  end
  for _, action in ipairs(ACTIONS) do
    local k1, k2 = GetBindingKey(action)
    Say(format("%s: %s", action, k1 and (k2 and (k1 .. ", " .. k2) or k1) or L["unbound (Game Menu > Options > Keybindings > Wuwei, or /wuwei keys default)"]))
  end
end

function Keys.Init()
  if Keys.events then return end
  local ev = CreateFrame("Frame")
  for name in pairs(H) do ev:RegisterEvent(name) end
  ev:SetScript("OnEvent", function(_, event, ...)
    if ns.db and H[event] then H[event](...) end
    if event ~= "AUCTION_HOUSE_CLOSED" then Banner.Refresh() end
  end)
  Keys.events = ev
end
