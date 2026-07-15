#!/usr/bin/env bash
# Shared library: assertion output contract parsing (architecture §3.A.1).
# Source this from run-scenario.sh and from bats tests — no side effects.
#
# Functions:
#   lookup_depth <type>           → prints declared depth (L0-L3) or ""
#   parse_assert_log <log> <ec>   → sets _PARSED_RESULT + _PARSED_DETAIL
#   resolve_assert_script <type> [consumer_dir] [engine_dir]
#                                 → prints RESOLVED:<path> or FAIL:<reason>
#
# Dependencies:
#   $ENGINE_DIR   (set by the caller before sourcing)
# lookup_depth and resolve_assert_script also use $PROJECT_DIR.

# ── Depth registry lookup ────────────────────────────────────────────
# Resolves the declared depth_level for an assert type from the merged
# registry (consumer overrides engine).  Returns empty string when the
# type or both registries are absent.
# Consumer registry: $PROJECT_DIR/chart-test/asserts/registry.yaml
# Engine registry:  $ENGINE_DIR/asserts/registry.yaml
lookup_depth() {
  local assert_type="$1"
  local consumer_registry="${PROJECT_DIR:-}/chart-test/asserts/registry.yaml"
  local engine_registry="${ENGINE_DIR:-}/asserts/registry.yaml"

  # Consumer registry wins (if it exists and declares this type).
  if [ -f "$consumer_registry" ] && command -v yq >/dev/null 2>&1; then
    local depth
    depth=$(yq ".[\"$assert_type\"]" "$consumer_registry" 2>/dev/null) || true
    if [ -n "$depth" ] && [ "$depth" != "null" ]; then
      echo "$depth"
      return
    fi
  fi

  # Fall back to engine registry.
  if [ -f "$engine_registry" ] && command -v yq >/dev/null 2>&1; then
    local depth
    depth=$(yq ".[\"$assert_type\"]" "$engine_registry" 2>/dev/null) || true
    if [ -n "$depth" ] && [ "$depth" != "null" ]; then
      echo "$depth"
    else
      echo ""
    fi
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

# ── Consumer-first assert script resolver (architecture §3.E.1) ──────
# Resolves the filesystem path of an assert script following consumer-first
# layering: the consumer project's chart-test/asserts/<type>.sh wins when
# present AND executable; otherwise the engine assert is used.
#
# CALLING CONVENTION:
#   resolve_assert_script <assert_type> [consumer_asserts_dir] [engine_asserts_dir]
#
# Output (stdout):
#   RESOLVED:<absolute-path>   — a runnable script was found
#   FAIL:no runner at <path>…  — no runnable script exists
#
# Defaults (when the optional arguments are omitted):
#   consumer_asserts_dir = $PROJECT_DIR/chart-test/asserts
#   engine_asserts_dir   = $ASSERTS_DIR  (or $ENGINE_DIR/asserts)
#
# This is the single source of truth for assert resolution.  Both the
# production runner (run-scenario.sh) and the bats tests MUST call this
# function rather than duplicating the logic inline.
resolve_assert_script() {
  local atype="$1"
  local consumer_asserts_dir="${2:-${PROJECT_DIR:-}/chart-test/asserts}"
  local engine_asserts_dir="${3:-${ASSERTS_DIR:-${ENGINE_DIR:-}/asserts}}"

  local consumer_assert="${consumer_asserts_dir}/${atype}.sh"
  local engine_assert="${engine_asserts_dir}/${atype}.sh"

  if [ -x "$consumer_assert" ]; then
    # Consumer wins: present AND executable (VAL-PLUGGABLE-001, -002)
    echo "RESOLVED:$consumer_assert"
  elif [ -x "$engine_assert" ]; then
    # Engine fallback: consumer absent, non-executable, or not found
    # (VAL-PLUGGABLE-003, -004, -005)
    echo "RESOLVED:$engine_assert"
  elif [ -f "$consumer_assert" ]; then
    # Consumer exists but not executable, no engine fallback
    # (VAL-PLUGGABLE-006)
    echo "FAIL:no runner at $consumer_assert (not executable)"
  else
    # Neither consumer nor engine has a runner
    echo "FAIL:no runner at $engine_assert"
  fi
}
