#!/usr/bin/env bash
# Scaffold addons/<Name> from templates/addon. Name must be PascalCase, [A-Za-z0-9].
# Usage: scripts/new-addon.sh <Name> "<one-line notes>"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: new-addon.sh <Name> \"notes\"}"; NOTES="${2:-}"
[[ "$NAME" =~ ^[A-Z][A-Za-z0-9]+$ ]] || { echo "Name must be PascalCase alphanumeric"; exit 1; }
DEST="$ROOT/addons/$NAME"
[[ -e "$DEST" ]] && { echo "exists: $DEST"; exit 1; }
cp -R "$ROOT/templates/addon" "$DEST"
mv "$DEST/__ADDON___Forever.toc" "$DEST/${NAME}_Forever.toc"
NOTES_ESC="$(printf '%s' "$NOTES" | sed -e 's/[\\&|]/\\&/g')"   # sed replacement metacharacters
UPPER="$(tr '[:lower:]' '[:upper:]' <<<"$NAME")"; LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$NAME")"
find "$DEST" -type f -print0 | xargs -0 sed -i '' \
  -e "s/__ADDON_UPPER__/$UPPER/g" -e "s/__ADDON_LOWER__/$LOWER/g" \
  -e "s/__ADDON__/$NAME/g" -e "s|__NOTES__|$NOTES_ESC|g"
echo "created $DEST"; find "$DEST" -type f | sed "s#$ROOT/##"
