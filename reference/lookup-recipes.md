# Lookup recipes: answering API questions from local sources

**Order of authority:** in-game behavior > local Blizzard source (`reference/upstream`) > warcraft.wiki.gg > anything else.
Never answer an API question from memory. Training data is mostly Retail-pre-Midnight and Classic, and both are wrong for Forever in different ways.

## tools/wowapi.py (generated docs: signatures + secrecy)

```sh
W="uv run --no-project python tools/wowapi.py"
$W fn UnitHealth                 # exact (bare name or Namespace.Name)
$W fn 'C_Spell.*Cooldown*'       # glob
$W event UNIT_AURA               # payload + flags
$W search quest                  # substring across functions/events/tables
$W ns C_DamageMeter              # a whole namespace or system
$W table AuraData                # struct/enum definition (JSON)
$W exists GetSpellInfo           # present in client globals? documented where?
$W flagged SecretWhenCooldownsRestricted
$W flags                         # flag histogram (diff after patches)
$W fn X --json                   # machine-readable
```

Exit code 1 means no match. **A missing entry means it doesn't exist in Forever unless proven otherwise.** Cross-check with `exists`, which reads Ketho's `GlobalAPI.lua` and includes undocumented globals.

## rg over FrameXML (how Blizzard actually uses things)

```sh
U=reference/upstream/wow-ui-source/Interface/AddOns
rg -n "C_UnitAuras.GetAuraDataByIndex" $U --glob '!Blizzard_APIDocumentationGenerated/**'   # real call sites
rg -n "Mixin\b.*=.*{" $U/Blizzard_UnitFrame                      # mixins to reuse
fd -t d '^Camelot$' $U                                            # every Forever override folder
rg -n "AllowLoadGameType [a-z,]*camelot" $U --glob '*.toc'        # files that load ONLY/also on Forever
rg -n "Camelot" $U --glob '*.lua' --glob '!*Documentation*'       # Forever-specific behavior comments
```

**Override rule:** if `Blizzard_X/Camelot/` exists, its files win for Forever. Read it before relying on `Blizzard_X/Mainline/` or `Shared/`.

## Ketho BlizzardInterfaceResources (`reference/upstream/BlizzardInterfaceResources/Resources`)

| File | Use |
|---|---|
| `GlobalAPI.lua` | Every global function in the client |
| `Events.lua` | Every event, grouped by system |
| `Frames.lua`, `FrameXML.lua`, `Templates.lua`, `Mixins.lua` | Named frames, templates, mixins |
| `CVars.lua` | Console variables |
| `AtlasInfo.lua` | Atlas names for `SetAtlas` |
| `GlobalStrings/<locale>.lua` | Localized global strings (use these instead of hardcoding English) |
| `WidgetAPI.lua`, `ScriptObjectAPI.lua` | Widget methods |

Note: this mirror can lag the client (it was at build 70532 when wow-ui-source was at 70790). Prefer wow-ui-source when they disagree.

## Web (only when local sources can't answer)

- https://warcraft.wiki.gg (search `<API> Forever` and check the page's flavor badges)
- Blizzard UI Discord announcements, relayed by Wowhead. Record anything learned in `reference/` with a confidence tag.
