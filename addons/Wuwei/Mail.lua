-- Mail invoices (SPEC D-048): the AH's own record of each sale (price, deposit refund, cut, money received), plus
-- expired/canceled returns. Read-only: header and invoice getters only. Never GetInboxText (it marks mail read),
-- never takes money or items, never deletes.
local _, ns = ...

local floor, abs, ipairs, pairs, pcall, tonumber = math.floor, math.abs, ipairs, pairs, pcall, tonumber

local Mail = {}
ns.Mail = Mail

Mail.MAX_DAYS = 30            -- AH mail lifetime: arrival is estimated as now - (MAX_DAYS - daysLeft) days
Mail.MATCH_SLACK = 600        -- s: the same mail seen again has its estimated arrival within this window
Mail.KEEP = 31 * 86400        -- s: dedupe records older than this are pruned

local function State()
  local st = ns.db.ledgerState
  st.mail = st.mail or {}
  return st.mail
end

-- "Auction expired: %s" -> "^Auction expired: (.+)$" (GlobalStrings are format strings; escape magic characters).
local function SubjectPattern(fmt)
  if type(fmt) ~= "string" or not fmt:find("%%s") then return nil end
  local lit = fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  return "^" .. (lit:gsub("%%s", "(.+)", 1)) .. "$"
end

local function Subjects()
  return {
    sold = SubjectPattern(_G.AUCTION_SOLD_MAIL_SUBJECT),
    expired = SubjectPattern(_G.AUCTION_EXPIRED_MAIL_SUBJECT),
    canceled = SubjectPattern(_G.AUCTION_REMOVED_MAIL_SUBJECT),
  }
end

-- House from the sender name [TODO-INGAME exact names]: Blackwater mail says so; everything else is the faction
-- house (D-032: Horde 114 only).
function Mail.HouseFromSender(sender)
  if type(sender) ~= "string" then return nil end
  if sender:lower():find("blackwater", 1, true) then return 117 end
  return 114
end

-- "Waylaid Crate: Apprentice Ore (10)" -> "Waylaid Crate: Apprentice Ore", 10. The subject names a stack as
-- AUCTION_MAIL_ITEM_STACK "%s (%d)" and a single item bare (MailFrame.lua formats invoices the same way only when
-- count > 1 [SRC]; seen on every 2026-11-16 subject [INGAME]). The subject never changes, so neither does this.
function Mail.SplitName(s)
  if type(s) ~= "string" then return nil, nil end
  local base, n = s:match("^(.-) %((%d+)%)$")
  if base and base ~= "" then return base, tonumber(n) end
  return s, nil
end

