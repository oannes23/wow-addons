local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, k) return k end })
-- Keys are the English text; add overrides here when a string needs different wording.
-- ns.L["Key"] = "English text"
