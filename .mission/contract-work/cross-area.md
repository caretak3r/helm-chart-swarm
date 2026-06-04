## Cross-Area Flows

### VAL-CROSS-001: CLI `run` end-to-end produces dashboard-visible scenario card with linked artifacts
Crosses M9 (cli-tool) → M1 (engine-foundations) → M2 (dashboard-uplift). Invoking `chart-test-swarm run <scenario>` (M9 F9.2) must drive `dispatch-swarm.sh` (M1) to spin up a `chart-test-swarm-*` kind cluster, write `reports/run-<id>/` with the M1 F1.4 artifact bundle, then `chart-test-swarm dashboard` (M9 F9.3 / M1 build-dashboard.sh) must render `reports/run-<id>/dist/index.html` containing a card for that scenario whose anchor links to `artifacts/scenario.yaml`, `artifacts/applied-overrides.yaml`, fixtures, and manifests all resolving (HTTP 200 on file:// fetch).
Tool: agent-browser
Evidence: screenshot, dom-text(.scenario-card a[href$="scenario.yaml"]), file(reports/run-<id>/dist/index.html)

### VAL-CROSS-002: CLI `run --parallelism 2` executes two scenarios concurrently and both surface on dashboard
Crosses M9 (cli-tool) → M1 (engine-foundations, dispatch-swarm.sh parallelism) → M2 (dashboard-uplift). Running `chart-test-swarm run --all --parallelism 2` against a scenario set drawn from two different integration categories (e.g. one from M4 ingress-controllers + one from M6 service-mesh) must produce two simultaneous `chart-test-swarm-*` clusters (observable mid-run), both `result.yaml`s written under the same `run-<id>/`, and the rendered dashboard must show both cards with their correct PASS/FAIL status under their respective category groupings.
Tool: bash
Evidence: terminal-output (kind get clusters during run shows ≥2 chart-test-swarm-* entries), file(reports/run-<id>/agent-1/result.yaml), file(reports/run-<id>/agent-2/result.yaml), dom-text(.matrix-view)

### VAL-CROSS-003: LLM `generate author` → CLI `run` → dashboard shows authored scenario with correct outcome
Crosses M10 (llm-generator F10.2) → M9 (cli-tool) → M1 (engine) → M2 (dashboard). Running `chart-test-swarm generate author "istio with strict-mtls + cert-manager"` (M10) must emit a schema-valid scenario YAML (jsonschema validation passes against `engine/templates/scenario.schema.json`); piping that file into `chart-test-swarm run` (M9 F9.2) must execute it end-to-end (M1 dispatch); the resulting card on the rendered dashboard (M2) must carry `generated_by.by` provenance and render as a normal scenario.
Tool: bash
Evidence: file(authored-scenario.yaml), terminal-output (yq '.generated_by.by' shows LLM provenance), terminal-output (jsonschema validate exits 0), dom-text(.scenario-card[data-id=authored-*])

### VAL-CROSS-004: LLM `generate explore` iterates across integrations and writes summary listing all combinations tried
Crosses M10 (llm-generator F10.3) → M9 (cli-tool) → M1 (engine). Running `chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager,nginx-ingress,istio --max-iterations 3` must drive the LLM through ≥2 distinct combos, invoke `chart-test-swarm run` (M9) for each (producing `reports/run-*/` under M1 contract), and at completion emit a summary file enumerating each combo with its outcome (PASS/FAIL/SKIP) and reasoning trace.
Tool: bash
Evidence: file(reports/explore-<id>/summary.yaml), terminal-output (summary lists ≥2 combos with status fields)

### VAL-CROSS-005: cert-manager (M3) + nginx-ingress (M4) compose into a single scenario with TLS-terminated HTTPS
Crosses M3 (certificates) → M4 (ingress-controllers). A composed scenario authored with `preinstall_items` containing cert-manager + nginx-ingress (and a self-signed ClusterIssuer fixture) must run to completion: cert-manager issues a Certificate, the resulting Secret is referenced by an nginx Ingress with TLS, and an `https://` request to the ingress endpoint from inside the cluster returns 200 with a cert chain rooted at the ClusterIssuer CA.
Tool: kubectl
Evidence: terminal-output (kubectl get certificate -A → Ready=True), terminal-output (kubectl exec curl-pod -- curl -kv https://<host>/ shows 200 + issuer matches ClusterIssuer), file(reports/run-<id>/artifacts/manifests/ingress.yaml)

### VAL-CROSS-006: istio-service-mesh (M6) + cert-manager (M3) — istio Gateway uses cert-manager-issued cert
Crosses M6 (service-mesh) → M3 (certificates). Composed scenario installs istio (M6 F6.1) + cert-manager (M3 F3.1) and binds an istio Gateway listener to a TLS Secret produced by a cert-manager Certificate (cross-namespace if needed). Result: `istioctl analyze` clean, Gateway resource references the Secret, and an external HTTPS request through the ingress gateway returns 200 with the cert-manager-issued cert presented.
Tool: kubectl
Evidence: terminal-output (kubectl get gateway -o yaml shows credentialName referencing cert-manager Secret), terminal-output (openssl s_client -connect <gw>:443 -showcerts shows expected issuer DN), file(reports/run-<id>/artifacts/applied-overrides.yaml)

### VAL-CROSS-007: opa-gatekeeper (M7) + nginx-ingress (M4) — policy rejects non-compliant Ingress, accepts compliant one
Crosses M7 (policy-engines) → M4 (ingress-controllers). Composed scenario installs gatekeeper (M7 F7.1) with a required-labels ConstraintTemplate + Constraint targeting Ingress resources, then attempts two `kubectl apply` calls: (a) an nginx Ingress missing the required label — must be rejected by the admission webhook with the policy message in stderr; (b) a compliant Ingress — must be admitted and reach Ready.
Tool: kubectl
Evidence: terminal-output (kubectl apply bad-ingress.yaml exits non-zero with constraint violation text), terminal-output (kubectl apply good-ingress.yaml exits 0 + kubectl get ingress shows ADDRESS populated), file(reports/run-<id>/artifacts/manifests/constraint.yaml)

### VAL-CROSS-008: envoy-gateway (M5) + cert-manager (M3) — Gateway listener uses cert-manager-terminated TLS
Crosses M5 (gateway-api-variants) → M3 (certificates). Composed scenario installs envoy-gateway (M5 F5.1, OCI helm ref per F1.2) + cert-manager (M3) with a Gateway resource whose listener `tls.certificateRefs` points to a cert-manager Secret. Result: HTTPRoute attaches successfully, listener reports `Programmed=True`, and a curl through the gateway address returns 200 with the expected cert.
Tool: kubectl
Evidence: terminal-output (kubectl get gateway -o jsonpath shows Programmed=True), terminal-output (curl -kv https://<gw>/ → 200 + cert issuer matches ClusterIssuer), file(reports/run-<id>/artifacts/scenario.yaml)

### VAL-CROSS-009: Dashboard matrix view groups all integration categories together when scenarios span M3–M8
Crosses M2 (dashboard-uplift) → M3, M4, M5, M6, M7, M8. Running a mixed scenario set drawn from every integration category must produce a dashboard whose matrix view (M2 F2.1, F2.3) renders each category (certificates, ingress-controllers, gateway-api, service-mesh, policy, cloud-native) as a distinct grouping with the correct integration cards under each, and cloud-native cards visually distinct (M2 F2.3 icon/tooltip).
Tool: agent-browser
Evidence: screenshot, dom-text(.matrix .category-group) shows six categories, dom-text(.cloud-native-badge) present on M8 cards

### VAL-CROSS-010: Cloud-native (M8) scenarios appear on dashboard alongside locally-run scenarios with "AUTHORED ONLY" indicator
Crosses M8 (cloud-native-primers) → M2 (dashboard-uplift). After a run that includes a mix of locally-executed scenarios (M3–M7) and cloud-native scenarios (M8 GKE/EKS/AKS authored YAMLs that pass `kubectl --dry-run=client` only), the rendered dashboard must show local scenarios with PASS/FAIL status and cloud-native scenarios with an "AUTHORED ONLY" indicator (icon + tooltip per M2 F2.3) that does not show as failure or untested.
Tool: agent-browser
Evidence: screenshot, dom-text(.scenario-card[data-category=cloud-native] .badge) equals "AUTHORED ONLY", dom-text(.scenario-card[data-category=ingress-controllers] .status) equals "PASS"

### VAL-CROSS-011: Variant grouping (M2 F2.2) correctly aggregates mixed PASS/FAIL outcomes under one integration header
Crosses M2 (dashboard-uplift) → any integration milestone (M3–M7). When a single integration has 3–4 variants where at least one passes and one fails, the dashboard collapses them under a single header row whose aggregate display shows the variant count and PASS/FAIL breakdown (e.g. "3 variants: 2 PASS, 1 FAIL"), and expanding the header reveals each variant's individual status.
Tool: agent-browser
Evidence: dom-text(.integration-header .variant-summary) matches `\d+ variants: \d+ PASS, \d+ FAIL`, screenshot of expanded vs collapsed state

### VAL-CROSS-012: All committed scenario YAMLs across every integration milestone pass jsonschema validation
Crosses M1 (engine-foundations schema) → M3, M4, M5, M6, M7, M8 (scenario authors). A sweep script that runs `jsonschema -i <scenario>.yaml engine/templates/scenario.schema.json` (or equivalent uv/python invocation) against every `*.yaml` under `examples/sample-product-chart/chart-test/scenarios/` must exit 0 for all files. This validates F1.1 (minikube enum), F1.2 (raw_manifest preinstall + relaxed additionalProperties), and per-scenario authoring discipline in milestones 3–8.
Tool: bash
Evidence: terminal-output (sweep script prints PASS for every scenario file + exit 0), file(engine/templates/scenario.schema.json)

### VAL-CROSS-013: Every successful scenario run produces the F1.4 artifact bundle regardless of integration
Crosses M1 (engine-foundations F1.4) → M3, M4, M5, M6, M7 (running milestones). After running the full local scenario suite, an audit walk of `reports/run-*/` must confirm that every `result.yaml` with `status: PASS` has a sibling `artifacts/` dir containing all required files: `scenario.yaml`, `applied-overrides.yaml`, `fixtures/`, `manifests/`, `versions.json` (with helm/kubectl/kind/minikube/k8s_server version keys all populated).
Tool: bash
Evidence: terminal-output (find reports/run-*/result.yaml + xargs verify shows all bundles complete), file(reports/run-<id>/artifacts/versions.json) parseable with `jq '.helm,.kubectl,.kind,.minikube,.k8s_server'` returning non-empty values

### VAL-CROSS-014: `applied-overrides.yaml` artifact shape is consistent across all running integrations
Crosses M1 (F1.4 artifact contract) → M3, M4, M5, M6, M7. For every run that includes helm preinstall + product chart install + override merges, the resulting `artifacts/applied-overrides.yaml` must follow a uniform structure: top-level `helm_values` (flattened final merge) + top-level `raw_manifest_refs` (array of applied raw_manifest paths from F1.2). Asserted by parsing each file and confirming both keys present and well-typed.
Tool: bash
Evidence: terminal-output (yq '.helm_values | type, .raw_manifest_refs | type' returns map and seq across all artifact files), file(reports/run-<id>/artifacts/applied-overrides.yaml)

### VAL-CROSS-015: No engine script ever creates a cluster without the `chart-test-swarm-` prefix
Crosses M1 (engine scripts) → M9 (CLI delegation). A static-audit script that greps every `engine/scripts/*.sh` and every CLI handler in `engine/testgrid/src/testgrid/cli.py` for `kind create cluster`, `minikube start`, `--name` arguments, and CLUSTER_NAME defaults must show that every cluster-creating invocation either receives an explicit `chart-test-swarm-*` name or defaults to one (with the default itself audited to start with `chart-test-swarm-`).
Tool: bash
Evidence: terminal-output (grep audit finds all cluster-name sources and each is verified to be chart-test-swarm-prefixed; script prints OK)

### VAL-CROSS-016: After any scenario run (across integrations), no orphan kind/minikube clusters remain
Crosses M1 (engine cluster-down.sh) → M3–M7 (scenario runs). Run a scenario from each integration category sequentially, then after each invocation verify `kind get clusters` shows no `chart-test-swarm-*` entries AND `minikube profile list -o json` shows no `chart-test-swarm-*` profiles. Architectural invariant #5.
Tool: bash
Evidence: terminal-output (kind get clusters | grep chart-test-swarm- → empty; minikube profile list -o json | jq '.valid[].Name' | grep chart-test-swarm- → empty)

### VAL-CROSS-017: After any scenario run, no orphan docker containers remain
Crosses M1 (engine cleanup) → M3–M7. After each scenario completes (success or fail), `docker ps -a --filter "name=chart-test-swarm-"` must return empty. Stronger than VAL-CROSS-016 because kind sometimes leaks node containers even after `kind delete cluster`. Architectural invariant #5.
Tool: bash
Evidence: terminal-output (docker ps -a --filter name=chart-test-swarm- prints only the header row)

### VAL-CROSS-018: Re-running the full pipeline from a clean state produces identical PASS/FAIL outcomes (deterministic)
Crosses M1 (engine) → M9 (CLI) → M3–M7 (scenarios). Tear down all `chart-test-swarm-*` clusters, delete `reports/`, run `chart-test-swarm run --all`, record outcomes per scenario_id; repeat the entire cycle from clean state; the per-scenario PASS/FAIL set must be byte-identical between the two runs (ignoring timestamps + log_dir paths).
Tool: bash
Evidence: terminal-output (diff <(yq '.scenarios[] | {id,status}' run-A.yaml) <(yq '.scenarios[] | {id,status}' run-B.yaml) → empty)

### VAL-CROSS-019: CLI (M9) `run` correctly delegates backend selection to engine scripts (M1)
Crosses M9 (cli-tool F9.2) → M1 (engine-foundations F1.1 minikube backend). Invoking `chart-test-swarm run <scenario> --backend minikube` must result in a `minikube start --profile chart-test-swarm-*` invocation (not `kind create`); inversely `--backend kind` must invoke `kind create cluster`. Verified by tracing the engine script invocation through stdout/log capture.
Tool: bash
Evidence: terminal-output (--backend minikube run shows minikube start in cluster-up.log; --backend kind shows kind create cluster in cluster-up.log), file(reports/run-<id>/agent-*/logs/cluster-up.log)

### VAL-CROSS-020: LLM generator (M10) `explore` invokes the real CLI (M9) and produces real reports
Crosses M10 (llm-generator) → M9 (cli-tool). `chart-test-swarm generate explore` must not stub or mock the run pipeline — it must shell out to `chart-test-swarm run` (M9 F9.2) such that real `reports/run-*/result.yaml` files are produced per iteration. Verified by checking that the run subdirs from explore mode contain real artifacts (not placeholders) and that the LLM's "feed result" step reads those real files.
Tool: bash
Evidence: terminal-output (each iteration writes a real reports/run-*/ with artifacts), file(reports/run-<id>/artifacts/scenario.yaml present + non-empty for each explore iteration)

### VAL-CROSS-021: Dashboard (M2) correctly reads engine reports (M1) regardless of which integration produced them
Crosses M2 (dashboard-uplift) → M1 (reports artifact contract). Build the dashboard against a `reports/` directory containing runs from every integration category; the rendered HTML must include cards for every scenario across categories with no "missing scenario", no schema-mismatch warnings, and every card's artifact anchor links resolve. Exercises M2 F2.4 multi-run aggregation safeguards.
Tool: agent-browser
Evidence: screenshot, dom-text(.scenario-card) count equals total scenarios across runs, terminal-output (HTTP HEAD against each .scenario-card a[href] returns 200)

### VAL-CROSS-022: After each milestone gate, `commands.test`, `commands.typecheck`, `commands.lint` all pass against the modified codebase
Crosses any milestone (M1–M10) → M1 F1.5 (repo test scaffolding). At the end of every milestone, the three command strings defined in `services.yaml` (`bats engine/scripts/tests engine/asserts/tests && uv run --directory engine/testgrid pytest`, `uv run --directory engine/testgrid mypy src/testgrid`, `uv run --directory engine/testgrid ruff check src/testgrid && shellcheck ... && yamllint ... && helm lint ...`) must each exit 0.
Tool: bash
Evidence: terminal-output (each of the three commands prints summary line + exit 0), file(services.yaml)

### VAL-CROSS-023: Authored cloud-native YAMLs (M8) pass the full lint suite (M1 F1.5 yamllint + helm lint + kubectl --dry-run=client + kubeval)
Crosses M8 (cloud-native-primers) → M1 (engine-foundations test scaffolding). For every YAML under `engine/skills/chart-test-swarm/references/integrations/cloud-native/` (and any related scenario files under `examples/`), the lint chain must produce clean output: `yamllint` exits 0, every Kubernetes manifest validates with `kubectl apply --dry-run=client -f`, every Helm chart in those primers passes `helm lint`, and `kubeval` passes per the non-functional requirements section.
Tool: bash
Evidence: terminal-output (yamllint exits 0 + kubectl --dry-run=client over all cloud-native YAMLs exits 0 + kubeval exits 0)

### VAL-CROSS-024: Every completed feature (F-ID) has its corresponding bd issue closed in the .beads tracker
Crosses every milestone (M1–M10). At mission close, `bd list --status closed` must return one entry per feature_id documented in `features.json` (38 total per the mission proposal); any feature whose code lands without a closed bd issue is a contract violation. Cross-checked by joining bd closed list against features.json feature_id list.
Tool: bash
Evidence: terminal-output (comm -23 <(jq -r '.features[].id' features.json | sort) <(bd list --status closed -o json | jq -r '.[].id' | sort) → empty), file(.beads/issues.jsonl)

### VAL-CROSS-025: Dispatch parallelism honors the 16 GiB / 2-cluster ceiling — no third concurrent cluster ever appears
Crosses M1 (dispatch-swarm.sh parallelism cap) → M9 (CLI parallelism flag) → integration scenarios. With `chart-test-swarm run --all --parallelism 4` (deliberately above ceiling), the engine must clamp to 2 concurrent clusters; observed via `kind get clusters` + `minikube profile list` snapshots taken every 5s during a multi-scenario run. The peak count of `chart-test-swarm-*` clusters across the run must be ≤ 2.
Tool: bash
Evidence: terminal-output (monitoring loop captures cluster counts; max line shows ≤2), file(reports/run-<id>/run-meta.yaml shows num_agents capped)

### VAL-CROSS-026: Concurrent CLI invocations against the same reports/ directory do not corrupt each other
Two `chart-test-swarm run --scenario <distinct paths>` invocations launched concurrently against the same `reports/` directory each produce their own `reports/run-<id>/` subdirectory with unique ids. The two run directories do not overlap (different timestamps, different run ids). After both complete, the dashboard build (`chart-test-swarm dashboard`) renders both runs in its index with no broken artifact links. Pass requires distinct run ids + no overlapping subdirs + both visible in rebuilt dashboard.
Tool: bash
Evidence: terminal-output (count distinct `reports/run-*` directories after concurrent run = 2), file(reports/dist/index.html), dom-text(`section.runs tbody tr`) shows both run ids

### VAL-CROSS-027: Every CLI subcommand exposes --help and matches the subcommands listed under `--help` at the root
For each subcommand path in (`run`, `dashboard`, `list integrations`, `list variants`, `generate pick`, `generate author`, `generate explore`), `chart-test-swarm <path> --help` exits 0 within 5 seconds with a non-empty stdout. The set of subcommands listed under `chart-test-swarm --help` matches the union of subcommand paths whose `--help` returns 0 (no dark subcommands; no advertised commands without help). Pass requires every advertised subcommand to expose --help AND no orphan subcommands.
Tool: bash
Evidence: exit-code per subcommand, terminal-output (`chart-test-swarm --help` listing == set of subcommands with working `--help`)

### VAL-CROSS-028: `RUN_ID` collisions across concurrent dispatches are detected, not silently overwritten
Two `dispatch-swarm.sh` (or CLI-equivalent) invocations against the same `reports/` directory in the same second either: (a) both produce distinct `run-<id>` subdirs because the `RUN_ID` format includes a uniqueness suffix (e.g., `run-20260520-101500-$$` or `run-20260520-101500-<hash>`), OR (b) the second invocation detects the existing `reports/run-<existing-id>/` and refuses with a stderr line naming the existing run + a suggestion (`--run-id <override>` or wait a second). Pass requires that running two dispatches concurrently NEVER results in only ONE `run-*` directory holding interleaved artifacts from both invocations.
Tool: bash
Evidence: bash-test (launch two `dispatch-swarm.sh` in background within the same second, wait for both, assert `ls reports/run-* -d | wc -l` reports the expected count and that no single dir contains contradictory `agent-*/result.yaml` from both invocations)

### VAL-CROSS-029: `helm --set` overrides with backslash-escaped dots or special characters survive scenario → engine round-trip
For a scenario with `product.set: { "podAnnotations.sidecar\\.istio\\.io/inject": "true" }` (i.e., the existing `customer-A-istio.yaml` fixture), `run-scenario.sh` produces an `applied-overrides.yaml` (or, equivalently, `helm get values <release> -n <ns>`) in which `podAnnotations` contains a key `sidecar.istio.io/inject: "true"` (literal dot preserved, NOT split into a nested map). Pass requires the round-trip preserves the escaped key.
Tool: bash
Evidence: bash-test (run the `customer-A-istio` scenario, then `helm get values sample -n sample -o yaml | yq '.podAnnotations'` produces a key with literal `.` characters), file(reports/run-*/scenario-customer-A-istio-*/artifacts/applied-overrides.yaml)

### VAL-CROSS-030: Pre-F1.2 scenarios (no raw_manifest, only helm preinstall items) continue to validate without modification
A scenario authored prior to F1.2 (canonical example: the pre-mission `examples/sample-product-chart/chart-test-swarm/scenarios/customer-A-istio.yaml` shape — only helm preinstall items, `additionalProperties:false` on the helm preinstall shape, no `kind:` discriminator) MUST continue to validate against the post-F1.2 schema (`engine/templates/scenario.schema.json`) with exit 0. Equivalently: the relaxation introduced for `raw_manifest` MUST NOT regress backward compatibility for existing helm-only scenarios. Pass requires: running `jsonschema -i <each pre-mission scenario> engine/templates/scenario.schema.json` for each of the five pre-mission scenarios returns exit 0 AND emits no warnings about additional properties or unknown discriminators.
Tool: jsonschema
Evidence: terminal-output (`for f in customer-A-istio.yaml with-cert-manager.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml minimal.yaml; do jsonschema -i "examples/sample-product-chart/chart-test/scenarios/$f" engine/templates/scenario.schema.json && echo OK $f; done` outputs `OK` five times)
