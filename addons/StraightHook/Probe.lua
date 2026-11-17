-- StraightHook · bite probe (SPEC scope 4): is there ANY event that fires on the bite? Off by default.
-- During the Fishing channel every event is recorded. For casts that ended in a catch or an escape, the channel stop is
-- the player's click; events seen in [stop - 2.5 s, stop - 0.15 s] (the bite and the reaction time) are counted against
-- a baseline window right after the cast. An event that is common before the click and rare in the baseline is a
-- candidate bite signal.
local _, ns = ...
local Probe = {}
ns.Probe = Probe

local GetTime, pairs, format = GetTime, pairs, string.format
local PRE_FROM, PRE_TO = 2.5, 0.15
local BASE_FROM, BASE_TO = 0.3, 1.5

local KEEP_TIMELINES = 10 -- casts kept verbatim in SavedVariables for inspection
local TIMELINE_FROM = 12   -- s before the click

local frame, rec, t0, stopAt, clickAt

local function On() return ns.db and ns.db.probe and ns.db.probe.on end

function Probe.Start()
  if not On() then return end
  if not frame then
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event)
      if not rec then return end
      local t = GetTime() - t0
      rec[#rec + 1] = { t, event }
      -- The player's click: the interact fires just before the channel stops (seen in game 2026-11-17).
      if event == "PLAYER_SOFT_TARGET_INTERACTION" and not clickAt then clickAt = t end
    end)
  end
  rec, t0, stopAt, clickAt = {}, GetTime(), nil, nil
  frame:RegisterAllEvents()
end

-- The channel stopped (called at the stop itself; the verdict comes later with Stop).
function Probe.MarkStop() if rec and not stopAt then stopAt = GetTime() - t0 end end

-- outcome: "caught" | "escaped" | other (ignored). Called once the cast's outcome is known.
function Probe.Stop(outcome)
  if frame then frame:UnregisterAllEvents() end
  if not rec then return end
  local events = rec
  local stop = math.min(clickAt or math.huge, stopAt or (GetTime() - t0))
  rec = nil
  if outcome ~= "caught" and outcome ~= "escaped" then return end
  local p = ns.db.probe
  -- Verbatim timeline relative to the click, consecutive duplicates collapsed: what really happens before a bite.
  local line, last = {}, nil
  for _, e in ipairs(events) do
    local dt = e[1] - stop
    if dt >= -TIMELINE_FROM and dt <= 0.5 and e[2] ~= last then line[#line + 1] = format("%+.2f %s", dt, e[2]) end
    last = e[2]
  end
  p.timelines = p.timelines or {}
  table.insert(p.timelines, 1, { outcome = outcome, castAt = format("%+.2f", -stop), events = line })
  while #p.timelines > KEEP_TIMELINES do table.remove(p.timelines) end
  local pre, base = {}, {}
  for _, e in ipairs(events) do
    local t, name = e[1], e[2]
    if t >= stop - PRE_FROM and t <= stop - PRE_TO then pre[name] = true end
    if t >= BASE_FROM and t <= BASE_TO then base[name] = true end
  end
  p.casts = (p.casts or 0) + 1
  for name in pairs(pre) do p.pre[name] = (p.pre[name] or 0) + 1 end
  for name in pairs(base) do p.base[name] = (p.base[name] or 0) + 1 end
end

-- Ranked candidates: { name, preShare, baseShare }.
function Probe.Ranked()
  local p = ns.db.probe
  local n, out = p.casts or 0, {}
  if n == 0 then return out, 0 end
  for name, c in pairs(p.pre) do
    local b = (p.base[name] or 0) / n
    out[#out + 1] = { name = name, pre = c / n, base = b }
  end
  table.sort(out, function(a, b)
    local da, db = a.pre - a.base, b.pre - b.base
    if da ~= db then return da > db end
    return a.name < b.name
  end)
  return out, n
end

function Probe.Report(say)
  local rows, n = Probe.Ranked()
  if n == 0 then say(ns.L["probe: no finished casts yet (catch or escape a fish with the probe on)."]) return end
  say(format(ns.L["probe: %d casts. Events before your click vs. right after the cast (a bite signal is near 100%% / 0%%):"], n))
  for i = 1, math.min(10, #rows) do
    local r = rows[i]
    say(format("  %-40s %3d%% / %3d%%", r.name, math.floor(r.pre * 100 + 0.5), math.floor(r.base * 100 + 0.5)))
  end
end
