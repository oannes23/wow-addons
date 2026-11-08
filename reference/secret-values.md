# Secret values and addon restrictions (Midnight rules, active in Forever)

This is the single most important design constraint for Forever addons. It changes what kinds of addon are possible at all.
Confidence key as in [forever-platform.md](forever-platform.md).

## The model

| Concept | Meaning | Confidence |
|---|---|---|
| **Secret value** | An opaque value some APIs return to **tainted** (addon) code instead of the real number/string/bool. Addon code can hold it, store it, and pass it to permitted sinks. It **cannot inspect** it: no arithmetic, comparison, `tostring`, or use as a table key. | [SRC] helper docs + [NEWS]; exact op set [TODO-INGAME] |
| **Taint** | Execution originating from addon code. Blizzard code runs untainted and can access secrets. | [SRC] (`canaccesssecrets`: "immediate calling function has appropriate permissions") |
| **Sink** | An API whose doc says `SecretArguments = "AllowedWhenTainted"`. It accepts secrets from addon code. These are mostly **display** primitives. | [SRC] |
| **Restriction state** | Many APIs are secret only *conditionally* (`SecretWhenUnitAuraRestricted`, `SecretWhenInCombat`, `SecretInChatMessagingLockdown`, …). | [SRC] flags; trigger conditions [TODO-INGAME] |

**Design axiom: under secrets, addons *render*, they don't *decide*.** You can show a secret health value on a bar. You can't write `if health < 30% then warn()`. Logic that branches on combat state belongs to Blizzard's built-in systems (Cooldown Manager, Damage Meter, Encounter Timeline/Warnings).

## Helper API (FrameScript, global functions)

| Function | Purpose |
|---|---|
| `issecretvalue(v)` | Is `v` a secret? Use it to guard any code path that might inspect a value. |
| `canaccessvalue(v)` / `canaccessallvalues(...)` | Can *this* caller operate on `v`? |
| `canaccesssecrets()` | Can the current function touch secrets at all (i.e. are we untainted)? |
| `issecrettable(t)` / `canaccesstable(t)` | Secret tables: whether this caller can index the table |
| `hasanysecretvalues(...)` | Is any of the values secret? |
| `scrubsecretvalues(...)` | Returns the values with secrets replaced (by nil) [INFER from name, verify] |
| `secretwrap` / `secretunwrap` / `dropsecretaccess` | Advanced. Mostly for Blizzard secure code. Rarely needed. |
| `C_Secrets.*` | Predicates: `ShouldAurasBeSecret()`, `ShouldCooldownsBeSecret()`, `ShouldSpellCooldownBeSecret(id)`, `ShouldUnitAuraInstanceBeSecret(unit, id)`, `GetSpellAuraSecrecy(id)`, `HasSecretRestrictions()`, … These let you check **before** calling. |

Look any of these up with `uv run --no-project python tools/wowapi.py ns SecretUtil` or `... ns FrameScript`.

## Flag taxonomy (from `Blizzard_APIDocumentationGenerated`, build 70790)

Run `uv run --no-project python tools/wowapi.py flags` for live counts, and `... flagged <Flag>` to list the APIs carrying a flag.

