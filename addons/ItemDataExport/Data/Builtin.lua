-- Smoke-test input used when Data/Pairs.lua (generated, gitignored) is absent. Items seen on house 114 (2026-11-08).
local _, ns = ...
ns.BUILTIN = {
  generated = "builtin",
  source = "hand-picked smoke set",
  tuples = {
    { 869 }, { 870 }, { 873 }, { 867 }, { 1204 }, -- in-game listings matched to house 114 (Method B)
    { 2589 },                                      -- Linen Cloth (commodity)
    { 3195 }, { 3195, 12918 }, { 3195, 12719 },     -- same item: base vs two suffix bonus ids
    { 3195, 12918, 28, 5254 },                     -- modifier type 28 probe (meaning unknown)
  },
}
