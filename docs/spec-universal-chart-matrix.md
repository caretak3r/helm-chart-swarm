# Spec: Universal Chart Matrix Testing — Gap Analysis & Required Changes

Status: DRAFT (gap analysis, 2026-06-10)
Scope: what must change so **anyone** can point this framework at **their**
Helm chart and test the capability/configuration matrix under strict, real
test conditions, driven as a portable LLM skill.

---

## 1. Goal model (target taxonomy)

| Term | Definition | Example |
|------|-----------|---------|
| **Capability** | product chart + some OSS helm chart, OR product chart + a specific configuration | chart + cert-manager; chart + istio; chart + https-only scheme |
| **Configuration** | product chart + a native k8s configuration / API object | securityContext, probes, volumes+mounts, RBAC, Gateway API, Ingress, nodeSelector, scheduling, PDB, HPA |
| **Scenario** | product chart + N capabilities + M configurations, composed like a real customer environment | chart + cert-manager + nginx-ingress + restricted securityContext + NetworkPolicy + nodeSelector |

Non-negotiables:

1. **Accuracy over everything** — strict, real test conditions on a live
   cluster; assertions verify behavior, not just YAML shape.
2. **Chart-agnostic** — works with any chart, not the bundled stellarium
   sample.
3. **Skill-portable** — runs as a skill with any LLM/agent harness.
4. **Actionable output** — concrete recommendations on what the chart needs
   to change to support a failed scenario.

---

## 2. Current state assessment

Codebase is well-built for what it does: ~390 bats + ~985 pytest tests,
mypy --strict, schema-validated scenarios, per-scenario cluster isolation,
3-layer helm values merge with correct precedence
(`run-scenario.sh:605-608`), artifact bundles, LLM fix loop with path
traversal protection (`fix_cmd.py:238-252`), recommendations engine,
dashboard. Readiness for the goal above: **~70%** on plumbing, **~35%** on
the matrix/composition/strictness goals.

What it is today: a **hand-authored single-point scenario runner**. Each of
the 129 sample scenarios is one manually written YAML pinning one
integration OR one capability, with chart-specific values keys inlined.

What the goal requires: a **composable matrix engine** with behavioral
verification and a chart-agnostic values abstraction.

---

## 3. Gap analysis

### G1 — Scenarios cannot compose (CRITICAL)

The schema **forbids** the goal taxonomy. `scenario.schema.json:82-88`
makes `capability` and `integration` mutually exclusive, and there is no
field to declare multiple capabilities or configuration overlays. A
"customer-shaped" scenario (chart + cert-manager + ingress + restricted
securityContext + NetworkPolicy) can only be expressed by hand-writing a
bespoke YAML that hardcodes everything. N capabilities × M configurations
= N×M hand-authored files.

**Evidence:** all 129 scenarios are single points; `catalog.py` lists, it
never generates; `sweep-scenarios.sh` enumerates existing files only;
`generate explore` produces one variant per LLM iteration.

### G2 — Values coupling: scenarios are chart-specific (CRITICAL)

Scenarios hardcode the product chart's values keys
(`security-context-on.yaml` sets `podSecurityContext.runAsNonRoot`,
`scheduling-affinity-on.yaml` sets the sample chart's exact affinity
path) and foreign chart keys (nginx `controller.service.type`, istio
`pilot.resources`). There is no layer translating "enable ingress" →
this-chart's values path. Consequences:

- Zero scenario reuse across charts. The 129-scenario library is a
  stellarium library, not a portable matrix.
- Assertions double-bind: the assert repeats the same expected field
  names, so a chart restructure breaks scenario + assert together.
- A new user must author every scenario from scratch knowing the values
  structure of their chart AND every addon chart.

### G3 — Assertion depth: ~67% of engine asserts are render-grep (CRITICAL for "accuracy over everything")

Depth ladder found in `engine/asserts/`:

| Level | Meaning | Engine asserts |
|-------|---------|----------------|
| L0 | helm template render + yq grep | 10 of 15 (labels, annotations, rbac-objects, scheme-enforced, security-context, network-policy, resources, scheduling, priority-class, imagepullsecrets) |
| L1 | object exists in cluster | dual-source `live` mode of the above |
| L2 | object state/readiness | pods-ready |
| L3 | behavioral (real traffic / real enforcement) | service-reachable, smoke-script delegate |

