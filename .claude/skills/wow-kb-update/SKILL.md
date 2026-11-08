---
name: wow-kb-update
description: Grow or refresh the WoW: Forever knowledge base in reference/. Use after a Forever patch or hotfix, when the in-game build differs from the source build, when an in-game test confirms or refutes a claim, when research turns up a new platform fact, or when a mistake should become a pitfall.
---

# wow-kb-update

## A. After a patch / build change
1. `uv run --no-project python tools/wowapi.py flags > reference/generated/flags.before` (skip if no index yet)
2. `scripts/sync-reference.sh` (prints the new build)
3. `uv run --no-project python tools/wowapi.py flags | diff reference/generated/flags.before -` → summarize what loosened or tightened.
4. Read `reference/generated/wow-ui-source.changed` (name-status diff written by the sync) and check whether these changed: `version.txt`, `Blizzard_ProjectConstants/Camelot`, `Blizzard_APIDocumentationGenerated/{SecretPredicateAPI,FrameScript}Documentation.lua`, and any `*/Camelot/*`.
5. Update `reference/forever-platform.md`: build, interface number (if the TOC version moved, bump every `addons/*/*_Forever.toc` and `templates/addon`), and "Last verified".
6. The sync regenerates `reference/generated/camelot-overrides.md`. If new `Camelot/` areas appear in the `.changed` list, update `forever-vs-mainline.md`.

## B. Recording a fact
- Put it in the most specific existing file. Create a new `reference/<topic>.md` only for a genuinely new topic, and link it from `reference/README.md`.
- Tag every claim: [SRC] (cite file path), [WIKI]/[NEWS] (cite URL), [INFER], [TODO-INGAME]. When an in-game test resolves a [TODO-INGAME], change the tag to `[INGAME yyyy-mm-dd]` and note the build.
- Contradictions: higher authority wins (in-game > SRC > WIKI > NEWS). Keep a one-line note about the losing claim when it's a likely trap, e.g. a widely repeated fan-site error.

## C. Pitfalls
A mistake that cost more than one iteration gets `## P-NNN · title (date)` in `reference/pitfalls.md` with symptom → cause → rule. If it's a rule that applies everywhere, also add one line to `CLAUDE.md` Rules.

## D. In-game verification requests
When a fact can only be settled in game, give the user copy-pasteable commands, e.g.
`/dump select(4, GetBuildInfo())`, `/dump WOW_PROJECT_ID`, `/etrace`, `/fstack`. `/dump` runs tainted, so it sees what addons see.
For secrecy-trigger tests, probe **conditional** APIs (`SecretWhen*` flags, e.g. `UnitHealthMax`, or the `C_Secrets.Should*BeSecret()` predicates) in and out of combat/instances. Unconditional `SecretReturns` APIs (e.g. `UnitHealth`) are secret everywhere and tell you nothing about triggers. Always have the user report where and in what state each probe ran. Probes must be self-describing: label every printed value, print the unit identity, `pcall` any arithmetic, and have `/console scriptErrors 1` on (pitfall P-006).
