## Area: Cloud-Native Primers

Behavioral validation assertions for Milestone 8 — cloud-native primers:
F8.1 `gke`, F8.2 `eks`, F8.3 `aks`.

**AUTHORED-ONLY DISCIPLINE.** Cloud-native scenarios are never applied to any
real GKE / AKS / EKS cluster from this repo. Validation is strictly limited to:
schema validity, `kubectl --dry-run=client` admission shape, `kubeval`
manifest correctness, primer completeness, and dashboard "AUTHORED ONLY"
badging. Every assertion below MUST be satisfiable without real cloud
credentials.

---

### VAL-CLOUD-001: gke primer authored under cloud-native/
The GKE primer markdown MUST exist at the canonical path with sections
covering (a) which GCP features the variants depend on (Workload Identity,
IAP, GKE Gateway Controller, regional networking), (b) credential prerequisites
(`gcloud auth`, IAM bindings), and (c) cluster prerequisites (GKE version,
add-ons, network mode).
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/cloud-native/gke.md) — file contains H2 headings for the four named features and an explicit "AUTHORED ONLY — not run from this repo" notice

### VAL-CLOUD-002: eks primer authored under cloud-native/
The EKS primer markdown MUST exist with sections covering IRSA, ALB Ingress
Controller, ACK (AWS Controllers for Kubernetes), and Fargate, plus credential
prerequisites (AWS IAM role, OIDC provider) and cluster prerequisites.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/cloud-native/eks.md) — file contains H2 headings for the four named features and an explicit "AUTHORED ONLY" notice

### VAL-CLOUD-003: aks primer authored under cloud-native/
The AKS primer markdown MUST exist with sections covering Workload Identity,
AGIC (Application Gateway Ingress Controller), App Routing addon, and Azure
Policy, plus credential prerequisites (Azure AD, managed identity) and cluster
prerequisites.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/cloud-native/aks.md) — file contains H2 headings for the four named features and an explicit "AUTHORED ONLY" notice

### VAL-CLOUD-004: each cloud has at least 3 per-cloud scenario YAMLs authored
The repo MUST contain at least 3 scenario YAMLs per cloud under
`examples/sample-product-chart/chart-test/scenarios/cloud-native/` (e.g.,
`gke-workload-identity.yaml`, `gke-iap.yaml`, `gke-gateway-controller.yaml`).
Tool: bash
Evidence: file(examples/sample-product-chart/chart-test/scenarios/cloud-native/gke-*.yaml); file(examples/sample-product-chart/chart-test/scenarios/cloud-native/eks-*.yaml); file(examples/sample-product-chart/chart-test/scenarios/cloud-native/aks-*.yaml) — at least 3 files matching each glob

### VAL-CLOUD-005: every cloud-native scenario uses a non-local cluster.provider
Each YAML under `examples/sample-product-chart/chart-test/scenarios/cloud-native/` MUST
set `cluster.provider` to one of `gke | eks | aks` so the dashboard's "AUTHORED
ONLY" badge trigger fires correctly.
Tool: yq
Evidence: terminal-output — `yq '.cluster.provider' <file>` returns one of `gke|eks|aks` for every cloud-native scenario; no `kind`/`minikube`/`k3d` slips in

### VAL-CLOUD-006: cloud-native CLUSTER_NAME still matches the cluster-prefix invariant
Despite being authored-only, every cloud-native scenario is designed to be invoked with the `CLUSTER_NAME` env var matching `^chart-test-swarm-[a-z0-9-]+$` so the script-enforced cluster-prefix invariant holds uniformly across local and cloud backends. The scenario YAML itself does NOT carry a cluster-name field; the prefix is enforced by the engine scripts at run/dispatch time.
Tool: bash
Evidence: terminal-output — running `CLUSTER_NAME=chart-test-swarm-cloud-x bash engine/scripts/run-scenario.sh <cloud-native scenario>` (in `--dry-run` or stub mode where applicable) accepts the name; `CLUSTER_NAME=bad-name` for the same scenario is refused by the same prefix guard exercised in VAL-ENGINE-022