Concrete false-pass risks:

- `network-policy.sh` passes if a NetworkPolicy **exists** — a policy with
  an empty/wrong podSelector that blocks nothing still passes. No traffic
  is ever sent.
- `rbac-objects.sh` checks roleRef/subjects are present but never that
  roleRef points at a real Role, that subjects match the actual SA, or
  that permissions suffice (no `kubectl auth can-i`).
- `scheduling-present.sh` checks the field exists; never verifies the pod
  actually landed on the targeted node.
- `scheme-enforced.sh` greps rendered ports; never confirms HTTP is
  actually rejected.
- The `RAW_`+`grep -oE '[0-9]{3}'`+`tail -1` pattern can pick a 3-digit
  number out of an error message and treat it as an HTTP code.
- `labels-present.sh` kind filter uses jq `index()` substring semantics
  (`"Deploy"` matches `"Deployment"`), and a kinds filter silently skips
  unlabeled objects outside the filter.
- No release-scoped selectors: asserts count all objects in the
  namespace, so preinstall objects can satisfy product-chart assertions.
- No retry/backoff: single `kubectl wait` with a 5m cliff; eventual
  consistency near the cutoff yields false FAILs.

The behavioral (L3) checks that DO exist live in the **sample chart's** 71
custom assertions (policy-actually-denies, mTLS, ingress traffic with Host
header, cert field validation) — i.e., exactly the strict checks the goal
needs are in `examples/`, not the engine, and are not reusable.

### G4 — Native k8s configuration coverage is incomplete (HIGH)

Assert-type coverage vs the configuration list in §1:

| Covered (assert exists) | Partial (smoke-script only) | Missing (no assert type) |
|---|---|---|
| securityContext (pod+container), RBAC objects, NetworkPolicy presence, nodeSelector/affinity/tolerations/topologySpread, priorityClass, resources requests/limits, imagePullSecrets, SA annotations (IRSA/WI), labels, annotations, scheme | Ingress, Gateway API, PVC, sidecar injection | **probes (readiness/liveness/startup)**, **volumes+volumeMounts (configmap/secret/emptyDir/hostPath)**, **PDB**, **HPA**, hostNetwork/hostPort, **initContainers**, DNS config, lifecycle hooks |

Probes and volume mounts are table-stakes customer requirements with zero
schema-driven verification today.

### G5 — Measurements: single-version, install-only, no matrix axes (HIGH)

Measured today: tool versions (`versions.json`), per-scenario
PASS/FAIL/INTERRUPTED + per-assert status, support-matrix pass rate,
benchmark duration + peak RSS (`benchmark-scenarios.sh`, not CI-wired),
recommendations with dedup.

Not measured (gaps against "in-depth compatibility before distribution"):

| Missing measurement | Why it matters |
|---|---|
| **k8s version matrix** | `cluster.k8s_version` is a single string; customers run 1.30–1.33. No cross-version explosion or per-version result axis. |
| **helm upgrade path** | No install-vN → upgrade-vN+1 scenario section; upgrade regressions ship undetected. |
| **rollback** | `helm rollback` never exercised. |
| **idempotency** | Re-apply same release/values never tested. |
| **values schema validation** | Consumer chart's `values.schema.json` never validated against scenario values. |
| **render vs live drift** | No `helm template` vs installed-state diff. |
| **capability coverage score** | No "chart supports X of Y capabilities" number — the single most useful pre-distribution metric. |
| **assertion depth per scenario** | A scenario can claim NetworkPolicy coverage with only an L0 check; nothing enforces an L2+/L3 assert per claimed capability. |

### G6 — Skill packaging & onboarding (HIGH)

- **Primers are engine-repo-only.** Integration primers live at
  `engine/skills/chart-test-swarm/references/integrations/`; a user cannot
  add a primer for their internal addon without forking the engine.
- **Custom assert types are engine-repo-only.** `run-scenario.sh:870`
  resolves only `$ASSERTS_DIR/<type>.sh`; consumer asserts are reachable
  solely via `smoke-script` path indirection — second-class, unvalidated,
  unlinted.
- **`chart-test-swarm.yaml` is under-specified**: no `chart_dir`,
  pull-secret/registry declaration, external scenario sources, or
  dependency/subchart declarations. Non-standard chart layouts can't
  onboard cleanly.
