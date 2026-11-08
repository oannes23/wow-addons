#!/usr/bin/env bash
# Sync local ground-truth sources for WoW: Forever and rebuild the API index.
# Idempotent. Run after every Forever patch (or when the client build changes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="$ROOT/reference/upstream"
BRANCH="${WOW_FLAVOR_BRANCH:-forever}"   # do NOT change to live/classic_era: wrong game
mkdir -p "$UP"

sync() { # name url
  local dir="$UP/$1"
  if [[ -d "$dir/.git" ]]; then
    local old; old="$(git -C "$dir" rev-parse HEAD)"
    git -C "$dir" fetch -q --depth 1 origin "$BRANCH"
    git -C "$dir" reset -q --hard FETCH_HEAD
    if [[ "$old" != "$(git -C "$dir" rev-parse HEAD)" ]]; then
      mkdir -p "$ROOT/reference/generated"
      git -C "$dir" diff --name-status "$old" HEAD > "$ROOT/reference/generated/$1.changed" 2>/dev/null \
        && echo "  $1: $(wc -l < "$ROOT/reference/generated/$1.changed" | tr -d ' ') files changed -> reference/generated/$1.changed"
    fi
  else
    git clone -q --depth 1 -b "$BRANCH" "$2" "$dir"
  fi
  printf '%-28s %s\n' "$1" "$(git -C "$dir" log -1 --format='%cs %s')"
}

sync wow-ui-source              https://github.com/Gethe/wow-ui-source
sync BlizzardInterfaceResources https://github.com/Ketho/BlizzardInterfaceResources

uv run --no-project python "$ROOT/tools/wowapi.py" build-index
uv run --no-project python "$ROOT/tools/wowapi.py" overrides > "$ROOT/reference/generated/camelot-overrides.md"

# Sanity: the source must be the Forever/Camelot client.
grep -q "WOW_PROJECT_ID = WOW_PROJECT_CAMELOT" \
  "$UP/wow-ui-source/Interface/AddOns/Blizzard_ProjectConstants/Camelot/ProjectConstants.lua" \
  || { echo "ERROR: upstream does not look like the Forever (Camelot) client"; exit 1; }

echo "source build: $(cat "$UP/wow-ui-source/version.txt")"
echo "Compare with in-game: /dump GetBuildInfo()  — if they differ, the mirror lags; note it in reference/forever-platform.md"
