-- Panel beside the profession window (SPEC UX): header (skill, totals, price age), then the route's steps, two lines
-- each: what to craft and its cost per point, then what to buy and where. Writes no Blizzard frame state; Open only
-- calls C_TradeSkillUI.OpenRecipe.
local _, ns = ...
local L = ns.L

local format, floor, ceil, ipairs, type, max, min = string.format, math.floor, math.ceil, ipairs, type, math.max, math.min

local Panel = {}
ns.Panel = Panel

local WIDTH, TOP, STEP_H, MAX_STEPS = 360, 58, 34, 9
local HOUSE = { [114] = "Horde", [117] = "Blackwater" }
local COLOUR = { orange = "ffff8040", yellow = "ffffff00", green = "ff40c040", grey = "ff808080" }

local function Money(c) return ns.Planner.Money(c) end

-- Seconds since an ISO "YYYY-MM-DDTHH:MM:SSZ" (UTC) stamp, using the server clock. nil when unparseable.
function Panel.Age(iso)
  if type(iso) ~= "string" then return nil end -- (`x and s:match()` would keep only the first capture)
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
  if not y then return nil end
  y, mo = tonumber(y), tonumber(mo)
  if mo <= 2 then y, mo = y - 1, mo + 12 end -- days from civil (proleptic Gregorian), then epoch seconds
  local days = 365 * y + floor(y / 4) - floor(y / 100) + floor(y / 400) + floor((153 * (mo - 3) + 2) / 5) + tonumber(d) - 719469
  local t = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  return max(0, GetServerTime() - t)
end

local function AgeText(sec)
  if not sec then return "?" end
  if sec < 3600 then return format("%dm", floor(sec / 60)) end
  if sec < 86400 then return format("%dh", floor(sec / 3600)) end
  return format("%dd", floor(sec / 86400))
end

local function ItemName(id)
  local it = ns.LADDER and ns.LADDER.items[id]
  return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or (it and it.n) or ("item:" .. id)
end

local function Have(id) return C_Item.GetItemCount(id, true) or 0 end

