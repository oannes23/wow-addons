# wow-addons

Monorepo of addons for **World of Warcraft: Forever** (Interface 16001, `_Forever.toc`).

```sh
scripts/sync-reference.sh          # pull Blizzard UI source (forever branch) + build API index
scripts/new-addon.sh MyAddon "…"   # scaffold addons/MyAddon (spec-first)
scripts/link-addon.sh MyAddon      # symlink into the local _forever_ client, then /reload
scripts/release-addon.sh MyAddon   # tag + GitHub release with an install-ready zip (ADR 0002)
uv run --no-project python tools/wowapi.py fn UnitHealth
```

Knowledge base: [reference/README.md](reference/README.md). Agent instructions: [CLAUDE.md](CLAUDE.md).

## Addons
| Addon | What it does | Version |
|---|---|---|
| [QuestTrackerSort](addons/QuestTrackerSort) | Sorts the Quests tracker by distance or level instead of newest-first | 1.0.0 |

Players: download addon zips from [Releases](https://github.com/oannes23/wow-addons/releases).

## License
GPL-3.0-or-later. See [LICENSE](LICENSE).
