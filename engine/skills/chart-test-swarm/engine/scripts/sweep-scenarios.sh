#!/usr/bin/env bash
# sweep-scenarios.sh — Cross-scenario schema validation sweep tool (VAL-CROSS-012).
#
# Runs check-jsonschema CLI against every scenario YAML found under the
# examples directory (or a configurable root), validating each against
# the project's scenario.schema.json. Exits 0 only if ALL scenarios pass.
#
# Usage:   sweep-scenarios.sh [OPTIONS]
# Options: --root <dir>   Override scenarios search root (default: examples/)
#          --schema <f>   Override schema file (default: engine/templates/scenario.schema.json)
#          --help         Show usage banner and exit
set -euo pipefail

# ---- Usage banner (checked before bash version preflight so --help always works) ----
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Cross-scenario schema validation sweep: validate every scenario YAML under
the examples/ directory (or a configurable root) against the project's
scenario.schema.json using the check-jsonschema CLI.

Options:
  --root <dir>     Override scenarios search root (default: examples/)
  --schema <f>     Override schema file (default: engine/templates/scenario.schema.json)
  --help           Show this usage banner and exit

Exits 0 if all scenarios validate; exits 1 on any failure.
EOF
  exit 0
}

# Check for --help before any further processing
case "${1:-}" in
  --help|-h) usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"

SCHEMA="$ENGINE_DIR/templates/scenario.schema.json"
SEARCH_ROOT="$ROOT_DIR/examples"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)   SEARCH_ROOT="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -f "$SCHEMA" ] || { echo "ERROR: schema not found: $SCHEMA" >&2; exit 1; }
[ -d "$SEARCH_ROOT" ] || { echo "ERROR: search root not found: $SEARCH_ROOT" >&2; exit 1; }

# Ensure check-jsonschema is available — install via uv if not present.
if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "==> Installing check-jsonschema via uv..."
  if command -v uv >/dev/null 2>&1; then
    uv tool install check-jsonschema 2>/dev/null || uv pip install --system check-jsonschema 2>/dev/null || {
      echo "ERROR: could not install check-jsonschema" >&2
      exit 1
    }
  else
    echo "ERROR: check-jsonschema not found and uv not available to install it" >&2
    exit 1
  fi
fi

# Collect scenario YAMLs — only files under **/scenarios/ directories
# to avoid validating Helm chart templates, values, fixtures, etc.
SCENARIOS=()
while IFS= read -r f; do
  SCENARIOS+=("$f")
done < <(find "$SEARCH_ROOT" -type f \( -name "*.yaml" -o -name "*.yml" \) -path '*/scenarios/*' | sort)

if [ ${#SCENARIOS[@]} -eq 0 ]; then
  echo "WARN: no scenario YAMLs found under $SEARCH_ROOT" >&2
  exit 0
fi

echo "==> Sweeping ${#SCENARIOS[@]} scenario(s) against $SCHEMA"

PASS=0
FAIL=0
FAILS=()

for f in "${SCENARIOS[@]}"; do
  rel="${f#"$ROOT_DIR"/}"
  if check-jsonschema --schemafile "$SCHEMA" "$f" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  OK: $rel"
  else
    FAIL=$((FAIL + 1))
    FAILS+=("$rel")
    echo "  FAIL: $rel"
    # Re-run with verbose output to show the validation error
    check-jsonschema --schemafile "$SCHEMA" "$f" 2>&1 | sed 's/^/       /' || true
  fi
done

echo ""
echo "==> Sweep complete: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
  echo "==> Failed scenarios:" >&2
  for f in "${FAILS[@]}"; do
    echo "    $f" >&2
  done
  exit 1
fi

exit 0
