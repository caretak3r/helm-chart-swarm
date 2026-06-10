#!/usr/bin/env bats
# drift-guard.bats — Bundle mirror drift guard tests (architecture §F)
#
# Proves that drift between the canonical engine (engine/) and the bundled
# skill engine (engine/skills/chart-test-swarm/engine/) is detected in BOTH
# directions.  The sync-engine.sh script is the canonical way to reconcile
# drift; these tests verify that a `diff -r` comparison catches changes made
# to EITHER side independently.
#
# The tests:
#  1. Prove zero drift after a clean sync.
#  2. Prove drift is detected when canonical changes but bundled does not.
#  3. Prove drift is detected when bundled changes but canonical does not.
#
# IMPORTANT: These tests modify files in the mirrored tree.  They ALWAYS
# re-run sync-engine.sh at the end to restore byte-identical state so
# the repo is left clean regardless of test outcome.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
  ENGINE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
  ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

  BUNDLED_DIR="$ROOT_DIR/engine/skills/chart-test-swarm/engine"
  SYNC_SCRIPT="$ROOT_DIR/engine/skills/chart-test-swarm/scripts/sync-engine.sh"

  # Anchor file: a known script that exists in BOTH trees.  We'll modify
  # its copy independently to simulate canonical-only and bundled-only drift.
  ANCHOR="scripts/lib/output-contract.sh"

  # Make sure we start from a cleanly synced state.
  run bash "$SYNC_SCRIPT"
  if [ "$status" -ne 0 ]; then
    echo "WARNING: sync-engine.sh failed in setup — proceeding anyway" >&2
  fi
}

teardown() {
  # Always restore byte-identical state after every test.
  run bash "$SYNC_SCRIPT"
  if [ "$status" -ne 0 ]; then
    echo "WARNING: sync-engine.sh failed in teardown" >&2
  fi
}

# Helper: diff the two trees and capture the exit code.
# Returns 0 if trees are identical, 1 if they differ.
_diff_trees() {
  set +e
  diff -rq "$ENGINE_DIR" "$BUNDLED_DIR" \
    -x 'skills' \
    -x '__pycache__' \
    -x '.venv' \
    -x '.ruff_cache' \
    -x 'dist' \
    -x 'uv.lock' \
    >/dev/null 2>&1
  local rc=$?
  set -e
  return $rc
}

# ── Clean sync produces zero drift ──
@test "drift-guard: clean sync produces zero drift between trees" {
  bash "$SYNC_SCRIPT"
  run _diff_trees
  # diff -r exits 0 when identical, 1 when files differ
  if [ "$status" = "0" ]; then
    true   # no drift — PASS
  else
    echo "Drift detected after clean sync — this should not happen" >&2
    diff -r "$ENGINE_DIR" "$BUNDLED_DIR" \
      -x 'skills' -x '__pycache__' -x '.venv' \
      -x '.ruff_cache' -x 'dist' -x 'uv.lock' | head -40 >&2
    false
  fi
}

# ── Drift detected: canonical changes, bundled does not ──
@test "drift-guard: drift is detected when canonical engine changes without mirror" {
  # Ensure clean starting state
  bash "$SYNC_SCRIPT"

  # Modify ONE file in the canonical tree ONLY
  local canonical_file="$ENGINE_DIR/$ANCHOR"
  local bundled_file="$BUNDLED_DIR/$ANCHOR"
  local marker="# DRIFT-GUARD-CANONICAL-ONLY-MARKER-$(date +%s)"

  # Append a marker line to the canonical copy
  echo "$marker" >> "$canonical_file"

  # Verify the two files now differ
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 1 ]  # diff -q exits 1 when files differ

  # Remove the marker from canonical (restore)
  sed -i.bak "/^# DRIFT-GUARD-CANONICAL-ONLY-MARKER-/d" "$canonical_file"
  rm -f "${canonical_file}.bak"

  # Verify files are back in sync after marker removal
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 0 ]  # diff -q exits 0 when files are identical
}

# ── Drift detected: bundled changes, canonical does not ──
@test "drift-guard: drift is detected when bundled engine changes without mirror" {
  # Ensure clean starting state
  bash "$SYNC_SCRIPT"

  # Modify ONE file in the bundled tree ONLY
  local canonical_file="$ENGINE_DIR/$ANCHOR"
  local bundled_file="$BUNDLED_DIR/$ANCHOR"
  local marker="# DRIFT-GUARD-BUNDLED-ONLY-MARKER-$(date +%s)"

  # Append a marker line to the bundled copy
  echo "$marker" >> "$bundled_file"

  # Verify the two files now differ
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 1 ]  # diff -q exits 1 when files differ

  # Remove the marker from bundled (restore)
  sed -i.bak "/^# DRIFT-GUARD-BUNDLED-ONLY-MARKER-/d" "$bundled_file"
  rm -f "${bundled_file}.bak"

  # Verify files are back in sync after marker removal
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 0 ]  # diff -q exits 0 when files are identical
}

# ── sync-engine.sh repairs drift completely ──
@test "drift-guard: sync-engine.sh repairs drift in both directions" {
  bash "$SYNC_SCRIPT"

  local canonical_file="$ENGINE_DIR/$ANCHOR"
  local bundled_file="$BUNDLED_DIR/$ANCHOR"
  local marker1="# DRIFT-REPAIR-CANONICAL-$(date +%s)"
  local marker2="# DRIFT-REPAIR-BUNDLED-$(date +%s)"

  # --- Phase 1: drift canonical → bundled ---
  echo "$marker1" >> "$canonical_file"
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 1 ]  # drift confirmed

  # Run sync — should repair
  bash "$SYNC_SCRIPT"
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 0 ]  # drift repaired

  # Clean up marker1 from canonical (sync copied it to bundled too)
  sed -i.bak "/^# DRIFT-REPAIR-CANONICAL-/d" "$canonical_file"
  sed -i.bak "/^# DRIFT-REPAIR-CANONICAL-/d" "$bundled_file"
  rm -f "${canonical_file}.bak" "${bundled_file}.bak"
  # Re-sync to get bundled clean again
  bash "$SYNC_SCRIPT"

  # --- Phase 2: drift bundled → canonical (sync overwrites bundled) ---
  echo "$marker2" >> "$bundled_file"
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 1 ]  # drift confirmed

  # Run sync — canonical should win, overwriting bundled
  bash "$SYNC_SCRIPT"
  run diff -q "$canonical_file" "$bundled_file"
  [ "$status" -eq 0 ]  # drift repaired

  # Clean up marker2 from canonical (sync would have removed it from bundled)
  sed -i.bak "/^# DRIFT-REPAIR-BUNDLED-/d" "$canonical_file"
  rm -f "${canonical_file}.bak"
  # Final sync
  bash "$SYNC_SCRIPT"
}
