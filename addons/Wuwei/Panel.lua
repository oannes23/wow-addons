-- AH side panel: today's plays for this house, anchored right of AuctionHouseFrame. Phase 1 only searches and
-- hands off to Blizzard's buy UI; it never calls a HasRestrictions API (PlaceBid, StartCommoditiesPurchase, Post*).
-- Steals (SPEC D-038): a status line, a Scan steals button and up to Steals.MAX_ROWS STEAL rows above the plays.
local _, ns = ...
local L = ns.L

local GetTime, floor, format, ipairs = GetTime, math.floor, string.format, ipairs

local MAX_ROWS = 15
local ROW_H = 20
local WIDTH = 520

-- Client-side search throttle. Blizzard allows 100 SendSearchQuery calls/min and its own AH UI shares the quota,
-- so we stop at 90. Sliding window of timestamps.
local Throttle = { limit = 90, window = 60, stamps = {} }
ns.Throttle = Throttle

function Throttle.Take()
  local now = GetTime()
  local s = Throttle.stamps
  local keep = {}
  for i = 1, #s do if now - s[i] < Throttle.window then keep[#keep + 1] = s[i] end end
  Throttle.stamps = keep
  if #keep >= Throttle.limit then
    return false, Throttle.window - (now - keep[1])
  end
  keep[#keep + 1] = now
  return true
end

-- Tokens still free in the current window (the steals scan keeps a reserve for the player's clicks, D-036).
function Throttle.Free()
  local now, n = GetTime(), 0
  for _, t in ipairs(Throttle.stamps) do if now - t < Throttle.window then n = n + 1 end end
  return Throttle.limit - n
end

local Panel = {}
ns.Panel = Panel

-- One load request per item per session. Re-requesting on every refresh would loop on an item that never loads:
-- request -> ITEM_DATA_LOAD_RESULT(false) -> Refresh -> request ...
local requested = {}

local function ItemName(id)
  local name = C_Item.GetItemNameByID(id)
  if name then return name end
  if not requested[id] then
    requested[id] = true
    C_Item.RequestLoadItemDataByID(id) -- ITEM_DATA_LOAD_RESULT triggers a refresh
  end
  return "item:" .. id
end

-- Pure: row data for a house (no frames), at most MAX_ROWS: STEAL rows found this visit first (deepest discount
-- first), then plays, gain-descending.
function Panel.BuildRows(house)
  local rows = {}
  local Plan, Steals = ns.Plan, ns.Steals
  for _, st in ipairs(Steals and Steals.Rows() or {}) do
    local gain = (st.fair - st.price) / 10000
    rows[#rows + 1] = {
      id = st.id, signal = "STEAL", name = ItemName(st.id), steal = st,
      rule = format(L["%s · %d%% of fair %s"], Plan.Money(st.price), floor(st.pct * 100 + 0.5), Plan.Money(st.fair)),
      gain = gain, gainText = gain >= 1 and ("+" .. floor(gain) .. "g") or "",
    }
  end
  for _, play in ipairs(Plan.Plays(house, MAX_ROWS - #rows)) do
    local it = play.item
    rows[#rows + 1] = {
      id = play.id, item = it, signal = it.signal, name = ItemName(play.id),
      rule = Plan.Rule(it, house), gain = it.gain,
      gainText = it.gain and it.gain > 0 and ("+" .. floor(it.gain) .. "g") or "",
    }
  end
  return rows
end

function Panel.HeaderText(house)
  local Plan = ns.Plan
  local hname = house and format("%s AH (%d)", Plan.HouseName(house), house) or L["unknown AH"]
  local regime = Plan.Regime(house)
  local parts = { hname, format(L["data %s old"], Plan.AgeText()) }
  if Plan.IsBuiltin() then parts[#parts + 1] = L["SAMPLE DATA"] end
  if regime then parts[#parts + 1] = L["market: "] .. regime:upper() end
  local hidden = house and Plan.ShuttleHidden(house) or 0
  if hidden > 0 then parts[#parts + 1] = format(L["shuttle off (%d)"], hidden) end
  return table.concat(parts, " · ")
end

-- Search: hand the player to Blizzard's own buy frame. Public path is the one Blizzard's browse results use:
-- AuctionHouseFrame:QueryItem (-> C_AuctionHouse.SendSearchQuery) then :SelectBrowseResult. If the item key info
-- is not cached yet, fall back to a name search through Blizzard's search bar. [TODO-INGAME] confirm both paths.
-- A STEAL row passes the item key its browse reply carried (item level included) and the live minimum (D-038).
function Panel.Search(id, itemKey, livePrice)
  local ahf = _G.AuctionHouseFrame
  if not (ahf and ahf:IsShown()) then return false, "auction house not open" end
  local ok, wait = Throttle.Take()
  if not ok then
    print(format("|cff00ccffWuwei|r " .. L["search limit reached; wait %ds"], floor(wait) + 1))
    return false, "throttled"
  end
  local key = itemKey or C_AuctionHouse.MakeItemKey(id)
  local info = C_AuctionHouse.GetItemKeyInfo(key)
  local ctx = AuctionHouseSearchContext
  if info and ctx and ahf.QueryItem and ahf.SelectBrowseResult then
    local it = ns.Plan.Item(id)
    local minPrice = livePrice or (it and ns.Plan.RefPrice(it, ns.House.Detect())) or 0
    ahf:QueryItem(info.isCommodity and ctx.BuyCommodities or ctx.BuyItems, key)
    ahf:SelectBrowseResult({ itemKey = key, minPrice = minPrice })
    return true, "itemkey"
  end
  local name = C_Item.GetItemNameByID(id)
  if name and ahf.SendBrowseQuery then
    if ahf.SetSearchText then ahf:SetSearchText(name) end
    ahf:SendBrowseQuery(name, 0, 0, {})
    return true, "name"
  end
  C_Item.RequestLoadItemDataByID(id)
  return false, "item data not loaded; try again"
end

local function MakeRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(WIDTH - 16, ROW_H)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -(44 + (i - 1) * ROW_H))
  local function fs(w, x, justify)
    local f = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f:SetPoint("LEFT", row, "LEFT", x, 0)
    f:SetWidth(w)
    f:SetJustifyH(justify or "LEFT")
    return f
  end
  row.signal = fs(58, 0)
  row.name = fs(150, 60)
  row.rule = fs(150, 214)
  row.gain = fs(50, 366, "RIGHT")
  row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.button:SetSize(60, ROW_H - 2)
  row.button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.button:SetText(L["Search"])
  row.button:SetScript("OnClick", function()
    if not row.itemID then return end
    if row.steal then Panel.Search(row.itemID, row.steal.key, row.steal.price) else Panel.Search(row.itemID) end
  end)
  return row
end

local function Build()
  local f = CreateFrame("Frame", "WuweiPanelFrame", UIParent) -- named for /fstack; not an API surface
  f:SetSize(WIDTH, 52 + MAX_ROWS * ROW_H)
  f:SetFrameStrata("HIGH")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.8)
  f.header = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.header:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -10)
  f.steals = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- steals status line (D-038)
  f.steals:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -26)
  f.scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.scan:SetSize(96, 18)
  f.scan:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
  f.scan:SetText(L["Scan steals"])
  f.scan:SetScript("OnClick", function() if ns.Steals then ns.Steals.Scan() end end)
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -50)
  f.rows = {}
  for i = 1, MAX_ROWS do f.rows[i] = MakeRow(f, i) end
  f:Hide()
  return f
end

function Panel.Refresh()
  local f = Panel.frame
  if not (f and f:IsShown()) then return end
  local house = ns.House.Detect()
  f.header:SetText(Panel.HeaderText(house))
  local stealsText = ns.Steals and ns.Steals.StatusText() or ""
  f.steals:SetText(stealsText)
  if stealsText ~= "" then f.scan:Show() else f.scan:Hide() end
  local rows = house and Panel.BuildRows(house) or {}
  f.empty:SetText(#rows == 0 and (house and L["No plays for this house in the current plan."] or
    L["House unknown. Use /wuwei house <id>."]) or "")
  for i = 1, MAX_ROWS do
    local row, d = f.rows[i], rows[i]
    if d then
      row.itemID, row.steal = d.id, d.steal
      row.signal:SetText(ns.Plan.Colorize(d.signal, d.signal))
      row.name:SetText(d.name)
      row.rule:SetText(d.rule)
      row.gain:SetText(d.gainText)
      row:Show()
    else
      row.itemID, row.steal = nil, nil
      row:Hide()
    end
  end
end

function Panel.Show()
  if not (ns.db and ns.db.enabled) then return end
  local ahf = _G.AuctionHouseFrame
  if not ahf then return end
  if not Panel.frame then Panel.frame = Build() end
  local f = Panel.frame
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", ahf, "TOPRIGHT", 4, 0)
  f:Show()
  Panel.Refresh()
end

function Panel.Hide()
  if Panel.frame then Panel.frame:Hide() end
end

function Panel.Init()
  if Panel.events then return end
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("AUCTION_HOUSE_SHOW")
  ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
  ev:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  ev:SetScript("OnEvent", function(_, event, itemID)
    if event == "AUCTION_HOUSE_SHOW" then Panel.Show()
    elseif event == "AUCTION_HOUSE_CLOSED" then Panel.Hide()
    elseif requested[itemID] then Panel.Refresh() end -- only our own name loads; browsing fires this event constantly
  end)
  Panel.events = ev
end
