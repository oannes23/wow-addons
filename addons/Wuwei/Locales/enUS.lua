local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, k) return k end })
-- Keys are the English text; add overrides here when a string needs different wording.
-- ns.L["Key"] = "English text"
-- Steals (Steals.lua, SPEC D-033 to D-040) use the same key-is-English convention: "Scan steals", "STEAL %s listed at
-- %s · fair %s (%d%%) · alert ≤ %s · Search in the Wuwei panel", "Steals: %d watched · Scan steals to check", ...
-- No Blizzard GlobalString fits these (SEARCH and AUCTION_HOUSE_SEARCH_BUTTON mean a search, not a watchlist scan).

-- Key Bindings UI strings. Globals by necessity: the client reads BINDING_HEADER_* / BINDING_NAME_* by name (SPEC D-023).
BINDING_HEADER_WUWEI = "Wuwei"
BINDING_NAME_WUWEI_ACCEPT = "Accept (next step of the current play)"
BINDING_NAME_WUWEI_SKIP = "Skip (next play, cancels a pending quote)"
