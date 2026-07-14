#!/usr/bin/env bash
# Sync the bundled engine inside this skill from the canonical source.
# Use during dev when the engine evolves and the skill bundle drifts.
#
# Usage: sync-engine.sh [--check] [canonical_engine_dir]
#
#   --check   Report drift and exit 1 if the bundle is stale. Writes nothing.
#             This is what CI runs; a green --check means the shipped skill
#             serves the same code as engine/.
#
# The canonical engine defaults to the one in this checkout (engine/), which is
# the tree the bundle is vendored from. Pass a path to override.
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$SKILL_DIR/engine"
# engine/skills/chart-test-swarm/scripts -> engine/
SRC="${1:-$(cd "$SKILL_DIR/../.." && pwd)}"

[ -d "$SRC" ] || { echo "ERROR: canonical engine not at $SRC" >&2; exit 1; }

# Refuse to wipe the source by accident
if [ "$(cd "$SRC" && pwd)" = "$(cd "$DEST" 2>/dev/null && pwd || echo "")" ]; then
  echo "ERROR: source and dest are the same dir; skipping" >&2
  exit 1
fi

# One list of things that are never part of the bundle: the skill itself (no
# recursion), build caches, and the lockfile. Both the sync and the --check
# read from this list, so the two can never disagree on what "in sync" means.
NOT_BUNDLED=(
  skills
  __pycache__
  '*.pyc'
  .venv
  .ruff_cache
  .mypy_cache
  .pytest_cache
  dist
  uv.lock
)

if [ "$CHECK_ONLY" -eq 1 ]; then
  diff_args=()
  for p in "${NOT_BUNDLED[@]}"; do
    diff_args+=(-x "$p")
  done

  echo "==> Checking engine bundle: $SRC → $DEST"
  # Compare content only. rsync's own dry-run compares mtimes and permissions,
  # which flag byte-identical files as drift after a plain copy; diff does not.
  if drift="$(diff -rq "${diff_args[@]}" "$SRC" "$DEST" 2>&1)" && [ -z "$drift" ]; then
    echo "==> OK: engine bundle in sync"
    exit 0
  fi

  echo "ERROR: engine bundle is out of sync with the canonical engine/." >&2
  echo "The shipped skill would serve stale code. Drift:" >&2
  echo "$drift" >&2
  echo "" >&2
  echo "Fix: run engine/skills/chart-test-swarm/scripts/sync-engine.sh and commit." >&2
  exit 1
fi

echo "==> Syncing engine: $SRC → $DEST"
mkdir -p "$DEST"
# Use rsync if available (cleaner), else fall back to cp -R
if command -v rsync >/dev/null 2>&1; then
  rsync_args=()
  for p in "${NOT_BUNDLED[@]}"; do
    rsync_args+=(--exclude "$p")
  done
  rsync -a --delete "${rsync_args[@]}" "$SRC/" "$DEST/"
else
  rm -rf "$DEST"
  cp -R "$SRC" "$DEST"
  for p in "${NOT_BUNDLED[@]}"; do
    find "$DEST" -name "$p" -exec rm -rf {} + 2>/dev/null || true
  done
fi

# Re-mark scripts executable (cp/rsync usually preserves but be defensive)
find "$DEST/scripts" "$DEST/asserts" -type f -name '*.sh' -exec chmod +x {} \;

echo "==> OK: engine bundle in sync"
