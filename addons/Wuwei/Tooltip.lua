-- One quiet tooltip line for items in the plan: "Wuwei: SHUTTLE → BW ≥ 65s · ref 3s 60c · 42m".
-- Shuttle toggle off (default): "Wuwei: SELL ≥ 2s · ref 2s 10c · BW ≥ 65s (2.4×) shuttle off · 42m", or for an item
-- whose only play is the shuttle, "Wuwei: SHUTTLE (off) → BW ≥ 65s (2.4×) · ref 3s 60c · 42m" (information only).
-- Items only in the steals watchlist: "Wuwei: STEAL ≤ 22g 50s · fair 45g (n 6) · 42m" (the plan line wins, D-039).
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

-- Post-call receives (tooltip, tooltipData); tooltipData.id is the item ID (cf. Blizzard TooltipUtil.lua).
local function OnItemTooltip(tooltip, data)
  if not (ns.db and ns.db.enabled and ns.db.tooltip) then return end
  local id = data and data.id
  if not id or (issecretvalue and issecretvalue(id)) then return end
  local line = Tooltip.Line(id)
  if line and tooltip and tooltip.AddLine then tooltip:AddLine(line) end
end

function Tooltip.Init()
  if Tooltip.registered then return end
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
    Tooltip.registered = true
  end
end
