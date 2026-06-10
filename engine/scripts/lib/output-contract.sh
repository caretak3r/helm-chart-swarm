#!/usr/bin/env bash
# Shared library: assertion output contract parsing (architecture §3.A.1).
# Source this from run-scenario.sh and from bats tests — no side effects.
#
# Functions:
#   lookup_depth <type>           → prints declared depth (L0-L3) or ""
#   parse_assert_log <log> <ec>   → sets _PARSED_RESULT + _PARSED_DETAIL
#
# Both functions depend on:
#   $ENGINE_DIR   (set by the caller before sourcing)

# ── Depth registry lookup ────────────────────────────────────────────
# Resolves the declared depth_level for an assert type from the engine
# registry.  Returns empty string when the type or registry is absent.
lookup_depth() {
  local assert_type="$1"
  local registry_file="${ENGINE_DIR:-}/asserts/registry.yaml"
  if [ -f "$registry_file" ] && command -v yq >/dev/null 2>&1; then
    yq ".[\"$assert_type\"]" "$registry_file" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Structured output parser ─────────────────────────────────────────
# Scans an assert log for ASSERTION_RESULT / ASSERTION_DETAIL contract
# lines (architecture §3.A.1).  The LAST matching line of each type
# wins; the prefix is anchored (^<ws>ASSERTION_RESULT:) to avoid
# matching prose-embedded occurrences.  When no valid structured line
# is present, falls back to the exit-code semantics (0 → PASS,
# non‑0 → FAIL).  Malformed values also fall back to the exit code.
#
# CALLING CONVENTION (global side-effect variables):
#   _PARSED_RESULT   — PASS | FAIL | SKIP  (derived)
#   _PARSED_DETAIL   — raw JSON string or ""
parse_assert_log() {
  local logfile="$1" _exit_code="$2"
  _PARSED_RESULT=""
  _PARSED_DETAIL=""

  # ── Last ASSERTION_RESULT line (anchored line-prefix match) ──────
  local last_result_line
  last_result_line=$(grep '^[[:space:]]*ASSERTION_RESULT:' "$logfile" 2>/dev/null | tail -1 || echo "")

  # ── Last ASSERTION_DETAIL line ────────────────────────────────────
  local last_detail_line
  last_detail_line=$(grep '^[[:space:]]*ASSERTION_DETAIL:' "$logfile" 2>/dev/null | tail -1 || echo "")

  # ── Parse the result value (whitespace-tolerant) ──────────────────
  if [ -n "$last_result_line" ]; then
    local value
    value=$(echo "$last_result_line" | sed 's/^[[:space:]]*ASSERTION_RESULT:[[:space:]]*//' | sed 's/[[:space:]]*$//')

    case "$value" in
      PASS|FAIL|SKIP)
        _PARSED_RESULT="$value"
        ;;
      *)
        # Malformed value — fall back to exit code below
        _PARSED_RESULT=""
        ;;
    esac
  fi

  # ── Exit-code fallback ────────────────────────────────────────────
  if [ -z "$_PARSED_RESULT" ]; then
    if [ "$_exit_code" -eq 0 ]; then
      _PARSED_RESULT="PASS"
    else
      _PARSED_RESULT="FAIL"
    fi
  fi

  # ── Capture detail (opaque — stored as-is; no JSON validation) ────
  if [ -n "$last_detail_line" ]; then
    _PARSED_DETAIL=$(echo "$last_detail_line" | sed 's/^[[:space:]]*ASSERTION_DETAIL:[[:space:]]*//')
  fi
}
