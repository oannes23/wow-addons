local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, k) return k end })
local L = ns.L

L.MODE_DISTANCE_SHORT = "Dist"
L.MODE_LEVEL_SHORT = "Lvl"
L.MODE_DISTANCE = "Distance"
L.MODE_LEVEL = "Level"
L.TOGGLE_TIP = "Sort mode: %s"
L.TOGGLE_TIP_HINT = "Click to switch between Distance (closest first) and Level (lowest first)."
L.REFRESH_TIP = "Re-sort quests now"
L.REFRESH_TIP_HINT = "Sorting pauses during combat."
L.UNSUPPORTED = "the client re-orders the quest watch list itself; auto-sort paused. Press Refresh to retry."
L.LEARNED_PREPEND = "learned: new watches are inserted at the top."
L.MODE_LOCKED_COMBAT = "Sort mode is locked during combat."
L.PENDING_COMBAT = "in combat; will sort when combat ends."
L.STATUS = "mode=%s interval=%ds insertMode=%s unsupported=%s pending=%s"
L.USAGE = "/qts toggle | distance | level | refresh | interval <sec> | debug | status"
