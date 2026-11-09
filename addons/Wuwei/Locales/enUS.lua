local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, k) return k end })
-- Keys are the English text; add overrides here when a string needs different wording.
-- ns.L["Key"] = "English text"

-- Key Bindings UI strings. Globals by necessity: the client reads BINDING_HEADER_* / BINDING_NAME_* by name (SPEC D-023).
BINDING_HEADER_WUWEI = "Wuwei"
BINDING_NAME_WUWEI_ACCEPT = "Accept (next step of the current play)"
BINDING_NAME_WUWEI_SKIP = "Skip (next play, cancels a pending quote)"
