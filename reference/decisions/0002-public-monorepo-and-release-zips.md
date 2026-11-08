# ADR 0002: Public monorepo, per-addon release zips

- Status: accepted (2026-11-07)
- Context: QuestTrackerSort is the first addon to ship. The user chose to publish the **whole monorepo** publicly (`oannes23/wow-addons`) under **GPL-3.0**, not a separate repo per addon.

## Decision
1. One public repo, default branch `main`. GPL-3.0 at the root, plus a copy in each addon folder so the license travels inside the zip.
2. Players don't clone the repo; WoW needs the folder name to match the TOC name. Each addon ships as a **GitHub release** with a zip whose only top-level entry is `<Name>/`. `scripts/release-addon.sh <Name>` builds the zip from the committed tree (`git archive HEAD:addons/<Name>`), tags `<Name>-v<semver>`, and attaches the zip to the release.
3. `## Version:` in the TOC is a **literal semver**, kept in sync with `CHANGELOG.md` (`## <version>` sections become the release notes). No `@project-version@` (see `toc-and-loading.md`).
4. `## Author: oannes23` (GitHub handle). `## X-Website` points to the addon's folder in the monorepo.

## Implications / what breaks
- Tags are namespaced per addon (`Name-vX.Y.Z`), so `releases/latest` means "latest of any addon". Link to specific tags.
- The public repo exposes `CLAUDE.md`, `.claude/skills`, and the knowledge base. That's intended, but **never commit `reference/upstream/` or `reference/generated/`** (Blizzard code) and never commit secrets. Run a quick secret grep before each push.
- No CurseForge/Wago packaging yet. If that's added later, the `.pkgmeta`/BigWigs packager could replace step 2. Supersede this ADR then.
