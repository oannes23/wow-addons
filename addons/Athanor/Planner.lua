-- Planner (SPEC D-001, D-002): the cheapest expected-cost route from the current skill to a target, over the
-- pipeline's ladder (ns.LADDER, Data/Ladder.lua). Pure: no frames, no events; the caller passes a context:
--   ctx = { houses = {114, 117}, learned = {[spell] = true}, trainer = {[spell] = {skill = N}}, vendor = {[item] = copper},
--           deSkill = N or nil (Enchanting skill: disenchanting and fodder allowed), includeTrainer = bool }
local _, ns = ...

local floor, max, min, ceil, ipairs, pairs, type, format = math.floor, math.max, math.min, math.ceil, ipairs, pairs, type, string.format

local Planner = {}
ns.Planner = Planner

Planner.DISENCHANT = 13262
Planner.PASSES = 2       -- plan, reprice reagents at the planned quantities, plan again
Planner.FIRST_GUESS = 10 -- crafts per recipe assumed on the first pass (prices at depth for ~10 crafts)

function Planner.Data() return ns.LADDER end

-- Chance that one craft at skill s gives a point (reference/professions.md): 1 below yellow (orange), then linear
-- down to 0 at grey. The yellow/green rate is a prior [INFER]; the craft log (Scan.lua) collects data to fit it.
function Planner.Chance(r, s)
  if s >= r.gr then return 0 end
  if s < r.y then return 1 end
  return (r.gr - s) / (r.gr - r.y)
end

-- Colour of recipe r at skill s: "orange" | "yellow" | "green" | "grey".
function Planner.Colour(r, s)
  if s >= r.gr then return "grey" end
  if s >= r.g then return "green" end
  if s >= r.y then return "yellow" end
  return "orange"
end

-- Learn level estimate for a trainer recipe nobody has scanned yet: grey minus twice the yellow-to-grey span,
-- i.e. the orange range is assumed as long as yellow-to-grey (Classic trainers mostly fit; flagged "~" in the UI).
function Planner.EstLearn(r)
  return max(1, r.y - (r.gr - r.y))
end

