# wow-addons: WoW: Forever addon monorepo

## Target: non-negotiable
We build addons for **World of Warcraft: Forever** (launched 2026-11-04; codename **Camelot**; `WOW_PROJECT_ID` **18**; client 1.60.x; TOC `## Interface: 16001`; TOC file `<Name>_Forever.toc`).
- **Not Retail/Midnight, not Classic Era.** Forever = **Mainline 12.1.5 engine/API + Midnight addon restrictions (secret values) + Vanilla-era content + `Camelot/` UI overrides.**
- Forever postdates the model's training data. **Never answer an API question from memory.** Look it up locally (`/wow-api` skill). Treat remembered Retail/Classic knowledge as a hypothesis to verify.

## Layout
```
reference/            knowledge base: read reference/README.md first
  upstream/           Blizzard UI source mirrors, `forever` branches (gitignored; scripts/sync-reference.sh)
  generated/          api-index.json, camelot-overrides.md (gitignored; regenerated)
  decisions/          repo-wide ADRs
addons/<Name>/        one addon per dir; dir name == TOC base name
templates/addon/      scaffold used by scripts/new-addon.sh
tools/wowapi.py       API/event/flag lookup over generated docs (stdlib Python)
scripts/              sync-reference.sh · new-addon.sh · link-addon.sh · release-addon.sh
.claude/skills/       wow-api · wow-new-addon · wow-kb-update
```

## Commands
```sh
scripts/sync-reference.sh                         # fresh clone / after each patch
uv run --no-project python tools/wowapi.py fn <Name|glob>    # also: event, search, ns, table, exists, flagged, flags, overrides
scripts/new-addon.sh <PascalName> "notes"         # scaffold
scripts/link-addon.sh <Name>                      # symlink into /Applications/World of Warcraft/_forever_/Interface/AddOns
```
In-game dev loop: edit → `/reload`. Use `/dump expr`, `/etrace` (event trace), `/fstack` (frame stack). Lua errors show with `/console scriptErrors 1`.

## Rules
1. **Spec first.** Each addon starts with `addons/<Name>/SPEC.md` (template provided), including the **secret-value viability table**, before any code. Record per-addon decisions in the spec's Decisions section; repo-wide ones go in `reference/decisions/NNNN-*.md`.
2. **Secret-safe by construction.** Combat/unit/aura/cooldown data goes into widget sinks (`SetValue`, `SetText`, `SetAlphaFromBoolean`, curves, Duration objects). Don't branch on it. Check every API's flags with `tools/wowapi.py` before use. See `reference/secret-values.md`.
3. **Check Camelot overrides.** Before hooking or anchoring to a Blizzard frame or system, check for `Blizzard_X/Camelot/` in upstream. Its files win on Forever.
4. **Namespaced APIs only.** Use `C_*` directly. Deprecated globals may not load on Forever (pitfall P-004). Feature-detect over `WOW_PROJECT_ID` checks.
5. **No globals** except SavedVariables, slash commands, and compartment funcs. Share state through the addon namespace (`local addonName, ns = ...`).
6. **Libraries:** none by default. Add Ace3/LibStub/etc. only via an ADR in the addon's spec, and embed them (no external deps). Verify Forever compatibility first.
7. **Knowledge hygiene.** New facts go into `reference/` with a confidence tag ([SRC]/[WIKI]/[NEWS]/[INFER]/[TODO-INGAME]). A mistake that cost more than one iteration gets an entry in `reference/pitfalls.md`. Use the `/wow-kb-update` skill.
8. **Don't commit** `reference/upstream/` or `reference/generated/` (Blizzard code; regenerable). The repo is **public** (GPL-3.0): no secrets.
9. **Releases:** literal semver in `## Version`, a matching `CHANGELOG.md` section, then `scripts/release-addon.sh <Name>` (ADR 0002).

## Lua conventions
Lua 5.1 dialect (WoW). `local` everything, upvalue hot globals at file top, tabs or 2-space indent consistently per addon, `ns.L` for user-facing strings, Blizzard `GlobalStrings` before custom strings. Mixins (`CreateFromMixins`) over ad-hoc OOP, matching FrameXML style.
