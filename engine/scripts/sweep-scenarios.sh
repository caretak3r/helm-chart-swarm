#!/usr/bin/env bash
# sweep-scenarios.sh — Cross-scenario schema validation sweep tool (VAL-CROSS-012).
#
# Runs check-jsonschema CLI against every scenario YAML found under the
# examples directory (or a configurable root), validating each against
# the project's scenario.schema.json. Also enforces that every assert type
# referenced by any scenario has a declared depth in the engine depth registry
# AND that each engine assert script's # DEPTH: header matches its registry entry.
# Exits 0 only if ALL scenarios pass and depth enforcement passes.
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

# ── Helper: find consumer project root for a scenario file ──────────
# Walks up from the scenario file until it finds a 'chart-test/'
# subdirectory; returns the directory that CONTAINS 'chart-test/'
# (the consumer project root). This correctly handles nested scenario
# layouts (e.g. chart-test/scenarios/capability/minimal.yaml) as well
# as flat layouts (chart-test/scenarios/test.yaml).
# Falls back to the legacy fixed-depth calculation when 'chart-test/'
# is not found anywhere in the path hierarchy.
find_project_dir() {
  local scenario_file="$1"
  local d
  d="$(cd "$(dirname "$scenario_file")" && pwd)"
  while [ "$d" != "/" ]; do
    if [ -d "$d/chart-test" ]; then
      echo "$d"
      return
    fi
    d="$(dirname "$d")"
  done
  # Fallback: legacy fixed-depth assumption (flat layout)
  echo "$(dirname "$(dirname "$(dirname "$scenario_file")")")"
}

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

# ── Depth Registry Enforcement (architecture §3.A.3) ──────────────────────
REGISTRY="$ENGINE_DIR/asserts/registry.yaml"
echo ""
echo "==> Depth Registry Enforcement"

DEPTH_FAIL=0

if [ ! -f "$REGISTRY" ]; then
  echo "  FAIL: depth registry not found: $REGISTRY" >&2
  DEPTH_FAIL=1
else
  # Validate all registry values are within {L0,L1,L2,L3}
  echo "── Validating registry depth values ──"
  while IFS=':' read -r rtype rdepth; do
    rtype="${rtype// /}"   # trim whitespace
    rdepth="${rdepth// /}"
    if [ -z "$rtype" ] && [ -z "$rdepth" ]; then continue; fi
    case "$rdepth" in
      L0|L1|L2|L3) ;;
      *) echo "  FAIL: registry type '$rtype' has invalid depth '$rdepth' (expected L0|L1|L2|L3)" >&2; DEPTH_FAIL=$((DEPTH_FAIL + 1)) ;;
    esac
  done < <(yq 'to_entries[] | "\(.key):\(.value)"' "$REGISTRY" 2>/dev/null || echo "")

  # Check every engine assert script carries a # DEPTH: Lx header matching the registry
  echo "── Checking engine assert DEPTH headers vs registry ──"
  for script in "$ENGINE_DIR"/asserts/*.sh; do
    if [ ! -f "$script" ]; then continue; fi
    type=$(basename "$script" .sh)
    header_depth=$(grep '^# DEPTH: L[0-3]' "$script" 2>/dev/null | head -1 | awk '{print $NF}')
    registry_depth=$(yq ".[\"$type\"]" "$REGISTRY" 2>/dev/null || echo "")
    if [ -z "$header_depth" ]; then
      echo "  FAIL: $type — missing # DEPTH: header" >&2
      DEPTH_FAIL=$((DEPTH_FAIL + 1))
    elif [ "$header_depth" != "$registry_depth" ]; then
      echo "  FAIL: $type — header=$header_depth registry=$registry_depth" >&2
      DEPTH_FAIL=$((DEPTH_FAIL + 1))
    fi
  done

  # ── Consumer registry depth validation (VAL-PLUGGABLE-035) ──
  # Validate that every consumer registry (if present for a project) contains
  # only L0-L3 depth values. Out-of-taxonomy values are rejected.
  echo "── Validating consumer registry depth values ──"
  declare -A _SEEN_CONSUMER_REGISTRIES=()
  for _cr_f in "${SCENARIOS[@]}"; do
    _cr_project_dir="$(find_project_dir "$_cr_f")"
    _consumer_reg="${_cr_project_dir}/chart-test/asserts/registry.yaml"
    if [ -f "$_consumer_reg" ] && [ -z "${_SEEN_CONSUMER_REGISTRIES[$_consumer_reg]:-}" ]; then
      _SEEN_CONSUMER_REGISTRIES["$_consumer_reg"]=1
      echo "   checking: $_consumer_reg"
      while IFS=':' read -r _crtype _crdepth; do
        _crtype="${_crtype// /}"
        _crdepth="${_crdepth// /}"
        [ -z "$_crtype" ] && continue
        case "$_crdepth" in
          L0|L1|L2|L3) ;;
          *) echo "  FAIL: consumer registry type '$_crtype' has invalid depth '$_crdepth' (expected L0|L1|L2|L3)" >&2; DEPTH_FAIL=$((DEPTH_FAIL + 1)) ;;
        esac
      done < <(yq 'to_entries[] | "\(.key):\(.value)"' "$_consumer_reg" 2>/dev/null || echo "")
    fi
  done

  # Check every scenario-referenced assert type has a declared depth in the
  # merged registry (consumer overlay over engine base).  Consumer registry
  # wins on conflict per the layering contract (VAL-PLUGGABLE-014).
  echo "── Checking scenario assert types vs merged depth registry ──"
  for f in "${SCENARIOS[@]}"; do
    rel="${f#"$ROOT_DIR"/}"
    _pd="$(find_project_dir "$f")"
    _creg="${_pd}/chart-test/asserts/registry.yaml"
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      [ "$t" = "null" ] && continue
      depth=""
      # Consumer registry wins when it declares the type (VAL-PLUGGABLE-011, -016)
      if [ -f "$_creg" ]; then
        depth=$(yq ".[\"$t\"]" "$_creg" 2>/dev/null || echo "")
        # Reject out-of-taxonomy consumer depths even when already validated
        # above — a null/empty consumer value means try the engine fallback
        case "$depth" in
          L0|L1|L2|L3) ;;
          *) depth="" ;;  # not a valid depth → fall through to engine registry
        esac
      fi
      # Engine fallback (VAL-PLUGGABLE-013, -018)
      if [ -z "$depth" ] || [ "$depth" = "null" ]; then
        depth=$(yq ".[\"$t\"]" "$REGISTRY" 2>/dev/null || echo "")
      fi
      if [ -z "$depth" ] || [ "$depth" = "null" ]; then
        echo "  FAIL: $rel references unregistered assert type '$t' (not found in engine or consumer registry)" >&2
        DEPTH_FAIL=$((DEPTH_FAIL + 1))
      fi
    done < <(yq '.asserts[].type' "$f" 2>/dev/null || true)
  done
fi

if [ "$DEPTH_FAIL" -gt 0 ]; then
  echo "  FAIL: $DEPTH_FAIL depth enforcement issue(s)"
  FAIL=$((FAIL + 1))
  FAILS+=("depth-enforcement")
else
  echo "  OK: depth enforcement passed"
fi

echo ""
echo "==> Sweep complete: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
  echo "==> Failed scenarios/checks:" >&2
  for f in "${FAILS[@]}"; do
    echo "    $f" >&2
  done
  exit 1
fi

exit 0
