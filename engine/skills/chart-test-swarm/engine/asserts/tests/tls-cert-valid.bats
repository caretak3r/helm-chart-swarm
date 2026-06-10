#!/usr/bin/env bats
# tls-cert-valid.bats — Tests for the L3 behavioral assert tls-cert-valid.
# Covers SKIP (no TLS infrastructure), FAIL paths (expired cert, SAN mismatch,
# untrusted CA), and PASS path (valid cert with matching SAN).
#
# Non-live tests use stubbed kubectl and openssl to control cert verification.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)/../../.."
ASSERTS_DIR="$REPO_ROOT/engine/asserts"
PROJECT_DIR="$REPO_ROOT/examples/sample-product-chart"

setup() {
  TEST_TMPDIR="$(mktemp -d /tmp/tcv-bats-XXXXXX)"
  STUB_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH:/opt/homebrew/bin:/usr/local/bin"
  export RELEASE="test-release"
  export NAMESPACE="test-ns"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-/tmp/tcv-dummy}" 2>/dev/null || true
}

run_assert() {
  PROJECT_DIR="$PROJECT_DIR" run "$ASSERTS_DIR/tls-cert-valid.sh" "$1" "${2:-0}"
}

# ── Basic scenario fixture ───────────────────────────────────────────────
make_scenario() {
  local id="${1:-tls-test}"
  local port="${2:-443}"
  local tls_secret="${3:-test-release-tls}"
  local tls_host="${4:-test-release.test-ns.svc}"
  cat <<EOF
id: ${id}
name: TLS cert valid test
cluster:
  provider: kind
product:
  chart: chart
  release: test-release
  namespace: test-ns
asserts:
  - type: tls-cert-valid
    namespace: test-ns
    port: ${port}
    tls_secret: "${tls_secret}"
    tls_host: "${tls_host}"
EOF
}

# ── Fake cert data (short base64 strings — not real certs, test stubs only)
FAKE_CERT_B64="ZmFrZS1jZXJ0LWRhdGEtZm9yLXRlc3RpbmcK"
FAKE_KEY_B64="ZmFrZS1rZXktZGF0YS1mb3ItdGVzdGluZwo="
FAKE_CA_B64="ZmFrZS1jYS1kYXRhLWZvci10ZXN0aW5nCg=="

# ═══════════════════════════════════════════════════════════════════════
# SKIP: platform capability absent
# ═══════════════════════════════════════════════════════════════════════

@test "tls-cert-valid SKIPs when no TLS Secret exists" {
  cat > "$STUB_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get secret test-release-tls"*"jsonpath"*)
    echo '{"no-keys":"none"}'
    ;;
  *"get secret test-release-tls"*)
    exit 1
    ;;
  *"get secret"*)
    exit 1
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/tcv-skip-nosecret.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: SKIP"* ]]
}

@test "tls-cert-valid SKIPs non-failing (exit 0)" {
  cat > "$STUB_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get secret test-release-tls"*)
    exit 1
    ;;
  *"get secret"*)
    exit 1
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  local s="$TEST_TMPDIR/tcv-skip-exit.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: expired cert — checkend returns non-zero
# ═══════════════════════════════════════════════════════════════════════

@test "tls-cert-valid FAILs when cert is expired" {
  cat > "$STUB_BIN/kubectl" <<STUB
#!/usr/bin/env bash
FAKE_CERT="${FAKE_CERT_B64}"
FAKE_KEY="${FAKE_KEY_B64}"
case "\$*" in
  *"get secret test-release-tls"*"tls.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"tls.key"*)
    echo "\$FAKE_KEY"
    ;;
  *"get secret test-release-tls"*"ca.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"jsonpath='{.data}'"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*"-o jsonpath"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*)
    echo "TLS Secret exists"
    exit 0
    ;;
  *"run"*)
    echo "200"
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  # openssl: checkend fails (expired)
  cat > "$STUB_BIN/openssl" <<'STUB2'
#!/usr/bin/env bash
case "$*" in
  *"x509"*"-checkend"*)
    echo "Certificate will expire" >&2
    exit 1
    ;;
  *"x509"*"subjectAltName"*)
    echo "X509v3 Subject Alternative Name: DNS:test-release.test-ns.svc"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB2
  chmod +x "$STUB_BIN/openssl"

  local s="$TEST_TMPDIR/tcv-fail-expired.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: SAN mismatch — SAN does not contain the configured host
# ═══════════════════════════════════════════════════════════════════════

