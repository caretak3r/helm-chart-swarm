#!/usr/bin/env bash
# assert-helpers.sh — Shared helper library for engine assertions.
# Source this file (no side effects on source): all helpers are pure function
# definitions with no execution at parse time.
#
# Functions:
#   wait_with_backoff   — Retry loop with exponential backoff + timeout ceiling
#   selector_for_release — Build app.kubernetes.io/instance=$RELEASE selector
#   parse_http_code      — Anchored, exact 3-digit %{http_code} parser
#
# Source this from your assert script:
#   source "${BASH_SOURCE[0]%/*}/lib/assert-helpers.sh" 2>/dev/null ||
#     source "$(dirname "$(readlink -f "$0")")/lib/assert-helpers.sh"

# ──────────────────────────────────────────────────────────────────────
# wait_with_backoff  —  Retry a probe command with exponential backoff.
#
# Usage:  wait_with_backoff <probe_cmd> <retries> <timeout_seconds>
#
#   probe_cmd       — Shell command that returns 0 on success, non-zero on failure.
#   retries         — Number of retry attempts AFTER the initial try.
#                     retries=0 → single attempt (no retry).
#                     Defaults to 0 if empty/unset.
#   timeout_seconds — Maximum total elapsed wall-clock time (integer seconds).
#                     The loop stops when this ceiling is reached, even if
#                     retries remain.  Defaults to 30s if empty/unset.
#
#   Returns: 0 if probe_cmd succeeds within budget; non-zero if budget exhausted.
#
#   Test injection: set WAIT_BACKOFF_SLEEP_CMD to a stub (e.g. 'true' or
#   'echo $1 >> log') before calling.  Default is 'sleep'.
# ──────────────────────────────────────────────────────────────────────
wait_with_backoff() {
  local probe_cmd="$1"
  local retries="${2:-0}"
  local timeout_sec="${3:-30}"
  local sleep_cmd="${WAIT_BACKOFF_SLEEP_CMD:-sleep}"

  # Validate numeric inputs
  case "$retries" in
    ''|*[!0-9]*) retries=0 ;;
  esac
  case "$timeout_sec" in
    ''|*[!0-9]*) timeout_sec=30 ;;
  esac

  local attempt=0
  local max_attempts=$((retries + 1))
  local start_time
  start_time=$(date +%s 2>/dev/null || printf '%s' "$SECONDS")

  while [ "$attempt" -lt "$max_attempts" ]; do
    # Check timeout ceiling before each attempt
    local now elapsed
    now=$(date +%s 2>/dev/null || printf '%s' "$SECONDS")
    elapsed=$((now - start_time))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      echo "wait_with_backoff: timeout ($timeout_sec s) reached after $attempt attempt(s)" >&2
      return 1
    fi

    # Execute probe
    if eval "$probe_cmd" 2>/dev/null; then
      return 0
    fi

    attempt=$((attempt + 1))

    # No sleep after the last attempt
    if [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi

    # Calculate backoff: 1s, 2s, 4s, 8s, 16s, 30s (capped)
    local delay=$(( 1 << (attempt - 1) ))
    [ "$delay" -gt 30 ] && delay=30

    # Ensure we don't sleep past the timeout ceiling
    now=$(date +%s 2>/dev/null || printf '%s' "$SECONDS")
    elapsed=$((now - start_time))
    local remaining=$((timeout_sec - elapsed))
    if [ "$remaining" -le 0 ]; then
      echo "wait_with_backoff: timeout ($timeout_sec s) reached" >&2
      return 1
    fi
    [ "$delay" -gt "$remaining" ] && delay=$remaining

    # Invoke sleep via eval so test stubs that use $1 work correctly.
    # For production the default is 'sleep' (a simple command).
    eval "$sleep_cmd $delay" 2>/dev/null || true
  done

  return 1
}

# ──────────────────────────────────────────────────────────────────────
# selector_for_release  —  Build a release-scoped label selector.
#
# Usage:  selector_for_release [extra_selector]
#
#   extra_selector — Optional additional selector (e.g. 'app=nginx').
#                    If provided, AND-combined with the release selector.
#
#   RELEASE env var MUST be set and non-empty.
#
#   Outputs:  app.kubernetes.io/instance=<RELEASE>[,<extra_selector>]
#   Returns:  0 on success; 1 if RELEASE is unset/empty.
# ──────────────────────────────────────────────────────────────────────
selector_for_release() {
  local extra="${1:-}"

  if [ -z "${RELEASE:-}" ]; then
    echo "selector_for_release: RELEASE is not set" >&2
    return 1
  fi

  local sel="app.kubernetes.io/instance=${RELEASE}"
  if [ -n "$extra" ]; then
    sel="${sel},${extra}"
  fi

  printf '%s' "$sel"
}

# ──────────────────────────────────────────────────────────────────────
# parse_http_code  —  Anchored, exact 3-digit HTTP status-code parser.
#
# Usage:  parse_http_code <raw_curl_output>
#
#   raw_curl_output — The captured stdout from a curl invocation that used
#                     -w '%{http_code}' (and ideally -o /dev/null).
#
#   The parser extracts the LAST line/word as the %{http_code} value and
#   validates it is exactly three decimal digits (100–999).
#
#   Outputs the 3-digit code on stdout.
#   Returns 0 if a valid code was extracted; non-zero otherwise.
#
#   What it REJECTS (no false-PASS):
#     • Codes embedded in response body (e.g. "error 200 occurred")
#     • Non-anchored multi-digit noise (e.g. "2001", "12003")
#     • Empty / whitespace-only / non-numeric input
# ──────────────────────────────────────────────────────────────────────
parse_http_code() {
  local raw="$1"

  # Strip trailing whitespace, then extract the last whitespace-delimited token.
  # This is the anchored position: %{http_code} from curl -w is the final token.
  local code
  code=$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//' | awk '{print $NF}')

  # Must be exactly 3 decimal digits (100–999).
  # Anchored regex: start-of-string, three digits, end-of-string.
  if ! printf '%s' "$code" | grep -qE '^[0-9]{3}$'; then
    echo "parse_http_code: invalid or missing HTTP status code '${code}'" >&2
    return 1
  fi

  printf '%s' "$code"
  return 0
}