- **chart-test-swarm skill is human-in-the-loop** (diff + confirm phases);
  helm-swarm-test is fully portable, but the *generation* skill needs an
  explicit non-interactive mode for headless agents.
- Residual sample-chart defaults in code: `testgrid/cli.py:40`,
  `list_cmd.py:59`, `new_cmd.py:120`, `recommendations.py:508`,
  `benchmark-scenarios.sh:62` (fallbacks only — medium).

### G7 — Recommendation classification is brittle heuristics (MEDIUM)

`recommendations.py:194-234`: gap-probe = substring match on scenario ID
against a hardcoded 2-pattern list; infrastructure = case-insensitive
keyword grep ("cni", "proxy"…) on unstructured fail_msg; severity =
substring match on scenario ID ("rbac" → high). Accurate-recommendation
goals need structured failure causes, not string sniffing. Fix prompts
also lack chart context (no README/values.schema in prompt), capping LLM
fix quality.

---

## 4. Required changes (workstreams)

### WS1 — Composable scenario schema (closes G1)

Schema v2 additions (backward compatible; v1 scenarios remain valid):

```yaml
# scenario.schema.json v2
id: customer-replica-secure-ingress
product: { chart: ./chart, release: app, namespace: app }
capabilities:            # 0..N, replaces single `integration`
  - ref: certificates/cert-manager        # resolves a capability pack
  - ref: ingress-controllers/nginx
configurations:          # 0..N, replaces single `capability`
  - ref: security-context/restricted      # resolves a configuration pack
  - ref: network-policy/default-deny
  - ref: scheduling/node-selector
asserts: []              # additional scenario-specific asserts; packs bring their own
```

- Drop the `capability`/`integration` mutual exclusion; keep both as
  deprecated v1 aliases.
- A **pack** (capability or configuration) is a directory bundling:
  preinstall spec, values intent (see WS2), required asserts with minimum
  depth level, fixtures. Packs are the reusable unit; scenarios become
  thin composition manifests.
- Preinstall lists from multiple packs merge in declaration order;
  conflicts (same release name/namespace) fail validation, not runtime.

### WS2 — Values intent mapping (closes G2)

The single highest-leverage change. Introduce a per-chart **values map**
that translates abstract intents to chart-specific paths:

```yaml
# chart-test/values-map.yaml (generated, then human-verified)
schema_version: 1
intents:
  ingress.enable:        { path: ingress.enabled, value: true }
  ingress.className:     { path: ingress.className }
  securityContext.pod:   { path: podSecurityContext }
  securityContext.container: { path: securityContext }
  scheduling.nodeSelector:   { path: nodeSelector }
  rbac.create:           { path: rbac.create }
  probes.readiness:      { path: skywatcher.readinessProbe }   # chart-specific
unsupported:             # explicit, honest gaps → feed recommendations
  - intent: pdb.enable
    reason: chart has no PDB template
```

- `chart-test-swarm init` generates a draft map by introspecting
  `values.yaml` + templates (extend `introspect-chart.sh`); the skill
  asks the user/LLM to confirm ambiguous mappings once. Accuracy rule:
  **never guess silently** — unresolved intents go to `unsupported`.
- Packs declare intents, not paths. At apply time the engine resolves
  intent → path via the map and emits `--set`/values files exactly as
  today (`run-scenario.sh:849-854` unchanged downstream).
