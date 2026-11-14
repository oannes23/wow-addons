# Pitfalls log

Append-only. Each entry: **symptom → cause → rule**. Read this before starting work on any addon. Add an entry whenever a mistake costs more than one iteration.

## P-001 · WOW_PROJECT_ID for Forever is 18, not 1 (2026-11-06)
- Symptom: a fan guide (wowforeverguides.com) claims `WOW_PROJECT_ID == 1` on Forever.
- Cause: secondary sources conflate "shares Mainline UI" with "is Mainline".
- Rule: Forever is `WOW_PROJECT_CAMELOT = 18` ([SRC] `Blizzard_ProjectConstants/Camelot/ProjectConstants.lua`). Prefer feature detection over project-ID checks.

## P-002 · Classic Era knowledge doesn't transfer (2026-11-06)
- Symptom: the content looks like Vanilla, so it's tempting to write Classic Era (1.15.x) addon code.
- Cause: Forever's *content* is Vanilla-era. Its *client/API* is Mainline 12.1.5.
- Rule: always look up APIs in the `forever` branch. Classic Era addons need porting.

## P-003 · Midnight secrets apply (2026-11-06)
- Symptom: code that compares `UnitHealth()` or reads CLEU works out of combat and errors or silently does nothing in instances.
- Rule: see [secret-values.md](secret-values.md). Write the secret-safe path first and test it in a dungeon.

## P-004 · Deprecated global shims may not load on Forever (2026-11-06)
- Symptom: `GetSpecialization()` is nil on Forever even though it works on Midnight.
- Cause: `Blizzard_DeprecatedSpecialization.toc` has `## AllowLoadGameType: classic, standard`, which excludes `camelot`. Other `Blizzard_Deprecated*` addons load everywhere, but their per-file `_[Game].lua` variants may not have a Camelot file.
- Rule: call the `C_*` namespaced API directly. Never rely on a deprecated global. Check with `rg -n "^\s*Name\s*=" ... Blizzard_Deprecated*` plus the TOC gating.

## P-005 · Unconditional-secret APIs make useless trigger probes (2026-11-06)
- Symptom: we suggested `issecretvalue(UnitHealth("target"))` in and out of instances to learn when secrecy kicks in. It returns `true` everywhere, so the comparison tells us nothing.
- Cause: didn't check the flag type first. `UnitHealth` is `SecretReturns=true` (always secret), not `SecretWhen*` (conditional).
- Rule: before proposing an in-game probe, run `tools/wowapi.py fn <API>` and pick an API with a `SecretWhen*` flag, or query `C_Secrets.Should*BeSecret()` directly.

## P-006 · In-game probes must be self-describing (2026-11-06)
- Symptom: a bare `/dump UnitPosition("target")` returned coordinates, which we briefly read as "NPC positions are readable". A labeled follow-up showed `nil` coordinates for the mob. A `/run` with arithmetic printed nothing at all (a silent Lua error on nil).
- Cause: unlabeled output (unclear which unit or call produced it), and Lua errors hidden when `scriptErrors` is 0.
- Rule: probes print labels and the unit identity (`UnitIsUnit(u,"target")`, `UnitExists(u)`) and wrap risky math in `pcall`. Ask the user to run `/console scriptErrors 1` first. **One surprising result is never a finding**: tag it [TODO-INGAME] until a cross-check agrees.

## P-007 · Multi-line chat probes get merged when pasted (2026-11-07)
- Symptom: `'(' expected near '<eof>'`. The message ended `...end/run QTSD=function`. Two `/run` lines (a helper definition plus a caller) were pasted into chat together, the newline was lost, and the message was cut at 255 characters.
- Cause: we split a probe over 255 characters into dependent lines and assumed the user would send them one at a time.
- Rule: every chat probe is **one self-contained `/run` line of 255 characters or fewer**. Check with `awk '{print length($0)}'` and parse it with `uv run --no-project --with luaparser python -I` before handing it over. If later probes need a helper, define it inside the first probe's single line. Tell the user to send each code block as its own message.

## P-008 · "Not in GlobalAPI.lua" does not mean "does not exist" (2026-11-09)
- Symptom: `wowapi.py exists GetCVar` said `in_GlobalAPI: false`, and a review nearly rewrote working code to `C_CVar.GetCVar`. Blizzard's own AH sell frame calls `GetCVar`.
- Cause: Ketho's `GlobalAPI.lua` lists C-side globals only. `GetCVar` is a Lua function defined in `Blizzard_SharedXMLBase/CvarUtil.lua` [SRC]. Same class as P-004, opposite direction.
- Rule: read all three fields of `exists` (`in_GlobalAPI`, `documented_as`, `lua_defined_in`). For a Lua-defined global, also check that its file's addon loads on Forever (TOC `AllowLoadGameType`) and that Blizzard code under `Shared/` or `Camelot/` calls it.

## P-009 · `wowapi.py fn` misses undocumented C functions (2026-11-14)
- Symptom: `wowapi.py search GetAllRecipeIDs` found nothing, so `C_TradeSkillUI.GetAllRecipeIDs` looked absent on Forever, and the recipe-enumeration design nearly assumed a classic `GetTradeSkillInfo` list.
- Cause: the generated docs (`Blizzard_APIDocumentationGenerated`) omit many C functions that Blizzard's own UI calls: `C_TradeSkillUI.GetAllRecipeIDs/GetFilteredRecipeIDs/GetCategories/GetCategoryInfo/GetSubCategories/GetRecipeCooldown`, `GetLootSlotInfo/GetLootSlotLink/GetLootSlotType/GetNumLootItems/GetLootSourceInfo`, `GetProfessions/GetProfessionInfo`. They exist (`exists` shows `in_GlobalAPI` true) but their **secrecy flags, argument and return types are unknown** [SRC, 1.60.1.70862]. Forever uses the modern Professions UI (`Blizzard_Professions`, `Camelot/` overrides only re-implement tabs and art), so the Mainline `C_TradeSkillUI` is the enumeration API.
- Rule: when `fn`/`search` finds nothing, run `exists <name>` and grep the Blizzard UI source for call sites (`grep -rnE "Name" reference/upstream/wow-ui-source/Interface/AddOns`) to recover signatures from usage. Treat such APIs as flag-unknown: pcall, type-check, `issecretvalue`, and list them as [TODO-INGAME] in the spec.

## P-010 · lupa table fields named like Python dict methods (2026-11-14)
- Symptom: a harness assertion on a mocked Lua record failed, then raised `'cython_function_or_method' object has no attribute 'values'`. `rec.items` and `rec.keys` returned lupa's `_LuaTable.items`/`.keys` methods, not the Lua fields.
- Cause: lupa exposes `keys()`, `values()`, `items()` as Python attributes on every Lua table; attribute access prefers them over same-named Lua fields.
- Rule: in `tools/luatest` mocks never name Lua fields `keys`, `values` or `items` if Python reads them with dot syntax; read them as `t["keys"]` or rename (`sentKeys`, `nitems`).
