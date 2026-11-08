#!/usr/bin/env bash
# Symlink addons/<Name> into the local WoW: Forever AddOns folder (dev loop: edit -> /reload).
# Usage: scripts/link-addon.sh <AddonName> [--unlink]     |   scripts/link-addon.sh --all
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WOW_DIR="${WOW_FOREVER_DIR:-/Applications/World of Warcraft/_forever_}"
DEST="$WOW_DIR/Interface/AddOns"
[[ -d "$WOW_DIR" ]] || { echo "No Forever install at $WOW_DIR (set WOW_FOREVER_DIR)"; exit 1; }
mkdir -p "$DEST"

link() {
  local name="$1" src="$ROOT/addons/$1"
  [[ -d "$src" ]] || { echo "no such addon: $src"; exit 1; }
  ls "$src"/*.toc >/dev/null 2>&1 || { echo "$name has no .toc"; exit 1; }
  if [[ -e "$DEST/$name" && ! -L "$DEST/$name" ]]; then
    echo "refusing: $DEST/$name exists and is not a symlink"; exit 1
  fi
  ln -sfn "$src" "$DEST/$name"
  echo "linked $name -> $DEST/$name"
}

case "${1:-}" in
  --all) for d in "$ROOT"/addons/*/; do link "$(basename "$d")"; done ;;
  "") echo "usage: $0 <AddonName> [--unlink] | --all"; exit 2 ;;
  *) if [[ "${2:-}" == "--unlink" ]]; then
       [[ -L "$DEST/$1" ]] && rm "$DEST/$1" && echo "unlinked $1"
     else link "$1"; fi ;;
esac
