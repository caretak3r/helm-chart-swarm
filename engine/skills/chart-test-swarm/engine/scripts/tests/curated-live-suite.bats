#!/usr/bin/env bats
# bats file_tags: curated-live
# Validates the curated-live suite definition (f17-1).
#
# Setup: PROJECT_DIR points to the sample-product-chart.
# These tests do NOT spin up clusters — they only validate the suite
# definition and scenario metadata via yq / jq / dispatch-swarm --dry-run.

setup() {
  PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/../../../examples/sample-product-chart" && pwd)"
  CONFIG="$PROJECT_DIR/chart-test-swarm.yaml"
  SCEN_DIR="$PROJECT_DIR/chart-test/scenarios"
  ENGINE_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DISPATCH="$ENGINE_DIR/dispatch-swarm.sh"
}

# ---------- VAL-E2E-001: curated-live suite exists and resolves to exactly 18 members ----------

@test "curated-live suite is defined in chart-test-swarm.yaml" {
  yq -e '.suites."curated-live"' "$CONFIG"
}

@test "curated-live suite has tag_filter containing curated-live" {
  filter=$(yq -o=json '.suites."curated-live".tag_filter // []' "$CONFIG")
  echo "$filter" | jq -e 'index("curated-live") != null'
}

@test "curated-live suite resolves to exactly 18 scenarios via dispatch --dry-run" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]
  # Extract the "matched N scenario(s)" line
  echo "$output" | grep -q "curated-live.*matched 18 scenario"
}

@test "curated-live suite resolves all 12 agreed integration scenarios" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]

  # The 12 integration scenario IDs
  local integration_ids=(
    tls-cert-manager-self-signed
    tls-manual-secret
    tls-mounted-projected
    service-mesh-istio-sidecar-live
    service-mesh-istio-ambient-live
    service-mesh-istio-ingress-gateway-basic
    service-mesh-istio-service-mesh-strict-mtls
    service-mesh-linkerd-live
    networking-traefik-ingress
    networking-kong-ingress
    networking-metallb-loadbalancer
    gateway-api-istio-gateway-api-basic
  )

  for id in "${integration_ids[@]}"; do
    echo "$output" | grep -q "$id" || {
      echo "FAIL: integration scenario '$id' not in curated-live resolution"
      return 1
    }
  done
}

@test "curated-live suite resolves all 4 capability test scenarios" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]

  local capability_ids=(
    labels-on
    annotations-on
    scheme-https-only
    rbac-on
  )

  for id in "${capability_ids[@]}"; do
    echo "$output" | grep -q "$id" || {
      echo "FAIL: capability scenario '$id' not in curated-live resolution"
      return 1
    }
  done
}

@test "curated-live suite resolves both gap-probe scenarios" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]

  local gap_ids=(
    ingress-controllers-contour-basic-httpproxy
    policy-opa-gatekeeper-required-labels
  )

  for id in "${gap_ids[@]}"; do
    echo "$output" | grep -q "$id" || {
      echo "FAIL: gap-probe scenario '$id' not in curated-live resolution"
      return 1
    }
  done
}

# ---------- VAL-E2E-013: every non-cloud curated member has tier in {live, capability} ----------

@test "every curated-live integration scenario has tier=live" {
  local integration_files=(
    "$SCEN_DIR/certificates/tls-cert-manager-self-signed.yaml"
    "$SCEN_DIR/certificates/tls-manual-secret.yaml"
    "$SCEN_DIR/certificates/tls-mounted-projected.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-sidecar-live.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-ambient-live.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-ingress-gateway-basic.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-service-mesh-strict-mtls.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-linkerd-live.yaml"
    "$SCEN_DIR/networking/networking-traefik-ingress.yaml"
    "$SCEN_DIR/networking/networking-kong-ingress.yaml"
    "$SCEN_DIR/networking/networking-metallb-loadbalancer.yaml"
    "$SCEN_DIR/gateway-api/gateway-api-istio-gateway-api-basic.yaml"
  )

  for f in "${integration_files[@]}"; do
    tier=$(yq '.tier' "$f")
    [ "$tier" = "live" ] || {
      echo "FAIL: $f has tier='$tier', expected 'live'"
      return 1
    }
  done
}

