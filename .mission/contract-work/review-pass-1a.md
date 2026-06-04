# Review Pass 1A — User-Flow Completeness Gaps

## Summary

The existing 223-assertion contract is strong on **structural** (files exist, schemas validate) and **happy-path execution** (scenarios PASS, dashboard renders, CLI subcommands wired) coverage. It is materially weaker on **error paths, discoverability, concurrency, edge inputs, and diagnostics**. A developer using this testgrid will routinely encounter conditions the contract does not currently assert: a scenario referencing a missing fixture file, a kind cluster that fails to boot mid-run, an LLM that returns malformed YAML, Ctrl+C mid-dispatch, two scenarios racing for the same cluster name, an old run-* report becoming the only signal of what broke. The contract also leaves the "natural follow-ons" implicit — e.g., the CLI is required to wrap dispatch-swarm.sh (M9), but no assertion proves that `chart-test-swarm run` and `bash engine/scripts/run-scenario.sh` produce equivalent reports/run-* outputs for the same scenario.

This pass proposes **22 new assertions** spread across all 10 areas (engine-foundations, dashboard, certificates, ingress, gateway-api, mesh, policy, cloud, cli, llm) plus cross-flows. Each fills a gap that maps to a concrete developer user-flow: starting a run, watching it succeed or fail, recovering from a failure, re-running from a prior artifact, asking for help, generating a scenario.

---

## Proposed New Assertions

### VAL-ENGINE-025: run-scenario.sh emits an actionable error when a referenced fixture path is missing
Running `bash engine/scripts/run-scenario.sh <scenario.yaml>` against a scenario whose `cluster.preinstall` includes `{kind: raw_manifest, path: chart-test/fixtures/does-not-exist.yaml}` exits non-zero within 30 seconds **before** any cluster boot is attempted. Stderr names the offending scenario id, the offending preinstall index, AND the missing path literal. No `chart-test-swarm-*` cluster is created (verified via `kind get clusters` + `minikube profile list`). Pass requires: pre-boot failure, named scenario id, named missing path, no cluster side effects.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`kind get clusters`), command-output(`minikube profile list -o json`)
Rationale: User flow — author writes a new scenario, typos a fixture path. Current contract proves schema validity but never asserts that `apply-scenario.sh` validates filesystem references before destructive cluster work begins. Without this, a typo wastes 30–60s of cluster boot before producing an opaque failure deep in the apply stage.

### VAL-ENGINE-026: Failed scenarios still emit a partial artifacts/ bundle
After a `run-scenario.sh` invocation that fails mid-preinstall or mid-assert (status: FAIL in result.yaml), the corresponding `reports/run-*/scenario-*/artifacts/` directory still exists and still contains `scenario.yaml` (verbatim copy of input), `versions.json` (tool versions captured), AND a `logs/` subdirectory with at least `preinstall.log` and `cluster-up.log`. The `applied-overrides.yaml` may be present (if the helm merge happened) or absent (if failure preceded merge). Pass requires that scenario.yaml + versions.json + logs/ are present even on failure.
Tool: bash
Evidence: file(reports/run-*/scenario-*/artifacts/scenario.yaml), file(reports/run-*/scenario-*/artifacts/versions.json), file-existence(reports/run-*/scenario-*/artifacts/logs/preinstall.log)
Rationale: User flow — scenario fails in CI, developer needs to diagnose. Current VAL-ENGINE-013/14/15 only assert artifacts on success. If a failure produces no artifacts, the developer must rerun locally to see what broke — slow, sometimes unreproducible. Failure cases are exactly when artifacts matter most.

