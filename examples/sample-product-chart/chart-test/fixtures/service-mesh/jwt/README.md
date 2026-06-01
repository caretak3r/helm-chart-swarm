# JWT Test Fixtures for Istio Ingress Gateway

Test-only JWKS reference for RequestAuthentication / AuthorizationPolicy scenarios.
The RSA private key is NO LONGER committed — it is generated at runtime by the
assertion scripts (`istio-ingress-gateway-jwt.sh` and
`istio-ingress-gateway-request-authentication.sh`) using `openssl genpkey`.

## Files

| File          | Purpose |
|---------------|---------|
| `jwks.json`   | Reference JSON Web Key Set (JWKS) — illustrates the expected format. |
| `jwt-key.pub` | Reference RSA public key (PEM) from the original test key. |

## Issuer

All JWTs signed with the runtime-generated key use issuer `https://test-issuer.local`.

## Usage in Scenarios

The assertion scripts generate ephemeral RSA 2048-bit keys and JWKS at runtime:
1. `openssl genpkey -algorithm RSA -out <tmp>/jwt-key.pem -pkeyopt rsa_keygen_bits:2048`
2. Extract public key: `openssl rsa -in <tmp>/jwt-key.pem -pubout -out <tmp>/jwt-key.pub`
3. Generate JWKS from the public key via Python
4. Sign JWTs with the ephemeral private key
5. Configure `RequestAuthentication` with the generated JWKS

## Regeneration

The committed `jwks.json` and `jwt-key.pub` are reference artifacts only.
Runtime keys are generated fresh on every scenario run — no regeneration needed.

