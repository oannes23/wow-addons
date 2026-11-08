#!/usr/bin/env bash
# Build an install-ready zip for one addon and publish it as a GitHub release (ADR 0002).
# The zip contains a single top-level folder named exactly <Name>/, so players unzip it
# straight into Interface/AddOns. Source = the committed tree at HEAD (uncommitted edits are ignored).
# Usage: scripts/release-addon.sh <Name> [--dry-run]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: release-addon.sh <Name> [--dry-run]}"; DRY="${2:-}"
TOC="$ROOT/addons/$NAME/${NAME}_Forever.toc"
[[ -f "$TOC" ]] || { echo "missing $TOC"; exit 1; }
VER="$(sed -n 's/^## Version: *//p' "$TOC" | tr -d '\r')"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "TOC Version must be literal semver, got '$VER'"; exit 1; }
TAG="$NAME-v$VER"
[[ -z "$(git -C "$ROOT" status --porcelain -- "addons/$NAME")" ]] || { echo "addons/$NAME has uncommitted changes; commit first"; exit 1; }

OUT="$ROOT/.release"; ZIP="$OUT/$NAME-$VER.zip"
mkdir -p "$OUT"; rm -f "$ZIP"
git -C "$ROOT" archive --format=zip --prefix="$NAME/" -o "$ZIP" "HEAD:addons/$NAME"
echo "built $ZIP"; unzip -l "$ZIP" | sed -n '4,$p'

NOTES="$(awk -v v="$VER" '$0 ~ "^## "v {f=1; next} /^## / {f=0} f' "$ROOT/addons/$NAME/CHANGELOG.md" 2>/dev/null || true)"
if [[ "$DRY" == "--dry-run" ]]; then echo "dry run: would tag $TAG"; exit 0; fi
git -C "$ROOT" tag -a "$TAG" -m "$NAME $VER"
git -C "$ROOT" push origin "$TAG"
(cd "$ROOT" && gh release create "$TAG" "$ZIP" --title "$NAME $VER" --notes "${NOTES:-$NAME $VER}")
