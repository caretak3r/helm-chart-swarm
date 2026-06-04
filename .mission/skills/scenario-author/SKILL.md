---
name: scenario-author
description: Author scenario YAMLs and supporting fixtures for an integration (cert-manager, ingress controllers, gateway-API, mesh, policy), exercising the engine end-to-end on a local cluster, with helm-lint, jsonschema, and yamllint gates.
---

# scenario-author

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for scenario-author workers (Milestones 3-7 + F3.4 fixtures).

## Required Skills and Tools

- `bd` (beads) — resolve issue ID with `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id')` then claim with `bd update "$BD_ID" --claim` at start; close with `bd close "$BD_ID"` before handoff.
- `jsonschema` — validate every authored scenario against `engine/templates/scenario.schema.json`.
- `yamllint` — every authored YAML must pass the repo's `.yamllint` config.
- `helm lint` — run against `examples/sample-product-chart/chart` after touching any chart-adjacent file.
- `helm template` — dry-render scenarios with their preinstall items to verify the chart + values produce valid manifests.
- `kind` + `kubectl` — actually run each authored scenario via `bash engine/scripts/run-scenario.sh <scenario.yaml>` end-to-end.
- `openssl` — for F3.x certificate fixtures (generating self-signed CA, leaf certs, JKS/PKCS12 bundles).
- `agent-browser` — to verify the rendered dashboard surfaces the scenario card with all artifact links after the run.
- The integration's primer (`engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md`) — your scenarios must align with its documented variants.
- Mission boundaries from `{missionDir}/AGENTS.md`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, and `fulfills` from `{missionDir}/features.json`.
   - For each ID in `fulfills`, read the full assertion in `{missionDir}/validation-contract.md`. Each scenario you author must satisfy specific assertions; map them explicitly.
   - Read the matching integration primer (e.g. for F3.1 cert-manager: `engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md`). Variants in your scenarios MUST match variants in the primer.
   - For F3.x fixture features (F3.4 in particular): generate the required TLS material via `openssl` and bundle under `examples/sample-product-chart/chart-test/fixtures/certificates/`.

2. **Write/refresh the integration primer first if not yet present.**
   - If your milestone's primer (`<category>/<integration>.md`) is missing, you author it. Follow the H2 section discipline from the `primer-author` skill (Overview, Variants, How to apply, Assertions, Known gotchas, References).
   - The primer's Variants section enumerates 3-4 scenarios; the file names listed there become the scenarios you author next.

3. **Author each scenario YAML.**
   - Path: `examples/sample-product-chart/chart-test/scenarios/<integration>-<variant>.yaml` (e.g. `cert-manager-self-signed.yaml`).
   - Required top-level fields: `id`, `cluster.provider`, `cluster.preinstall[]` (when needed), `product.chart`, `product.release`, `product.namespace`, `asserts[]`.
   - Use `cluster.provider: kind` for local runs unless the variant explicitly tests minikube.
   - `product.set` inline overrides preferred over `product.values` file references — preserves the style of the 5 pre-mission scenarios.
   - `cluster.preinstall[]` uses `kind: helm` for chart-based preinstalls or `kind: raw_manifest` (with `path`) for arbitrary manifests.
   - `asserts[]` has at least 1 entry; use built-in `type` values: `pods-ready`, `service-reachable`, `helm-status-deployed`, `smoke-script`.
   - Validate immediately: `jsonschema -i <scenario.yaml> engine/templates/scenario.schema.json` exit 0.
   - Validate style: `yamllint <scenario.yaml>` exit 0.

4. **Generate fixtures (F3.x cert material in particular).**
   - For TLS: generate a self-signed root CA, a wildcard leaf, and (if needed) JKS/PKCS12 bundles using `openssl` and `keytool`. Place under `examples/sample-product-chart/chart-test/fixtures/certificates/`.
   - Add a `.gitignore` line for any private key material that should NOT be committed — but TLS test material with a hardcoded test passphrase IS committed for reproducibility (document this in a `README.md` adjacent to the fixtures).
   - Reference fixtures from scenarios via relative path: `path: ../fixtures/certificates/test-ca.crt`.

5. **Run each authored scenario end-to-end on kind.**
   - `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/<scenario>.yaml` — must exit 0.
   - Status PASS in the produced `reports/run-*/result.yaml`.
   - Verify `reports/run-*/artifacts/` contains scenario.yaml, applied-overrides.yaml, fixtures/, manifests/, versions.json.
   - Tear down: `kind get clusters` shows no `chart-test-swarm-*` entries afterwards.