| Flag | Count | Reading |
|---|---|---|
| `SecretArguments = "AllowedWhenUntainted"` | ~3680 | **Default.** Passing a secret *from addon code* is an error. |
| `SecretArguments = "AllowedWhenTainted"` | ~176 | **Sink.** Addon code may pass secrets. See below. |
| `SecretArguments = "NotAllowed"` | ~92 | Never pass secrets, even from Blizzard code. |
| `SecretReturns = true` | 19 | Always returns secret to tainted callers (e.g. `UnitHealth`). |
| `SecretWhen<X>Restricted` | ~200 total | Returns are secret **while restriction X is active**: UnitStats, UnitIdentity, UnitAura, UnitSpellCast, Cooldowns, UnitPower, LossOfControl, Threat, … |
| `SecretWhenInCombat`, `SecretInActivePvPMatch`, `SecretWhenEncounterEvent` | few | Situational secrecy |
| `SecretInChatMessagingLockdown` | 100 | Chat/comm APIs go dark during lockdown (instanced combat/encounters [NEWS]) |
| `SecretReturnsForAspect` / `SecretArgumentsAddAspect` | ~150 | **Aspect taint on widgets.** Passing a secret into e.g. `Cooldown:SetCooldown` marks that object's aspect (`Enum.SecretAspect.Cooldown`) secret, so later getters on the object return secrets. [INFER from names, verify] |
| `SecretWhenAnchoringSecret` | 23 | Region geometry becomes secret once anchored to a secret-tainted region [INFER] |
| `ConstSecretAccessor` | 46 | Getter is safe to call on secret objects [INFER] |
| `ReturnsNeverSecret` | 16 | Guaranteed non-secret (`HasSecretValues`, `Copy`, heal-prediction modes) |
| `HasRestrictions` | 288 | Has some caller restriction. `COMBAT_LOG_EVENT_UNFILTERED` carries it. **Do not design around CLEU.** |
| `RequiresUnitAuraAccess`, `RequiresNonSecretAura` | — | Aura access gates |

## The sink set (what addons CAN do with secrets)

From `SecretArguments = "AllowedWhenTainted"`, grouped:

- **StatusBar**: `SetMinMaxValues`, `SetValue`, `SetStatusBarColor`, `SetStatusBarDesaturated(ion)`. → **Health/power bars work.**
- **FontString**: `SetText`, `SetFormattedText`, `SetTextColor`, `SetTextToFit`. → **Numbers can be displayed.**
- **Texture**: `SetTexture`, `SetAtlas`, `SetColorTexture`, `SetTexCoord`, `SetRotation`, `SetDesaturated`, `SetRadialProgressBarPercent`. → **Icons and radial fills work.**
- **Region/Frame**: `SetAlpha`, **`SetAlphaFromBoolean`**, `SetVertexColor`, **`SetVertexColorFromBoolean`**. → **Conditional visibility *without branching*.** Note: `SetShown(secretBool)` is **not** allowed from tainted code. Blizzard's own comment says use `SetAlphaFromBoolean` (`Blizzard_UnitFrame/Shared/UnitFrameUtil.lua:487`).
- **Cooldown**: `SetSwipeColor`, `SetEdgeColor`, `SetDrawSwipe/Edge/Bling`. Plus `SetCooldownFromDurationObject(durationObj)` takes **Duration objects**, Blizzard's sanctioned way to drive swipes from secret timings.
- **Curves** (`C_CurveUtil`): `CreateCurve`, `CreateColorCurve`, `EvaluateColorFromBoolean`, `EvaluateColorValueFromBoolean`. Map secret inputs to colors/alphas **inside the engine**. This is the replacement for `if x then color = red`.
- **Formatting**: `AbbreviateNumbers`, `AbbreviateLargeNumbers`, `BreakUpLargeNumbers`, `C_StringUtil.*`, `C_ColorUtil.WrapTextInColor*`, `C_Intl.*` / locale formatting.
- **Lookups keyed by secret**: `C_Spell.GetSpellInfo/GetSpellCooldown/GetSpellCharges/...`, `C_UnitAuras.GetPlayerAuraBySpellID/GetUnitAuraBySpellID/...`, `UnitName`, `UnitClassFromGUID`, `UnitTokenFromGUID`, `GetClassColor`. You can feed a secret spellID/GUID back into the API.
- `C_VoiceChat.SpeakText`: TTS of a secret string.

## Patterns

```lua
-- 1. Display-only pipeline: secret in, widget out, no Lua logic in between.
local function UpdateHealth(bar, unit)
  bar:SetMinMaxValues(0, UnitHealthMax(unit))   -- both may be secret; sink accepts
  bar:SetValue(UnitHealth(unit))
  bar.text:SetText(AbbreviateNumbers(UnitHealth(unit)))
end

-- 2. Conditional visuals without `if`: boolean -> alpha/color in-engine
icon:SetAlphaFromBoolean(isDebuffDispellable)                -- not icon:SetShown(...)
local c = C_CurveUtil.EvaluateColorFromBoolean(isEnemy, RED, GREEN)

-- 3. Guard any code that *must* inspect
local v = SomeApi()
if issecretvalue(v) then
  widget:SetText(v)          -- display path only
else
  -- full logic path (out of combat / unrestricted)
end

-- 4. Pre-check with C_Secrets instead of try/catch
if not C_Secrets.ShouldCooldownsBeSecret() then ... end
```

