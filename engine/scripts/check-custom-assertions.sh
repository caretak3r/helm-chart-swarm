#!/usr/bin/env bash
# check-custom-assertions.sh — Linter for consumer assert scripts
# (feature e-custom-assertion-linter, Area E architecture §3.E.3).
#
# Validates consumer assert scripts under $PROJECT_DIR/chart-test/asserts/:
#   1. Executable bit present
#   2. A valid `# DEPTH:` header present
#   3. The type (script basename without .sh) declared in a registry
#      (consumer registry layered over engine registry; consumer wins).
#   4. The header depth consistent with the registry-declared depth.
#
# Aggregates all violations and exits non-zero if ANY assert fails.
# No-op (exit 0) when there are no consumer assert scripts.
#
# Usage:   check-custom-assertions.sh <PROJECT_DIR>
#           PROJECT_DIR env var is also honored if no argument is given.
# Options: --help    Show usage banner and exit
set -euo pipefail

# ---- Usage banner ----
usage() {
  cat <<EOF
Usage: $(basename "$0") <PROJECT_DIR>

Validate consumer assert scripts under <PROJECT_DIR>/chart-test/asserts/.

Checks:
  - Executable bit set
  - # DEPTH: Lx header present and valid (L0|L1|L2|L3)
  - Type declared in a registry (consumer or engine)
  - Header depth consistent with registry-declared depth

Exits 0 if all checks pass or no consumer asserts exist.
Exits 1 if any violation is found (aggregates all violations).
EOF
  exit 0
}

case "${1:-}" in
  --help|-h) usage ;;
esac

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_REGISTRY="$ENGINE_DIR/asserts/registry.yaml"

# PROJECT_DIR: first positional argument, or $PROJECT_DIR env var
PROJECT_DIR="${1:-${PROJECT_DIR:-}}"
if [ -z "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR not set. Pass as argument or export PROJECT_DIR." >&2
  echo "Usage: $(basename "$0") <PROJECT_DIR>" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR not found: $PROJECT_DIR" >&2
  exit 1
fi

CONSUMER_ASSERTS="$PROJECT_DIR/chart-test/asserts"

# ---- No consumer asserts dir → no-op (VAL-PLUGGABLE-025) ----
if [ ! -d "$CONSUMER_ASSERTS" ]; then
  echo "check-custom-assertions: no consumer asserts dir ($CONSUMER_ASSERTS) — nothing to lint"
  exit 0
fi

# Collect .sh files (non-recursive, only direct children)
shopt -s nullglob
scripts=("$CONSUMER_ASSERTS"/*.sh)
shopt -u nullglob

if [ ${#scripts[@]} -eq 0 ]; then
  echo "check-custom-assertions: no consumer assert scripts — nothing to lint"
  exit 0
fi

# ---- Validate each script (VAL-PLUGGABLE-024: aggregate all) ----
violations=0

for script in "${scripts[@]}"; do
  rel="${script#"$PROJECT_DIR"/}"
  type=$(basename "$script" .sh)

  # 1. Executable bit (VAL-PLUGGABLE-020)
  if [ ! -x "$script" ]; then
    echo "FAIL: $rel — not executable"
    violations=$((violations + 1))
  fi

  # 2. # DEPTH: header (VAL-PLUGGABLE-021)
  header_line=$(grep '^# DEPTH:' "$script" 2>/dev/null | head -1 || echo "")
  header_depth=""
  has_header=true
  if [ -z "$header_line" ]; then
    echo "FAIL: $rel — missing # DEPTH: header"
    violations=$((violations + 1))
    has_header=false
  else
    header_depth=$(echo "$header_line" | awk '{print $NF}')
  fi

  # 3. Valid depth value (VAL-PLUGGABLE-022) — only when header exists
  if $has_header; then
    case "$header_depth" in
      L0|L1|L2|L3) ;;
      *)
        echo "FAIL: $rel — invalid DEPTH value '$header_depth' (expected L0|L1|L2|L3)"
        violations=$((violations + 1))
        has_header=false  # disable consistency check for invalid value
        ;;
    esac
  fi

  # 4. Declared in a registry (VAL-PLUGGABLE-023)
  consumer_reg="$CONSUMER_ASSERTS/registry.yaml"
  registry_depth=""

  # Consumer registry first (layering: consumer wins)
  if [ -f "$consumer_reg" ]; then
    registry_depth=$(yq ".[\"$type\"]" "$consumer_reg" 2>/dev/null || echo "")
  fi

  # Engine registry fallback
  if [ -z "$registry_depth" ] || [ "$registry_depth" = "null" ]; then
    if [ -f "$ENGINE_REGISTRY" ]; then
      registry_depth=$(yq ".[\"$type\"]" "$ENGINE_REGISTRY" 2>/dev/null || echo "")
    fi
  fi

  if [ -z "$registry_depth" ] || [ "$registry_depth" = "null" ]; then
    echo "FAIL: $rel — type '$type' not declared in any registry (consumer or engine)"
    violations=$((violations + 1))
  fi

  # 5. Header depth consistency with registry (VAL-PLUGGABLE-026)
  if $has_header && [ -n "$registry_depth" ] && [ "$registry_depth" != "null" ]; then
    if [ "$header_depth" != "$registry_depth" ]; then
      echo "FAIL: $rel — header depth $header_depth != registry depth $registry_depth"
      violations=$((violations + 1))
    fi
  fi
done

# ---- Report summary ----
if [ "$violations" -gt 0 ]; then
  echo ""
  echo "check-custom-assertions: $violations violation(s) found"
  exit 1
fi

echo "check-custom-assertions: all ${#scripts[@]} consumer assert(s) OK"
exit 0