### VAL-ENGINE-027: run-scenario.sh forwards SIGINT to clean up the cluster
Running `bash engine/scripts/run-scenario.sh <scenario.yaml>` in the background, waiting for `kind get clusters | grep chart-test-swarm-` to show the cluster, then sending `SIGINT` (Ctrl+C) to the parent script results in: (a) exit within 60 seconds with a non-zero status, (b) `kind get clusters | grep chart-test-swarm-` returns no rows after exit, (c) `docker ps | grep chart-test-swarm-` returns no rows, (d) `reports/run-*/scenario-*/result.yaml` (if written) carries status `INTERRUPTED` or equivalent (NOT `PASS`). Pass requires teardown completion + non-PASS status post-interrupt.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`kind get clusters`), command-output(`docker ps`), file(reports/run-*/scenario-*/result.yaml)
Rationale: User flow — developer kicks off a run, realizes wrong scenario, hits Ctrl+C. Without graceful interrupt handling, the cluster orphans (violates architecture invariant #5) and the developer must manually clean up. The contract's VAL-ENGINE-023/24 only cover normal completion, not interrupt.

### VAL-ENGINE-028: Every engine script accepts --help and exits 0 with a usage banner
For each of `cluster-up.sh`, `cluster-down.sh`, `apply-scenario.sh`, `run-asserts.sh`, `run-scenario.sh`, `dispatch-swarm.sh`, `build-dashboard.sh`, invoking the script with `--help` exits 0 within 5 seconds. Stdout contains the literal `Usage` (or `USAGE`) AND the script's filename. No cluster operations are performed (`kind get clusters` and `minikube profile list -o json` show no new entries). Pass requires all seven scripts to satisfy all conditions.
Tool: bash
Evidence: exit-code per script, terminal-output(stdout), command-output(`kind get clusters`), command-output(`minikube profile list -o json`)
Rationale: Architecture §3.1 says "Every script accepts `--help` and exits non-zero on unknown flags" — the unknown-flag case is implicit but the `--help`-must-work case is not asserted. User flow: new developer onboarding, runs `bash engine/scripts/cluster-up.sh --help` to discover its interface.

### VAL-ENGINE-029: Scenario id collisions in reports/run-* produce a deterministic suffix, not silent overwrite
Running the same scenario twice into the same `reports/run-<id>/` directory (e.g., via `RUN_ID=run-fixed bash engine/scripts/run-scenario.sh ...` twice) does NOT silently overwrite the first run's `scenario-<id>/` subdirectory. The second invocation either: (a) refuses with a clear stderr message identifying the prior scenario directory, or (b) appends a `-2`/timestamp suffix to the scenario directory name. Pass requires that after both invocations, BOTH scenario subdirs are present on disk and both have valid `result.yaml` files.
Tool: bash
Evidence: terminal-output, file-existence(reports/run-fixed/scenario-<id>-*/result.yaml count == 2), exit-code
Rationale: Architecture §1 invariant: "Reports are immutable once written; multiple runs accumulate side-by-side". Without this assertion, a re-dispatch could silently shred the prior evidence — exactly the audit trail the contract is built to preserve.

### VAL-DASH-019: Scenario card surfaces FAIL detail (error message or log link)
For any scenario card whose status is `FAIL`, the rendered HTML MUST include either: (a) a visible text element containing a non-empty error summary string (truncated >= 40 chars OK), OR (b) an anchor labeled "Log" / "Error log" whose `href` resolves to a non-empty `logs/*.log` file under the run's artifacts. Cards with status `PASS` MUST NOT render an empty error-summary element (no `class="error-summary"` with empty text). Pass requires every FAIL card to expose either an error string or a log link.
Tool: agent-browser
Evidence: dom-text(`details[data-status="FAIL"] .error-summary, details[data-status="FAIL"] a.error-log`)
Rationale: User flow — developer opens the dashboard to see what failed. Current VAL-DASH-* assertions cover status badges, artifact links, and visual cues for cloud-native, but never assert that a FAIL card actually tells the user *why* it failed. A red badge with no explanation is dashboard-as-decoration.

### VAL-DASH-020: Re-running a scenario into a new run-* dir leaves prior runs intact in the index
After a baseline run produces `reports/run-A/` (rendered to `reports/dist/index.html`), a second run produces `reports/run-B/`, and `bash engine/scripts/build-dashboard.sh` is invoked: the regenerated index page lists BOTH run-A and run-B in its Runs table, and clicking each run's link reveals its corresponding scenario cards. The run-A artifact links still resolve on disk (no broken hrefs introduced by the rebuild). Pass requires both runs visible, both link sets resolve.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr`) lists both `run-A` and `run-B`, terminal-output (script walks all `a[href]` under `details[data-run-id="run-A"]` and confirms `test -f` for each resolved path)
Rationale: User flow — developer runs against a chart yesterday and today; they need to see both runs in the dashboard to confirm "did my change regress yesterday's PASS?". VAL-DASH-014/15 cover mixed legacy + rich shapes; nothing currently asserts that two CHRONOLOGICAL rich runs both surface.

### VAL-DASH-021: Corrupt result.yaml in a run dir is reported but does not crash the dashboard build
Place an intentionally invalid `result.yaml` (e.g., truncated, missing keys, invalid YAML syntax) into `reports/run-<corrupt>/`. Running `bash engine/scripts/build-dashboard.sh` exits 0; stderr emits a clear warning naming the offending run id and the corruption type (`invalid YAML`, `missing required key 'scenarios'`, etc.); the resulting `reports/dist/index.html` either omits the corrupt run with a placeholder row labeled "metadata error" OR omits it entirely with a stderr warning. Pass requires: exit 0, named warning, non-crashing render.
Tool: bash
Evidence: exit-code 0, terminal-output(stderr contains the run id + reason), file(reports/dist/index.html)
Rationale: User flow — developer's CI accumulates 200 runs; one gets truncated by a disk-full scenario; subsequent dashboard builds in CI must not start failing. Adjacent to VAL-DASH-016 (orphan dir) but stronger: covers structurally-present-but-corrupt content.

### VAL-CERT-023: TLS private-key fixtures are gitignored or pre-generated, not committed real keys
The repo's `.gitignore` (or `examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore`) excludes `*.key` files, OR the committed `ca.key` and any other `*.key` files in the fixtures dir have a header comment indicating they are "test-only ephemeral keys, regenerated by ./regen.sh" (or equivalent). No fixture key is referenced by a production-shaped certificate (e.g., a key whose corresponding cert names a real domain such as `example.com` or a real ACME issuer URL pointing at a Let's-Encrypt production endpoint).
Tool: bash
Evidence: file(.gitignore) or file(examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore), terminal-output(`grep -l 'BEGIN.*PRIVATE KEY' examples/sample-product-chart/chart-test/fixtures/certificates/*.key | xargs head -n 5`)
Rationale: User flow — developer forks the repo, accidentally commits a real CA key. VAL-CERT-020 asserts the key is parseable; nothing currently asserts it's *safe to commit*. A real private key in a public repo is a security incident.

