# JWT Test Fixtures for Istio Ingress Gateway

Test-only RSA key material for RequestAuthentication / AuthorizationPolicy scenarios.
Generated with `openssl genrsa -out jwt-key.pem 2048`. These are hardcoded test keys
with no security sensitivity — committed intentionally for reproducible scenario runs.

## Files

| File          | Purpose |
|---------------|---------|
| `jwt-key.pem` | RSA 2048-bit private key (signing) |
| `jwt-key.pub` | RSA public key (PEM) |
| `jwks.json`   | JSON Web Key Set (JWKS) — embedded in RequestAuthentication for token verification |

## Issuer

All JWTs signed with this key should use issuer `https://test-issuer.local`.

## Usage in Scenarios

- The JWKS is embedded in a ConfigMap and mounted into test pods
- The `RequestAuthentication` references the JWKS via `jwksUri` (served from ConfigMap)
  or via inline `jwks` field
- Test pods sign JWTs using the private key with `jwt-cli` or a Python script

## Regeneration

```bash
openssl genrsa -out jwt-key.pem 2048
openssl rsa -in jwt-key.pem -pubout -out jwt-key.pub
# Then regenerate jwks.json with the Python script in regen.sh
```
