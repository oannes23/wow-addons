---
name: wow-api
description: Look up a WoW: Forever API, event, struct/enum, or Blizzard frame from the local ground-truth sources, including secret-value flags and Camelot (Forever) overrides. Use BEFORE writing or reviewing any addon Lua that calls a WoW API, registers an event, hooks or anchors to a Blizzard frame, or when asked "does X exist / what does X return" for WoW Forever.
---

# wow-api: verify before you write

Forever postdates training data. Memory of Retail or Classic APIs is a hypothesis, not an answer.

## Procedure
1. **Index present?** If `reference/generated/api-index.json` is missing, run `scripts/sync-reference.sh`.
2. **Query** (define a function, not a variable: zsh does not word-split `$W`, so `W="uv run ..."; $W fn X` fails with "no such file or directory": `w() { uv run --no-project python tools/wowapi.py "$@"; }`):
   - function: `w fn <Name>` or `w fn 'C_Ns.*Part*'`
   - event: `w event <EVENT_NAME>`
   - fuzzy: `w search <substring>`
   - struct/enum: `w table <Name>`
   - undocumented global?: `w exists <Name>`
3. **Read the SECRECY line.** Classify each API:
   - `SecretReturns` or `SecretWhen*`: returns may be opaque. Only feed them to sinks. No compare/math/branch.
   - `SecretArguments=AllowedWhenTainted`: sink. Secrets may be passed in.
   - `HasRestrictions`: restricted caller context. Find out why (`rg` its call sites) before depending on it.
   - Cross-check the meaning in `reference/secret-values.md`.
4. **See real usage**: `rg -n "<Name>" reference/upstream/wow-ui-source/Interface/AddOns --glob '!Blizzard_APIDocumentationGenerated/**'`. Prefer patterns from `Camelot/` or `Shared/` folders over `Mainline/`-only ones.
5. **Frames/mixins/templates**: check that the addon owning them loads on Forever (its TOC has no `AllowLoadGameType` excluding `camelot`), and check `Blizzard_X/Camelot/` for overrides (`w overrides`).
6. **Not found** → assume it doesn't exist on Forever. Search for the namespaced replacement (`w search <keyword>`). Only then check warcraft.wiki.gg, and tag anything learned there [WIKI].

## Output
State the signature, the secrecy classification, and the source file/line. If the answer came from anything other than local source, say so with its confidence tag.
