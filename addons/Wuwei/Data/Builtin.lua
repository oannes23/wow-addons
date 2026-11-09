-- Sample plan following the SPEC data contract. Used only when the generated Data/Plan.lua is absent.
-- Prices are copper. Item IDs are vanilla staples; the numbers are illustrative, not market data.
local _, ns = ...
ns.BUILTIN_PLAN = {
  generated = "2026-11-09T07:00:00Z", source = "builtin sample", ruleset = "Normal",
  houses = { [114] = "Horde", [117] = "Blackwater" },
  index = {
    [114] = { level = 76.5, d24h = -0.23, regime = "deflation" },
    [117] = { level = 81.0, d24h = -0.10, regime = "deflation" },
  },
  items = {
    [4304] = { ref = { [114] = 600, [117] = 1450 }, signal = "SHUTTLE", buyMax = 700, sellMin = 1300, qtyCap = 60, gain = 38, trend24h = -0.08 },
    [4338] = { ref = { [114] = 360, [117] = 410 }, signal = "SELL", sellMin = 420, qtyCap = 120, gain = 9, trend24h = -0.02 },
    [3357] = { ref = { [114] = 1200, [117] = 6500 }, signal = "SHUTTLE", buyMax = 4000, sellMin = 6500, qtyCap = 20, gain = 52 },
    [2772] = { ref = { [114] = 900, [117] = 880 }, signal = "HOLD", gain = 0, note = "wait for the index to bottom" },
    [8153] = { ref = { [114] = 2500, [117] = 5200 }, signal = "SELL", sellMin = 5000, qtyCap = 10, gain = 27 },
    [2589] = { ref = { [114] = 40, [117] = 55 }, signal = "BUY", buyMax = 35, qtyCap = 400, gain = 4 },
  },
}