### VAL-CLOUD-007: every cloud-native scenario passes jsonschema validation
Running the standard validator
(`uv run --directory engine/testgrid python -m testgrid.validate <file>` or
`jsonschema -i <file> engine/templates/scenario.schema.json`) on each
cloud-native scenario MUST exit 0. The schema's `cluster.provider` enum already
includes gke/eks/aks per F1.1.
Tool: jsonschema
Evidence: terminal-output — exit code 0, no validation error lines

### VAL-CLOUD-008: every cloud-native scenario passes `kubectl --dry-run=client`
For each cloud-native scenario, applying its embedded / referenced manifest
fragments through `kubectl apply -f <file> --dry-run=client -o yaml` MUST
succeed (exit 0) — proving the YAML is at least syntactically and
schematically well-formed at the client side without contacting any cluster.
Tool: kubectl
Evidence: terminal-output — `kubectl --dry-run=client` exit code 0 per file

### VAL-CLOUD-009: raw_manifest preinstall items pass `kubeval`
For each `preinstall_items` entry with `kind: raw_manifest`, the referenced
manifest at `path:` MUST pass `kubeval --strict --kubernetes-version <pinned>`
validation against the matching k8s API version pinned in the primer.
Tool: kubeval
Evidence: terminal-output — `kubeval` reports `PASS` for every cloud-native raw_manifest path

### VAL-CLOUD-010: helm preinstall items reference real reachable chart coordinates
For every `preinstall_items` entry with `kind: helm`, `helm template
--repo <repo.url> <chart> --version <version> --generate-name` MUST succeed
client-side (template rendering only — no cluster I/O) — verifying that the
chart coordinate strings the primer documents are reachable and renderable.
Tool: helm
Evidence: terminal-output — `helm template` exit code 0 per cloud-native helm preinstall_item

### VAL-CLOUD-011: dashboard renders cloud-native scenarios with the "AUTHORED ONLY" badge
When the dashboard is built against a `reports/` tree that contains
cloud-native result entries, every card whose `cluster.provider` ∈ `{gke, eks, aks}`
MUST be rendered with the "AUTHORED ONLY" badge (cross-reference VAL-DASH-*
in the dashboard area). The trigger is strictly `cluster.provider`, not the
integration name.
Tool: bash
Evidence: file(reports/run-*/dist/index.html) — every card derived from a `cluster.provider ∈ {gke,eks,aks}` scenario contains the badge HTML `class="badge authored-only"` (or equivalent)

### VAL-CLOUD-012: dispatch-swarm.sh skips cluster operations for cloud-native scenarios
Invoking `engine/scripts/dispatch-swarm.sh examples/sample-product-chart/chart-test/scenarios/cloud-native/gke-workload-identity.yaml` (and the EKS/AKS equivalents) MUST emit an explanatory message (e.g., "Cloud-native scenario — authored only; skipping cluster operations") on stderr and exit 0 WITHOUT calling `kind`, `minikube`, `kubectl --context`, `gcloud`, `aws`, or `az`.
Tool: bash
Evidence: terminal-output — stderr contains the explanatory message; `set -x` trace shows no `kind|minikube|kubectl --context|gcloud|aws|az` invocation; exit code 0

### VAL-CLOUD-013: no script in the repo calls `kubectl --context` for cloud-native scenarios
Static grep across `engine/scripts/*.sh` MUST show that any `kubectl
--context` invocation is gated by a `cluster.provider` check that excludes
`gke|eks|aks`, OR that no such invocation exists at all. No cloud-native
code path may dispatch to a non-local cluster.
Tool: bash
Evidence: terminal-output — `rg -n 'kubectl --context' engine/scripts/` returns zero unguarded matches; any matches are wrapped by an `if [[ "$CLUSTER_PROVIDER" =~ ^(kind|minikube|k3d)$ ]]; then ...; fi` block

