# Review Pass 2 — Final Sweep

## Summary

The contract is structurally sound with 263 assertions distributed across 11 areas
(40 + 24 + 23 + 22 + 20 + 22 + 20 + 19 + 23 + 21 + 29 = 263, all IDs contiguous).
Coverage of the 11 architectural risk hot-spots is materially complete; the
critical hot-spots (hardcoded kind backends, helm-only apply, schema
`additionalProperties:false`, defunct envoy-gateway URL, mypy stubs, reports
schema drift) are all directly validated by at least one assertion. Cross-area
flows (CLI ↔ engine ↔ dashboard ↔ LLM) are well integrated.

That said, two real cross-cutting consistency defects in the contract were
discovered during this pass. First, scenario file paths are inconsistent: the
ENGINE/CERT/INGRESS/GW assertions use `examples/sample-product-chart/chart-test/scenarios/`
(which matches the actual repo state and the project's `chart-test-swarm.yaml`
config `scenarios_dir: chart-test/scenarios`), while MESH/POLICY/CLOUD/CROSS
assertions use the bare `examples/sample-product-chart/scenarios/`. Second,
field naming is split: ENGINE/CERT/INGRESS/GW use the actual schema field names
(`cluster.provider`, `cluster.name`), while MESH/POLICY/CLOUD/CLI/LLM/DASH use
an anticipated-but-uncommitted rename (`backend.kind`, `backend.name`).
These inconsistencies will cause validators to either run against non-existent
paths or assert against schema fields that do not exist in
`engine/templates/scenario.schema.json`. Verdict: **NEEDS-CHANGES** on those
quality issues, with 5 small new assertions proposed to close residual gaps.

## Sweep 1: Final Gap Hunt — Proposed New Assertions

### VAL-ENGINE-041: Inline `product.set` style is preserved on the 5 pre-mission scenarios
After the full mission run completes, the five scenarios that used inline
`product.set: { ... }` style at mission start (e.g.
`examples/sample-product-chart/chart-test/scenarios/customer-A-istio.yaml`,
`with-cert-manager.yaml`, `customer-B-gatekeeper.yaml`,
`subchart-postgres-internal.yaml`, `minimal.yaml`) still parse as inline
`product.set` objects (NOT migrated to a `values:` file reference) unless a
documented F-ID explicitly converted them. `yq '.product.set | type'` on each
of those original files returns `!!map` and `yq '.product.values' < file`
returns null (or absent), preserving the original authoring style.
Tool: yq
Evidence: terminal-output (`for f in customer-A-istio.yaml with-cert-manager.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml minimal.yaml; do yq '.product.set | type' examples/sample-product-chart/chart-test/scenarios/$f; done` outputs `!!map` five times), terminal-output (`yq '.product.values' examples/sample-product-chart/chart-test/scenarios/{customer-A-istio,with-cert-manager,customer-B-gatekeeper,subchart-postgres-internal,minimal}.yaml` returns `null` for each)
Rationale: Architecture Section 8 hot-spot #11 explicitly calls this out as a
trap workers might fall into; no existing assertion directly checks the inline
style is preserved across mission edits.

### VAL-LLM-022: `generate explore` rejects mid-iteration scenarios that fail prefix/schema validation before any cluster spin-up
With `CTS_LLM_CMD` set to a stub that on iteration 1 proposes a schema-valid
scenario (PASS), and on iteration 2 proposes a scenario with `cluster.name:
escaped-cluster` (no `chart-test-swarm-` prefix), running `chart-test-swarm
generate explore --chart <path> --integrations <list> --max-iterations 3`
results in: (a) iteration 1 runs to completion creating a single
`chart-test-swarm-*` kind cluster (verifiable via `kind get clusters`
mid-iteration), (b) iteration 2 fails validation BEFORE any cluster work is
attempted (verifiable: no `kind create cluster` / `minikube start` invocation
recorded by the PATH stub for iteration 2), (c) the iteration-2 entry in the
explore summary records the rejection with the offending name + the schema
error message (NOT a generic `LLM_ERROR`), (d) the CLI continues to iteration
3 or exits cleanly with a non-zero status naming the violation. Pass requires:
no `escaped-cluster` cluster ever appears in `kind get clusters` or
`minikube profile list`, iteration-1 cluster IS torn down, summary records
the rejection reason.
Tool: pytest
Evidence: exit-code, file(reports/explore-*/summary.json) — iteration 2 entry contains `error: cluster.name pattern violation` (or equivalent), command-output (`kind get clusters | grep escaped-cluster` returns empty), command-output (PATH stub log shows zero `kind create cluster` invocations correlated with iteration 2)
Rationale: VAL-CLI-014 covers prefix enforcement for `run` and VAL-LLM-018
covers `generate author` schema retries, but neither asserts the
`explore`-mode mid-iteration rejection path. This is the most likely place
for a prefix-violating cluster to leak through, because the LLM is in the
generator loop and a worker may forget to re-validate per-iteration output.