## Addon archetype viability under Forever

| Archetype | Viability | Why |
|---|---|---|
| UI reskins, unit/raid frames, nameplates (display) | ✅ High | Sinks cover bars, text, textures, alpha |
| Bags, bank, AH, crafting, quest, map, tooltip, collections, chat cosmetics | ✅ High | Mostly non-combat APIs, few secrets |
| Leveling/questing helpers (Forever is a 1–60 game) | ✅ High | Quest/map APIs; check Camelot quest overrides |
| Cooldown/aura *display* | ⚠️ Medium | Possible via Duration objects and curves. Consider extending Blizzard's Cooldown Manager rather than replacing it. Secrecy is on in **any** combat, open world included [INGAME 2026-11-06], so out-of-combat logic is no fallback while fighting. |
| Damage meters | ❌ Low | CLEU restricted. Blizzard ships `Blizzard_DamageMeter` / `C_DamageMeter` (check its flags). |
| Boss mods, rotation helpers, "if X then alert" combat logic | ❌ Very low | Requires branching on secret combat state. Blizzard's Encounter Timeline/Warnings is the replacement. |
| Addon-to-addon comms in combat | ❌ | `SecretInChatMessagingLockdown` |

## In-game observations

| Probe | Result | Interpretation |
|---|---|---|
| `/dump issecretvalue(UnitHealth("target"))` | `true` [INGAME 2026-11-06; location/combat state not recorded] | `UnitHealth` has **unconditional** `SecretReturns=true`, so `true` is expected in every context. Also shows that **`/dump` runs as tainted code**, so slash-command probes see what addons see. |
| `/dump C_Secrets.ShouldAurasBeSecret(), C_Secrets.ShouldCooldownsBeSecret()` | open world, **out of combat**: `false, false` · open world, **in combat**: `true, true` [INGAME 2026-11-06] | **Combat alone turns aura and cooldown secrecy on, even in the open world.** No instance needed. |
| `/dump issecretvalue(UnitHealthMax(...))` | out of combat: **`"player"` → `false`**, friendly NPC target → `true`, hostile mob target → `true` · in combat, mob → `true` [INGAME 2026-11-06]. (An earlier out-of-combat `false` was probably with self or no target.) | Max health is readable **only for yourself**. Any NPC's max health, friendly or hostile, is secret even out of combat. The rule is **self vs others**, not hostile vs friendly. Other players, party members and pets are untested [TODO-INGAME]. |

**Working model (open world, build 70790):** player auras and cooldowns are readable at rest and secret in combat. Restrictions tied to a specific unit depend on **whose** data it is, whatever the combat state. Your own max health is readable, any NPC's is secret. Dungeon and boss behavior is still untested.

**Choosing probes:** an in vs out of instance comparison only tells you something for **conditional** flags (`SecretWhen*`). Unconditional `SecretReturns` APIs are secret everywhere. Good conditional probes: `UnitHealthMax` (`SecretWhenUnitHealthMaxRestricted`), `C_UnitAuras.GetAuraDataByIndex` (`SecretWhenUnitAuraRestricted`), and `C_Secrets.ShouldAurasBeSecret()` / `ShouldCooldownsBeSecret()` (they report the restriction state directly).

## What breaks if taken too literally

- Flag **names** are reliable. Their runtime **triggers** are not in the source. A `SecretWhenUnitAuraRestricted` API may be fully readable in the open world and secret in a dungeon. Always test in the restricted context. Design for the secret path and treat the readable path as a bonus.
- Blizzard has been loosening restrictions incrementally in Midnight (whitelisted spells, etc. [NEWS]). Re-run `tools/wowapi.py flags` after each patch and diff it. Today's ❌ may become ⚠️.
