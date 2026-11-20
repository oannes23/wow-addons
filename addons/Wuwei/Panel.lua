-- AH side panel, anchored right of AuctionHouseFrame, with three modes (SPEC D-058): Steals (STEAL/CHECK rows from
-- the watchlist scan, Scan/Stop button), Markets (sector movers, Markets.lua) and Plays (today's plan for this house).
-- It only searches and hands off to Blizzard's buy UI; it never calls a HasRestrictions API (PlaceBid,
-- StartCommoditiesPurchase, Post*). A Search click cancels a running steals scan first (D-057).
local _, ns = ...
local L = ns.L

local GetTime, floor, format, ipairs, pcall = GetTime, math.floor, string.format, ipairs, pcall

local MAX_ROWS = 20
local ROW_H = 20
local WIDTH = 600

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

local CONF_COLOR = { high = "ff40e060", med = "ffffd200", low = "ffa0a0a0" }

local function ItemName(id)
  local name = C_Item.GetItemNameByID(id)
  if name then return name end
  if not requested[id] then
    requested[id] = true
    C_Item.RequestLoadItemDataByID(id) -- ITEM_DATA_LOAD_RESULT triggers a refresh
  end
  return "item:" .. id
end

Panel.MAX_ROWS = MAX_ROWS
Panel.MODES = { "steals", "markets", "plays" }
local MODE_LABEL = { steals = L["Steals"], markets = L["Markets"], plays = L["Plays"] }
local drill -- markets: the open sector key, or nil for the overview

-- Current mode (D-058): steals | markets | plays, remembered in WuweiDB.panelMode (default steals).
function Panel.Mode()
  local m = ns.db and ns.db.panelMode
  if m == "markets" or m == "plays" or m == "steals" then return m end
  return "steals"
end

-- quiet = true: no refresh (the caller refreshes), used by a scan start.
function Panel.SetMode(mode, quiet)
  if not ns.db or not MODE_LABEL[mode] then return false end
  ns.db.panelMode = mode
  if mode ~= "markets" then drill = nil end
  if not quiet then Panel.Refresh() end
  return true
end

function Panel.OpenSector(key) drill = key Panel.Refresh() end
function Panel.Sector() return drill end

-- Pure row builders (no frames). Rows: { id?, signal, name?, rule, gainText, steal?, sector?, label?, button? }.
function Panel.StealRows(limit)
  local rows = {}
  local Plan, Steals = ns.Plan, ns.Steals
  for _, st in ipairs(Steals and Steals.Rows(limit or MAX_ROWS) or {}) do
    local gain = ((st.net or st.fair) - st.price) / 10000 -- net at the resale house when the plan has it (D-050)
    local resale = Steals.ResaleText(st)
    local cpct, clabel = Steals.Confidence(st, Steals.ActiveHouse()) -- D-059
    rows[#rows + 1] = {
      id = st.id, signal = st.check and "CHECK" or "STEAL", name = ItemName(st.id), steal = st, conf = cpct,
      rule = format(L["%s · %d%% of fair %s"], Plan.Money(st.price), floor(st.pct * 100 + 0.5), Plan.Money(st.fair))
        .. " · |c" .. CONF_COLOR[clabel] .. format(L["conf %d%%"], cpct) .. "|r" .. (resale and (" · " .. resale) or ""),
      gain = gain, gainText = gain >= 1 and ("+" .. floor(gain) .. "g") or "",
    }
  end
  return rows
end

function Panel.PlayRows(house, limit)
  local rows = {}
  local Plan = ns.Plan
  for _, play in ipairs(Plan.Plays(house, limit or MAX_ROWS)) do
    local it = play.item
    rows[#rows + 1] = {
      id = play.id, item = it, signal = it.signal, name = ItemName(play.id),
      rule = Plan.Rule(it, house), gain = it.gain,
      gainText = it.gain and it.gain > 0 and ("+" .. floor(it.gain) .. "g") or "",
    }
  end
  return rows
end

-- Rows of the current mode, at most MAX_ROWS. Steals mode shows only STEAL/CHECK rows (owner request 2026-11-20:
-- the plays used to fill the rows under them and read as noise during a scan).
function Panel.BuildRows(house, mode)
  mode = mode or Panel.Mode()
  if mode == "steals" then return Panel.StealRows(MAX_ROWS) end
  if mode == "markets" then
    local rows = ns.Markets and ns.Markets.Rows(house, drill, MAX_ROWS) or {}
    for _, r in ipairs(rows) do if r.id and not r.name then r.name = ItemName(r.id) end end
    return rows
  end
  return Panel.PlayRows(house, MAX_ROWS)
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
-- is not cached yet, fall back to a name search through Blizzard's search bar.
-- A STEAL row passes the item key its browse reply carried (item level included) and the live minimum (D-038).
-- D-057: a running steals scan is cancelled BEFORE anything is sent, and a search the client drops from its
-- throttled-message queue (AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED within DROP_WINDOW s) is sent again once the
-- queue is ready, at most RETRIES times, so a steal can be searched the moment it shows.
Panel.DROP_WINDOW, Panel.RETRIES, Panel.RETRY_WAIT = 3, 2, 5
local lastSearch, retry -- the last search sent { id, key, price, sentAt, tries }; one waiting to be resent