### VAL-CLI-024: `list integrations` enumerates all six expected category subdirectories
Running `chart-test-swarm list integrations` against a populated production
integrations tree (post-F1.3 reorg) emits at least one line per the six
expected categories: `certificates`, `ingress-controllers`, `gateway-api`,
`service-mesh`, `policy`, `cloud-native`. The output is sorted deterministically,
and no spurious top-level categories (e.g. legacy unmoved primers) appear.
Pass requires: all six categories present in the output AND no top-level
categories outside the expected set.
Tool: bash
Evidence: terminal-output (`chart-test-swarm list integrations | awk '{print $1}' | sort -u` produces the exact set `{certificates, ingress-controllers, gateway-api, service-mesh, policy, cloud-native}`)
Rationale: VAL-CLI-012 verifies the listing mechanic against a synthetic two-category
fixture, but does not assert that the production tree's six categories are
discoverable. A worker who forgets to add `cloud-native/` to the walked
directories would silently break the dashboard's authored-only filter.

### VAL-CROSS-030: Pre-F1.2 scenarios (no raw_manifest, only helm preinstall items) continue to validate without modification
A scenario authored prior to F1.2 (canonical example: the pre-mission
`examples/sample-product-chart/chart-test-swarm/scenarios/customer-A-istio.yaml`
shape — only helm preinstall items, `additionalProperties:false` on the helm
preinstall shape, no `kind:` discriminator) MUST continue to validate against
the post-F1.2 schema (`engine/templates/scenario.schema.json`) with exit 0.
Equivalently: the relaxation introduced for `raw_manifest` MUST NOT regress
backward compatibility for existing helm-only scenarios. Pass requires:
running `jsonschema -i <each pre-mission scenario> engine/templates/scenario.schema.json`
for each of the five pre-mission scenarios returns exit 0 AND emits no
warnings about additional properties or unknown discriminators.
Tool: jsonschema
Evidence: terminal-output (`for f in customer-A-istio.yaml with-cert-manager.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml minimal.yaml; do jsonschema -i "examples/sample-product-chart/chart-test/scenarios/$f" engine/templates/scenario.schema.json && echo OK $f; done` outputs `OK` five times)
Rationale: VAL-ENGINE-006 covers the no-regression case in general terms
(`A pre-existing scenario with a kind: helm preinstall item still validates 0`),
but does not enumerate the actual pre-mission scenarios. This makes the
backward-compat guarantee testable against the specific files at risk.