- An intent that maps to `unsupported` produces a structured
  **gap recommendation** ("chart needs a PDB template to support
  pdb.enable") instead of a confusing runtime FAIL. This directly
  delivers the "recommendations on what our helm chart needs" goal.
- Addon (OSS chart) values stay inside the pack — they're coupled to the
  addon by nature, and the pack is versioned with the addon version.

### WS3 — Assertion depth ladder + strictness contract (closes G3, G4)

1. **Tag every assert with a depth level** (`# DEPTH: L0|L1|L2|L3` header
   + registry manifest `engine/asserts/registry.yaml`). Scenario
   validation enforces: every capability/configuration pack must include
   at least one **L2+** assert; packs claiming enforcement semantics
   (network-policy, policy engines, scheme, mTLS) must include an **L3**
   assert.
2. **Promote the sample chart's L3 patterns into engine asserts**
   (they already exist as custom scripts — generalize, parameterize by
   RELEASE/NAMESPACE/label selector):
   - `network-policy-enforced` — launch a violating client pod, verify
     traffic is actually denied (and allowed path still works).
   - `policy-denies-violation` — apply a violating manifest, expect
     admission rejection (gatekeeper/kyverno).
   - `tls-cert-valid` — pull served cert, verify issuer/SAN/expiry.
   - `ingress-routes-traffic` / `gateway-routes-traffic` — curl through
     the ingress/gateway data path with Host/SNI, assert body + code.
   - `mesh-mtls-enforced` — plaintext probe must fail, mesh path must
     succeed.
   - `rbac-effective` — `kubectl auth can-i --as=system:serviceaccount:…`
     for the chart's declared needs.
   - `scheduled-on-target` — assert pod node matches the selector.
3. **New assert types for missing configs**: `probes-present` (+ L2:
   probe actually transitions Ready), `volume-mounts-present` (+ L2: file
   visible inside container via exec), `pdb-present`, `hpa-present`
   (+ L2: scaling event under synthetic load optional), `init-containers`,
   `host-network`, `lifecycle-hooks`, `dns-config`.
4. **Strictness fixes in existing asserts**:
   - Mandatory release-scoped label selector
     (`app.kubernetes.io/instance=$RELEASE`) on all live checks.
   - Replace jq `index()` substring kind matching with exact match.
   - Formalize `RAW_` pattern: anchor the grep
     (`grep -oE 'HTTP/[0-9.]+ ([0-9]{3})'`), fail loudly when no match.
   - Shared `wait_with_backoff()` helper (exponential, separate
     initial-timeout vs max-wait), per-assert `retries` schema field.
   - rbac-objects: verify roleRef resolves and subjects match the actual SA.
5. **Structured assert output contract**: each assert emits
   `ASSERTION_RESULT: PASS|FAIL|SKIP` + `ASSERTION_DETAIL: <json>` lines;
   `run-scenario.sh:883-891` parses these into `result.yaml` instead of
   `tail -n 40` of free text. SKIP becomes a first-class status
   (currently only PASS/FAIL exists). This is also what fixes G7's
   classification: categories derive from structured detail, not keyword
   grep.

### WS4 — Matrix generation (closes G1 operationally, G5 partially)

New command `chart-test-swarm generate matrix`:

```yaml
# chart-test/matrix.yaml
axes:
  k8s_version: [v1.31.0, v1.32.0, v1.33.0]
  capabilities: [certificates/cert-manager, ingress-controllers/nginx, service-mesh/istio]
  configurations: [security-context/restricted, network-policy/default-deny, scheduling/node-selector]
strategy: pairwise        # full | pairwise | curated
exclude:
  - { capabilities: [service-mesh/istio], k8s_version: v1.31.0 }   # known-incompatible
```

- Deterministic expansion (pairwise/all-pairs by default — full cartesian
  explodes fast; 3×3×3 full = 27, pairwise ≈ 9) into generated scenario
  files under `chart-test/scenarios/generated/` with provenance stamps.
- `k8s_version` becomes a first-class matrix axis: `cluster.k8s_version`
  stays a single string per generated scenario; the matrix expands it.
  (`cluster-up.sh` already supports pinning — only the explosion layer is
  new.)
- The support matrix dashboard gains the version axis and a
  **capability coverage score**: `supported / declared` per chart, the
  headline pre-distribution metric.

### WS5 — Lifecycle measurements (closes G5)

Scenario schema additions:

```yaml
lifecycle:
  upgrade_from: { chart: oci://…/app, version: 1.2.0 }   # install old → upgrade to ./chart → asserts run post-upgrade
  rollback: true                                          # after upgrade asserts pass, rollback → re-run asserts
  idempotency: true                                       # re-apply same release+values → assert no diff, still PASS
```

Plus pre-install gates in `run-scenario.sh`:
- validate scenario values against the chart's `values.schema.json` when
  present (helm does this on install, but fail-fast with a structured
  `schema-mismatch` cause);
- capture `helm template` output and diff against live post-install state
  into `artifacts/render-drift.yaml`.

Wire `benchmark-scenarios.sh` duration into `result.yaml`
(`duration_s` is already computed there; today result.yaml has only
timestamps).

### WS6 — Pluggable packs, primers, asserts + onboarding (closes G6)

- **Search-path layering** for primers, packs, and assert types:
  `chart-test/{primers,packs,asserts}/` (consumer) →
  engine equivalents (fallback). One change in `run-scenario.sh:870`
  (assert resolution) + primer loader. Consumer asserts get the same
  registry/linter treatment as engine asserts
  (`check-custom-assertions.sh`: exit-code contract, anchored greps, no
  hardcoded selectors).
- **`chart-test-swarm.yaml` v2 fields**: `chart_dir`, `registries`/
  `pull_secrets`, `scenario_sources` (extra dirs/repos), `values_map`
  path, `dependencies`.
- **`chart-test-swarm init` becomes the one-command onboarding**:
  locate chart → scaffold → introspect → generate draft values-map →
  generate a starter matrix.yaml from detected chart features → report
  which capabilities/configurations the chart can/cannot support
  (feasibility verdicts per pack, reusing the existing
  POSSIBLE/WITH-CAVEATS/IMPOSSIBLE machinery).
- **Skill non-interactive mode**: `--yes`/`CTS_NON_INTERACTIVE=1`
  replaces the diff-confirm phase so any headless agent can drive the
  full flow; SKILL.md documents both modes (helm-swarm-test already does
  this — mirror it).
- Remove sample-chart fallback defaults from `testgrid/cli.py:40`,
  `list_cmd.py:59`, `new_cmd.py:120`, `recommendations.py:508`,
  `benchmark-scenarios.sh:62`; require explicit project dir or fail with
  guidance.

### WS7 — Accurate recommendations (closes G7)

- Failure cause becomes structured: every FAIL carries
  `{stage, assert_type, depth_level, detail_json}` from WS3's output
  contract; classification maps from these fields, with the keyword grep
  kept only as last-resort fallback.
- `unsupported` intents from WS2 generate `chart-gap` recommendations
  with the exact missing template/values surface named.
- Fix prompts include chart context: README, values.schema.json, the
  values-map, and the failing assert's DETAIL json.
- Add the missing unit test for path-traversal rejection in
  `_write_chart_file` (noted untested).

---

## 5. Acceptance criteria

1. **Composition**: a single scenario YAML declaring ≥2 capabilities +
   ≥3 configurations validates, runs, and reports per-pack assert results.
2. **Portability**: `chart-test-swarm init` on a foreign chart (e.g.,
   bitnami/nginx or a private chart) produces a values-map + starter
   matrix and runs a generated scenario to PASS/FAIL **with zero edits to
   the engine repo**.
3. **Strictness**: every engine pack ships ≥1 L2 assert; enforcement
   packs ship ≥1 L3 assert; a NetworkPolicy with an empty podSelector
   FAILS the network-policy pack (regression test for the current false
   pass).
4. **Matrix**: `generate matrix` expands a 3-axis spec pairwise,
   dashboard shows the k8s-version axis and a capability coverage score.
5. **Lifecycle**: upgrade_from + rollback + idempotency scenarios run
   green on the sample chart in CI.
6. **Recommendations**: an intent in `unsupported` yields a chart-gap
   recommendation naming the missing values surface; zero
   classifications produced by keyword-grep on the sample suite.
7. **Skill**: full init → matrix → run → recommend flow completes
   headless (`CTS_NON_INTERACTIVE=1`) under at least two harnesses
   (Claude Code + one of droid/opencode/gemini).
8. Existing gates stay green: bats, pytest, mypy --strict, ruff,
   shellcheck, helm lint; v1 scenarios still validate (compat suite).

## 6. Phasing & sizing

| Phase | Workstreams | Rationale |
|-------|-------------|-----------|
| P1 | WS3 (strictness fixes + output contract + depth registry), WS6 search-path layering | Accuracy is the stated top priority and unblocks nothing-else; pluggability is a small, isolated change. |
| P2 | WS2 (values-map), WS1 (schema v2 packs) | Values-map first — packs are useless while values are chart-coupled. |
| P3 | WS4 (matrix gen), WS5 (lifecycle) | Needs packs to exist to be worth generating. |
| P4 | WS7 (recommendations), skill non-interactive polish, docs | Consumes WS3 structured output. |

Biggest risk: WS2 mapping accuracy. Mitigation is the "never guess
silently" rule — unresolved intents are explicit `unsupported` entries
reviewed by a human/LLM once per chart, and the map is committed and
versioned with the chart.