### VAL-CLOUD-014: no script invokes cloud-provider CLIs for cloud-native scenarios
Static grep across `engine/scripts/*.sh` and `engine/testgrid/src/**/*.py`
MUST show no `gcloud`, `aws`, or `az` subprocess call — these tools are
neither installed nor required, and their absence is the strongest guarantee
that authored-only discipline holds.
Tool: bash
Evidence: terminal-output — `rg -nw 'gcloud|aws|az' engine/scripts/ engine/testgrid/src/` returns no matches outside comments/docstrings; `(exit code 1)` from rg is acceptable evidence

### VAL-CLOUD-015: cloud-native scenarios are NOT included in default `chart-test-swarm run --all`
The CLI's `run --all` (or `dispatch-swarm.sh --all`) MUST default to filtering
out scenarios where `cluster.provider ∈ {gke, eks, aks}`. Including them requires
an explicit `--include-cloud-native` (or equivalent) flag, AND even then the
runner emits the skip message from VAL-CLOUD-012.
Tool: bash
Evidence: terminal-output — `chart-test-swarm run --all --dry-run` lists only local-backend scenarios; with `--include-cloud-native` they appear, each annotated as authored-only

### VAL-CLOUD-016: cloud-native fixtures contain no real secrets
Any fixture file under
`examples/sample-product-chart/chart-test/fixtures/cloud-native/` MUST contain
only placeholder values (e.g., `<REPLACE_WITH_YOUR_PROJECT_ID>`,
`<REPLACE_WITH_ROLE_ARN>`) — no real GCP project IDs, AWS account numbers,
Azure tenant IDs, JWT private keys, or service-account JSON bodies.
Tool: bash
Evidence: terminal-output — `rg -nE '(AKIA[0-9A-Z]{16}|arn:aws:iam::[0-9]{12}|projects/[a-z0-9-]+/serviceAccounts|"private_key":)' examples/sample-product-chart/chart-test/fixtures/cloud-native/` returns no matches

### VAL-CLOUD-017: yamllint clean on all cloud-native authored YAMLs and primers
`yamllint engine/skills/chart-test-swarm/references/integrations/cloud-native/**/*.yaml examples/sample-product-chart/chart-test/scenarios/cloud-native/*.yaml` exits 0 — no remaining style errors on cloud-native-touched files (clean-as-you-go).
Tool: bash
Evidence: terminal-output — `yamllint` exit code 0, no error lines

### VAL-CLOUD-018: cloud-native primers document credential + prereq blocks explicitly
Each of the three cloud primers MUST contain a top-level section titled
"Credential prerequisites" AND a top-level section titled "Cluster
prerequisites" (or equivalent H2 headings) — verified by header-only grep on
each primer file. This ensures consumers shipping the YAMLs know what they
need before applying.
Tool: bash
Evidence: terminal-output — `rg -n '^## (Credential prerequisites|Cluster prerequisites)' engine/skills/chart-test-swarm/references/integrations/cloud-native/{gke,eks,aks}.md` returns at least one match per file per heading

### VAL-CLOUD-019: Cloud-native authored YAMLs version-pin their cloud-K8s API
Each cloud-native primer documents a "Target Kubernetes version" (e.g., `GKE 1.30+`, `EKS 1.30+`, `AKS 1.30+`) in an explicit H2 heading. Every authored YAML under `examples/sample-product-chart/chart-test/scenarios/cloud-native/` carries a `metadata.annotations.chart-test-swarm/target-k8s-version` annotation (or equivalent top-level comment), and the documented version matches what passes `kubeval --kubernetes-version <pinned>` in VAL-CLOUD-009. Pass requires the primer doc + per-scenario stamp + match with kubeval-pinned version.
Tool: bash
Evidence: terminal-output (`rg -n '^## Target Kubernetes version' engine/skills/chart-test-swarm/references/integrations/cloud-native/{gke,eks,aks}.md` returns ≥ 1 match per file), terminal-output (`yq '.metadata.annotations."chart-test-swarm/target-k8s-version"' examples/sample-product-chart/chart-test/scenarios/cloud-native/*.yaml`)
