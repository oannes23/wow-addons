# TOC files, load order, and addon anatomy (Forever)

Confidence: TOC mechanics are inherited from Mainline 12.x [WIKI]. Forever-specific values are marked.

## Canonical Forever TOC

File: `addons/MyAddon/MyAddon_Forever.toc`. **Folder name = TOC base name = addon name.**

```toc
## Interface: 16001
## Title: MyAddon
## Notes: One-line description
## Author: JNS
## Version: 0.1.0
## Category: <see Settings categories>
## IconTexture: Interface\Icons\INV_Misc_QuestionMark
## SavedVariables: MyAddonDB
## SavedVariablesPerCharacter: MyAddonCharDB
## AddonCompartmentFunc: MyAddon_OnCompartmentClick

Locales\enUS.lua
Core.lua
UI.xml
```

| Rule | Detail |
|---|---|
| Interface | `16001` for Forever 1.60.1 [WIKI+INFER]. Multi-flavor TOC: `## Interface: 16001, 120105`. **We ship Forever only** unless an addon's ADR says otherwise. |
| Suffix resolution | Client loads the most specific match: `_Forever`/`_Camelot` > `_Mainline` (family) > plain `.toc`. Policy: **ship `Name_Forever.toc` only.** A plain `Name.toc` would also load on Classic/Retail, which we don't target. |
| Per-file gating | `File.lua [AllowLoadGameType camelot]` (Blizzard uses `camelot`. `forever` is a wiki-documented alias). Only useful for multi-flavor addons. |
| Inline variables | `[Family]`, `[Game]`, `[TextLocale]`, `[RegionalTextLocale]` (Forever supports the last one) [WIKI] |
| `## Dependencies` / `## OptionalDeps` / `## LoadOnDemand: 1` / `## LoadWith` | Standard Mainline semantics |
| `## Version` | Write a **literal** semver (`1.0.0`). `@project-version@` is a BigWigs-packager token: without the packager it stays as-is, and the in-game AddOns list showed **no version** for QuestTrackerSort [INGAME 2026-11-07]. Release flow: `scripts/release-addon.sh` (ADR 0002). |
| Out-of-date | Interface mismatch → listed as out of date, disabled unless the user ticks "load out of date". Bump after every patch. |

## Load lifecycle

1. Client reads the TOCs. Files execute top to bottom **in TOC order**. Each file gets varargs `local addonName, ns = ...`. `ns` is a private table shared by all files of the addon. **Use `ns`, not globals.**
2. `ADDON_LOADED` (arg1 = addonName). SavedVariables are now populated. Initialize the DB here, not at file scope.
3. `PLAYER_LOGIN`: everything is loaded and the player exists. Safe to query most character APIs.
4. `PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)` fires on every loading screen.
5. `PLAYER_LOGOUT`: last chance to mutate SavedVariables before they're written to `WTF/Account/<ACCT>/SavedVariables/<Addon>.lua`.

## Minimal skeleton (no libraries)

```lua
local addonName, ns = ...
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" and ... == addonName then
    MyAddonDB = MyAddonDB or {}
    ns.db = MyAddonDB
    self:UnregisterEvent("ADDON_LOADED")
  end
end)
```

Prefer `EventUtil.ContinueOnAddOnLoaded(addonName, fn)` and `EventRegistry` callbacks where they exist. Verify with `rg` over upstream before using.

## Settings, slash commands, compartment

- Options UI: the Mainline Settings API (`Settings.RegisterVerticalLayoutCategory`, `Settings.RegisterAddOnCategory`). `Blizzard_Settings_Shared` has a `Camelot/` override, so check it before assuming identical behavior.
- Slash: `SLASH_MYADDON1 = "/myaddon"; SlashCmdList.MYADDON = function(msg) ... end`.
- Addon compartment (minimap dropdown): `## AddonCompartmentFunc`. Exists in Forever: `Blizzard_Minimap/Camelot/AddonCompartment.lua` [SRC].

## Combat lockdown (classic taint rules still apply on top of secrets)

- Protected frames (secure action buttons, unit frames with `SecureUnitButtonTemplate`) can't be created, moved, shown, or hidden in combat from addon code. Check `InCombatLockdown()`, queue the change, and apply it on `PLAYER_REGEN_ENABLED`.
- Never overwrite Blizzard functions/globals or call protected APIs from insecure paths. Use `hooksecurefunc` (post-hook) or `EventRegistry` callbacks. Taint spreads to everything downstream.

## Key bindings (Bindings.xml)

- An addon declares actions in `Bindings.xml` in its folder: `<Bindings><Binding name="MYADDON_ACTION" category="BINDING_HEADER_MYADDON">MyAddon_Action();</Binding></Bindings>` [SRC: Blizzard_Commentator/Bindings.xml, Blizzard_GroupFinder_VanillaStyle/Bindings.xml]. Blizzard's own TOCs do not list their `Bindings.xml`, so it is loaded by filename [INFER].
- `category` is resolved via `_G[category]` for the section title in Settings > Keybindings; define `BINDING_HEADER_*` and `BINDING_NAME_<name>` globals [SRC: Blizzard_SettingsDefinitions_Frame/Keybindings.lua `GetBindingCategoryName`; Camelot override only changes `HasHousingCategory`].
- **No default key can be declared** (no key attribute). Set one with `SetBinding(key, action)` then `SaveBindings(GetCurrentBindingSet())` (Blizzard_Commentator does this), checking `GetBindingAction(key)` first [SRC].
- `GetBindingKey(action)` is a legacy global, not in the generated API docs (`tools/wowapi.py` finds nothing) but used by Blizzard UI (Blizzard_HUDInventoryButton.lua:120) [SRC]. [TODO-INGAME] confirm the Wuwei section appears (Wuwei SPEC checklist 19).