-- Cost of q units from a flat ladder { units1, price1, units2, price2, ... } (cumulative units, each segment at its
-- upper price). Past the book's depth the rest is priced at the dearest point and `short` is true.
function Planner.LadderCost(lad, q)
  local cost, prev = 0, 0
  for k = 1, #lad - 1, 2 do
    local u, p = lad[k], lad[k + 1]
    local take = min(q, u) - prev
    if take > 0 then cost = cost + take * p end
    prev = u
    if q <= u then return cost, false end
  end
  return cost + (q - prev) * (lad[#lad] or 0), true
end

-- A stride-4 ladder { cum, price, item, skill, ... } (fodder, disenchant options) filtered to rows with skill <= s,
-- as a stride-2 ladder plus the first (cheapest) row's item. Row units are the differences of `cum`.
function Planner.Filter4(flat, s)
  local out, cum, prev, first = {}, 0, 0, nil
  for k = 1, #flat - 3, 4 do
    local units = flat[k] - prev
    prev = flat[k]
    if flat[k + 3] <= s and units > 0 then
      cum = cum + units
      out[#out + 1], out[#out + 2] = cum, flat[k + 1]
      first = first or flat[k + 2]
    end
  end
  return out, first
end

local function Houses(ctx) return ctx.houses or (Planner.Data() and Planner.Data().houses) or {} end

-- Segments { u, p, src, house, via } of a cumulative ladder (stride 2: AH; stride 4: fodder rows with a skill gate).
local function Segments(segs, lad, stride, src, house, skill)
  local prev = 0
  for k = 1, #lad - (stride - 1), stride do
    local units = lad[k] - prev
    prev = lad[k]
    if units > 0 and (stride == 2 or lad[k + 3] <= skill) then
      segs[#segs + 1] = { u = units, p = lad[k + 1], src = src, house = house, via = stride == 4 and lad[k + 2] or nil }
    end
  end
end

-- Price per unit of `id` when buying q units. A vendor price (merchant scan, then the pipeline's list) beats
-- everything: never buy a vendor item on the AH. Otherwise one combined order book is walked cheapest first: every
-- house's AH listings plus, for an enchanter, disenchant fodder (D-002). A thin cheap source supplies what it holds
-- and the rest comes from the next one. Returns unit, src ("vendor" | "ah" | "de", the source supplying most
-- units), house, fodder item, short (the book holds fewer than q: the rest priced at its dearest point).
function Planner.UnitPrice(ctx, id, q)
  local L = Planner.Data()
  local it = L and L.items[id]
  local v = (ctx.vendor and ctx.vendor[id]) or (it and it.v)
  if v then return v, "vendor" end
  if not it then return nil end
  q = max(1, q or 1)
  local segs = {}
  for _, h in ipairs(Houses(ctx)) do
    if type(it[h]) == "table" then Segments(segs, it[h], 2, "ah", h) end
    local fl = ctx.deSkill and it["f" .. h]
    if type(fl) == "table" then Segments(segs, fl, 4, "de", h, ctx.deSkill) end
  end
  if #segs == 0 then return nil end
  table.sort(segs, function(a, b)
    if a.p ~= b.p then return a.p < b.p end
    if a.house ~= b.house then return a.house < b.house end
    return a.src < b.src
  end)
  local left, cost, dearest, top, topTake = q, 0, 0, nil, 0
  for _, s in ipairs(segs) do
    if left <= 0 then break end
    local take = min(left, s.u)
    cost, left, dearest = cost + take * s.p, left - take, max(dearest, s.p)
    if take > topTake then top, topTake = s, take end
  end
  local short = left > 0
  if short then
    for _, s in ipairs(segs) do dearest = max(dearest, s.p) end
    cost = cost + left * dearest
  end
  return cost / q, top.src, top.house, top.via, short
end

-- Value per unit of `qty` units of an output (D-005). Each house's AH takes at most its demand cap (c<h>: about
-- three days of sales) at its net-of-cut price (a<h>), best house first; every other unit goes at the floor: the
-- disenchant value (d<h>, only for an enchanter, and never for no-disenchant items: the pipeline leaves d out) or
-- the vendor price.
function Planner.Exit(ctx, id, qty)
  local L = Planner.Data()
  local it = id and L and L.items[id]
  if not it then return 0 end
  qty = max(1, qty or 1)
  local floorV = it.vs or 0
  local ah = {}
  for _, h in ipairs(Houses(ctx)) do
    if ctx.deSkill then floorV = max(floorV, it["d" .. h] or 0) end
    local a, c = it["a" .. h], it["c" .. h]
    if a and c and c > 0 then ah[#ah + 1] = { a = a, c = c } end
  end
  table.sort(ah, function(x, y) return x.a > y.a end)
  local left, value = qty, 0
  for _, s in ipairs(ah) do
    if left <= 0 or s.a <= floorV then break end
    local take = min(left, s.c)
    value, left = value + take * s.a, left - take
  end
  return (value + left * floorV) / qty
end

-- Net cost of one craft of recipe r when making `crafts` of them: reagents at their cheapest source for the whole
-- quantity, minus the output's exit. Disenchanting costs a fodder item minus its materials (L.de). nil = can't price.
function Planner.CraftCost(ctx, spell, r, crafts)
  local L = Planner.Data()
  crafts = max(1, crafts or 1)
  if spell == Planner.DISENCHANT then
    if not ctx.deSkill then return nil end
    local best
    for _, h in ipairs(Houses(ctx)) do
      local de = L.de and L.de[h]
      if type(de) == "table" then
        local lad = Planner.Filter4(de, ctx.deSkill)
        if #lad >= 2 then
          local c = Planner.LadderCost(lad, crafts)
          if not best or c / crafts < best then best = c / crafts end
        end
      end
    end
    return best
  end
  local cost = 0
  local rg = r.r or {}
  for k = 1, #rg - 1, 2 do
    local unit = Planner.UnitPrice(ctx, rg[k], rg[k + 1] * crafts)
    if not unit then return nil end
    cost = cost + rg[k + 1] * unit
  end
  if r.o then cost = cost - (r.q or 1) * Planner.Exit(ctx, r.o, (r.q or 1) * crafts) end
  return cost
end

-- Can recipe r be crafted at skill s? Returns ok, how ("known" | "learn" | "learn~": a trainer visit; ~ = estimated level).
function Planner.Eligible(ctx, spell, r, s)
  if spell == Planner.DISENCHANT then return ctx.deSkill ~= nil, "known" end
  if ctx.learned and ctx.learned[spell] then return true, "known" end
  if r.s == "auto" then return true, "known" end
  if r.s == "trainer" and ctx.includeTrainer then
    local t = ctx.trainer and ctx.trainer[spell]
    if t and type(t.skill) == "number" then return t.skill <= s, "learn" end
    local est = Planner.EstLearn(r)
    -- A trainer of this profession was scanned up to skill `seen` and didn't list it: not a trainer recipe (DB2 can't
    -- tell trainer from quest/drop recipes without a teaching item, D-003). Above `seen`, a higher trainer may teach it.
    local seen = ctx.trainerSeen and ctx.trainerSeen[r.p]
    if seen and est <= seen then return false end
    return est <= s, "learn~"
  end
  return false
end

-- Score of one point: profit per craft counts once (a profitable recipe is good, but more crafts don't make it
-- better per point), cost is divided by the chance. Lower is better.
local function Score(cost, p)
  if cost < 0 then return cost end
  return cost / p
end

-- The route for profession `prof` from skill `from` to `to` (exclusive). Returns steps:
--   { spell, r, from, to, crafts, cost, colour (at the step's start), how } and totals { crafts, cost }.
function Planner.Plan(ctx, prof, from, to)
  local L = Planner.Data()
  local steps, totals = {}, { crafts = 0, cost = 0 }
  if not L or not from or not to or from >= to then return steps, totals end
  local cands = {}
  for spell, r in pairs(L.recipes) do
    if r.p == prof and r.gr > from then cands[#cands + 1] = spell end
  end
  table.sort(cands) -- deterministic ties
  local crafts = {}
  local choice
  for _ = 1, Planner.PASSES do
    local cost = {}
    for _, spell in ipairs(cands) do
      cost[spell] = Planner.CraftCost(ctx, spell, L.recipes[spell], crafts[spell] or Planner.FIRST_GUESS)
    end
    choice = {}
    local n = {}
    for s = from, to - 1 do
      local best, bestScore, bestP, bestHow
      for _, spell in ipairs(cands) do
        local r, c = L.recipes[spell], cost[spell]
        local p = c and Planner.Chance(r, s) or 0
        if p > 0 then
          local ok, how = Planner.Eligible(ctx, spell, r, s)
          if ok then
            local sc = Score(c, p)
            if not best or sc < bestScore - 1e-9 or (math.abs(sc - bestScore) <= 1e-9 and p > bestP) then
              best, bestScore, bestP, bestHow = spell, sc, p, how
            end
          end
        end
      end
      if not best then break end -- nothing craftable: the route stops here (the UI says why)
      choice[s] = { spell = best, p = bestP, cost = cost[best], how = bestHow }
      n[best] = (n[best] or 0) + 1 / bestP
    end
    crafts = n
  end
  for s = from, to - 1 do
    local c = choice[s]
    if not c then break end
    local last = steps[#steps]
    if last and last.spell == c.spell then
      last.to = s + 1
    else
      last = { spell = c.spell, r = L.recipes[c.spell], from = s, to = s + 1, crafts = 0, cost = 0, how = c.how,
               colour = Planner.Colour(L.recipes[c.spell], s) }
      steps[#steps + 1] = last
    end
    last.crafts = last.crafts + 1 / c.p
    last.cost = last.cost + c.cost / c.p
  end
  for _, st in ipairs(steps) do
    totals.crafts = totals.crafts + st.crafts
    totals.cost = totals.cost + st.cost
  end
  totals.reached = (#steps > 0) and steps[#steps].to or from
  return steps, totals
end

-- What to buy for a step: per reagent, units needed (ceil of crafts x qty) minus what `have(id)` still covers after
-- earlier steps took theirs (`used` carries that across steps). Returns { {id, need, buy, unit, src, house, via} }.
function Planner.Shopping(ctx, st, have, used)
  local out = {}
  if st.spell == Planner.DISENCHANT then return out end
  local rg = st.r.r or {}
  local n = ceil(st.crafts - 1e-9)
  for k = 1, #rg - 1, 2 do
    local id, q = rg[k], rg[k + 1]
    local need = n * q
    local own = max(0, (have and have(id) or 0) - (used[id] or 0))
    local take = min(own, need)
    used[id] = (used[id] or 0) + take
    local buy = need - take
    local unit, src, house, via = Planner.UnitPrice(ctx, id, max(1, buy))
    out[#out + 1] = { id = id, need = need, buy = buy, unit = unit, src = src, house = house, via = via }
  end
  return out
end

-- Money text: 1g 23s, 45s 6c, 7c; negative with a leading minus.
function Planner.Money(c)
  c = floor((c or 0) + 0.5)
  local neg = c < 0
  if neg then c = -c end
  local g, s, cp = floor(c / 10000), floor(c / 100) % 100, c % 100
  local t
  if g > 0 then t = s > 0 and format("%dg %ds", g, s) or format("%dg", g)
  elseif s > 0 then t = cp > 0 and format("%ds %dc", s, cp) or format("%ds", s)
  else t = format("%dc", cp) end
  return (neg and "-" or "") .. t
end