local function Send(req)
  local ahf = _G.AuctionHouseFrame
  if not (ahf and ahf:IsShown()) then return false, "auction house not open" end
  local ok, wait = Throttle.Take()
  if not ok then
    print(format("|cff00ccffWuwei|r " .. L["search limit reached; wait %ds"], floor(wait) + 1))
    return false, "throttled"
  end
  local id, itemKey, livePrice = req.id, req.key, req.price
  local key = itemKey or C_AuctionHouse.MakeItemKey(id)
  local info = C_AuctionHouse.GetItemKeyInfo(key)
  local ctx = AuctionHouseSearchContext
  if info and ctx and ahf.QueryItem and ahf.SelectBrowseResult then
    local it = ns.Plan.Item(id)
    local minPrice = livePrice or (it and ns.Plan.RefPrice(it, ns.House.Detect())) or 0
    req.sentAt = GetTime()
    lastSearch = req
    ahf:QueryItem(info.isCommodity and ctx.BuyCommodities or ctx.BuyItems, key)
    ahf:SelectBrowseResult({ itemKey = key, minPrice = minPrice })
    return true, "itemkey"
  end
  local name = C_Item.GetItemNameByID(id)
  if name and ahf.SendBrowseQuery then
    req.sentAt = GetTime()
    lastSearch = req
    if ahf.SetSearchText then ahf:SetSearchText(name) end
    ahf:SendBrowseQuery(name, 0, 0, {})
    return true, "name"
  end
  C_Item.RequestLoadItemDataByID(id)
  return false, "item data not loaded; try again"
end

function Panel.Search(id, itemKey, livePrice)
  local ahf = _G.AuctionHouseFrame
  if not (ahf and ahf:IsShown()) then return false, "auction house not open" end
  if ns.Steals and ns.Steals.Cancel then ns.Steals.Cancel("search") end -- before sending (D-057)
  retry = nil
  return Send({ id = id, key = itemKey, price = livePrice, tries = 0 })
end

-- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED: our search, if it went out just now, is queued for a resend.
function Panel.OnDropped()
  local r = lastSearch
  if not (r and r.sentAt and GetTime() - r.sentAt <= Panel.DROP_WINDOW) then return end
  lastSearch = nil
  if r.tries >= Panel.RETRIES then
    print("|cff00ccffWuwei|r " .. L["The auction house dropped your search; click Search again."])
    return
  end
  r.tries, r.queuedAt = r.tries + 1, GetTime()
  retry = r
  if Panel.events then Panel.events:SetScript("OnUpdate", function() Panel.RetryTick() end) end
end

-- Resends a dropped search once the throttled-message queue is ready (polled from OnUpdate while one waits).
function Panel.RetryTick()
  local r = retry
  if not r then
    if Panel.events then Panel.events:SetScript("OnUpdate", nil) end
    return
  end
  if GetTime() - r.queuedAt > Panel.RETRY_WAIT then
    retry = nil
    print("|cff00ccffWuwei|r " .. L["The auction house dropped your search; click Search again."])
    return
  end
  local AH = C_AuctionHouse
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end
  retry = nil
  Send(r)
end

function Panel.PendingRetry() return retry end

local TOP = 66 -- y offset of the first row: header, tabs, status line above it

local function MakeRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(WIDTH - 16, ROW_H)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -(TOP + (i - 1) * ROW_H))
  local function fs(w, x, justify)
    local f = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f:SetPoint("LEFT", row, "LEFT", x, 0)
    f:SetWidth(w)
    f:SetJustifyH(justify or "LEFT")
    return f
  end
  row.signal = fs(58, 0)
  row.name = fs(150, 60)
  row.rule = fs(230, 214)
  row.gain = fs(50, 446, "RIGHT")
  row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.button:SetSize(60, ROW_H - 2)
  row.button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  row.button:SetText(L["Search"])
  row.button:SetScript("OnClick", function()
    if row.sector then return Panel.OpenSector(row.sector) end
    if not row.itemID then return end
    if row.steal then Panel.Search(row.itemID, row.steal.key, row.steal.price) else Panel.Search(row.itemID, nil, row.price) end
  end)
  return row
