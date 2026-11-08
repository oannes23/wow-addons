# ADR-0001: Knowledge base architecture

- Status: accepted
- Date: 2026-11-06

## Context
WoW: Forever launched 2026-11-04, after the assistant's training cutoff. Model priors about WoW addons are Retail (pre-Midnight) and Classic Era, and both are wrong for Forever in different ways. Secondary web sources about Forever are thin and sometimes wrong (see pitfalls P-001).

## Decision
Three-layer knowledge base, ordered by authority:

1. **Upstream mirrors (generated, gitignored).** `reference/upstream/{wow-ui-source,BlizzardInterfaceResources}` on their `forever` branches, synced by `scripts/sync-reference.sh`. This is ground truth for API existence, signatures, secrecy flags, and Blizzard usage patterns.
2. **Query tooling.** `tools/wowapi.py` parses `Blizzard_APIDocumentationGenerated` into `reference/generated/api-index.json` and answers lookups. It is stdlib-only Python run via `uv run --no-project`.
3. **Curated prose (committed).** `reference/*.md`: synthesized frames, patterns, and decisions, each claim tagged with confidence ([SRC]/[WIKI]/[NEWS]/[INFER]/[TODO-INGAME]).

Skills in `.claude/skills/` encode the workflows: API lookup, new-addon scaffold, KB update.

## Rationale
- Generated docs carry machine-readable secrecy metadata, which is the single most important Forever constraint. Prose summaries of it would rot every patch.
- Not vendoring Blizzard source avoids redistributing their code in our git history and keeps the repo small. The sync script makes it reproducible.
- Confidence tags make it possible to prune stale claims after a patch.

## Consequences / what breaks
- Offline fresh clones have no API reference until the sync runs (requires network + git).
- The mirrors are community-maintained (Gethe, Ketho). If they stop tracking `forever`, fall back to exporting the UI from the client (`ExportInterfaceFiles code` console command; requires launching with the dev console enabled) [WIKI, verify].
- The source declares *which* APIs can be secret, not *when*. Runtime triggers need in-game testing and get recorded in prose.
