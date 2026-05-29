#!/usr/bin/env bash
# Sync the bundled engine inside this skill from the canonical source.
# Use during dev when the engine evolves and the skill bundle drifts.
#
# Usage: sync-engine.sh [canonical_engine_dir]
# Default canonical dir: ~/Documents/chart-test-swarm/engine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$SKILL_DIR/engine"
SRC="${1:-$HOME/Documents/chart-test-swarm/engine}"

[ -d "$SRC" ] || { echo "ERROR: canonical engine not at $SRC" >&2; exit 1; }

# Refuse to wipe the source by accident
if [ "$(cd "$SRC" && pwd)" = "$(cd "$DEST" 2>/dev/null && pwd || echo "")" ]; then
  echo "ERROR: source and dest are the same dir; skipping" >&2
  exit 1
fi

echo "==> Syncing engine: $SRC → $DEST"
mkdir -p "$DEST"
# Use rsync if available (cleaner), else fall back to cp -R
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude 'skills/' \
    --exclude '__pycache__/' \
    --exclude '.venv/' \
    --exclude '.ruff_cache/' \
    --exclude 'testgrid/dist/' \
    --exclude 'testgrid/uv.lock' \
    "$SRC/" "$DEST/"
else
  rm -rf "$DEST"
  cp -R "$SRC" "$DEST"
  find "$DEST" -type d \( -name skills -o -name __pycache__ -o -name .venv -o -name .ruff_cache -o -name dist \) -exec rm -rf {} + 2>/dev/null || true
fi

# Re-mark scripts executable (cp/rsync usually preserves but be defensive)
find "$DEST/scripts" "$DEST/asserts" -type f -name '*.sh' -exec chmod +x {} \;

echo "==> OK: engine bundle in sync"