6. **Dashboard sanity check (after the scenarios run).**
   - `bash engine/scripts/build-dashboard.sh`.
   - Open `reports/run-<latest>/dist/index.html` in `agent-browser`; verify each scenario card appears with its 5 artifact anchors and PASS status.
   - For variant grouping (M2 F2.2 already merged by M3+), verify the card collapses correctly under the integration header.

7. **Run worker-scoped gates.**
   - `jsonschema -i <each new scenario> engine/templates/scenario.schema.json`.
   - `yamllint <each new YAML>`.
   - `helm lint examples/sample-product-chart/chart`.
   - `helm template test-release examples/sample-product-chart/chart --values <(yq '.product.set // .product.values' <scenario.yaml>)` for inline value sanity (only when overrides are non-trivial).
   - `bats engine/scripts/tests/` (only the tests that exercise your scenarios; usually none new — but make sure existing engine bats tests still pass).

8. **Cluster + process hygiene at handoff.**
   - `kind get clusters` empty of `chart-test-swarm-*`.
   - `minikube profile list -o json | jq -r '.valid[].Name'` empty.
   - `docker ps --filter "name=chart-test-swarm-" --format '{{.Names}}'` empty.

9. **Commit and close.**
   - Commit on the worker branch.
   - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Authored F3.1 cert-manager primer refresh + 4 scenarios (self-signed CA issuer, Let's Encrypt staging, wildcard, JKS-PKCS12 secret). Each scenario ran end-to-end on a chart-test-swarm-cm<n> kind cluster (PASS); all 4 artifact bundles complete; dashboard cards verified in agent-browser; helm-lint and jsonschema both clean; clusters torn down at handoff.",
  "whatWasImplemented": "Refreshed engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md to use the H2 section discipline. Authored 4 scenario YAMLs under examples/sample-product-chart/chart-test/scenarios/: cert-manager-self-signed.yaml, cert-manager-letsencrypt-staging.yaml, cert-manager-wildcard.yaml, cert-manager-jks-pkcs12-secret.yaml. Each uses cluster.provider=kind, cluster.preinstall=[{kind:helm, release:cert-manager, chart:cert-manager, version:v1.15.0, namespace:cert-manager}], asserts=[pods-ready, service-reachable, helm-status-deployed]. Added 3 reusable fixtures (test-ca.crt, test-ca.key, README.md noting test-only material) under examples/sample-product-chart/chart-test/fixtures/certificates/.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "for f in examples/sample-product-chart/chart-test/scenarios/cert-manager-*.yaml; do jsonschema -i \"$f\" engine/templates/scenario.schema.json && echo OK $f; done", "exitCode": 0, "observation": "All 4 scenarios validate against schema."},
      {"command": "yamllint examples/sample-product-chart/chart-test/scenarios/cert-manager-*.yaml examples/sample-product-chart/chart-test/fixtures/certificates/*.yaml", "exitCode": 0, "observation": "Clean."},
      {"command": "helm lint examples/sample-product-chart/chart", "exitCode": 0, "observation": "1 chart linted, 0 chart(s) failed."},
      {"command": "for s in self-signed letsencrypt-staging wildcard jks-pkcs12-secret; do bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/cert-manager-$s.yaml; done", "exitCode": 0, "observation": "4 scenarios, all PASS. Aggregate runtime ~12 minutes (cert-manager install + ACME ~3m each)."},
      {"command": "for r in reports/run-*/result.yaml; do yq '.status' $r; done | sort -u", "exitCode": 0, "observation": "Only 'PASS' shows."},
      {"command": "bash engine/scripts/build-dashboard.sh", "exitCode": 0, "observation": "Dashboard built for 4 new runs + prior runs."},
      {"command": "kind get clusters | grep chart-test-swarm- || echo CLEAN", "exitCode": 0, "observation": "CLEAN — no residual clusters."}
    ],
    "interactiveChecks": [
      {"action": "Open reports/run-<latest>/dist/index.html in agent-browser; verify each of the 4 cert-manager cards shows PASS, with 5 artifact anchors (scenario, overrides, fixtures, manifests, versions) all resolving.", "observed": "All 4 cards green; 20 anchor clicks resolved successfully to the artifacts files."}
    ]
  },
  "tests": {
    "added": []
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- A scenario requires a `cluster.preinstall` kind beyond `helm` and `raw_manifest`.
- A variant requires a feature that the assertion runners don't support (e.g. mutual-TLS verification, which isn't a built-in assertion type).
- A run produces a FAIL that you cannot diagnose — flag it before claiming done.
- The chart `examples/sample-product-chart/chart` is missing a value path your scenario needs to override.