-- One step's two text lines (pure; tests call it).
function Panel.StepText(ctx, st, used)
  local P = ns.Planner
  local crafts = ceil(st.crafts - 1e-9)
  local perPt = st.cost / max(1, st.to - st.from)
  local how = (st.how == "learn" and (" · " .. L["learn at trainer"])) or (st.how == "learn~" and (" · " .. L["learn at trainer (~level)"])) or ""
  local line1 = format("|c%s%d→%d|r  %s  ×%d  |cffc0c0c0%s/pt|r%s", COLOUR[st.colour] or COLOUR.grey, st.from, st.to,
    st.r.n, crafts, Money(perPt), how)
  local parts = {}
  if st.spell == P.DISENCHANT then
    local Ld = ns.LADDER
    for _, h in ipairs(ctx.houses) do
      local de = Ld.de and Ld.de[h]
      if type(de) == "table" then
        local _, first = P.Filter4(de, ctx.deSkill or 0)
        if first then parts[#parts + 1] = format(L["disenchant e.g. %s (%s)"], ItemName(first), L[HOUSE[h]] or h) break end
      end
    end
  else
    for _, b in ipairs(P.Shopping(ctx, st, Have, used)) do
      if b.buy > 0 then
        local where = (b.src == "vendor" and L["vendor"]) or (b.src == "de" and format(L["DE %s, %s"], ItemName(b.via), L[HOUSE[b.house]] or ""))
          or (L[HOUSE[b.house]] or "?")
        parts[#parts + 1] = format("%d %s %s (%s)", b.buy, ItemName(b.id), b.unit and Money(b.unit) or "?", where)
      end
    end
    if #parts == 0 then parts[1] = L["all in your bags"] end
  end
  if st.r.t and #st.r.t > 0 then parts[#parts + 1] = format(L["needs %s"], table.concat(st.r.t, ", ")) end
  return line1, "   " .. table.concat(parts, " · ")
end

-- Header lines (pure).
function Panel.HeaderText(state, steps, totals, target)
  local Ld = ns.LADDER
  local ages = {}
  for _, h in ipairs(Ld.houses or {}) do
    ages[#ages + 1] = format("%s %s", L[HOUSE[h]] or h, AgeText(Panel.Age(Ld.prices and Ld.prices[h])))
  end
  local h1 = format(L["Athanor · %s %d / %d"], state.name or "?", state.skill, state.max)
  local h2
  if #steps == 0 then
    h2 = state.skill >= target and L["At the target: nothing to plan."] or L["No craftable recipe found for the next point."]
  else
    h2 = format(L["To %d: ~%d crafts · ~%s"], totals.reached, ceil(totals.crafts - 1e-9), Money(totals.cost))
    if totals.reached < target then h2 = h2 .. " · " .. format(L["stops at %d"], totals.reached) end
  end
  return h1, h2, L["prices"] .. " " .. table.concat(ages, " · ")
end

local function Build()
  local f = CreateFrame("Frame", "AthanorPanelFrame", UIParent) -- named for /fstack
  f:SetSize(WIDTH, TOP + 8 + MAX_STEPS * STEP_H)
  f:SetFrameStrata("HIGH")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.8)
  local function Text(font, x, y)
    local t = f:CreateFontString(nil, "OVERLAY", font)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
    t:SetWidth(WIDTH - 16)
    t:SetJustifyH("LEFT")
    t:SetWordWrap(false)
    return t
  end
  f.h1, f.h2, f.h3 = Text("GameFontNormal", 8, -8), Text("GameFontHighlightSmall", 8, -26), Text("GameFontDisableSmall", 8, -40)
  f.steps = {}
  for i = 1, MAX_STEPS do
    local y = -(TOP + (i - 1) * STEP_H)
    local row = { a = Text("GameFontHighlightSmall", 8, y), b = Text("GameFontDisableSmall", 8, y - 14) }
    row.a:SetWidth(WIDTH - 70)
    row.b:SetWidth(WIDTH - 16)
    row.button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    row.button:SetSize(52, 18)
    row.button:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, y + 3)
    row.button:SetText(L["Open"])
    row.button:SetScript("OnClick", function()
      if row.spell then C_TradeSkillUI.OpenRecipe(row.spell) end
    end)
    f.steps[i] = row
  end
  return f
end

local function Target(state)
  local t = ns.db and ns.db.target[state.prof]
  return (type(t) == "number" and t > state.skill) and t or state.max
end

function Panel.Compute(state)
  local ctx = ns.Context(state)
  local target = Target(state)
  local steps, totals = ns.Planner.Plan(ctx, state.prof, state.skill, target)
  return ctx, steps, totals, target
end

function Panel.Refresh()
  local f = Panel.frame
  if not (f and f:IsShown()) then return end
  local state = ns.Scan.State()
  if not (state and ns.LADDER) then
    f.h1:SetText(L["Athanor"])
    f.h2:SetText(ns.LADDER and L["This profession isn't planned (gathering or fishing)."] or L["No ladder data: run wowf-analysis export-addon."])
    f.h3:SetText("")
    for _, row in ipairs(f.steps) do row.a:SetText("") row.b:SetText("") row.button:Hide() end
    return
  end
  local ctx, steps, totals, target = Panel.Compute(state)
  local h1, h2, h3 = Panel.HeaderText(state, steps, totals, target)
  f.h1:SetText(h1)
  f.h2:SetText(h2)
  f.h3:SetText(h3)
  local used = {}
  for i, row in ipairs(f.steps) do
    local st = steps[i]
    if st then
      local a, b = Panel.StepText(ctx, st, used)
      row.a:SetText(a)
      row.b:SetText(b)
      row.spell = (st.how == "known" and st.spell ~= ns.Planner.DISENCHANT) and st.spell or nil
      row.button:SetShown(row.spell ~= nil)
    else
      row.a:SetText("")
      row.b:SetText("")
      row.spell = nil
      row.button:Hide()
    end
  end
end

function Panel.Debug(state)
  local ctx, steps, totals = Panel.Compute(state)
  ns.Say(format("%s %d/%d · %d steps · ~%d crafts · %s", state.name or "?", state.skill, state.max, #steps,
    ceil(totals.crafts - 1e-9), Money(totals.cost)))
  for i = 1, min(#steps, 12) do
    local st = steps[i]
    ns.Say(format("%d→%d %s (%s, %s) ×%.1f %s", st.from, st.to, st.r.n, st.colour, st.how or "", st.crafts, Money(st.cost)))
  end
  local _ = ctx
end

function Panel.Show()
  if not (ns.db and ns.db.shown) then return Panel.Hide() end
  local pf = _G.ProfessionsFrame
  if not pf then return end
  if not Panel.frame then Panel.frame = Build() end
  local f = Panel.frame
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", pf, "TOPRIGHT", 4, 0)
  f:Show()
  Panel.Refresh()
end

function Panel.Hide()
  if Panel.frame then Panel.frame:Hide() end
end

-- Show with the profession window. Blizzard_Professions is load-on-demand: hook its frame once it loads.
function Panel.Init()
  if Panel.hooked then return end
  EventUtil.ContinueOnAddOnLoaded("Blizzard_Professions", function()
    if Panel.hooked or not _G.ProfessionsFrame then return end
    Panel.hooked = true
    _G.ProfessionsFrame:HookScript("OnShow", Panel.Show)
    _G.ProfessionsFrame:HookScript("OnHide", Panel.Hide)
    if _G.ProfessionsFrame:IsShown() then Panel.Show() end
  end)
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("BAG_UPDATE_DELAYED")
  ev:SetScript("OnEvent", function() Panel.Refresh() end)
end

-- Slash toggle while the window is open.
local toggle = SlashCmdList.ATHANOR
SlashCmdList.ATHANOR = function(msg)
  toggle(msg)
  if (msg or "") == "" then
    if ns.db and ns.db.shown and _G.ProfessionsFrame and _G.ProfessionsFrame:IsShown() then Panel.Show() else Panel.Hide() end
  end
end