end

-- The button at the top right: Scan steals / Stop scan in steals mode, Back inside a market sector, else hidden.
local function OnAction()
  local mode = Panel.Mode()
  if mode == "markets" and drill then drill = nil return Panel.Refresh() end
  if mode == "steals" and ns.Steals then
    if ns.Steals.Active() then ns.Steals.Cancel("cancel") else ns.Steals.Scan() end
  end
end

local function Build()
  local f = CreateFrame("Frame", "WuweiPanelFrame", UIParent) -- named for /fstack; not an API surface
  f:SetSize(WIDTH, TOP + 8 + MAX_ROWS * ROW_H)
  f:SetFrameStrata("HIGH")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.8)
  f.header = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.header:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -10)
  f.tabs = {}
  for i, mode in ipairs(Panel.MODES) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(76, 18)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 8 + (i - 1) * 80, -26)
    b:SetText(MODE_LABEL[mode])
    b:SetScript("OnClick", function() Panel.SetMode(mode) end)
    b.mode = mode
    f.tabs[i] = b
  end
  f.scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate") -- the action button (OnAction)
  f.scan:SetSize(96, 18)
  f.scan:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -26)
  f.scan:SetText(L["Scan steals"])
  f.scan:SetScript("OnClick", OnAction)
  f.steals = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") -- status line of the current mode
  f.steals:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -50)
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(TOP + 4))
  f.rows = {}
  for i = 1, MAX_ROWS do f.rows[i] = MakeRow(f, i) end
  f:Hide()
  return f
end

local function EmptyText(mode, house)
  if not house then return L["House unknown. Use /wuwei house <id>."] end
  if mode == "steals" then
    if not (ns.Steals and ns.Steals.On()) then return L["No steals list for this house in the current plan."] end
    if ns.Steals.Active() then return L["Scanning... a steal shows here the moment a reply has one; Search stops the scan."] end
    return L["No steals found this visit."]
  end
  if mode == "markets" then return "" end -- the status line explains a missing block
  return L["No plays for this house in the current plan."]
end

function Panel.Refresh()
  local f = Panel.frame
  if not (f and f:IsShown()) then return end
  local house = ns.House.Detect()
  local mode = Panel.Mode()
  f.header:SetText(Panel.HeaderText(house))
  for _, b in ipairs(f.tabs) do
    b:SetText(b.mode == mode and ("[" .. MODE_LABEL[b.mode] .. "]") or MODE_LABEL[b.mode])
  end
  local status, action = "", nil
  if mode == "steals" then
    status = ns.Steals and ns.Steals.StatusText() or ""
    if status ~= "" then action = ns.Steals.Active() and L["Stop scan"] or L["Scan steals"] end
  elseif mode == "markets" then
    status = ns.Markets and house and ns.Markets.StatusText(house, drill) or ""
    if drill then action = L["Back"] end
  end
  f.steals:SetText(status)
  if action then f.scan:SetText(action) f.scan:Show() else f.scan:Hide() end
  local rows = house and Panel.BuildRows(house, mode) or {}
  f.empty:SetText(#rows == 0 and EmptyText(mode, house) or "")
  for i = 1, MAX_ROWS do
    local row, d = f.rows[i], rows[i]
    if d then
      row.itemID, row.steal, row.sector, row.price = d.id, d.steal, d.sector, d.price
      if d.label then
        row.signal:SetText("")
        row.name:SetText("|cffffd200" .. d.name .. "|r")
        row.rule:SetText("")
        row.gain:SetText("")
        row.button:Hide()
      else
        row.signal:SetText(d.signalRaw and d.signal or ns.Plan.Colorize(d.signal, d.signal))
        row.name:SetText(d.name or "")
        row.rule:SetText(d.rule or "")
        row.gain:SetText(d.gainText or "")
        row.button:SetText(d.button or L["Search"])
        row.button:Show()
      end
      row:Show()
    else
      row.itemID, row.steal, row.sector, row.price = nil, nil, nil, nil
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
  ev:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  ev:SetScript("OnEvent", function(_, event, itemID)
    if event == "AUCTION_HOUSE_SHOW" then drill = nil Panel.Show()
    elseif event == "AUCTION_HOUSE_CLOSED" then
      retry, lastSearch, drill = nil, nil, nil
      ev:SetScript("OnUpdate", nil)
      ns.House.ResetProbe()
      Panel.Hide()
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then pcall(Panel.OnDropped)
    elseif requested[itemID] then Panel.Refresh() end -- only our own name loads; browsing fires this event constantly
  end)
  Panel.events = ev
end
