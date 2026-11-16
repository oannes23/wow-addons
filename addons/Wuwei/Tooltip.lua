-- One quiet tooltip line for items in the plan: "Wuwei: SHUTTLE → BW ≥ 65s · ref 3s 60c · 42m".
-- Shuttle toggle off (default): "Wuwei: SELL ≥ 2s · ref 2s 10c · BW ≥ 65s (2.4×) shuttle off · 42m", or for an item
-- whose only play is the shuttle, "Wuwei: SHUTTLE (off) → BW ≥ 65s (2.4×) · ref 3s 60c · 42m" (information only).
-- Items only in the steals watchlist: "Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · 42m" (the plan line wins, D-039).
-- Above it, for every item in Data/Prices.lua: the two-house price block (Prices.lua, D-042 to D-046).
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

-- Pure: the line for an item ID in the current house, or nil when the item is not in the plan.
function Tooltip.Line(id)
  local Plan = ns.Plan
  local it = id and Plan.Item(id)
  if not it then return id and ns.Steals and ns.Steals.TooltipLine(id) or nil end
  local house = ns.House.Detect()
  local rule = Plan.Rule(it, house)
  local parts = { Plan.Colorize(it.signal, Plan.Label(it.signal) .. (rule ~= "" and (" " .. rule) or "")) }
  local ref = Plan.RefPrice(it, house)
  if ref and it.signal ~= "HOLD" then parts[#parts + 1] = "ref " .. Plan.Money(ref) end
  if it.shuttle and it.signal ~= "INFO" then
    local info = Plan.ShuttleInfo(it)
    if info then parts[#parts + 1] = Plan.Colorize("INFO", info .. " shuttle off") end
  end
  parts[#parts + 1] = Plan.AgeText()
  return "Wuwei: " .. table.concat(parts, " · ")
end

-- The two-house price block (SPEC D-042 to D-046) as { left, right } rows, or nil. `data` is the tooltip data (stack
-- count and the sell price line come from it); nil data = a bare item ID, one unit, no vendor flags.
function Tooltip.PriceRows(id, data)
  local Prices = ns.Prices
  local mode = Prices.Mode()
  if mode == "off" or not Prices.Get() then return nil end
  local count, vendorUnit = Prices.Context(data)
  local house, _, confident = ns.House.Detect()
  return Prices.Lines(id, { mode = mode, house = house, confident = confident, count = count, vendorUnit = vendorUnit,
    now = GetServerTime() })
end

-- Post-call receives (tooltip, tooltipData); tooltipData.id is the item ID (cf. Blizzard TooltipUtil.lua). It runs after
-- every data line, so the price block lands below Blizzard's sell price (D-042); the plan/steals line stays last.
local function OnItemTooltip(tooltip, data)
  if not (ns.db and ns.db.enabled and ns.db.tooltip) then return end
  local id = data and data.id
  if not id or (issecretvalue and issecretvalue(id)) then return end
  if not (tooltip and tooltip.AddLine) then return end
  if not tooltip.isShopping and tooltip.AddDoubleLine then -- comparison tooltips skip it, as Blizzard skips sell price
    local rows = Tooltip.PriceRows(id, data)
    if rows then
      for _, r in ipairs(rows) do
        if r[2] then tooltip:AddDoubleLine(r[1], r[2], 1, 1, 1, 1, 1, 1) else tooltip:AddLine(r[1], 1, 1, 1) end
      end
    end
  end
  local line = Tooltip.Line(id)
  if line then tooltip:AddLine(line) end
end

function Tooltip.Init()
  if Tooltip.registered then return end
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    Tooltip.registered = true
  end
end