local function IDFromLink(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- itemName -> itemID via the item IDs Wuwei has already seen (cached names), then the client's own lookup.
function Mail.ResolveName(name)
  if type(name) ~= "string" or name == "" then return nil end
  local byName = C_Item and C_Item.GetItemNameByID
  if byName then
    local seen = {}
    local function try(id)
      if id and not seen[id] then
        seen[id] = true
        local ok, n = pcall(byName, id)
        if ok and n == name then return id end
      end
    end
    for _, rec in pairs(ns.db.ledgerState.owned or {}) do
      local id = try(rec.itemID)
      if id then return id end
    end
    local l = ns.db.ledger or {}
    for i = #l, math.max(1, #l - 500), -1 do
      local id = try(l[i].itemID)
      if id then return id end
    end
  end
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, id = pcall(C_Item.GetItemInfoInstant, name)
    if ok and type(id) == "number" then return id end
  end
  return nil
end

-- One inbox row -> an invoice record (fields for Ledger.Add) or nil when it is not an auction outcome.
function Mail.Classify(i, subjects)
  local ok, _, _, sender, subject, money, _, daysLeft, _, _, _, _, _, _, firstQty, firstLink = pcall(GetInboxHeaderInfo, i)
  if not ok then return nil end
  local rec
  if GetInboxInvoiceInfo then
    local ok2, invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count = pcall(GetInboxInvoiceInfo, i)
    if ok2 and invoiceType == "seller" then
      -- net from the invoice itself: the header money drops to 0 the moment the gold is taken (D-049)
      local net = (money and money > 0) and money or nil
      if not net and bid and consignment then net = bid + (deposit or 0) - consignment end
      rec = { outcome = "sold", itemName = itemName, qty = count, gross = bid, deposit = deposit, cut = consignment,
        net = net }
    elseif ok2 and invoiceType then
      return nil -- seller_temp_invoice (sale pending; the final invoice follows) or buyer
    end
  end
  -- The subject is the stable part of a mail: name and stack size from it, never from the attachments (the first
  -- attachment is one stack of several, and attachments vanish when taken: D-049).
  local subjBase, subjQty
  if type(subject) == "string" then
    for outcome, pat in pairs(subjects) do
      local name = pat and subject:match(pat)
      if name then
        subjBase, subjQty = Mail.SplitName(name)
        if not rec then
          rec = { outcome = outcome, itemName = subjBase }
          if outcome == "sold" then
            rec.net = (money and money > 0) and money or nil
          else
            rec.itemID = IDFromLink(firstLink)
          end
        end
        break
      end
    end
  end
  if not rec then return nil end
  rec.itemName = rec.itemName or subjBase
  rec.qty = rec.qty or subjQty or 1
  rec.sender = sender
  rec.house = Mail.HouseFromSender(sender)
  rec.daysLeft = daysLeft
  return rec
end

-- Identity of a mail: only fields that never change while it sits in the inbox (D-049). Money, attachments and a
-- late-loading item link are not identity; they enrich the entry already recorded.
local function Key(r)
  return table.concat({ r.outcome or "", (Mail.SplitName(r.itemName)) or "", r.sender or "" }, "|")
end

local FILL = { "itemID", "gross", "deposit", "cut", "net" }

-- Copy what a later read knows into the entry recorded at `at` (same mail, fields loaded late).
local function Enrich(at, k, r)
  local l = ns.db.ledger or {}
  for i = #l, math.max(1, #l - 500), -1 do
    local e = l[i]
    if e.kind == "invoice" and e.at == at and Key(e) == k then
      local itemID = r.itemID or (not e.itemID and Mail.ResolveName(r.itemName)) or nil
      for _, f in ipairs(FILL) do
        local v = (f == "itemID") and itemID or r[f]
        if e[f] == nil and v ~= nil then e[f] = v end
      end
      if not e.unit and e.gross and e.qty and e.qty > 0 then e.unit = floor(e.gross / e.qty + 0.5) end
      ns.Ledger.Invalidate()
      return
    end
  end
end

-- Scan the open inbox; record each auction mail once (multiset match on fields + estimated arrival).
function Mail.Scan()
  if not (ns.db and ns.db.ledgerState and GetInboxNumItems and GetInboxHeaderInfo) then return 0 end
  if ns.db.mail == false then return 0 end
  local now = GetServerTime()
  local seen = State()
  local kept = {}
  for _, s in ipairs(seen) do
    if now - (s.at or 0) <= Mail.KEEP then kept[#kept + 1] = s end
  end
  seen = kept
  ns.db.ledgerState.mail = seen
  local ok, n = pcall(GetInboxNumItems)
  if not ok or type(n) ~= "number" then return 0 end
  local subjects = Subjects()
  local used, added = {}, 0
  for i = 1, n do
    local r = Mail.Classify(i, subjects)
    if r then
      local at = r.daysLeft and floor(now - (Mail.MAX_DAYS - r.daysLeft) * 86400) or now
      local k = Key(r)
      local match
      for j, s in ipairs(seen) do
        if not used[j] and s.k == k and abs((s.at or 0) - at) <= Mail.MATCH_SLACK then match = j break end
      end
      if match then
        used[match] = true
        Enrich(seen[match].at, k, r)
      else
        local itemID = r.itemID or Mail.ResolveName(r.itemName)
        local unit = r.gross and r.qty and r.qty > 0 and floor(r.gross / r.qty + 0.5) or nil
        local e = ns.Ledger.Add("invoice", itemID, r.qty, unit, "MAIL", {
          outcome = r.outcome, itemName = r.itemName, gross = r.gross, deposit = r.deposit, cut = r.cut, net = r.net,
          sender = r.sender, house = r.house, at = at })
        if e then
          seen[#seen + 1] = { k = k, at = at }
          used[#seen] = true
          added = added + 1
        end
      end
    end
  end
  return added
end

-- One-time repair (D-049): 0.4.0 keyed a mail on fields that change while it sits in the inbox, so taking the gold
-- or the items, or an item link loading late, recorded the same mail again. Collapse each cluster of invoices with
-- the same outcome, item name (stack suffix stripped), sender and estimated arrival within MATCH_SLACK into its
-- first entry, filling fields it lacks; take the stack size from the subject suffix. Rekey the dedupe records.
function Mail.Repair()
  local db = ns.db
  if not db or (db.mailRepair or 0) >= 1 then return 0 end
  local l, keep, changed = db.ledger or {}, {}, 0
  local heads = {}
  for _, e in ipairs(l) do
    local drop = false
    if e.kind == "invoice" then
      local base, n = Mail.SplitName(e.itemName)
      if n or e.qtyUnknown then
        e.itemName, e.qty, e.qtyUnknown, e.repaired = base, n or e.qty or 1, nil, true
        if not e.itemID then e.itemID = Mail.ResolveName(base) end
        if e.gross and e.qty > 0 then e.unit = floor(e.gross / e.qty + 0.5) end
        changed = changed + 1
      end
      local k = Key(e)
      for _, h in ipairs(heads) do
        if Key(h) == k and h.house == e.house and abs((h.at or 0) - (e.at or 0)) <= Mail.MATCH_SLACK then
          for _, f in ipairs(FILL) do if h[f] == nil then h[f] = e[f] end end
          if not h.unit and e.unit then h.unit = e.unit end
          h.repaired, drop = true, true
          break
        end
      end
      if not drop then heads[#heads + 1] = e end
    end
    if drop then changed = changed + 1 else keep[#keep + 1] = e end
  end
  db.ledger = keep
  local seen = {}
  for _, h in ipairs(heads) do seen[#seen + 1] = { k = Key(h), at = h.at } end
  if db.ledgerState then db.ledgerState.mail = seen end
  db.mailRepair = 1
  ns.Ledger.Invalidate()
  return changed
end

function Mail.Init()
  if ns.db then pcall(Mail.Repair) end
  if Mail.events or not CreateFrame then return end
  local f = CreateFrame("Frame")
  f:RegisterEvent("MAIL_SHOW")
  f:RegisterEvent("MAIL_INBOX_UPDATE")
  f:SetScript("OnEvent", function() if ns.db then pcall(Mail.Scan) end end)
  Mail.events = f
end