@test "tls-cert-valid FAILs when SAN does not match host" {
  cat > "$STUB_BIN/kubectl" <<STUB
#!/usr/bin/env bash
FAKE_CERT="${FAKE_CERT_B64}"
FAKE_KEY="${FAKE_KEY_B64}"
case "\$*" in
  *"get secret test-release-tls"*"tls.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"tls.key"*)
    echo "\$FAKE_KEY"
    ;;
  *"get secret test-release-tls"*"ca.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"jsonpath='{.data}'"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*"-o jsonpath"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*)
    echo "TLS Secret exists"
    exit 0
    ;;
  *"run"*)
    echo "200"
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  # openssl: checkend passes, but SAN is wrong
  cat > "$STUB_BIN/openssl" <<'STUB2'
#!/usr/bin/env bash
case "$*" in
  *"x509"*"-checkend"*)
    echo "Certificate will not expire"
    exit 0
    ;;
  *"x509"*"subjectAltName"*)
    echo "X509v3 Subject Alternative Name: DNS:wrong.example.com"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB2
  chmod +x "$STUB_BIN/openssl"

  local s="$TEST_TMPDIR/tcv-fail-san.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
  [[ "$output" == *"SAN"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# FAIL: untrusted CA — curl returns TLS error
# ═══════════════════════════════════════════════════════════════════════

@test "tls-cert-valid FAILs when CA is untrusted (curl verify fails)" {
  cat > "$STUB_BIN/kubectl" <<STUB
#!/usr/bin/env bash
FAKE_CERT="${FAKE_CERT_B64}"
FAKE_KEY="${FAKE_KEY_B64}"
case "\$*" in
  *"get secret test-release-tls"*"tls.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"tls.key"*)
    echo "\$FAKE_KEY"
    ;;
  *"get secret test-release-tls"*"ca.crt"*)
    echo ""
    ;;
  *"get secret test-release-tls"*"jsonpath='{.data}'"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*"-o jsonpath"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy"}'
    ;;
  *"get secret test-release-tls"*)
    echo "TLS Secret exists"
    exit 0
    ;;
  *"run"*)
    echo "60 60"
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  # openssl: checkend passes (cert itself is not expired)
  cat > "$STUB_BIN/openssl" <<'STUB2'
#!/usr/bin/env bash
case "$*" in
  *"x509"*"-checkend"*)
    echo "Certificate will not expire"
    exit 0
    ;;
  *"x509"*"subjectAltName"*)
    echo "X509v3 Subject Alternative Name: DNS:test-release.test-ns.svc"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB2
  chmod +x "$STUB_BIN/openssl"

  local s="$TEST_TMPDIR/tcv-fail-untrusted.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -ne 0 ]
  [[ "$output" == *"ASSERTION_RESULT: FAIL"* ]]
}

# ═══════════════════════════════════════════════════════════════════════
# PASS: valid cert, SAN matches, CA trusted
# ═══════════════════════════════════════════════════════════════════════

@test "tls-cert-valid PASSes when valid cert served with matching SAN" {
  cat > "$STUB_BIN/kubectl" <<STUB
#!/usr/bin/env bash
FAKE_CERT="${FAKE_CERT_B64}"
FAKE_KEY="${FAKE_KEY_B64}"
case "\$*" in
  *"get secret test-release-tls"*"tls.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"tls.key"*)
    echo "\$FAKE_KEY"
    ;;
  *"get secret test-release-tls"*"ca.crt"*)
    echo "\$FAKE_CERT"
    ;;
  *"get secret test-release-tls"*"jsonpath='{.data}'"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy","ca.crt":"dummy"}'
    ;;
  *"get secret test-release-tls"*"-o jsonpath"*)
    echo '{"tls.crt":"dummy","tls.key":"dummy","ca.crt":"dummy"}'
    ;;
  *"get secret test-release-tls"*)
    echo "TLS Secret exists"
    exit 0
    ;;
  *"run"*)
    echo "200"
    ;;
  *"get svc"*)
    echo "10.0.0.1"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_BIN/kubectl"

  # openssl: checkend passes, SAN matches
  cat > "$STUB_BIN/openssl" <<'STUB2'
#!/usr/bin/env bash
case "$*" in
  *"x509"*"-checkend"*)
    echo "Certificate will not expire"
    exit 0
    ;;
  *"x509"*"subjectAltName"*)
    echo "X509v3 Subject Alternative Name: DNS:test-release.test-ns.svc"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB2
  chmod +x "$STUB_BIN/openssl"

  local s="$TEST_TMPDIR/tcv-pass.yaml"
  make_scenario > "$s"
  run_assert "$s"
  [ $status -eq 0 ]
  [[ "$output" == *"ASSERTION_RESULT: PASS"* ]]
}
