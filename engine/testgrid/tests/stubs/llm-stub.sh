#!/usr/bin/env bash
# LLM stub for testing chart-test-swarm generate subcommands.
#
# Usage:
#   CTS_LLM_CMD="bash tests/stubs/llm-stub.sh" \
#     LLM_STUB_MODE=valid \
#     chart-test-swarm generate author "some description"
#
# Modes (via LLM_STUB_MODE):
#   valid         Emit a schema-valid scenario YAML.
#   invalid-yaml  Emit unparseable YAML (mixed garbage).
#   schema-fail   Emit parseable YAML that fails schema validation
#                 (cluster.provider = bogus-backend).
#   invalid-yaml-schema-fail  First emit invalid YAML, then (on retry) schema-fail.
#
# Multi-invocation plan (via LLM_STUB_PLAN):
#   LLM_STUB_PLAN="fail,fail,pass"  Emit invalid YAML on calls 1-2, valid on call 3.
#   Each token: pass=valid, fail=invalid-yaml, schema-fail=schema-fail.
#
# Counter file (via LLM_STUB_COUNT_FILE): records invocation count.
#
# All invocations are logged to stderr (key:value format) for test assertions.

set -euo pipefail

# ── increment invocation counter ───────────────────────────────────────────
COUNT_FILE="${LLM_STUB_COUNT_FILE:-/tmp/llm-stub-count.txt}"
if [[ -f "$COUNT_FILE" ]]; then
  COUNT=$(cat "$COUNT_FILE")
else
  COUNT=0
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNT_FILE"

# ── log the invocation to stderr ──────────────────────────────────────────
echo "LLM_STUB invocation=$COUNT" >&2

# Read description from stdin (passed via subprocess)
DESCRIPTION="$(cat)"
echo "LLM_STUB description=$DESCRIPTION" >&2

# ── determine which mode/plan to use ───────────────────────────────────────
MODE="${LLM_STUB_MODE:-valid}"

# If LLM_STUB_PLAN is set, override MODE per invocation
if [[ -n "${LLM_STUB_PLAN:-}" ]]; then
  # Split plan by comma: e.g. "fail,fail,pass"
  IFS=',' read -ra TOKENS <<< "$LLM_STUB_PLAN"
  IDX=$((COUNT - 1))
  if [[ $IDX -ge ${#TOKENS[@]} ]]; then
    # If we've exceeded the plan, use the last token
    IDX=$((${#TOKENS[@]} - 1))
  fi
  TOKEN="${TOKENS[$IDX]}"
  case "$TOKEN" in
    pass)        MODE=valid ;;
    fail)        MODE=invalid-yaml ;;
    schema-fail) MODE=schema-fail ;;
    *)           MODE=valid ;;
  esac
  echo "LLM_STUB mode=$MODE (plan token: $TOKEN)" >&2
else
  echo "LLM_STUB mode=$MODE" >&2
fi

# ── emit output ────────────────────────────────────────────────────────────
case "$MODE" in
  valid)
    cat <<'EOF'
---
id: llm-generated-scenario
name: LLM-generated cert-manager + istio scenario
description: Scenario authored by LLM stub for cert-manager with self-signed CA and istio strict mTLS
labels:
  generated: "true"
  source: llm-stub
cluster:
  provider: kind
  k8s_version: v1.30.0
  preinstall:
    - kind: helm
      chart: jetstack/cert-manager
      version: v1.15.0
      release: cert-manager
      namespace: cert-manager
      repo:
        name: jetstack
        url: https://charts.jetstack.io
      values:
        installCRDs: "true"
      wait: pods-ready
product:
  chart: chart
  release: sample
  namespace: sample
  set:
    replicaCount: "1"
    service.type: ClusterIP
    tls.enabled: "true"
    tls.secretName: sample-tls
  subcharts:
    cert-manager: "v1.15.0"
asserts:
  - type: pods-ready
    namespace: sample
  - type: service-reachable
    service: sample.sample
    port: 443
    path: /healthz
    expect: 200
tags:
  - pr-subset
  - llm-generated
mechanisms:
  - certificate:self-signed-ca
  - mesh:istio
generated_by:
  by: llm-stub
  at: "2026-06-01T00:00:00Z"
EOF
    ;;

  invalid-yaml)
    cat <<'EOF'
---INVALID-START::
this is not valid yaml :: @@@ garbage
  - [unclosed bracket
cluster:
  provider: kind
    bad::indent: !!str nonsense
EOF
    ;;

  schema-fail)
    cat <<'EOF'
---
id: schema-failing
name: Schema-failing scenario
description: This YAML parses but fails schema validation
cluster:
  provider: bogus-backend
  k8s_version: v1.30.0
product:
  chart: chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
generated_by:
  by: llm-stub
  at: "2026-06-01T00:00:00Z"
EOF
    ;;

  invalid-yaml-schema-fail)
    if [[ $COUNT -eq 1 ]]; then
      cat <<'EOF'
---INVALID-START::
this is not valid yaml :: @@@ garbage
EOF
    else
      cat <<'EOF'
---
id: schema-failing
cluster:
  provider: bogus-backend
product:
  chart: chart
  release: sample
  namespace: sample
asserts:
  - type: pods-ready
    namespace: sample
EOF
    fi
    ;;

  *)
    echo "LLM_STUB unknown mode=$MODE" >&2
    exit 1
    ;;
esac