### VAL-DASH-025: Dashboard renders a non-crashing card when `result.yaml` lists zero scenarios
Build the dashboard against a `reports/` containing one valid-shape run whose
`result.yaml` has `scenarios: []` (empty list — e.g. a dispatch invocation
whose suite filter matched zero scenarios). The build MUST exit 0; the
rendered `reports/dist/index.html` MUST contain a row for that run id whose
scenario count shows `0` (NOT a missing or `null` cell) and that has no
scenario-card subtree. The run-detail page (or details block) for that run
MUST render an explicit "0 scenarios in this run" placeholder text node, not
crash and not silently omit the run. Pass requires: exit 0 + run id visible
in index + explicit zero-count text.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr td:contains("run-<empty>") td.scenario-count`) shows `0`, dom-text(`details[data-run-id="run-<empty>"] .empty-state`) contains "0 scenarios" or equivalent, terminal-output (`bash engine/scripts/build-dashboard.sh; echo "exit=$?"` shows `exit=0`)
Rationale: VAL-DASH-021 covers the corrupt-result.yaml path, VAL-DASH-016
covers the orphan-dir path, but neither covers the edge case where the
result.yaml is valid YAML with an empty scenarios array. This is the most
likely "valid but unexpected" shape to hit when suite filters or
dry-runs are combined and would otherwise cause a silent template loop bug.

## Sweep 2: Consistency + Quality Issues Found

- **Issue 1 (HIGH): Scenario path inconsistency across areas.** ENGINE/CERT/INGRESS/GW
  assertions use `examples/sample-product-chart/chart-test/scenarios/`
  (matches the actual repo + `examples/sample-product-chart/chart-test-swarm.yaml`'s
  `scenarios_dir: chart-test/scenarios`). MESH/POLICY/CLOUD/CROSS-012 assertions
  use the bare `examples/sample-product-chart/scenarios/` form. Specifically affected
  assertions: VAL-MESH-005, VAL-MESH-006, VAL-MESH-007, VAL-MESH-021, VAL-POLICY-004,
  VAL-POLICY-005, VAL-CLOUD-004, VAL-CLOUD-005, VAL-CLOUD-012, VAL-CLOUD-015,
  VAL-CLOUD-017, VAL-CLOUD-019, VAL-CROSS-012, VAL-CLI-007. Recommend reconciling
  all to `chart-test/scenarios/` since the actual repo state and project config
  agree on that path; alternatively, update the architecture.md Section 2 + 3.6
  diagrams (which currently show the bare-`scenarios/` form) to match
  `chart-test/scenarios/`.

- **Issue 2 (HIGH): Schema field-name inconsistency: `cluster.provider`/`cluster.name`
  vs `backend.kind`/`backend.name`.** The actual schema
  (`engine/templates/scenario.schema.json`) uses `cluster.provider` (verified
  in repo) and does not currently include any `backend.*` namespace at all.
  VAL-ENGINE-005 uses `cluster.provider` AND `cluster.name (or equivalent
  backend-name field, per F1.1 schema spec)`. F1.1 in mission.md commits only
  to extending the enum and enforcing the prefix; it does not commit to a
  rename. But assertions VAL-DASH-011, VAL-DASH-013, VAL-MESH-005, VAL-MESH-006,
  VAL-POLICY-004, VAL-POLICY-005, VAL-CLOUD-005, VAL-CLOUD-006, VAL-CLOUD-007,
  VAL-CLOUD-011, VAL-CLOUD-013, VAL-CLOUD-015, VAL-CLI-014, VAL-LLM-004,
  VAL-LLM-018 all assume the post-rename `backend.kind`/`backend.name` form.
  This will break validators against the actual schema. Recommend either
  (a) pinning F1.1 to also rename `cluster.provider` → `backend.kind` and
  adding `backend.name` as a top-level required field, then updating the
  ENGINE/CERT/INGRESS/GW assertions to match; OR (b) reverting all
  `backend.kind`/`backend.name` references to the actual `cluster.provider`/
  `cluster.name`-or-equivalent form.

- **Issue 3 (MEDIUM): VAL-MESH-019 lists only 4 `versions.json` keys (missing
  `minikube`).** The F1.4 contract (VAL-ENGINE-015) requires 5 keys: `helm,
  kubectl, kind, minikube, k8s_server`. VAL-CROSS-013 also lists 5. But
  VAL-MESH-019 says "versions.json contains keys helm, kubectl, kind, k8s_server"
  — missing `minikube`. Recommend updating VAL-MESH-019's Evidence to include
  the `minikube` key.

- **Issue 4 (LOW): VAL-DASH-022 / VAL-DASH-023 / VAL-CLI-022 anchor to specific
  source lines/paths.** These assertions reference paths such as
  `engine/testgrid/src/testgrid/collect.py line 25` and
  `engine/cli/src/chart_test_swarm/forward.py` that are implementation-detail
  anchors. The behavioral side of each assertion is sound (synthetic input +
  observed rendered output), but the line-number/path references will go stale
  if the implementation reshuffles files. Recommend keeping the behavioral
  observation and softening the path reference to "in the testgrid collector
  module" / "in the CLI forward module".

- **Issue 5 (LOW): VAL-CROSS-013 evidence overlaps VAL-ENGINE-013/014/015.**
  Cross-area assertion asserts the artifact bundle exists for every successful
  run; engine-area assertions assert the same for individual runs. This is
  intentional aggregation and not a duplicate (the cross-area one walks ALL
  runs), but the contract reader should be aware they overlap. No action
  needed.

## Sweep 3: Duplicates and Contradictions

- **No exact duplicates found.** The repeated `helm lint` assertions
  (VAL-CERT-019, VAL-INGRESS-020, VAL-GW-019, VAL-MESH-020, VAL-POLICY-019)
  share text but are correctly area-scoped milestone gates and pass-through
  to the same `helm lint examples/sample-product-chart/chart` invocation; this
  is intentional repetition for per-milestone scrutiny, not a duplicate.
- **No ID gaps found.** All area sequences are contiguous:
  ENGINE 001–040, DASH 001–024, CERT 001–023, INGRESS 001–022, GW 001–020,
  MESH 001–022, POLICY 001–020, CLOUD 001–019, CLI 001–023, LLM 001–021,
  CROSS 001–029.
- **No outright contradictions found.** The closest is VAL-MESH-019 vs
  VAL-ENGINE-015 / VAL-CROSS-013 (4 keys vs 5 keys in `versions.json`); this
  is a quality bug rather than a contradiction since VAL-MESH-019 is silently
  permissive — it asserts a subset is present, which would be satisfied even
  if the full 5 keys are present. Still recommended to align (see Issue 3
  above).
- **Near-duplicate worth noting:** VAL-ENGINE-023 + VAL-ENGINE-024 (orphan
  cluster/container cleanup, engine area) and VAL-CROSS-016 + VAL-CROSS-017
  (orphan cluster/container cleanup, cross area). The engine versions stress
  the failure-path branch with deliberately-failed scenarios; the cross-area
  versions sweep across all integration categories. Together they cover both
  axes; no consolidation needed.

## Sweep 4: Risk Hot-Spot Coverage

| Hot-Spot | Covered By | Status |
|---|---|---|
| 1. Hardcoded kind backends (cluster-up/down.sh) | VAL-ENGINE-001, VAL-ENGINE-003, VAL-ENGINE-004, VAL-ENGINE-022, VAL-CROSS-019 | ✓ |
| 2. Helm-only apply (apply-scenario.sh) | VAL-ENGINE-006, VAL-ENGINE-008, VAL-CERT-012, VAL-GW-002, VAL-GW-016 | ✓ |
| 3. Schema `additionalProperties: false` | VAL-ENGINE-006, VAL-ENGINE-007 | ✓ |
| 4. Dispatch swarm snapshot drops product/asserts | VAL-ENGINE-031 | ✓ |
| 5. build-dashboard.sh single-scenario / run-* shape | VAL-DASH-014, VAL-DASH-015, VAL-DASH-016, VAL-DASH-021 | ✓ |
| 6. Envoy-gateway primer defunct repo URL | VAL-ENGINE-009, VAL-ENGINE-010, VAL-GW-001 | ✓ |
| 7. mypy missing stubs (types-PyYAML, jinja2) | VAL-ENGINE-020 | ✓ |
| 8. Yamllint/shellcheck style errors (clean as you go) | VAL-ENGINE-021, VAL-MESH-021, VAL-CLOUD-017, VAL-CROSS-022 (transitive via commands.lint) | ✓ |
| 9. Reports schema drift (legacy vs rich shape) | VAL-DASH-006, VAL-DASH-014, VAL-DASH-015, VAL-DASH-021 | ✓ |
| 10. examples/fixtures + chart-test/assertions empty dirs | VAL-CERT-020 (TLS fixtures), VAL-CERT-021 (byte-identical), VAL-CERT-023 (gitignored keys), VAL-ENGINE-014 (fixtures bundled) — `chart-test/assertions/` itself not asserted populated, but F3.4 only commits to fixtures | ✓ (with caveat — see below) |
| 11. 5 scenarios use inline `product.set` (preserve style) | (no existing coverage — proposed VAL-ENGINE-041 above) | ✓ if VAL-ENGINE-041 accepted; otherwise UNCOVERED |

**Caveat on hot-spot 10:** The architecture's `examples/sample-product-chart/chart-test/assertions/` dir
is marked NEW but the mission (F3.4) only commits to populating `chart-test/fixtures/certificates/`.
This means `chart-test/assertions/` may remain empty post-mission. If the
architecture intends it to be populated, an assertion is missing. Recommend
clarifying mission scope: either trim Section 3.6 to drop the `assertions/`
expectation, or extend a feature to populate it.

**Hot-spot 11 status:** Currently UNCOVERED in the existing 263 assertions.
Adding the proposed VAL-ENGINE-041 closes it.

## Final Verdict

**NEEDS-CHANGES** — The contract is comprehensive but two cross-cutting
consistency defects (scenario path mismatch across areas, schema field-name
mismatch across areas) will cause real validation failures if shipped as-is.
The minimum changes are:
1. Reconcile all `examples/sample-product-chart/scenarios/` references in
   MESH/POLICY/CLOUD/CROSS to `examples/sample-product-chart/chart-test/scenarios/`
   to match the actual repo + project config.
2. Pin the schema-field naming question: either commit F1.1 to rename
   `cluster.provider/name` → `backend.kind/name` AND update the actual schema
   accordingly, OR revert all `backend.kind/name` references in
   MESH/POLICY/CLOUD/DASH/CLI/LLM to `cluster.provider/name`.
3. Add the `minikube` key to VAL-MESH-019's evidence list.
4. Soften the line-number/path anchors in VAL-DASH-022, VAL-DASH-023,
   VAL-CLI-022 (low priority).
5. Adopt the 5 proposed new assertions (VAL-ENGINE-041, VAL-LLM-022,
   VAL-CLI-024, VAL-CROSS-030, VAL-DASH-025) to close residual gaps in
   inline-product.set preservation, LLM explore mode prefix enforcement,
   list-integrations comprehensiveness, pre-F1.2 backward-compat, and
   empty-scenarios dashboard rendering. Brings the total to 268.

11/11 risk hot-spots are addressed after these changes (hot-spot 11 becomes
covered with VAL-ENGINE-041; hot-spot 10's `assertions/` dir status needs a
mission-scope clarification but is not a contract bug per se).