### VAL-INGRESS-022: Ingress controller pod is Ready before the variant assertion runs its HTTP probe
For each ingress controller variant (traefik, nginx-ingress, contour) before any in-cluster `curl` HTTP probe is issued, the controller pod's `status.conditions[type=Ready].status` is `True` AND its container's `readinessProbe` has succeeded (verifiable: `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=<controller> -n <controller-ns> --timeout=120s` exits 0). Probes that run against a not-yet-ready controller MUST be retried or wait, not flake. Pass requires every variant to satisfy the wait before its HTTP assertion.
Tool: kubectl
Evidence: kubectl-output(`kubectl wait --for=condition=ready` exits 0), terminal-output(test runner log shows the wait happened before the curl)
Rationale: User flow — CI runs the suite, intermittent FAIL on a single ingress variant because the curl raced the controller's readiness. Current VAL-INGRESS-007 through VAL-INGRESS-018 assert HTTP outcomes but never assert the controller is ready first. Flake = false-negative noise in CI.

### VAL-GW-020: Gateway API CRD version is captured in the artifacts/ bundle
For every gateway-api scenario run that PASSes, the produced `reports/run-*/scenario-*/artifacts/manifests/` directory contains at least one file whose content shows `apiVersion: gateway.networking.k8s.io/v1` (or `v1beta1` if the scenario declares it) AND `artifacts/versions.json` includes a new key `gateway_api_crds` reflecting the installed CRD version (e.g., `v1.0.0`, `v1.1.0`). Pass requires both the manifest evidence and the version stamp.
Tool: bash
Evidence: file(reports/run-*/scenario-*/artifacts/manifests/*.yaml), command-output(`yq '.apiVersion'`), command-output(`jq '.gateway_api_crds' artifacts/versions.json`)
Rationale: User flow — Gateway API ships breaking changes between v1.0 and v1.1; a scenario authored against v1.0 may misbehave silently on v1.1. The architecture's "artifact reproducibility" invariant requires capturing what CRD version was used. VAL-ENGINE-015 covers kube/helm/kind versions but not CRD versions.

### VAL-MESH-022: Mesh teardown removes mesh-installed admission webhooks
After `cluster-down.sh` runs for a cluster that hosted a mesh variant (istio or linkerd), the next clean kind cluster created in the same Docker Desktop session shows zero `MutatingWebhookConfiguration` or `ValidatingWebhookConfiguration` entries with names matching `istio-sidecar-injector` or `linkerd-proxy-injector-webhook`. Pass requires zero mesh-installed webhooks survive teardown.
Tool: kubectl
Evidence: kubectl-output(`kubectl get mutatingwebhookconfiguration -o name | grep -E 'istio|linkerd'` returns empty), exit-code 1 from grep
Rationale: User flow — developer tears down mesh scenario, immediately runs an ingress scenario in a fresh cluster, ingress scenario fails because a phantom mesh webhook is still intercepting pod creation. Webhook leakage is one of the top mesh-teardown gotchas; VAL-CROSS-016/17 cover cluster + container teardown but not in-cluster admission state.

### VAL-POLICY-020: Policy webhook failure mode is documented and exercised
Each policy primer (opa-gatekeeper, kyverno) declares in a "Webhook failure mode" section whether the chart-as-shipped configures `failurePolicy: Fail` or `failurePolicy: Ignore`. For at least one variant per engine, the rendered admission webhook (verified via `kubectl get validatingwebhookconfiguration -o yaml`) shows the declared failurePolicy. A scenario that intentionally takes the policy controller offline (e.g., `kubectl scale deploy/gatekeeper-controller --replicas=0`) THEN applies a target resource exhibits the documented behavior (apply succeeds under Ignore; apply fails with webhook-timeout under Fail). Pass requires primer-documented + cluster-observed + scenario-exercised match.
Tool: kubectl
Evidence: file(<primer>.md contains `## Webhook failure mode`), kubectl-output(`.webhooks[0].failurePolicy`), terminal-output(deliberate-outage probe result)
Rationale: User flow — security-conscious operator deploys policy, then policy controller crashes. Whether prod admission fails-open (security regression) or fails-closed (cluster lockup) is a load-bearing operational behavior. Currently the contract verifies policy enforcement when controller is healthy but never the unhealthy case.

### VAL-CLOUD-019: Cloud-native authored YAMLs version-pin their cloud-K8s API
Each cloud-native primer documents a "Target Kubernetes version" (e.g., `GKE 1.30+`, `EKS 1.30+`, `AKS 1.30+`) in an explicit H2 heading. Every authored YAML under `examples/sample-product-chart/scenarios/cloud-native/` carries a `metadata.annotations.chart-test-swarm/target-k8s-version` annotation (or equivalent top-level comment), and the documented version matches what passes `kubeval --kubernetes-version <pinned>` in VAL-CLOUD-009. Pass requires the primer doc + per-scenario stamp + match with kubeval-pinned version.
Tool: bash
Evidence: terminal-output (`rg -n '^## Target Kubernetes version' engine/skills/chart-test-swarm/references/integrations/cloud-native/{gke,eks,aks}.md` returns ≥ 1 match per file), terminal-output (`yq '.metadata.annotations."chart-test-swarm/target-k8s-version"' examples/sample-product-chart/scenarios/cloud-native/*.yaml`)
Rationale: User flow — operator copies a GKE-Workload-Identity scenario from this repo into their cluster, the cluster is running GKE 1.27, the scenario uses an API only available at GKE 1.30; opaque failure. Cloud-native YAMLs are shipped *to consumers*; their reproducibility hinges on knowing the target version.

### VAL-CLI-019: CLI exits with a clear error for a missing scenario file (no Python traceback)
Invoking `chart-test-swarm run --scenario /tmp/does-not-exist.yaml` exits non-zero within 5 seconds. Stderr contains the literal path `/tmp/does-not-exist.yaml` AND a phrase like "not found" / "no such file" / "does not exist". Stderr DOES NOT contain `Traceback (most recent call last)` or `FileNotFoundError`. Pass requires non-zero exit + actionable message + no raw Python traceback.
Tool: bash
Evidence: exit-code, terminal-output(stderr)
Rationale: User flow — developer typos `--scenario` arg, gets back a Python traceback, can't tell where it went wrong. Tracebacks are debugging noise to users. CLI tools convert exceptions to friendly errors at the boundary; this assertion makes that explicit.

### VAL-CLI-020: CLI `--version` prints a semver-ish version string and exits 0
Running `chart-test-swarm --version` exits 0 within 2 seconds and stdout contains a version token matching `^\d+\.\d+\.\d+` (semver) OR `^v\d+\.\d+\.\d+`. The version is the version recorded in `engine/testgrid/pyproject.toml`'s `[project].version` field. Pass requires both exit 0, semver-shaped output, AND match against pyproject.
Tool: bash
Evidence: exit-code, terminal-output(stdout), command-output(`yq -p toml '.project.version' engine/testgrid/pyproject.toml`)
Rationale: User flow — developer files a bug, support asks "what version are you on?". Without `--version`, the answer is "I don't know". Standard CLI hygiene that VAL-CLI-003 (root --help) doesn't substitute for.

### VAL-CLI-021: CLI `run` and `bash engine/scripts/run-scenario.sh` produce equivalent reports/run-* outputs for the same scenario
For the same scenario YAML, invoking once via `chart-test-swarm run --scenario <path>` and once via `bash engine/scripts/run-scenario.sh <path>` both produce a `reports/run-*` directory. Comparing the two: `result.yaml.scenarios[].status` is identical, `artifacts/scenario.yaml` is byte-identical (or differs only in absolute-path normalization), `artifacts/versions.json` keys are identical (values may differ if tool versions changed), and `artifacts/applied-overrides.yaml` is byte-identical. Pass requires status equivalence + artifact-shape equivalence.
Tool: bash
Evidence: terminal-output(`diff <(yq '.scenarios[] | {id,status}' reports/run-A/result.yaml) <(yq '.scenarios[] | {id,status}' reports/run-B/result.yaml)` empty), terminal-output(`diff reports/run-A/scenario-*/artifacts/scenario.yaml reports/run-B/scenario-*/artifacts/scenario.yaml` empty)
Rationale: User flow — CI uses the engine scripts directly (faster), developer locally uses the CLI; both must produce equivalent results. The architecture promises the CLI is a "wrap" — this assertion proves it doesn't subtly differ. Currently VAL-CLI-007 only asserts the CLI invokes the script; nothing checks output parity.

### VAL-LLM-019: Generated scenarios refuse to overwrite an existing file without --force
Running `chart-test-swarm generate pick --output /tmp/exists.yaml` when `/tmp/exists.yaml` already exists with non-empty content exits non-zero, leaves the existing file's content byte-identical, and stderr contains the path + a phrase like "already exists" / "use --force". With `--force`, the same command exits 0 and replaces the content. The same protection applies to `generate author --output` and `generate explore --output`. Pass requires: refuse + actionable message + preservation; --force succeeds + replaces.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`sha256sum /tmp/exists.yaml`) before/after
Rationale: User flow — developer accidentally targets an output path that already holds a hand-authored scenario; LLM blows it away. Destroying user work silently is the worst kind of UX bug. The contract has no assertion preventing it today.

### VAL-LLM-020: `generate explore` writes its summary incrementally so a crash leaves a partial summary
With `CTS_LLM_CMD` set to a fake that succeeds for iteration 1 and then crashes (`exit 137`) on iteration 2, running `chart-test-swarm generate explore --max-iterations 3 --output /tmp/explore.json` exits non-zero and `/tmp/explore.json` exists with exactly one record (the iteration-1 result). The file is valid JSON parseable by `jq`. Pass requires: non-zero CLI exit, single-record JSON, valid JSON shape.
Tool: bash
Evidence: exit-code, file(/tmp/explore.json), command-output(`jq 'length' /tmp/explore.json` == 1)
Rationale: User flow — developer runs explore for an hour, machine dies; without incremental writes, all evidence is lost. The current VAL-LLM-011 only asserts the post-completion summary, never the mid-run durability. Long-running exploratory jobs MUST be crash-tolerant.

### VAL-LLM-021: Generated scenarios carry `generated_by` provenance and the LLM cmd used
Every scenario produced by `generate pick`, `generate author`, or `generate explore` includes a top-level `generated_by` mapping with: `by` (always present, value is one of `pick|author|explore`), `cmd` (the resolved `CTS_LLM_CMD` for author/explore; absent or `null` for pick), and `timestamp` (ISO-8601 UTC). The scenario otherwise validates against the schema (i.e., `generated_by` is either schema-allowed or in a documented `additionalProperties: true` extension namespace). Pass requires all three keys present + schema-valid result.
Tool: yq
Evidence: command-output(`yq '.generated_by.by, .generated_by.cmd, .generated_by.timestamp' <generated.yaml>`) — three non-null values for author/explore; non-null `by` + `timestamp` for pick
Rationale: User flow — developer reviews CI dashboard, sees a scenario card, wants to know "was this hand-authored or LLM-authored, and with which model?". VAL-CROSS-003 mentions `generated_by.by` but the LLM area's own assertions never require it. Provenance is load-bearing for trust + reproducibility.

### VAL-CROSS-026: Concurrent CLI invocations against the same reports/ directory do not corrupt each other
Two `chart-test-swarm run --scenario <distinct paths>` invocations launched concurrently against the same `reports/` directory each produce their own `reports/run-<id>/` subdirectory with unique ids. The two run directories do not overlap (different timestamps, different run ids). After both complete, the dashboard build (`chart-test-swarm dashboard`) renders both runs in its index with no broken artifact links. Pass requires distinct run ids + no overlapping subdirs + both visible in rebuilt dashboard.
Tool: bash
Evidence: terminal-output (count distinct `reports/run-*` directories after concurrent run = 2), file(reports/dist/index.html), dom-text(`section.runs tbody tr`) shows both run ids
Rationale: User flow — developer runs CLI locally while CI is also running CLI on the same checkout; both processes race the timestamp generator. Cluster prefix collisions are covered by VAL-ENGINE-022, but reports/run-* directory collisions are not. Two runs writing to the same directory at the same time is silent data loss.

### VAL-CROSS-027: Every CLI subcommand exposes --help and matches the subcommands listed under `--help` at the root
For each subcommand path in (`run`, `dashboard`, `list integrations`, `list variants`, `generate pick`, `generate author`, `generate explore`), `chart-test-swarm <path> --help` exits 0 within 5 seconds with a non-empty stdout. The set of subcommands listed under `chart-test-swarm --help` matches the union of subcommand paths whose `--help` returns 0 (no dark subcommands; no advertised commands without help). Pass requires every advertised subcommand to expose --help AND no orphan subcommands.
Tool: bash
Evidence: exit-code per subcommand, terminal-output (`chart-test-swarm --help` listing == set of subcommands with working `--help`)
Rationale: User flow — developer discovers the CLI through `--help`, drills into each subcommand. VAL-CLI-003 covers root `--help`; VAL-CLI-006 covers `run --help`; the dashboard/list/generate sub-helps are untested. Discoverability is the difference between a CLI that's used and one that's abandoned.

---

## Proposed Modifications to Existing Assertions

(None proposed in this pass — all gaps are coverable as additions without restructuring existing assertions.)
