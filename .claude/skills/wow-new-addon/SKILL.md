---
name: wow-new-addon
description: Create a new WoW: Forever addon in this monorepo, spec-first, with a secret-value viability check, scaffold, and symlink into the local client. Use when the user wants to start, design, or scaffold a new addon.
---

# wow-new-addon

## 1. Interrogate and spec (before any code)
- Read `reference/README.md`, `reference/secret-values.md` (archetype viability table), `reference/forever-vs-mainline.md`, `reference/pitfalls.md`.
- Pin down the problem, scope in/out, and UX surface. Ask the user only what changes the design.
- **Viability gate:** list every piece of game data the addon needs. For each, find the API with the `wow-api` skill and record its secrecy flags in the SPEC table. If core functionality needs to *branch on* secret data, say so plainly and propose a display-only redesign, an extension of a Blizzard system (Cooldown Manager, Damage Meter, Encounter Timeline), or dropping the feature. Don't build something that will silently fail in instances.

## 2. Scaffold
```sh
scripts/new-addon.sh <PascalName> "<one-line notes>"
```
Then fill `addons/<Name>/SPEC.md`. The template gives you: `<Name>_Forever.toc` (Interface 16001), `Core.lua` (ns, DB init via `EventUtil.ContinueOnAddOnLoaded`, login hook, slash command, compartment), and `Locales/enUS.lua`.

## 3. Implement
- Each file starts `local addonName, ns = ...`. Add files to the TOC in load order.
- Verify every API call with `wow-api` as you write it. Wrap secret-flagged data paths per the secret-values patterns.
- Protected/secure frames: no create/move/show/hide in combat. Queue the change until `PLAYER_REGEN_ENABLED`.

## 4. Run
```sh
scripts/link-addon.sh <Name>
```
Tell the user to `/reload` in game (and `/console scriptErrors 1` once). Give them the exact `/dump` or test steps for each SPEC item marked for in-game verification, including **one test inside a dungeon/combat** for anything touching secret-flagged APIs.

## 5. Close the loop
Record verified behavior and surprises: addon-local in SPEC.md Decisions, platform-level through the `wow-kb-update` skill.