@test "every curated-live capability scenario has tier=capability" {
  local capability_files=(
    "$SCEN_DIR/capability/labels-on.yaml"
    "$SCEN_DIR/capability/annotations-on.yaml"
    "$SCEN_DIR/capability/scheme-https-only.yaml"
    "$SCEN_DIR/capability/rbac-on.yaml"
  )

  for f in "${capability_files[@]}"; do
    tier=$(yq '.tier' "$f")
    [ "$tier" = "capability" ] || {
      echo "FAIL: $f has tier='$tier', expected 'capability'"
      return 1
    }
  done
}

@test "every curated-live gap-probe scenario has tier=live" {
  local gap_files=(
    "$SCEN_DIR/networking/ingress-controllers-contour-basic-httpproxy.yaml"
    "$SCEN_DIR/policy/policy-opa-gatekeeper-required-labels.yaml"
  )

  for f in "${gap_files[@]}"; do
    tier=$(yq '.tier' "$f")
    [ "$tier" = "live" ] || {
      echo "FAIL: $f has tier='$tier', expected 'live'"
      return 1
    }
  done
}

@test "no curated-live member has tier=authored-only" {
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]

  # Extract all resolved file paths from dry-run output
  local files
  files=$(echo "$output" | grep -oE '/[^ ]+\.yaml' | sort -u)

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    tier=$(yq '.tier' "$f")
    [ "$tier" != "authored-only" ] || {
      echo "FAIL: curated-live member '$f' has tier=authored-only (should be live or capability)"
      return 1
    }
  done <<< "$files"
}

@test "every curated-live scenario carries the curated-live tag" {
  local all_files=(
    "$SCEN_DIR/certificates/tls-cert-manager-self-signed.yaml"
    "$SCEN_DIR/certificates/tls-manual-secret.yaml"
    "$SCEN_DIR/certificates/tls-mounted-projected.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-sidecar-live.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-ambient-live.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-ingress-gateway-basic.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-istio-service-mesh-strict-mtls.yaml"
    "$SCEN_DIR/service-mesh/service-mesh-linkerd-live.yaml"
    "$SCEN_DIR/networking/networking-traefik-ingress.yaml"
    "$SCEN_DIR/networking/networking-kong-ingress.yaml"
    "$SCEN_DIR/networking/networking-metallb-loadbalancer.yaml"
    "$SCEN_DIR/gateway-api/gateway-api-istio-gateway-api-basic.yaml"
    "$SCEN_DIR/capability/labels-on.yaml"
    "$SCEN_DIR/capability/annotations-on.yaml"
    "$SCEN_DIR/capability/scheme-https-only.yaml"
    "$SCEN_DIR/capability/rbac-on.yaml"
    "$SCEN_DIR/networking/ingress-controllers-contour-basic-httpproxy.yaml"
    "$SCEN_DIR/policy/policy-opa-gatekeeper-required-labels.yaml"
  )

  for f in "${all_files[@]}"; do
    tags=$(yq -o=json '.tags // []' "$f")
    echo "$tags" | jq -e 'index("curated-live") != null' >/dev/null || {
      echo "FAIL: $f does not have 'curated-live' tag. tags=$tags"
      return 1
    }
  done
}

@test "cloud-authored scenarios are excluded from curated-live dispatch by default" {
  # Verify that no authored-only scenario appears in the curated-live dry-run
  run bash "$DISPATCH" "$PROJECT_DIR" curated-live 1 test-dry --dry-run
  [ "$status" -eq 0 ]

  # List of known cloud-authored scenario IDs that should NOT appear
  local cloud_ids=(
    cloud-native-eks-alb-ingress
    cloud-native-eks-irsa
    cloud-native-aks-agic
    cloud-native-gke-iap
    networking-aws-lbc-alb-ingress
    networking-azure-lb-agic
    networking-gcp-lb-external
  )

  for id in "${cloud_ids[@]}"; do
    if echo "$output" | grep -q "$id"; then
      echo "FAIL: cloud-authored '$id' should not appear in curated-live dispatch"
      return 1
    fi
  done
}
