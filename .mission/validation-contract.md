# Chart-Test-Swarm Validation Contract

This is the formal validation contract — the finite checklist of testable behavioral assertions that define "done" for the mission. Validators MUST treat each assertion as black-box and behavior-based; they NEVER derive tests from implementation details.

Each assertion has a stable ID, a behavioral description with explicit pass/fail conditions, the tool used to test it, and the evidence required.

## Coverage Map

| Area                 | ID prefix      | File-origin section |
| -------------------- | -------------- | ------------------- |
| Engine Foundations   | VAL-ENGINE-NNN | Milestone 1         |
| Dashboard            | VAL-DASH-NNN   | Milestone 2         |
| Certificates         | VAL-CERT-NNN   | Milestone 3         |
| Ingress Controllers  | VAL-INGRESS-NNN| Milestone 4         |
| Gateway API          | VAL-GW-NNN     | Milestone 5         |
| Service Mesh         | VAL-MESH-NNN   | Milestone 6         |
| Policy Engines       | VAL-POLICY-NNN | Milestone 7         |
| Cloud-Native Primers | VAL-CLOUD-NNN  | Milestone 8 (AUTHORED ONLY) |
| CLI Tool             | VAL-CLI-NNN    | Milestone 9         |
| LLM Generator        | VAL-LLM-NNN    | Milestone 10        |
| Cross-Area           | VAL-CROSS-NNN  | spans multiple      |

## Discipline

- Cluster operations: tests MUST use cluster names with `chart-test-swarm-` prefix.
- Cloud-native (VAL-CLOUD-*): NO `kubectl --context` against real GKE/AKS/EKS clusters.
- Every assertion's `Tool` is the concrete CLI/skill used to test it.
- Every assertion's `Evidence` is concrete (file paths, exit codes, command output, screenshots, DOM selectors).

---


## Area: Engine Foundations
## Area: Engine Foundations

### VAL-ENGINE-001: cluster-up.sh provisions a minikube profile with the required prefix
Running `PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-mvalid bash engine/scripts/cluster-up.sh` from a clean state exits 0 within 180 seconds. After it returns, `minikube profile list -o json` contains exactly one entry whose `Name` equals `chart-test-swarm-mvalid` and whose status is `Running`, and `kubectl config current-context` equals `chart-test-swarm-mvalid` (or the minikube-canonical equivalent the script sets). Pass requires both the profile existence and the active context. Fail if the script exits non-zero, the profile is missing, or the profile is in any state other than `Running`.
Tool: bash
Evidence: terminal-output, exit-code, file(reports/run-*/logs/cluster-up.log), command-output(`minikube profile list -o json`), command-output(`kubectl config current-context`)

### VAL-ENGINE-002: cluster-up.sh refuses cluster names without the chart-test-swarm- prefix
Running `PROVIDER=kind CLUSTER_NAME=notprefixed bash engine/scripts/cluster-up.sh` exits with a non-zero status (>= 1) within 5 seconds. Stderr contains the literal substring `chart-test-swarm-`. After the call, `kind get clusters` does not list any cluster named `notprefixed`. The same invocation with `PROVIDER=minikube` produces the same refusal behavior. Pass requires non-zero exit, the prefix-related stderr message, AND no side-effect cluster created. Additionally, invoking `cluster-up.sh` with `CLUSTER_NAME` unset MUST produce a cluster name matching `^chart-test-swarm-[a-z0-9-]+$` (i.e., a non-empty suffix is required; the bare prefix `chart-test-swarm` MUST NOT be accepted).
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`kind get clusters`), command-output(`minikube profile list`)

### VAL-ENGINE-003: cluster-down.sh idempotently removes a minikube profile
Given `chart-test-swarm-mtearx` exists as a minikube profile, running `PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-mtearx bash engine/scripts/cluster-down.sh` exits 0 within 120 seconds and the profile no longer appears in `minikube profile list -o json`. Re-running the identical command immediately also exits 0 (no-op branch). Pass requires both invocations exit 0 AND no profile remaining.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`minikube profile list -o json`)

### VAL-ENGINE-004: cluster-down.sh idempotently removes a kind cluster (regression)
Given `chart-test-swarm-ktearx` exists as a kind cluster, running `PROVIDER=kind CLUSTER_NAME=chart-test-swarm-ktearx bash engine/scripts/cluster-down.sh` exits 0 within 60 seconds and the cluster no longer appears in `kind get clusters`. Re-running the same command immediately exits 0. Pass requires both exits 0 AND no kind cluster remaining.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`kind get clusters`)

### VAL-ENGINE-005: Scenario schema accepts minikube and rejects unknown providers and unprefixed names
Validating a scenario whose `cluster.provider` is `minikube` against `engine/templates/scenario.schema.json` via `jsonschema -i scenario.yaml engine/templates/scenario.schema.json` exits 0. Validating an otherwise-identical scenario with `cluster.provider: rancher-desktop` exits non-zero and stderr references the provider field. Validating a scenario whose `cluster.name` (or equivalent backend-name field, per F1.1 schema spec) is `mycluster` (missing the required `chart-test-swarm-` prefix) exits non-zero with the pattern-validation error referencing the name field. Pass requires all three outcomes.
Tool: jsonschema
Evidence: exit-code, terminal-output(stderr), file(engine/templates/scenario.schema.json)

### VAL-ENGINE-006: Scenario schema accepts raw_manifest preinstall items with a path
Validating a scenario containing `cluster.preinstall: [{kind: raw_manifest, path: chart-test/fixtures/example.yaml, namespace: default}]` against `engine/templates/scenario.schema.json` via `jsonschema` exits 0. Validating an otherwise-identical scenario with `kind: raw_manifest` but no `path` field exits non-zero. A pre-existing scenario with a `kind: helm` preinstall item still validates 0 (no regression). Pass requires all three outcomes.
Tool: jsonschema
Evidence: exit-code, terminal-output(stderr), file(engine/templates/scenario.schema.json)

### VAL-ENGINE-007: Scenario schema rejects unknown preinstall kinds
Validating a scenario with a preinstall item declaring `kind: kustomize` (or any kind outside `{helm, raw_manifest}`) against the schema via `jsonschema` exits non-zero and stderr references the preinstall_item discriminator (e.g. `kind` field, `oneOf`, or enum mismatch). Pass requires non-zero exit AND a stderr message naming `kind` or the unmatched value.
Tool: jsonschema
Evidence: exit-code, terminal-output(stderr)

### VAL-ENGINE-008: apply-scenario.sh applies raw_manifest preinstall items via kubectl
Given a kind cluster `chart-test-swarm-raw1` is current context and a scenario whose `cluster.preinstall` includes `{kind: raw_manifest, path: <abs path to a ConfigMap manifest in namespace cts-raw>}`, running `bash engine/scripts/apply-scenario.sh <scenario.yaml>` exits 0 within 120 seconds. After it returns, `kubectl -n cts-raw get configmap <name> -o yaml` returns the manifest's resource (exit 0). A scenario combining one `helm` preinstall and one `raw_manifest` preinstall in that order produces both the helm release (`helm list -n <ns>` shows it) and the raw resource (`kubectl get` finds it). Pass requires both single-item and mixed-item scenarios to succeed.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`kubectl get configmap -o yaml`), command-output(`helm list -n <ns>`)

### VAL-ENGINE-009: envoy-gateway primer references the OCI gateway-helm repository
`grep -rn 'oci://docker.io/envoyproxy/gateway-helm' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` exits 0 with at least one match. `grep -rn 'https://gateway.envoyproxy.io/install/' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` (the defunct classic-repo URL) returns no matches (exit 1). The associated scenario template under examples or scenarios for envoy-gateway likewise contains the OCI ref and no defunct URL. Pass requires the OCI string present AND the defunct URL absent in both files.
Tool: bash
Evidence: exit-code, terminal-output, file(engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md)

### VAL-ENGINE-010: envoy-gateway scenario runs end-to-end on a kind backend
`bash engine/scripts/run-scenario.sh <envoy-gateway scenario yaml>` against a fresh kind cluster `chart-test-swarm-eg1` exits 0 within 600 seconds. The emitted `reports/.../scenario-*/result.yaml` has `status: PASS`. `helm list -n envoy-gateway-system` shows the `envoy-gateway` release in `deployed` status. The previously-failing classic-repo error is absent from `reports/.../logs/preinstall.log`. Pass requires exit 0, PASS in result.yaml, AND deployed helm release.
Tool: bash
Evidence: exit-code, file(reports/run-*/scenario-*/result.yaml), command-output(`helm list -n envoy-gateway-system`), file(reports/.../logs/preinstall.log)

### VAL-ENGINE-011: Integration primers live under category subdirectories
`find engine/skills/chart-test-swarm/references/integrations -maxdepth 1 -type f -name '*.md' | wc -l` returns 0 (no primers at the top level). For each of the six pre-existing primers, the file is present under exactly one of `certificates/`, `ingress-controllers/`, `service-mesh/`, `gateway-api/`, or `policy/` (paths: `certificates/cert-manager.md`, `ingress-controllers/traefik.md`, `service-mesh/istio-service-mesh.md`, `service-mesh/istio-ingress-gateway.md`, `gateway-api/gateway-api.md`, `policy/opa-gatekeeper.md`). Pass requires the top-level count to be 0 AND all six expected category paths to exist.
Tool: bash
Evidence: terminal-output, command-output(`find ... -name '*.md'`), file-existence(per primer path)

### VAL-ENGINE-012: Primer content is byte-identical to the pre-reorg version
For each of the six pre-existing primers, `git diff HEAD~<reorg-commit> -- <new path>` shows the file as a pure rename (similarity 100%) OR `sha256sum` of the new file matches the sha256sum of the pre-reorg blob (recorded in the F1.3 commit message). No content edits accompany the move. Pass requires every primer to either be a 100%-similarity git rename OR have matching sha256 sums.
Tool: bash
Evidence: command-output(`git log --follow --name-status`), command-output(`sha256sum`), file(engine/skills/chart-test-swarm/references/integrations/<category>/<primer>.md)

### VAL-ENGINE-013: Every successful run emits artifacts/scenario.yaml and applied-overrides.yaml
After a successful `bash engine/scripts/run-scenario.sh <scenario>` against a kind backend, the produced `reports/run-*/scenario-*/artifacts/scenario.yaml` exists and `yq -e '.id' artifacts/scenario.yaml` returns the same id as the input scenario. `artifacts/applied-overrides.yaml` exists, is non-empty, and `yq` parses it as a YAML mapping representing the final merged helm values dict for the product chart (key set is a superset of the scenario's `product.set` keys). Pass requires both files exist, parse, and contain the asserted fields.
Tool: yq
Evidence: file(reports/run-*/scenario-*/artifacts/scenario.yaml), file(reports/run-*/scenario-*/artifacts/applied-overrides.yaml), command-output(`yq -e '.id'`)

### VAL-ENGINE-014: Reports artifact bundle contains fixtures and rendered manifests
After a successful run, `reports/run-*/scenario-*/artifacts/fixtures/` exists as a directory. If the source scenario referenced any fixture files, each one is copied into `artifacts/fixtures/` with the same basename and `sha256sum` matching the source. `artifacts/manifests/` exists and contains at least one YAML file produced from `kubectl get -o yaml` for resources created by the scenario (verifiable: `yq '.kind' artifacts/manifests/*.yaml` returns non-empty Kubernetes Kind strings). Pass requires both directories present, fixtures byte-matching when applicable, and manifests parseable as Kubernetes resources.
Tool: bash
Evidence: file-existence(artifacts/fixtures/), file-existence(artifacts/manifests/), command-output(`sha256sum`), command-output(`yq '.kind'`)

### VAL-ENGINE-015: artifacts/versions.json captures helm, kubectl, kind, minikube, and k8s_server versions
After a successful run, `reports/run-*/scenario-*/artifacts/versions.json` exists. `jq -e '.helm,.kubectl,.kind,.minikube,.k8s_server' artifacts/versions.json` returns five non-null string values. Each value is a recognizable version token (matches a semver-ish regex such as `^v?[0-9]+\.[0-9]+`). For a kind-backed run the `minikube` field may be the string of the locally-installed binary version (not the cluster); for a minikube-backed run the `kind` field is similarly the binary version. Pass requires the file exists, all five keys present, and all five values non-empty.
Tool: jq
Evidence: file(reports/run-*/scenario-*/artifacts/versions.json), command-output(`jq -e ...`)

### VAL-ENGINE-016: A reviewer can re-apply the scenario from artifacts alone
Copy `reports/run-*/scenario-*/artifacts/` to a tmp dir on a freshly-created kind cluster `chart-test-swarm-replay1` (no access to the source repo's `examples/` tree). Running `bash engine/scripts/apply-scenario.sh <tmp>/artifacts/scenario.yaml` with `PROJECT_DIR=<tmp>/artifacts` exits 0 within 300 seconds and reproduces the helm releases listed in the original run's `result.yaml`. Any fixture paths referenced inside the artifact scenario.yaml resolve relative to the artifact bundle. Pass requires the apply to succeed end-to-end without referencing the source tree.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`helm list -A`), file(<tmp>/artifacts/scenario.yaml)

### VAL-ENGINE-017: bats test suite runs cleanly on engine/scripts/tests/
Running `bats engine/scripts/tests/` from the repo root exits 0. The output reports at least one test executed (`ok 1 ...`), and there are no `not ok` lines, no test-file load errors, and no background processes lingering after the command returns (verifiable: `pgrep -f bats` returns nothing). Pass requires exit 0, at least one `ok` line, and no `not ok`.
Tool: bats
Evidence: exit-code, terminal-output, command-output(`pgrep -f bats`)

### VAL-ENGINE-018: pytest runs cleanly on engine/testgrid
Running `uv run --directory engine/testgrid pytest` exits 0 within 120 seconds. Stdout shows at least one test collected (`collected N items` with N >= 1) and the trailing summary reads `passed` for all tests (no `failed`, no `errors`). The command does not enter watch mode or leave child processes (`pgrep -f pytest` returns nothing after return). Pass requires exit 0, ≥ 1 test passed, and clean exit.
Tool: pytest
Evidence: exit-code, terminal-output, command-output(`pgrep -f pytest`)

### VAL-ENGINE-019: ruff check passes on the touched testgrid python sources
Running `uv run --directory engine/testgrid ruff check src/testgrid` exits 0. Stdout reports `All checks passed!` (or equivalent zero-finding banner). No `error:` or `warning:` lines are emitted. Pass requires exit 0 AND no findings.
Tool: ruff
Evidence: exit-code, terminal-output

### VAL-ENGINE-020: mypy resolves types-PyYAML and jinja2 stubs and reports no errors
Running `uv run --directory engine/testgrid mypy src/testgrid` exits 0 within 60 seconds. Stdout contains `Success: no issues found in N source files` with N >= 1. Stderr contains no `Library stubs not installed for "yaml"` or `Cannot find implementation or library stub for module named "jinja2"` lines. Pass requires exit 0, the success banner, and absence of the two specific stub-missing diagnostics.
Tool: mypy
Evidence: exit-code, terminal-output(stdout, stderr)

### VAL-ENGINE-021: shellcheck and yamllint pass on touched engine files
Running `shellcheck engine/scripts/*.sh engine/asserts/*.sh` exits 0 with no findings on stdout. Running `yamllint -c .yamllint engine/skills/chart-test-swarm/references/integrations/**/*.yaml examples/**/scenarios/*.yaml` exits 0 with no findings. Pass requires both commands exit 0 and emit no error/warning lines on touched files.
Tool: shellcheck
Evidence: exit-code, terminal-output, file(.yamllint), file(engine/scripts/*.sh)

### VAL-ENGINE-022: INVARIANT — cluster-name prefix is enforced in every cluster-touching script
For each of `cluster-up.sh`, `cluster-down.sh`, `run-scenario.sh`, and `dispatch-swarm.sh`, invoking the script with a derived cluster name lacking the `chart-test-swarm-` prefix (e.g. `CLUSTER_NAME=evil-cluster`) exits non-zero before any `kind`, `minikube`, `kubectl`, or `helm` action runs. Stderr in each case references the prefix requirement. `kind get clusters` and `minikube profile list -o json` show no new entries after each invocation. Pass requires all four scripts to refuse, with no side effects.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`kind get clusters`), command-output(`minikube profile list -o json`)

### VAL-ENGINE-023: INVARIANT — teardown leaves no orphan kind or minikube clusters
After any `run-scenario.sh` or `dispatch-swarm.sh` invocation completes (success or failure), with `KEEP_CLUSTER` unset, `kind get clusters | grep '^chart-test-swarm-'` returns no lines (exit 1) and `minikube profile list -o json | jq -e '[.valid[]?.Name | select(startswith("chart-test-swarm-"))] | length == 0'` exits 0. This holds even when the scenario fails mid-preinstall or mid-assert (verified by deliberately failing a scenario and rechecking). Pass requires zero `chart-test-swarm-*` entries in both backends post-run for both pass and fail paths.
Tool: bash
Evidence: command-output(`kind get clusters`), command-output(`minikube profile list -o json`), exit-code(`grep`), exit-code(`jq -e`)

### VAL-ENGINE-024: INVARIANT — teardown leaves no orphan docker containers
After any successful or failed scenario run completes (with `KEEP_CLUSTER` unset), `docker ps --format '{{.Names}}' | grep '^chart-test-swarm-'` returns no lines (exit 1). `docker ps -a --format '{{.Names}}' | grep '^chart-test-swarm-'` likewise returns no lines for the kind/minikube node containers tied to torn-down clusters. Pass requires zero running and zero exited `chart-test-swarm-*` containers attributable to the just-finished run.
Tool: bash
Evidence: command-output(`docker ps --format '{{.Names}}'`), command-output(`docker ps -a --format '{{.Names}}'`), exit-code(`grep`)

### VAL-ENGINE-025: run-scenario.sh emits an actionable error when a referenced fixture path is missing
Running `bash engine/scripts/run-scenario.sh <scenario.yaml>` against a scenario whose `cluster.preinstall` includes `{kind: raw_manifest, path: chart-test/fixtures/does-not-exist.yaml}` exits non-zero within 30 seconds **before** any cluster boot is attempted. Stderr names the offending scenario id, the offending preinstall index, AND the missing path literal. No `chart-test-swarm-*` cluster is created (verified via `kind get clusters` + `minikube profile list`). Pass requires: pre-boot failure, named scenario id, named missing path, no cluster side effects.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`kind get clusters`), command-output(`minikube profile list -o json`)

### VAL-ENGINE-026: Failed scenarios still emit a partial artifacts/ bundle
After a `run-scenario.sh` invocation that fails mid-preinstall or mid-assert (status: FAIL in result.yaml), the corresponding `reports/run-*/scenario-*/artifacts/` directory still exists and still contains `scenario.yaml` (verbatim copy of input), `versions.json` (tool versions captured), AND a `logs/` subdirectory with at least `preinstall.log` and `cluster-up.log`. The `applied-overrides.yaml` may be present (if the helm merge happened) or absent (if failure preceded merge). Pass requires that scenario.yaml + versions.json + logs/ are present even on failure.
Tool: bash
Evidence: file(reports/run-*/scenario-*/artifacts/scenario.yaml), file(reports/run-*/scenario-*/artifacts/versions.json), file-existence(reports/run-*/scenario-*/artifacts/logs/preinstall.log)

### VAL-ENGINE-027: run-scenario.sh forwards SIGINT to clean up the cluster
Running `bash engine/scripts/run-scenario.sh <scenario.yaml>` in the background, waiting for `kind get clusters | grep chart-test-swarm-` to show the cluster, then sending `SIGINT` (Ctrl+C) to the parent script results in: (a) exit within 60 seconds with a non-zero status, (b) `kind get clusters | grep chart-test-swarm-` returns no rows after exit, (c) `docker ps | grep chart-test-swarm-` returns no rows, (d) `reports/run-*/scenario-*/result.yaml` (if written) carries status `INTERRUPTED` or equivalent (NOT `PASS`). Pass requires teardown completion + non-PASS status post-interrupt.
Tool: bash
Evidence: exit-code, terminal-output, command-output(`kind get clusters`), command-output(`docker ps`), file(reports/run-*/scenario-*/result.yaml)

### VAL-ENGINE-028: Every engine script accepts --help and exits 0 with a usage banner
For each of `cluster-up.sh`, `cluster-down.sh`, `apply-scenario.sh`, `run-asserts.sh`, `run-scenario.sh`, `dispatch-swarm.sh`, `build-dashboard.sh`, invoking the script with `--help` exits 0 within 5 seconds. Stdout contains the literal `Usage` (or `USAGE`) AND the script's filename. No cluster operations are performed (`kind get clusters` and `minikube profile list -o json` show no new entries). Pass requires all seven scripts to satisfy all conditions.
Tool: bash
Evidence: exit-code per script, terminal-output(stdout), command-output(`kind get clusters`), command-output(`minikube profile list -o json`)

### VAL-ENGINE-029: Scenario id collisions in reports/run-* produce a deterministic suffix, not silent overwrite
Running the same scenario twice into the same `reports/run-<id>/` directory (e.g., via `RUN_ID=run-fixed bash engine/scripts/run-scenario.sh ...` twice) does NOT silently overwrite the first run's `scenario-<id>/` subdirectory. The second invocation either: (a) refuses with a clear stderr message identifying the prior scenario directory, or (b) appends a `-2`/timestamp suffix to the scenario directory name. Pass requires that after both invocations, BOTH scenario subdirs are present on disk and both have valid `result.yaml` files.
Tool: bash
Evidence: terminal-output, file-existence(reports/run-fixed/scenario-<id>-*/result.yaml count == 2), exit-code

### VAL-ENGINE-030: Engine script CLUSTER_NAME defaults satisfy the `chart-test-swarm-` prefix invariant
Each engine script that defaults `CLUSTER_NAME` (`cluster-up.sh` line 6, `cluster-down.sh` line 5, `run-scenario.sh` line 100) yields a default that matches the regex `^chart-test-swarm-[a-z0-9-]+$` (i.e., literally has a non-empty suffix after the `chart-test-swarm-` prefix). Pass requires: invoking each script with the env var unset and `--print-cluster-name` (or via grepping `set -x` output) produces a name that satisfies the prefix invariant asserted elsewhere in VAL-ENGINE-002 / VAL-ENGINE-022. The literal default `chart-test-swarm` (no suffix) MUST NOT appear; if a deterministic suffix (`-default`, `-local`, `-$USER`, etc.) is chosen, the choice is documented in the script header comment.
Tool: bash
Evidence: terminal-output (`bash -x engine/scripts/cluster-up.sh --dry-run 2>&1 | grep CLUSTER_NAME=` shows `chart-test-swarm-` followed by ≥ 1 char), grep-match in source (`rg 'CLUSTER_NAME:-chart-test-swarm[a-z0-9-]+' engine/scripts/`)

### VAL-ENGINE-031: `scenarios-snapshot.yaml` carries `product` and `asserts` per scenario (no metadata-only snapshots)
After `bash engine/scripts/dispatch-swarm.sh <project-dir> <suite> <n>` runs, the produced `reports/run-<id>/scenarios-snapshot.yaml` contains, for every entry in `.scenarios[]`, a non-null `product.chart`, `product.release`, `product.namespace`, AND a non-empty `asserts[]` array whose items match the original scenario YAML byte-for-byte (after YAML normalization). Pass requires: for each matched scenario file, the snapshot's projection includes all five keys (`id`, `cluster`, `product`, `asserts`, plus `mechanisms`/`tags`/`labels`/`name`/`description`).
Tool: yq
Evidence: command-output (`yq '.scenarios[] | {id, has_product: (.product != null), has_asserts: ((.asserts // []) | length > 0)}' reports/run-*/scenarios-snapshot.yaml` — every record shows `has_product: true` and `has_asserts: true`)

### VAL-ENGINE-032: `apply-scenario.sh` is idempotent over `helm repo add` for repeated runs of the same scenario
Running `bash engine/scripts/apply-scenario.sh <scenario.yaml>` twice in succession against a scenario whose `cluster.preinstall[].repo.name` matches an existing helm repo (e.g., two runs of `examples/sample-product-chart/chart-test/scenarios/with-cert-manager.yaml`) both exit 0. The second invocation does NOT emit a helm warning like `repo "jetstack" already exists with the same configuration, skipping` AS AN ERROR (informational is fine); on URL mismatch with an existing repo, the script exits non-zero with a stderr line naming the repo name and both URLs.
Tool: bash
Evidence: exit-code (both runs 0), terminal-output (second-run stderr does not contain `Error:`), terminal-output (URL-mismatch case produces named error)

### VAL-ENGINE-033: `apply-scenario.sh` cleans up every inline-values tempfile, not just the loop's last one
For a scenario whose `cluster.preinstall` has ≥ 2 items where each item provides an inline `values:` object (not a path string), after `apply-scenario.sh` completes (PASS or FAIL), `ls /tmp/tmp.*` shows NO leftover tempfiles created by the script's `mktemp` calls (line 79). Even if the script is killed with SIGTERM during the second item, the first item's tempfile is also cleaned up.
Tool: bash
Evidence: bash-test (record `ls /tmp/tmp.* | wc -l` before, run the scenario, then re-list and `diff`), command-output (`pgrep -f apply-scenario.sh && kill -TERM <pid>` mid-run, then `find /tmp -maxdepth 1 -name 'tmp.*' -newer /tmp/marker -not -path "$HOME/.cache/*"` returns empty)

### VAL-ENGINE-034: `aggregate.sh` correctly handles assertion `notes` containing commas, newlines, and quotes
A scenario whose `result.yaml` includes an assertion with `notes: "FAIL: pod x, container y; got HTTP 500\nresponse body: \"not ok\""` (embedded comma, newline, and quote) feeds into `aggregate.sh` and produces a `scenario-matrix.csv` that, when parsed by `python -c 'import csv; print(list(csv.reader(open("scenario-matrix.csv"))))'`, recovers the original `notes` string intact (modulo CRLF normalization). Pass requires that comma, newline, and quote round-trip through the aggregator's CSV writer.
Tool: bash
Evidence: bash-test (synthesize `result.yaml` with the pathological notes string, run `aggregate.sh`, then `python -c 'import csv; ...'` confirms exact round-trip)

### VAL-ENGINE-035: F1.3 primer reorg updates SKILL.md, workflow.md, and CLI list-integrations to use the new subdir paths
After F1.3 moves integration primers into category subdirs (`certificates/`, `ingress-controllers/`, `service-mesh/`, `gateway-api/`, `policy/`, `cloud-native/`), the following text references update accordingly: `engine/skills/chart-test-swarm/SKILL.md` lines 10–12 ("dropping a primer in references/integrations/"), line 58 ("whatever has a primer in `references/integrations/`"), line 73 ("`references/integrations/<x>.md`"), line 107 ("`references/integrations/*.md`"); `engine/skills/chart-test-swarm/references/workflow.md` line 11 ("under `references/integrations/`"), line 37 ("Read `references/integrations/<integration>.md`"), line 220 ("`references/integrations/<name>.md` primer"). Pass requires: every textual reference resolves to an existing file on disk OR points to the directory convention (`references/integrations/<category>/<integration>.md`).
Tool: bash
Evidence: terminal-output (`rg -n 'references/integrations/[a-z-]+\.md' engine/skills/chart-test-swarm/{SKILL.md,references/workflow.md}` — every match resolves with `test -f`), terminal-output (`rg -n 'references/integrations/' engine/skills/chart-test-swarm/` — no FLAT references remain after reorg)

### VAL-ENGINE-036: `run-meta.yaml` reflects the actual mix of providers/k8s_versions across all scenarios in the run, not just the first
For a multi-scenario run where scenarios have heterogeneous `cluster.provider` and `cluster.k8s_version` (e.g., one `kind v1.30` + one `minikube v1.29`), the produced `reports/run-<id>/run-meta.yaml` shows EITHER (a) `cluster_provider` and `k8s_version` as YAML lists reflecting the set actually used, OR (b) the dispatcher refuses the run with a clear error naming "mixed-provider suites are not yet supported." Pass requires that the meta file does NOT misleadingly report the FIRST scenario's provider as if it applied to all scenarios.
Tool: yq
Evidence: command-output (`yq '.cluster_provider, .k8s_version' reports/run-*/run-meta.yaml`) — output is a list OR matches the homogeneous case

### VAL-ENGINE-037: `dispatch-swarm.sh` agent-brief substitution does NOT re-expand `$VAR` or `${VAR}` inside scenario name/description fields
A scenario whose `name` field contains the literal string `"Cluster $PATH check"` and whose `description` contains `${HOME}` is dispatched, and the produced `reports/run-<id>/agent-N/brief.md` retains those literal substrings VERBATIM — no shell expansion happens. Pass requires that the brief preserves `$PATH` and `${HOME}` as plain text.
Tool: bash
Evidence: bash-test (write scenario with literal `$VAR` in name/desc, run dispatch-swarm, then `grep -F 'Cluster $PATH check' reports/run-*/agent-*/brief.md` exits 0)

### VAL-ENGINE-038: `cluster-up.sh` does not mutate the user's global active kubeconfig context
Running `bash engine/scripts/cluster-up.sh` with a non-empty `kubectl config current-context` (e.g., `prod-eks`) does NOT change `kubectl config current-context` from the caller's perspective after the script returns. Pass requires: `before=$(kubectl config current-context)`, run cluster-up, `after=$(kubectl config current-context)`, then `before == after`. The created cluster's context is selectable via `--context $CONTEXT` flag but is NOT made the global default.
Tool: bash
Evidence: terminal-output (`kubectl config current-context` before and after; assert equality)

### VAL-ENGINE-039: Engine scripts run cleanly under bash 3.2 (macOS default) or fail preflight with a clear bash-version error
Either: (a) every engine script that uses bash-4-only features (`mapfile` in `dispatch-swarm.sh` line 42, `aggregate.sh` line 37; associative arrays in `aggregate.sh` line 121) is rewritten with bash-3.2-compatible idioms, OR (b) `engine/scripts/verify.sh` (the preflight) and every entry-point script's prologue checks `BASH_VERSINFO[0] -ge 4` and exits non-zero with a clear stderr message naming the required version + how to upgrade (e.g., `brew install bash`). Pass requires: on a system with `bash --version` reporting 3.2, either the scripts succeed OR they fail at preflight with the version-named message — but NEVER with the cryptic `mapfile: command not found`.
Tool: bash
Evidence: bash-test (`/bin/bash --version` on macOS reports 3.2; `bash engine/scripts/verify.sh` exits non-zero with stderr containing both "bash" and "3.2" or "4" or "version", AND no `mapfile: command not found` text appears)

### VAL-ENGINE-040: `KEEP_CLUSTER` success-path behavior is observable, not just commented
After `bash engine/scripts/run-scenario.sh <scenario.yaml>` completes with **PASS**, with `KEEP_CLUSTER` UNSET (default=1), the cluster created by the run is STILL present in `kind get clusters | grep chart-test-swarm-` (or `minikube profile list -o json`). Conversely, with `KEEP_CLUSTER=0` explicitly set and a PASS result, the cluster IS torn down (absent post-run). Pass requires both success-path branches. NOTE: The failure/interrupt teardown behavior (cluster absent after FAIL/SIGINT regardless of KEEP_CLUSTER) is covered by the invariant assertions VAL-ENGINE-023 and VAL-ENGINE-024; `KEEP_ON_FAILURE=1` is the explicit debug override to retain a cluster on failure.
Tool: bash
Evidence: bash-test (run scenario to PASS with unset KEEP_CLUSTER, assert cluster present; rerun to PASS with `KEEP_CLUSTER=0`, assert cluster absent; failure path covered by VAL-ENGINE-023)

### VAL-ENGINE-041: Inline `product.set` style is preserved on the 5 pre-mission scenarios
After the full mission run completes, the five scenarios that used inline `product.set: { ... }` style at mission start (e.g. `examples/sample-product-chart/chart-test/scenarios/customer-A-istio.yaml`, `with-cert-manager.yaml`, `customer-B-gatekeeper.yaml`, `subchart-postgres-internal.yaml`, `minimal.yaml`) still parse as inline `product.set` objects (NOT migrated to a `values:` file reference) unless a documented F-ID explicitly converted them. `yq '.product.set | type'` on each of those original files returns `!!map` and `yq '.product.values' < file` returns null (or absent), preserving the original authoring style.
Tool: yq
Evidence: terminal-output (`for f in customer-A-istio.yaml with-cert-manager.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml minimal.yaml; do yq '.product.set | type' examples/sample-product-chart/chart-test/scenarios/$f; done` outputs `!!map` five times), terminal-output (`yq '.product.values' examples/sample-product-chart/chart-test/scenarios/{customer-A-istio,with-cert-manager,customer-B-gatekeeper,subchart-postgres-internal,minimal}.yaml` returns `null` for each)

---

## Area: Dashboard
## Area: Dashboard

Behavioral validation assertions for Milestone 2 (dashboard-uplift): per-scenario artifact links (F2.1), variant grouping (F2.2), cloud-platform rendering (F2.3), and multi-run aggregation safeguards (F2.4). Tested surfaces: `reports/run-*/dist/index.html` (rendered HTML opened via `file://`), the `python -m testgrid build` CLI, and the `reports/` filesystem layout.

### VAL-DASH-001: Scenario card exposes a "Scenario YAML" link
Open `reports/run-*/dist/index.html` and locate any scenario card produced from a run that has an `artifacts/` bundle. The card MUST contain a visible anchor whose accessible name is "Scenario YAML" (or equivalent label) whose `href` ends with `artifacts/scenario.yaml` for the matching scenario.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> a[href$="artifacts/scenario.yaml"]`)

### VAL-DASH-002: Scenario card exposes an "Applied Overrides" link
The same scenario card MUST contain a visible anchor labeled "Applied Overrides" whose `href` ends with `artifacts/applied-overrides.yaml`. The link MUST be present even when the overrides file is an empty document, so long as the file exists in the bundle.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> a[href$="artifacts/applied-overrides.yaml"]`)

### VAL-DASH-003: Scenario card lists every fixture file as a link
For each file present under `reports/<run-id>/artifacts/fixtures/`, the scenario card MUST render one anchor whose `href` points at that fixture file (relative or `file://`). The displayed link text MUST match the fixture filename. No fixture in the directory may be omitted from the rendered list.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> .artifact-fixtures a`)

### VAL-DASH-004: Scenario card lists every applied manifest as a link
For each file present under `reports/<run-id>/artifacts/manifests/`, the scenario card MUST render one anchor whose `href` points at that manifest file. Empty `manifests/` dirs MUST render an empty list section (not omit the section silently) so reviewers can confirm "no manifests captured" vs "section bug".
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> .artifact-manifests a, details#<scenario-id> .artifact-manifests .empty`)

### VAL-DASH-005: Every artifact link href resolves to an existing file on disk
Walk every `<a>` inside the artifact link sections of the rendered HTML. For each `href`, the resolved path on disk MUST exist and be a regular file. No `404`s, no broken relative paths.
Tool: bash
Evidence: terminal-output (script that parses index.html, resolves each artifact href against the run dir, runs `test -f` per target, exits non-zero on the first miss)

### VAL-DASH-006: Legacy runs without an artifacts/ bundle render cards without dead links
Build the dashboard against a `reports/` containing one legacy run (no `artifacts/` directory, only `result.yaml` + `scenarios-snapshot.yaml`). The rendered scenario cards for that run MUST omit the artifact link sections entirely (or render an explicit "no artifacts" placeholder). They MUST NOT emit anchors with empty/missing `href`s or anchors that point at non-existent paths.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id>`) showing no `a[href=""]` and no `a[href$="artifacts/scenario.yaml"]` when the legacy run is selected

### VAL-DASH-007: Multiple variants of the same (category, integration) collapse under a single header row
When `reports/run-*/scenarios-snapshot.yaml` contains 3+ scenarios sharing the same `(mechanism-category, integration)` (e.g., three `ingress-controllers/traefik-*` variants), the matrix table MUST render exactly one header row for that pair followed by the variants beneath it — not one row per variant at the top level.
Tool: agent-browser
Evidence: dom-text(`section.matrix tr.integration-header`) — there is one header row matching the integration and its variant rows are children of that group

### VAL-DASH-008: Integration header row displays variant count and pass/fail breakdown
The header row introduced in VAL-DASH-007 MUST contain a text segment of the form `"<N> variants: <P> PASS / <F> FAIL"` (additional statuses such as PARTIAL/UNTESTED MUST appear in the same line when present). The displayed counts MUST equal the per-variant statuses collected from the run.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header .variant-summary`)

### VAL-DASH-009: Clicking an integration header toggles expand/collapse of its variant list
Render the dashboard, locate an integration header with 2+ variants, capture the DOM (or visibility state) of its variant rows. Click the header. Re-capture. The variant rows MUST transition between visible and hidden (e.g., `[hidden]` attribute, `display: none`, or `<details open>` state change). A second click MUST return to the prior state.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header[aria-expanded]`) snapshot before/after a synthesized click event

### VAL-DASH-010: Collapsed integration header reflects rolled-up aggregate status
When an integration header is in its collapsed state, its status badge/cell MUST display the worst-of-set status across its variants using the same `STATUS_RANK` ordering as `render.py` (`FAIL` < `PARTIAL` < `INCONCLUSIVE` < `UNTESTED` < `PASS`). E.g., 2 PASS + 1 FAIL collapses to a `FAIL` badge on the header.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header .badge.status-*`)

### VAL-DASH-011: Cloud-platform scenarios render with a distinct visual marker
For scenarios whose `cluster.provider` is in `{gke, aks, eks}` (or whose `mechanisms` contains `cloud:*`), the scenario card and matrix row MUST render an additional visual cue distinct from local kind/minikube cards — e.g., a `.badge.cloud` element with text "AUTHORED ONLY" or a cloud-icon span. Local-backend scenarios MUST NOT render that cue.
Tool: agent-browser
Evidence: screenshot(reports/run-*/dist/index.html) plus dom-text(`details#<cloud-scenario-id> .badge.cloud`)

### VAL-DASH-012: Cloud-platform scenario card surfaces "authored, not run locally" tooltip
The visual marker from VAL-DASH-011 MUST carry an accessible tooltip whose text matches (case-insensitive) "authored, not run locally". This MUST be exposed via an attribute that screen readers and `dom-text` can read (`title`, `aria-label`, or a sibling `<span class="tooltip">` text node).
Tool: agent-browser
Evidence: dom-text(`details#<cloud-scenario-id> [title], [aria-label]`) value matches the required string

### VAL-DASH-013: Cloud-platform scenarios show "AUTHORED" status instead of PASS/FAIL
For cloud-platform scenarios, the per-row Status column and detail-summary badge MUST display `AUTHORED` (or `AUTHORED ONLY`) rather than `PASS`/`FAIL`/`UNTESTED`. A run that has no `result.yaml` entry for that scenario MUST still surface `AUTHORED` (not the default `UNTESTED`).
Tool: agent-browser
Evidence: dom-text(`section.matrix tr[data-scenario-id="<cloud-id>"] td.status, details#<cloud-id> summary .badge`)

### VAL-DASH-014: build-dashboard.sh succeeds across mixed minimal and rich report shapes
Run `bash engine/scripts/build-dashboard.sh` (no args) against a `reports/` directory that contains at least one legacy-shape run (snapshot + `agent-*/result.yaml`, no `artifacts/`) AND one rich-shape run (with full `artifacts/`). The script MUST exit `0` and produce `reports/dist/index.html`. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: bash
Evidence: terminal-output (`bash engine/scripts/build-dashboard.sh; echo "exit=$?"`) showing `exit=0` and the index file written

### VAL-DASH-015: Both legacy and rich runs appear on the rendered index page
After VAL-DASH-014, open `reports/dist/index.html`. The Runs table MUST contain one row per run directory that has valid metadata — both the legacy-shape and the rich-shape run IDs MUST be present, linkable, and reflect their respective scenario counts. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr td:first-child code`) listing both `run-<legacy>` and `run-<rich>` ids

### VAL-DASH-016: Orphaned run directory (no result.yaml, no snapshot) is skipped without crashing
Create a `reports/run-<orphan>/` containing only an empty directory or unrelated files (no `scenarios-snapshot.yaml`, no `agent-*/result.yaml`). Re-run `bash engine/scripts/build-dashboard.sh`. The script MUST exit `0`, emit a warning to stderr identifying the skipped run, and the index MUST NOT include a row for the orphan. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: bash
Evidence: terminal-output showing `exit=0`, the orphan id appearing on stderr (e.g., `warn: ... run-<orphan>`), and `grep -c "run-<orphan>" reports/dist/index.html` returning `0`

### VAL-DASH-017: Repeated dashboard builds produce byte-identical HTML (deterministic ordering)
Run `python -m testgrid build --reports reports/ --out /tmp/dash-a` and `python -m testgrid build --reports reports/ --out /tmp/dash-b` back to back against an unchanged `reports/`. The two outputs MUST be byte-identical (`diff -r` returns 0) for all non-timestamp lines; if a render timestamp is embedded, only that single line may differ. Row and column ordering within the matrix MUST be deterministic (e.g., scenario IDs sorted lexicographically), so the assertion is independent of dict iteration order.
Tool: bash
Evidence: terminal-output (`diff -r /tmp/dash-a /tmp/dash-b | grep -v 'rendered_at'` returns empty; non-zero exit indicates non-determinism)

### VAL-DASH-018: Rendered dashboard loads in a browser without console errors
Open the rendered `reports/run-*/dist/index.html` via `file://` and the runs index `reports/dist/index.html`. The browser console MUST report zero `error`-level entries (CSS/asset 404s for `style.css` or `run.json` count as failures). Network panel MUST show 200/`file://` success for every requested resource.
Tool: agent-browser
Evidence: dom-text(devtools console panel) showing 0 errors plus network-call log showing no non-200 / failed file:// fetches

### VAL-DASH-019: Scenario card surfaces FAIL detail (error message or log link)
For any scenario card whose status is `FAIL`, the rendered HTML MUST include either: (a) a visible text element containing a non-empty error summary string (truncated >= 40 chars OK), OR (b) an anchor labeled "Log" / "Error log" whose `href` resolves to a non-empty `logs/*.log` file under the run's artifacts. Cards with status `PASS` MUST NOT render an empty error-summary element (no `class="error-summary"` with empty text). Pass requires every FAIL card to expose either an error string or a log link.
Tool: agent-browser
Evidence: dom-text(`details[data-status="FAIL"] .error-summary, details[data-status="FAIL"] a.error-log`)

### VAL-DASH-020: Re-running a scenario into a new run-* dir leaves prior runs intact in the index
After a baseline run produces `reports/run-A/` (rendered to `reports/dist/index.html`), a second run produces `reports/run-B/`, and `bash engine/scripts/build-dashboard.sh` is invoked: the regenerated index page lists BOTH run-A and run-B in its Runs table, and clicking each run's link reveals its corresponding scenario cards. The run-A artifact links still resolve on disk (no broken hrefs introduced by the rebuild). Pass requires both runs visible, both link sets resolve.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr`) lists both `run-A` and `run-B`, terminal-output (script walks all `a[href]` under `details[data-run-id="run-A"]` and confirms `test -f` for each resolved path)

### VAL-DASH-021: Corrupt result.yaml in a run dir is reported but does not crash the dashboard build
Place an intentionally invalid `result.yaml` (e.g., truncated, missing keys, invalid YAML syntax) into `reports/run-<corrupt>/`. Running `bash engine/scripts/build-dashboard.sh` exits 0; stderr emits a clear warning naming the offending run id and the corruption type (`invalid YAML`, `missing required key 'scenarios'`, etc.); the resulting `reports/dist/index.html` either omits the corrupt run with a placeholder row labeled "metadata error" OR omits it entirely with a stderr warning. Pass requires: exit 0, named warning, non-crashing render.
Tool: bash
Evidence: exit-code 0, terminal-output(stderr contains the run id + reason), file(reports/dist/index.html)

### VAL-DASH-022: `STATUS_RANK` ordering ensures `INCONCLUSIVE` never bubbles up as "worse than" `UNTESTED` in mechanism rollups
For a mechanism that has two scenarios — one `INCONCLUSIVE` and one `UNTESTED` — the rendered mechanism rollup row shows `UNTESTED` (NOT `INCONCLUSIVE`), because UNTESTED reflects "we never even tried" which is a worse-confidence outcome than "we tried but couldn't conclude." Equivalently: the testgrid collector module orders `STATUS_RANK['UNTESTED']` strictly less than `STATUS_RANK['INCONCLUSIVE']`. Pass requires the unit test confirms the ordering AND a synthetic run with the two scenarios renders the mechanism cell as `UNTESTED`.
Tool: pytest
Evidence: pytest-output (`pytest engine/testgrid/tests/test_render.py::test_status_rank_untested_above_inconclusive`), file(reports/dist/<run-id>/index.html — the synthetic rollup cell shows badge text "UNTESTED")

### VAL-DASH-023: `collect.py` rejects (or visibly surfaces) `result.yaml` files whose `status` is not in the known status set
A `result.yaml` with `status: WEIRD_CUSTOM_STATUS` causes either (a) the testgrid collector to exit non-zero with a clear stderr line naming the offending status + scenario + file, OR (b) the resulting `Scenario.status` to be normalized to `UNKNOWN` AND the dashboard renders the scenario card with a visible "unknown status" badge (NOT a generic untested-styling fallback). Pass requires the gibberish status is either rejected at collect time or visibly surfaced — silent CSS coercion to `status-unknown` (current behavior) does not satisfy.
Tool: bash
Evidence: bash-test (synthesize result.yaml with bogus status, run `uv run testgrid build`, assert stderr names the status OR dashboard shows "unknown status" text), grep-match in the testgrid collector module (no longer accepts arbitrary string into `Scenario.status` without validation)

### VAL-DASH-024: Dashboard HTML escapes user-controlled fields (`name`, `description`, `notes`, `fail_msg`, `log_dir`) against XSS payloads
A scenario whose `name` is `"<script>alert(1)</script>"` and whose `description` contains `"</details><img src=x onerror=alert(1)>"` is collected and rendered. The resulting `reports/dist/<run-id>/index.html` does NOT contain `<script>alert(1)</script>` as live HTML (i.e., the payload is HTML-escaped to `&lt;script&gt;alert(1)&lt;/script&gt;`), and a headless-browser visit (`agent-browser` open + read DOM) shows the literal text "alert(1)" inside a text node (not executed). Pass requires escape-correctness for every field that originates from user-supplied YAML.
Tool: agent-browser
Evidence: dom-text (visible text contains literal `<script>alert(1)</script>` characters), terminal-output (`rg -F '<script>alert(1)</script>' reports/dist/<run-id>/index.html` returns no live-script match)

### VAL-DASH-025: Dashboard renders a non-crashing card when `result.yaml` lists zero scenarios
Build the dashboard against a `reports/` containing one valid-shape run whose `result.yaml` has `scenarios: []` (empty list — e.g. a dispatch invocation whose suite filter matched zero scenarios). The build MUST exit 0; the rendered `reports/dist/index.html` MUST contain a row for that run id whose scenario count shows `0` (NOT a missing or `null` cell) and that has no scenario-card subtree. The run-detail page (or details block) for that run MUST render an explicit "0 scenarios in this run" placeholder text node, not crash and not silently omit the run. Pass requires: exit 0 + run id visible in index + explicit zero-count text.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr td:contains("run-<empty>") td.scenario-count`) shows `0`, dom-text(`details[data-run-id="run-<empty>"] .empty-state`) contains "0 scenarios" or equivalent, terminal-output (`bash engine/scripts/build-dashboard.sh; echo "exit=$?"` shows `exit=0`)

---

## Area: Certificates
## Area: Certificates

Coverage: F3.1 cert-manager primer + variants, F3.2 manual-tls-secret primer + variants,
F3.3 mounted-tls-certs primer + variants, F3.4 shared certificates fixture set under
`examples/sample-product-chart/chart-test/fixtures/certificates/`.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$` (per the mission's hard constraint). Scenario YAMLs live
under `examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`.

### Structural / artifact assertions (per integration)

### VAL-CERT-001: cert-manager primer exists with required sections
The primer file at `engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md` exists, is non-empty, and contains a non-empty `## Cluster preinstall` section plus a section explaining *what* the integration does, *when* to use it, and *how* the consumer chart wires the resulting Secret into pods (mount + env vars).
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md`), terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/certificates/cert-manager.md` (≥ 3)

### VAL-CERT-002: cert-manager scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-*.yaml`, covering self-signed-ca, lets-encrypt-staging, wildcard, and (optionally) jks-pkcs12. Each file's `id` field matches its filename stem.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-*.yaml | wc -l` ≥ 3, file paths listed

### VAL-CERT-003: manual-tls-secret primer exists with required sections
The primer file at `engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md` exists, is non-empty, and documents what manual TLS Secret provisioning is, when a consumer ships a chart against a pre-existing TLS Secret, and how the scenario delivers the Secret via a `raw_manifest` preinstall item.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md`), terminal-output of `grep -E '^## (What|When|How|Cluster preinstall)' engine/skills/chart-test-swarm/references/integrations/certificates/manual-tls-secret.md` returns ≥ 3 matches

### VAL-CERT-004: manual-tls-secret scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml`, covering basic, multiple-sans, and ecdsa variants. Each file's `id` matches its filename stem.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml | wc -l` ≥ 3

### VAL-CERT-005: mounted-tls-certs primer exists with required sections
The primer at `engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md` exists, is non-empty, and documents what mounted-TLS-from-volume is, when to use it (PVC vs projected vs CSI secret-store), and how the consumer chart references the mounted path.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md`), terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/certificates/mounted-tls-certs.md` ≥ 3

### VAL-CERT-006: mounted-tls-certs scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-*.yaml`, covering pvc-mount, projected-volume, and csi-secret-store variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/certificates-mounted-tls-certs-*.yaml | wc -l` ≥ 3

### Variant execution assertions (cert-manager)

### VAL-CERT-007: cert-manager self-signed-ca scenario runs PASS
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/certificates-cert-manager-self-signed-ca.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. The cluster shows: a `cert-manager` namespace with controller + webhook + cainjector pods Ready; a `ClusterIssuer` of type `selfSigned`; a `Certificate` whose `Ready` condition is `True`; and a TLS `Secret` containing `tls.crt`, `tls.key`, and `ca.crt` data keys.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-self-signed-ca-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get certificate -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'` == `True`), kubectl-output(`kubectl get secret sample-tls -n sample -o json | jq -r '.data | keys[]' | sort` produces lines `ca.crt`, `tls.crt`, `tls.key`)

### VAL-CERT-008: cert-manager self-signed-ca serves HTTPS with matching SAN
After the self-signed-ca scenario installs the chart, an in-cluster `curl` against the product Service over HTTPS using `--cacert` pointing at the issuer's CA succeeds with HTTP `200`, and the served peer certificate's Subject Alternative Names include the host the chart was configured to serve (e.g. `sample.sample.svc.cluster.local`).
Tool: curl
Evidence: curl-response(headers: `HTTP/1.1 200`, body: matches expected probe response), terminal-output of `openssl s_client -connect <pod-ip>:443 -servername sample.sample.svc.cluster.local </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName` includes `DNS:sample.sample.svc.cluster.local`

### VAL-CERT-009: cert-manager lets-encrypt-staging scenario runs PASS
Running the `certificates-cert-manager-lets-encrypt-staging.yaml` scenario via `run-scenario.sh` results in `status: PASS`. The scenario uses a `staging` ACME server URL (so no real ACME challenge is solved against production). The scenario either uses the `selfSigned` issuer for offline behavior or stubs out the ACME challenge; the assertion verifies that the `Issuer`/`ClusterIssuer` resource is `Ready: True` and the chart pods are Ready.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-lets-encrypt-staging-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get clusterissuer -o jsonpath='{.items[?(@.metadata.name=="letsencrypt-staging")].status.conditions[?(@.type=="Ready")].status}'` == `True`)

### VAL-CERT-010: cert-manager wildcard scenario issues *.test.local certificate
Running the `certificates-cert-manager-wildcard.yaml` scenario via `run-scenario.sh` results in `status: PASS`. The issued TLS Secret's certificate has SAN `DNS:*.test.local` (or the documented wildcard host) and a sibling literal SAN for the base domain.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-wildcard-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret <wildcard-secret> -n sample -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName` includes `DNS:*.test.local`

### VAL-CERT-011: cert-manager jks-pkcs12 secret contains keystore + truststore (optional 4th variant)
If the scenario `certificates-cert-manager-jks-pkcs12.yaml` is present, running it via `run-scenario.sh` produces `status: PASS` and the resulting Secret contains data keys `keystore.jks` and `truststore.jks` (or `keystore.p12`) in addition to `tls.crt` / `tls.key`. If the variant file is not authored, this assertion is marked N/A.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-cert-manager-jks-pkcs12-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get secret -n sample <jks-secret> -o json | jq -r '.data | keys[]' | sort`) includes both `tls.crt` and either `keystore.jks` or `keystore.p12`

### Variant execution assertions (manual-tls-secret)

### VAL-CERT-012: manual-tls-secret basic scenario delivers Secret via raw_manifest preinstall
Running `certificates-manual-tls-secret-basic.yaml` via `run-scenario.sh` results in `status: PASS`. The scenario's `cluster.preinstall` list includes at least one item with `kind: raw_manifest` (per F1.2) whose `path` resolves to a manifest containing a `kind: Secret` with `type: kubernetes.io/tls` and base64-encoded `tls.crt` + `tls.key`. After the run, the Secret is present in the product namespace with both keys populated.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-basic-*/result.yaml`) with `status: PASS`, file(`examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-basic.yaml`) contains `kind: raw_manifest`, kubectl-output(`kubectl get secret <manual-tls-name> -n sample -o jsonpath='{.type}'` == `kubernetes.io/tls`)

### VAL-CERT-013: manual-tls-secret-multiple-sans certificate has all declared SANs
Running `certificates-manual-tls-secret-multiple-sans.yaml` via `run-scenario.sh` results in `status: PASS`. The certificate inside the manually-delivered TLS Secret has at least 2 SAN entries (e.g. `DNS:sample.test.local` AND `DNS:api.sample.test.local`).
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-multiple-sans-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret -n sample <secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName | grep -c DNS:` ≥ 2

### VAL-CERT-014: manual-tls-secret-ecdsa scenario installs an ECDSA-keyed certificate
Running `certificates-manual-tls-secret-ecdsa.yaml` via `run-scenario.sh` results in `status: PASS`. The certificate in the resulting Secret reports public-key algorithm `id-ecPublicKey` (P-256 or P-384), not RSA. The chart pods that mount this Secret reach Ready and serve TLS using the ECDSA key.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-manual-tls-secret-ecdsa-*/result.yaml`) with `status: PASS`, terminal-output of `kubectl get secret -n sample <ecdsa-secret> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep "Public Key Algorithm"` contains `id-ecPublicKey`

### Variant execution assertions (mounted-tls-certs)

### VAL-CERT-015: mounted-tls-certs-pvc-mount scenario mounts cert from PVC into pod
Running `certificates-mounted-tls-certs-pvc-mount.yaml` via `run-scenario.sh` results in `status: PASS`. The chart's main pod has a `volumeMount` whose `mountPath` matches the value in `tls.mountPath` (e.g. `/etc/tls`) and whose volume source is a `persistentVolumeClaim`. `kubectl exec` into the pod can `stat /etc/tls/tls.crt` successfully.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-pvc-mount-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get pod -n sample -l app.kubernetes.io/instance=sample -o jsonpath='{.items[0].spec.volumes[?(@.persistentVolumeClaim)].name}'` is non-empty), kubectl-output(`kubectl exec -n sample <pod> -- stat /etc/tls/tls.crt`) exit code 0

### VAL-CERT-016: mounted-tls-certs-projected-volume scenario uses a projected volume source
Running `certificates-mounted-tls-certs-projected-volume.yaml` via `run-scenario.sh` results in `status: PASS`. The product pod has a `volume` of kind `projected` that includes at least one `secret` source (the TLS Secret) and the mount path is reachable from inside the pod.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-projected-volume-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get pod -n sample <pod> -o jsonpath='{.spec.volumes[?(@.projected)].projected.sources[?(@.secret)].secret.name}'`) is non-empty

### VAL-CERT-017: mounted-tls-certs-csi-secret-store scenario produces SecretProviderClass-backed mount
Running `certificates-mounted-tls-certs-csi-secret-store.yaml` via `run-scenario.sh` results in `status: PASS`. The scenario's preinstall installs the `secrets-store-csi-driver` Helm chart (and a stub `SecretProviderClass` via `raw_manifest`); the chart pod has a volume of `csi.driver=secrets-store.csi.k8s.io`; the mount path contains the expected cert files. (If CSI driver cannot run on the test kind backend, the scenario must mark itself SKIP with a documented reason rather than FAIL.)
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-certificates-mounted-tls-certs-csi-secret-store-*/result.yaml`) with `status: PASS` (or `SKIP` with reason), kubectl-output(`kubectl get pod -n sample <pod> -o jsonpath='{.spec.volumes[?(@.csi.driver=="secrets-store.csi.k8s.io")].name}'`) is non-empty when status is PASS

### Area-wide structural assertions

### VAL-CERT-018: All certificates scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml` validates cleanly against `engine/templates/scenario.schema.json` (using the same validator the engine invokes in `dispatch-swarm.sh` / `run-scenario.sh`).
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-CERT-019: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the certificate-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-CERT-020: Shared TLS fixtures exist and are non-empty
The fixture set under `examples/sample-product-chart/chart-test/fixtures/certificates/` (F3.4) exists and contains at minimum `ca.crt` and `ca.key`. Each file is a non-empty regular file (> 0 bytes). `ca.crt` is a parseable PEM certificate; `ca.key` is a parseable PEM private key (RSA or ECDSA).
Tool: bash
Evidence: terminal-output of `ls -la examples/sample-product-chart/chart-test/fixtures/certificates/ca.crt examples/sample-product-chart/chart-test/fixtures/certificates/ca.key` shows both > 0 bytes; terminal-output of `openssl x509 -in examples/sample-product-chart/chart-test/fixtures/certificates/ca.crt -noout -subject` succeeds; terminal-output of `openssl pkey -in examples/sample-product-chart/chart-test/fixtures/certificates/ca.key -noout -text` succeeds

### VAL-CERT-021: Shared fixtures are byte-identical across scenarios that reference them
For any two certificates-area scenarios that reference the same fixture filename, the SHA-256 digest of the on-disk fixture file is identical. (Scenarios MUST NOT copy/duplicate fixture material — they reference the canonical file under `chart-test/fixtures/certificates/`.)
Tool: bash
Evidence: terminal-output of `shasum -a 256 examples/sample-product-chart/chart-test/fixtures/certificates/*` is a single deterministic set of digests; grep across `examples/sample-product-chart/chart-test/scenarios/certificates-*.yaml` shows no scenario embeds raw `BEGIN CERTIFICATE` PEM content inline

### VAL-CERT-022: manual-tls-secret scenarios reference fixtures via the fixture system, not inline base64
For each `certificates-manual-tls-secret-*.yaml`, the TLS material is delivered through a `raw_manifest` preinstall item whose `path` resolves into `examples/sample-product-chart/chart-test/fixtures/certificates/` (or a sibling fixtures directory) — not via a base64-encoded `tls.crt:` blob embedded inline in the scenario YAML.
Tool: bash
Evidence: terminal-output of `grep -lE 'tls\.crt:\s+[A-Za-z0-9+/=]{50,}' examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml` returns empty (no inline base64 blobs); terminal-output of `yq '.cluster.preinstall[] | select(.kind == "raw_manifest") | .path' examples/sample-product-chart/chart-test/scenarios/certificates-manual-tls-secret-*.yaml` returns paths that resolve under `chart-test/fixtures/certificates/`

### VAL-CERT-023: TLS private-key fixtures are gitignored or pre-generated, not committed real keys
The repo's `.gitignore` (or `examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore`) excludes `*.key` files, OR the committed `ca.key` and any other `*.key` files in the fixtures dir have a header comment indicating they are "test-only ephemeral keys, regenerated by ./regen.sh" (or equivalent). No fixture key is referenced by a production-shaped certificate (e.g., a key whose corresponding cert names a real domain such as `example.com` or a real ACME issuer URL pointing at a Let's-Encrypt production endpoint).
Tool: bash
Evidence: file(.gitignore) or file(examples/sample-product-chart/chart-test/fixtures/certificates/.gitignore), terminal-output(`grep -l 'BEGIN.*PRIVATE KEY' examples/sample-product-chart/chart-test/fixtures/certificates/*.key | xargs head -n 5`)

---

## Area: Ingress Controllers
## Area: Ingress Controllers

Coverage: F4.1 traefik refresh + variants, F4.2 nginx-ingress primer + variants,
F4.3 contour primer + variants.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$`. Scenario YAMLs live under
`examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`. HTTP probes use `curl` with the appropriate
`Host:` header against the controller pod IP (kind has no LoadBalancer; this avoids
NodePort indirection, matching the pattern in the existing traefik primer).

### Structural / artifact assertions (per integration)

### VAL-INGRESS-001: traefik primer exists, is in the ingress-controllers/ subdir, and documents required preinstall_items
The primer file at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` exists, is non-empty, and contains a `## Cluster preinstall` section that declares the `traefik/traefik` Helm chart + its repo URL + the `wait: pods-ready` directive. The primer also documents what the controller does, when to pick it, and how IngressRoute CRD-based routing differs from classic Ingress.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md`), terminal-output of `grep -E '^- chart: traefik/traefik' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` returns ≥ 1 match, terminal-output of `grep -c '^## ' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/traefik.md` ≥ 3

### VAL-INGRESS-002: traefik scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml`, covering basic, tls-passthrough, middleware-chain, and (optionally) ingressroute-crd variants. Each file's `id` field matches its filename stem and `mechanisms` includes `addon:traefik`.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml | wc -l` ≥ 3, terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-*.yaml; do yq -r '.mechanisms[]' "$f"; done | grep -c 'addon:traefik'` ≥ 3

### VAL-INGRESS-003: nginx-ingress primer exists and documents required preinstall_items
The primer at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md` exists, is non-empty, and contains a `## Cluster preinstall` section declaring the `ingress-nginx/ingress-nginx` Helm chart (or `kubernetes/ingress-nginx`) with its repo URL and a `pods-ready` wait. It documents what NGINX Ingress does, when to use it (annotation-driven snippets, canary, default-backend), and how the consumer chart wires `ingressClassName: nginx`.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md`), terminal-output of `grep -E '^- chart: (ingress-nginx|kubernetes/ingress-nginx)' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/nginx-ingress.md` returns ≥ 1 match

### VAL-INGRESS-004: nginx-ingress scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-*.yaml`, covering basic, snippet-annotations, default-backend, and canary variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-nginx-ingress-*.yaml | wc -l` ≥ 3

### VAL-INGRESS-005: contour primer exists and documents required preinstall_items
The primer at `engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md` exists, is non-empty, and documents the `bitnami/contour` (or `projectcontour/contour`) Helm chart preinstall, what Contour does, when to use HTTPProxy CRD vs classic Ingress, and how TLS delegation works.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md`), terminal-output of `grep -E '^- chart: .*/contour' engine/skills/chart-test-swarm/references/integrations/ingress-controllers/contour.md` returns ≥ 1 match

### VAL-INGRESS-006: contour scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-*.yaml`, covering basic-httpproxy, tls-delegation, rate-limit, and (optionally) jwt-auth variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/ingress-controllers-contour-*.yaml | wc -l` ≥ 3

### Variant execution assertions (traefik)

### VAL-INGRESS-007: traefik-basic scenario routes HTTP traffic through the controller
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/ingress-controllers-traefik-basic.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. An in-cluster `curl -H "Host: sample.test.local" http://<traefik-pod-ip>/` returns `HTTP/1.1 200 OK` with a body served by the product chart's pod (containing the chart's default response payload). Without the `Host:` header, the same curl returns the Traefik 404.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-basic-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200 OK`; body matches the chart's response signature), terminal-output of `kubectl -n sample get ingress` (or `kubectl -n sample get ingressroute`) shows the routing resource

### VAL-INGRESS-008: traefik-tls-passthrough scenario forwards encrypted traffic untouched
Running `ingress-controllers-traefik-tls-passthrough.yaml` via `run-scenario.sh` results in `status: PASS`. The IngressRoute (or IngressRouteTCP) has `tls.passthrough: true`. A `curl --insecure --resolve sample.test.local:443:<traefik-pod-ip> https://sample.test.local/` returns `HTTP/1.1 200` AND the certificate returned in the TLS handshake is the *backend's* certificate (matches what the pod serves), NOT Traefik's self-signed default.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-tls-passthrough-*/result.yaml`) with `status: PASS`, terminal-output of `openssl s_client -connect <traefik-pod-ip>:443 -servername sample.test.local </dev/null 2>/dev/null | openssl x509 -noout -subject` matches the backend pod's cert subject

### VAL-INGRESS-009: traefik-middleware-chain scenario applies declared middleware
Running `ingress-controllers-traefik-middleware-chain.yaml` via `run-scenario.sh` results in `status: PASS`. The IngressRoute references at least one Middleware CR (e.g. `headers` or `stripPrefix`). A curl through the controller shows the *effect* of the middleware: e.g. with a `headers` middleware adding `X-Test: chart-test-swarm`, the response includes that header; with a `stripPrefix` middleware, the backend log shows the stripped path. Without the middleware reference, the same curl does not exhibit the effect.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-middleware-chain-*/result.yaml`) with `status: PASS`, curl-response(headers includes the added header OR backend log shows stripped path), kubectl-output(`kubectl get middleware -n sample`) lists the declared middlewares

### VAL-INGRESS-010: traefik-ingressroute-crd scenario uses IngressRoute CRD, not classic Ingress (optional 4th variant)
If `ingress-controllers-traefik-ingressroute-crd.yaml` is present, running it via `run-scenario.sh` results in `status: PASS` and the routing resource created in the product namespace is `IngressRoute.traefik.io/v1alpha1` (verified via `kubectl get ingressroute`), not a classic `networking.k8s.io/v1` Ingress. HTTP traffic still reaches the backend via Host header. If absent, this assertion is N/A.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-traefik-ingressroute-crd-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get ingressroute.traefik.io -n sample -o name`) is non-empty, kubectl-output(`kubectl get ingress -n sample`) shows no classic Ingress

### Variant execution assertions (nginx-ingress)

### VAL-INGRESS-011: nginx-ingress-basic scenario routes through nginx controller
Running `ingress-controllers-nginx-ingress-basic.yaml` via `run-scenario.sh` results in `status: PASS`. The Ingress resource carries `ingressClassName: nginx`. An in-cluster `curl -H "Host: sample.test.local" http://<nginx-controller-pod-ip>/` returns `HTTP/1.1 200`. The nginx controller logs (`kubectl logs -n ingress-nginx`) show the request was matched to the product Service.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-basic-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200`), kubectl-output(`kubectl get ingress -n sample -o jsonpath='{.items[0].spec.ingressClassName}'` == `nginx`)

### VAL-INGRESS-012: nginx-ingress-snippet-annotations scenario activates the configured snippet
Running `ingress-controllers-nginx-ingress-snippet-annotations.yaml` via `run-scenario.sh` results in `status: PASS`. The Ingress carries an annotation like `nginx.ingress.kubernetes.io/configuration-snippet` (or `server-snippet`); the cluster's nginx-ingress controller is started with `--enable-annotation-validation` configured to allow snippets, OR the controller chart's values enable `allowSnippetAnnotations: true`. A curl through the controller exhibits the snippet's effect — e.g. an injected `add_header X-Test true;` snippet causes the response to include `x-test: true`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-snippet-annotations-*/result.yaml`) with `status: PASS`, curl-response(headers includes `x-test: true`), kubectl-output(`kubectl get ingress -n sample -o jsonpath='{.items[0].metadata.annotations}'`) includes `nginx.ingress.kubernetes.io/.*-snippet`

### VAL-INGRESS-013: nginx-ingress-default-backend scenario serves a custom 404 for unmatched hosts
Running `ingress-controllers-nginx-ingress-default-backend.yaml` via `run-scenario.sh` results in `status: PASS`. The nginx controller is configured (via preinstall values OR an additional Deployment + Service named in `defaultBackend.service.name`) to use a custom default backend. An in-cluster `curl http://<nginx-controller-pod-ip>/` (with NO Host header matching any Ingress) returns the custom-backend's distinctive response body (NOT nginx's stock `default backend - 404`).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-default-backend-*/result.yaml`) with `status: PASS`, curl-response(body contains the custom default backend's signature string, e.g. `chart-test-swarm-default-backend`), kubectl-output(`kubectl -n ingress-nginx get deploy <default-backend-name>`) returns a Deployment

### VAL-INGRESS-014: nginx-ingress-canary scenario splits traffic in measurable proportions
Running `ingress-controllers-nginx-ingress-canary.yaml` via `run-scenario.sh` results in `status: PASS`. Two Ingress resources exist for the same host; one carries `nginx.ingress.kubernetes.io/canary: "true"` plus `nginx.ingress.kubernetes.io/canary-weight: "20"` (or similar). A scripted set of 100 in-cluster curl probes against the controller routes between 10–30 of those requests to the canary backend and the remainder to the stable backend (validating the weight-driven split is *measurable*, not silently absent).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-nginx-ingress-canary-*/result.yaml`) with `status: PASS`, terminal-output of a probe loop counting responses by backend label (e.g. response header `x-backend: canary` vs `x-backend: stable`) reports counts within the documented tolerance window (e.g. `canary=22 stable=78` for a 20% canary)

### Variant execution assertions (contour)

### VAL-INGRESS-015: contour-basic-httpproxy scenario routes via HTTPProxy CRD
Running `ingress-controllers-contour-basic-httpproxy.yaml` via `run-scenario.sh` results in `status: PASS`. The routing resource created is `HTTPProxy.projectcontour.io/v1`, NOT a classic Ingress. An in-cluster `curl -H "Host: sample.test.local" http://<envoy-pod-ip>/` (Contour uses Envoy as the data plane) returns `HTTP/1.1 200`. The HTTPProxy's `status.currentStatus` is `valid`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-basic-httpproxy-*/result.yaml`) with `status: PASS`, curl-response(headers: `HTTP/1.1 200`), kubectl-output(`kubectl get httpproxy -n sample -o jsonpath='{.items[0].status.currentStatus}'` == `valid`)

### VAL-INGRESS-016: contour-tls-delegation scenario serves HTTPS using a Secret in a different namespace
Running `ingress-controllers-contour-tls-delegation.yaml` via `run-scenario.sh` results in `status: PASS`. A `TLSCertificateDelegation` resource exists granting the HTTPProxy access to a TLS Secret in a namespace OTHER than the HTTPProxy's namespace. An in-cluster `curl --insecure --resolve sample.test.local:443:<envoy-pod-ip> https://sample.test.local/` returns `HTTP/1.1 200` and serves the delegated Secret's certificate (Subject CN matches the host).
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-tls-delegation-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get tlscertificatedelegation -A`) lists the delegation, terminal-output of `openssl s_client -connect <envoy-pod-ip>:443 -servername sample.test.local </dev/null | openssl x509 -noout -subject` includes the expected CN

### VAL-INGRESS-017: contour-rate-limit scenario enforces request-rate ceiling
Running `ingress-controllers-contour-rate-limit.yaml` via `run-scenario.sh` results in `status: PASS`. The HTTPProxy carries a `rateLimitPolicy.local` (or `global`) limiting requests-per-second. Sending more than the limit (e.g. 50 curl probes in < 1s) produces at least one `HTTP/1.1 429 Too Many Requests` response. Below the limit, all probes return `200`.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-rate-limit-*/result.yaml`) with `status: PASS`, curl-response(at least one response with `HTTP/1.1 429`), kubectl-output(`kubectl get httpproxy -n sample -o jsonpath='{.items[0].spec.virtualhost.rateLimitPolicy}'`) is non-empty

### VAL-INGRESS-018: contour-jwt-auth scenario rejects requests without a valid JWT (optional 4th variant)
If `ingress-controllers-contour-jwt-auth.yaml` is present, running it via `run-scenario.sh` results in `status: PASS`. An in-cluster curl WITHOUT an `Authorization: Bearer <jwt>` header returns `HTTP/1.1 401` (or `403`); a curl WITH a JWT signed by the configured JWKS issuer returns `HTTP/1.1 200`. If absent, this assertion is N/A.
Tool: curl
Evidence: file(`reports/run-*/scenario-ingress-controllers-contour-jwt-auth-*/result.yaml`) with `status: PASS`, curl-response(no-auth: `HTTP/1.1 401`; valid-jwt: `HTTP/1.1 200`)

### Area-wide structural assertions

### VAL-INGRESS-019: All ingress-controllers scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/ingress-controllers-*.yaml` validates cleanly against `engine/templates/scenario.schema.json`.
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/ingress-controllers-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-INGRESS-020: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the ingress-controllers-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-INGRESS-021: Variant scenarios for the same controller differ ONLY in the feature they exercise
For each controller (traefik, nginx-ingress, contour), comparing any two variant scenario YAMLs side-by-side reveals shared `cluster.preinstall` for the controller chart itself and shared `product.chart` / `product.release` / `product.namespace`. The only meaningful diffs are in `product.set` overrides, ingress/HTTPProxy/IngressRoute annotations or spec fields, OR an added `raw_manifest` preinstall delivering a feature-specific CR (TLSCertificateDelegation, Middleware, ConfigMap with snippets, second Ingress for canary). No variant introduces a different ingress controller chart or changes the product namespace.
Tool: yq
Evidence: terminal-output of a yq + diff harness that, for each controller's variant pair, prints the structural diff between the two scenario YAMLs and the count of diff hunks outside `product.set` + `cluster.preinstall[-1]` (raw_manifest tail) + `mechanisms` is 0

### VAL-INGRESS-022: Ingress controller pod is Ready before the variant assertion runs its HTTP probe
For each ingress controller variant (traefik, nginx-ingress, contour) before any in-cluster `curl` HTTP probe is issued, the controller pod's `status.conditions[type=Ready].status` is `True` AND its container's `readinessProbe` has succeeded (verifiable: `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=<controller> -n <controller-ns> --timeout=120s` exits 0). Probes that run against a not-yet-ready controller MUST be retried or wait, not flake. Pass requires every variant to satisfy the wait before its HTTP assertion.
Tool: kubectl
Evidence: kubectl-output(`kubectl wait --for=condition=ready` exits 0), terminal-output(test runner log shows the wait happened before the curl)

---

## Area: Gateway API
## Area: Gateway API

Coverage: F5.1 envoy-gateway primer + variants, F5.2 istio-gateway-api primer + variants,
F5.3 contour-gateway-api primer + variants.

All cluster operations referenced below run on a cluster whose name matches
`^chart-test-swarm-[a-z0-9-]+$`. Scenario YAMLs live under
`examples/sample-product-chart/chart-test/scenarios/` and are validated against
`engine/templates/scenario.schema.json`. Each implementation's CRDs from
`kubernetes-sigs/gateway-api` (`gateway.networking.k8s.io/v1`) are installed via a
`raw_manifest` preinstall item (per F1.2) before the implementation's controller
chart is installed (per F1.2's envoy-gateway OCI URL fix:
`oci://docker.io/envoyproxy/gateway-helm`). HTTP probes target the gateway address
or the controller pod IP directly (kind has no LoadBalancer).

### Structural / artifact assertions (per integration)

### VAL-GW-001: envoy-gateway primer exists, uses OCI chart ref, and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` exists, is non-empty, references the OCI chart `oci://docker.io/envoyproxy/gateway-helm` (F1.2 fix — the older `https://gateway.envoyproxy.io/helm-chart` URL is defunct), and notes the expected GatewayClass name (`envoy`) plus its `controllerName` (`gateway.envoyproxy.io/gatewayclass-controller`). It documents what + when + how.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md`), terminal-output of `grep -F 'oci://docker.io/envoyproxy/gateway-helm' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` returns ≥ 1 match, terminal-output of `grep -F 'gateway.envoyproxy.io/gatewayclass-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` returns ≥ 1 match, terminal-output of `! grep -F 'gateway.envoyproxy.io/helm-chart' engine/skills/chart-test-swarm/references/integrations/gateway-api/envoy-gateway.md` (i.e. the old URL is NOT present)

### VAL-GW-002: envoy-gateway scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml`, covering httproute, grpcroute, and security-policy-attach variants. Each file's `cluster.preinstall` list includes a `raw_manifest` item delivering the Gateway API CRDs AND a helm item for the envoy-gateway OCI chart.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml | wc -l` ≥ 3, terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-*.yaml; do yq '.cluster.preinstall[] | select(.kind == "raw_manifest")' "$f"; done` returns ≥ 1 raw_manifest item per scenario

### VAL-GW-003: istio-gateway-api primer exists and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` exists, is non-empty, references the `istio/base` + `istio/istiod` Helm charts in the preinstall section, and notes the expected GatewayClass name (`istio`) along with its `controllerName` (`istio.io/gateway-controller`). It explains how Istio's Gateway-API mode differs from its classic ingress-gateway mode.
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md`), terminal-output of `grep -E 'gatewayClassName:\s+istio' engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` returns ≥ 1 match, terminal-output of `grep -F 'istio.io/gateway-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/istio-gateway-api.md` returns ≥ 1 match

### VAL-GW-004: istio-gateway-api scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-*.yaml`, covering basic-gateway, multi-listener, and backend-tls-policy variants. Each scenario's `cluster.preinstall` installs `istio/base` + `istio/istiod` and includes a `raw_manifest` item for Gateway API CRDs.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-istio-gateway-api-*.yaml | wc -l` ≥ 3

### VAL-GW-005: contour-gateway-api primer exists and documents GatewayClass name
The primer at `engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` exists, is non-empty, references the Contour Helm chart with Gateway-API provisioner enabled, and notes the expected GatewayClass name (`contour`) along with its `controllerName` (`projectcontour.io/gateway-controller`). It explains how Contour's Gateway-API mode differs from its HTTPProxy mode (covered by VAL-INGRESS-005).
Tool: bash
Evidence: file(`engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md`), terminal-output of `grep -E 'gatewayClassName:\s+contour' engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` returns ≥ 1 match, terminal-output of `grep -F 'projectcontour.io/gateway-controller' engine/skills/chart-test-swarm/references/integrations/gateway-api/contour-gateway-api.md` returns ≥ 1 match

### VAL-GW-006: contour-gateway-api scenario YAMLs exist (≥ 3 variants)
At least three scenario files exist matching `examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-*.yaml`, covering basic, response-header-modifier, and route-precedence variants.
Tool: bash
Evidence: terminal-output of `ls examples/sample-product-chart/chart-test/scenarios/gateway-api-contour-gateway-api-*.yaml | wc -l` ≥ 3

### Variant execution assertions (envoy-gateway)

### VAL-GW-007: envoy-gateway-httproute scenario admits Gateway and routes HTTP
Running `bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/gateway-api-envoy-gateway-httproute.yaml` against a `chart-test-swarm-<test-id>` kind cluster results in `status: PASS`. The cluster shows: GatewayClass `envoy` with `Accepted: True`; a Gateway with `Programmed: True`; an HTTPRoute with `parents[0].conditions[type=Accepted].status == True`; HTTP curl to the gateway address returns `HTTP/1.1 200` from the product backend.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-httproute-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass envoy -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), kubectl-output(`kubectl get gateway -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Programmed")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-008: envoy-gateway-grpcroute scenario admits GRPCRoute and a gRPC reflection probe succeeds
Running `gateway-api-envoy-gateway-grpcroute.yaml` via `run-scenario.sh` results in `status: PASS`. A `GRPCRoute` resource is admitted (`status.parents[0].conditions[type=Accepted].status == True`). An in-cluster `grpcurl -plaintext <gateway-address>:80 list` (or any gRPC reflection probe against the product chart's gRPC backend) returns at least one service entry without TLS error.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-grpcroute-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get grpcroute -n sample -o jsonpath='{.items[0].status.parents[0].conditions[?(@.type=="Accepted")].status}'` == `True`), terminal-output of `kubectl exec -n sample <probe-pod> -- grpcurl -plaintext <gw>:80 list` returns ≥ 1 service line

### VAL-GW-009: envoy-gateway-security-policy-attach scenario enforces the attached SecurityPolicy
Running `gateway-api-envoy-gateway-security-policy-attach.yaml` via `run-scenario.sh` results in `status: PASS`. A `SecurityPolicy` (Envoy Gateway CRD `gateway.envoyproxy.io/v1alpha1`) is created with a `targetRef` pointing at the HTTPRoute (or Gateway). The policy's effect is observable: e.g. a CORS policy returns the configured `access-control-allow-origin` header on a preflight `OPTIONS` request; a JWT policy rejects unauthenticated requests with `HTTP/1.1 401`. Without the policy, the same probe behaves differently.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-envoy-gateway-security-policy-attach-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get securitypolicy.gateway.envoyproxy.io -n sample -o jsonpath='{.items[0].status.conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers contain the policy's expected effect — e.g. `access-control-allow-origin: *` OR `HTTP/1.1 401` for unauthenticated request)

### Variant execution assertions (istio-gateway-api)

### VAL-GW-010: istio-gateway-api-basic scenario admits Istio-managed Gateway and routes HTTP
Running `gateway-api-istio-gateway-api-basic.yaml` via `run-scenario.sh` results in `status: PASS`. GatewayClass `istio` is `Accepted: True`; the Gateway resource gets `Programmed: True` (Istio auto-provisions the data-plane Deployment + Service in the Gateway's namespace); HTTPRoute is `Accepted: True`; in-cluster curl with the appropriate `Host:` header returns `HTTP/1.1 200`.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-basic-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), kubectl-output(`kubectl get deploy -n sample -l gateway.networking.k8s.io/gateway-name`) returns ≥ 1 auto-provisioned Deployment, curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-011: istio-gateway-api-multi-listener scenario serves HTTP and HTTPS on the same Gateway
Running `gateway-api-istio-gateway-api-multi-listener.yaml` via `run-scenario.sh` results in `status: PASS`. The Gateway declares ≥ 2 listeners (e.g. `name: http port: 80 protocol: HTTP` and `name: https port: 443 protocol: HTTPS`); both listeners report `conditions[type=Programmed].status == True` per `status.listeners[]`. An HTTP curl to port 80 returns `200`; an HTTPS curl to port 443 (with `--insecure` or the issuer CA) also returns `200`.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-multi-listener-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gateway -n sample -o jsonpath='{.items[0].status.listeners[*].name}'`) lists ≥ 2 listener names, curl-response on port 80: `HTTP/1.1 200`, curl-response on port 443: `HTTP/1.1 200`

### VAL-GW-012: istio-gateway-api-backend-tls-policy scenario terminates TLS to the backend per BackendTLSPolicy
Running `gateway-api-istio-gateway-api-backend-tls-policy.yaml` via `run-scenario.sh` results in `status: PASS`. A `BackendTLSPolicy` (Gateway API `v1alpha3`) targeting the product Service is `Accepted: True`. The HTTPRoute's path-prefix probe goes through the gateway and the gateway initiates a TLS handshake to the upstream backend Service (verifiable via Istio access logs, OR by configuring the backend to require TLS and observing the request succeed only when the policy is in place).
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-istio-gateway-api-backend-tls-policy-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get backendtlspolicy.gateway.networking.k8s.io -n sample -o jsonpath='{.items[0].status.ancestors[0].conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200` through the gateway; backend access log shows TLS handshake)

### Variant execution assertions (contour-gateway-api)

### VAL-GW-013: contour-gateway-api-basic scenario admits Contour-managed Gateway and routes HTTP
Running `gateway-api-contour-gateway-api-basic.yaml` via `run-scenario.sh` results in `status: PASS`. GatewayClass `contour` is `Accepted: True`; the Gateway is `Programmed: True`; the HTTPRoute is `Accepted: True`; in-cluster curl returns `HTTP/1.1 200`. The data plane Envoy pod is managed by Contour's `Gateway`-mode provisioner.
Tool: run-scenario.sh
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-basic-*/result.yaml`) with `status: PASS`, kubectl-output(`kubectl get gatewayclass contour -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` == `True`), curl-response(headers: `HTTP/1.1 200`)

### VAL-GW-014: contour-gateway-api-response-header-modifier scenario applies the declared header filter
Running `gateway-api-contour-gateway-api-response-header-modifier.yaml` via `run-scenario.sh` results in `status: PASS`. The HTTPRoute's `rules[0].filters[]` includes a `type: ResponseHeaderModifier` entry adding a header (e.g. `X-Powered-By: chart-test-swarm`). A curl through the gateway returns the response with that header set. Without the filter, the same response does not include the header.
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-response-header-modifier-*/result.yaml`) with `status: PASS`, curl-response(headers include `x-powered-by: chart-test-swarm` exactly as configured in the filter)

### VAL-GW-015: contour-gateway-api-route-precedence scenario resolves overlapping routes per the spec's precedence rules
Running `gateway-api-contour-gateway-api-route-precedence.yaml` via `run-scenario.sh` results in `status: PASS`. Two HTTPRoutes exist for the same host with overlapping path prefixes (e.g. `/api` and `/api/v2`); the more specific route (`/api/v2`) wins for matching requests and the less specific (`/api`) wins for non-overlapping paths. The probe verifies BOTH paths route to distinct backends (e.g. via a response header identifying which route handled the request).
Tool: curl
Evidence: file(`reports/run-*/scenario-gateway-api-contour-gateway-api-route-precedence-*/result.yaml`) with `status: PASS`, curl-response on `/api/v2/foo`: header `x-route: v2`; curl-response on `/api/foo`: header `x-route: v1`

### Area-wide structural assertions

### VAL-GW-016: All gateway-api scenario YAMLs install Gateway API CRDs via raw_manifest preinstall
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml` includes at least one `cluster.preinstall[]` item with `kind: raw_manifest` whose `path` resolves to a manifest that includes `gateway.networking.k8s.io` CRDs (or a documented URL to the upstream `standard-install.yaml`). No scenario relies on CRDs being pre-installed out-of-band.
Tool: yq
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml; do count=$(yq '[.cluster.preinstall[] | select(.kind == "raw_manifest")] | length' "$f"); echo "$f: $count"; done` reports `count >= 1` for every file

### VAL-GW-017: Scenarios use the correct GatewayClass name for their implementation
For each scenario, the GatewayClass referenced in the embedded Gateway manifest (or in a documented post-install step) matches the implementation's primer-declared name: `envoy` for envoy-gateway scenarios, `istio` for istio-gateway-api scenarios, `contour` for contour-gateway-api scenarios. No scenario uses a mismatched GatewayClass (e.g. an `envoy-gateway-*` scenario must NOT reference `gatewayClassName: contour`).
Tool: yq
Evidence: terminal-output of a grep harness that, for each scenario family, extracts the `gatewayClassName` value(s) from the inline manifest (in `raw_manifest` content or fixture file) and confirms it matches the implementation prefix — e.g. for `gateway-api-envoy-gateway-*.yaml`, `grep -rh 'gatewayClassName:' <referenced fixtures>` only ever returns `envoy`

### VAL-GW-018: All gateway-api scenario YAMLs pass jsonschema validation
Every scenario file under `examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml` validates cleanly against `engine/templates/scenario.schema.json`. (The schema's relaxed `preinstall_item` per F1.2 must accept `kind: raw_manifest` items.)
Tool: bash
Evidence: terminal-output of `for f in examples/sample-product-chart/chart-test/scenarios/gateway-api-*.yaml; do uv run --directory engine/testgrid python -m testgrid validate-scenario "$f" && echo OK $f || echo FAIL $f; done` shows `OK` for every file and exit code 0 overall

### VAL-GW-019: helm lint passes for the sample-product-chart
`helm lint examples/sample-product-chart/chart` exits 0 with no `[ERROR]` lines. The chart is the only chart referenced by the gateway-api-area scenarios via `product.chart`.
Tool: helm-lint
Evidence: terminal-output of `helm lint examples/sample-product-chart/chart` shows `1 chart(s) linted, 0 chart(s) failed` and exit code 0

### VAL-GW-020: Gateway API CRD version is captured in the artifacts/ bundle
For every gateway-api scenario run that PASSes, the produced `reports/run-*/scenario-*/artifacts/manifests/` directory contains at least one file whose content shows `apiVersion: gateway.networking.k8s.io/v1` (or `v1beta1` if the scenario declares it) AND `artifacts/versions.json` includes a new key `gateway_api_crds` reflecting the installed CRD version (e.g., `v1.0.0`, `v1.1.0`). Pass requires both the manifest evidence and the version stamp.
Tool: bash
Evidence: file(reports/run-*/scenario-*/artifacts/manifests/*.yaml), command-output(`yq '.apiVersion'`), command-output(`jq '.gateway_api_crds' artifacts/versions.json`)

---

## Area: Service Mesh
## Area: Service Mesh

Behavioral validation assertions for Milestone 6 — service-mesh integrations:
F6.1 `istio-service-mesh`, F6.2 `istio-ingress-gateway`, F6.3 `linkerd`.

All cluster operations are executed on a kind cluster whose name matches
`chart-test-swarm-<id>`. Assertions are written so they can be re-derived from
the reports artifact bundle alone.

---

### VAL-MESH-001: istio-service-mesh primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path,
documenting cluster preinstall, feasibility checklist, helm-test pattern, and
common failure modes for the integration.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/istio-service-mesh.md)

### VAL-MESH-002: istio-ingress-gateway primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path with the
gateway-component preinstall block, feasibility checklist, helm-test pattern
covering Gateway + VirtualService application, and Istio Gateway vs Gateway API
disambiguation guidance.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/istio-ingress-gateway.md)

### VAL-MESH-003: linkerd primer authored
A new Linkerd primer MUST exist documenting `linkerd-control-plane` preinstall,
feasibility checklist (no `hostNetwork`, no `runAsNonRoot: false`-forbidden
constraints), helm-test pattern injecting the test pod, and failure-mode
discussion (`linkerd check` failures, proxy not injected, mTLS rotation lag).
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/service-mesh/linkerd.md)

### VAL-MESH-004: every service-mesh scenario YAML validates against schema
Each scenario file produced for F6.1/F6.2/F6.3 (the 12 variants combined) MUST
parse successfully and validate against `engine/templates/scenario.schema.json`
with no additional-property or missing-required errors.
Tool: jsonschema
Evidence: terminal-output (exit code 0; no error lines per file)

### VAL-MESH-005: istio-service-mesh has 3-4 schema-valid variants
Scenarios named `service-mesh-istio-service-mesh-{sidecar-injection,strict-mtls,peer-authentication,telemetry-v2}.yaml` MUST exist under `examples/sample-product-chart/chart-test/scenarios/`, each with `cluster.provider: kind`, designed to be invoked with the `CLUSTER_NAME` env var matching `^chart-test-swarm-[a-z0-9-]+$`, and a complete `cluster.preinstall` list referencing the istio base + istiod charts.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-service-mesh-*.yaml) for each of the 4 variants

### VAL-MESH-006: istio-ingress-gateway has 3-4 schema-valid variants
Scenarios named `service-mesh-istio-ingress-gateway-{basic,multi-host,jwt,request-authentication}.yaml` MUST exist with the istio gateway helm chart added to `cluster.preinstall` and (for jwt + request-authentication variants) the JWT fixtures referenced under `examples/sample-product-chart/chart-test/fixtures/service-mesh/`.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-istio-ingress-gateway-*.yaml) for each of the 4 variants

### VAL-MESH-007: linkerd has 3-4 schema-valid variants
Scenarios named `service-mesh-linkerd-{basic-mesh,multi-cluster-preview,service-profile,mtls-rotation}.yaml` MUST exist, each with linkerd `helm` preinstall items (or `raw_manifest` for CRD bootstrap) and a product release that opts the namespace into mesh injection via the `linkerd.io/inject: enabled` annotation.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/service-mesh-linkerd-*.yaml) for each of the 4 variants

### VAL-MESH-008: istio sidecar is injected into product pods
After `run-scenario.sh` completes the `istio-service-mesh-sidecar-injection`
variant on a kind cluster, every product pod selected by
`app.kubernetes.io/name=<release>` MUST have exactly 2 containers in
`.spec.containers[*].name`: the product container plus `istio-proxy`.
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod -l app.kubernetes.io/name=<release> -o jsonpath='{.items[*].spec.containers[*].name}'` contains `istio-proxy`

### VAL-MESH-009: in-mesh pod can reach product Service over the sidecar
A second pod with `sidecar.istio.io/inject: "true"` and the namespace
`istio-injection=enabled` label issues an HTTP GET to the product Service FQDN
on its declared port and receives a 2xx response (curl exit 0 with `--fail`).
Tool: curl
Evidence: curl-response — HTTP 200 from `http://<release>.<ns>.svc.cluster.local:<port>/`, captured in the test pod log

### VAL-MESH-010: strict-mtls PeerAuthentication is enforced cluster-side
After the `strict-mtls` variant applies its setup, a `PeerAuthentication`
resource named `<release>-mtls` MUST exist in the product namespace with
`spec.mtls.mode == "STRICT"`.
Tool: kubectl
Evidence: kubectl-output(peerauthentication) — `kubectl -n <ns> get peerauthentication <release>-mtls -o yaml` shows `spec.mtls.mode: STRICT`

### VAL-MESH-011: plain HTTP from non-mesh pod is rejected under STRICT mTLS
A control pod created in a separate namespace with no Istio sidecar (and no
namespace injection label) issuing plain HTTP to the product Service under
the STRICT PeerAuthentication MUST be rejected — curl exits non-zero with
connection reset, or receives HTTP 503 — within the 15s probe timeout.
Tool: curl
Evidence: curl-response — non-zero exit / 503 / "Connection reset by peer" captured in helm-test log

### VAL-MESH-012: HTTPS / in-mesh traffic from mesh pod still works under STRICT mTLS
The mesh-resident probe pod (with sidecar injection enabled) issuing the same
HTTP request under STRICT MUST succeed (HTTP 200 via the auto-upgraded
sidecar-to-sidecar mTLS tunnel) — confirming the policy rejects only
non-mesh peers.
Tool: curl
Evidence: curl-response — HTTP 200 from in-mesh probe pod, captured in helm-test log

### VAL-MESH-013: istio Gateway resource is admitted and reconciled
After the `istio-ingress-gateway-basic` variant applies its setup, the
`networking.istio.io/v1beta1 Gateway` named `<release>-igw` MUST exist in the
product namespace and `kubectl get gateway` succeeds (no `no matches for kind`).
Tool: kubectl
Evidence: kubectl-output(gateway) — `kubectl -n <ns> get gateway <release>-igw -o yaml`

### VAL-MESH-014: VirtualService routes traffic through the ingress gateway
A request to the istio-ingressgateway pod IP with the Host header set to the
gateway's declared `hosts:` entry MUST be routed to the product Service and
return HTTP 200 from the application.
Tool: curl
Evidence: curl-response — HTTP 200 to `http://<gw-pod-ip>:80/` with `Host: <release>.test.local`, captured in helm-test log

### VAL-MESH-015: JWT variant rejects requests without a valid token
On the `istio-ingress-gateway-jwt` variant, a curl request through the
ingressgateway with no `Authorization: Bearer` header (or an invalid token)
MUST be rejected at the gateway with HTTP 401 or 403 from the
RequestAuthentication / AuthorizationPolicy combination.
Tool: curl
Evidence: curl-response — HTTP 401/403 captured in helm-test log

### VAL-MESH-016: JWT variant accepts requests with a valid token
On the same `istio-ingress-gateway-jwt` variant, the helm-test pod signs a
JWT with the test issuer key (mounted from `fixtures/service-mesh/jwt/`) and
curls the ingress gateway with `Authorization: Bearer <token>` — the request
MUST be admitted and return HTTP 200 from the product Service.
Tool: curl
Evidence: curl-response — HTTP 200 with valid bearer token, captured in helm-test log

### VAL-MESH-017: linkerd-proxy sidecar is injected into product pods
After `run-scenario.sh` completes the `linkerd-basic-mesh` variant, every
product pod MUST have a `linkerd-proxy` container alongside the product
container (2-container pod).
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod -l app.kubernetes.io/name=<release> -o jsonpath='{.items[*].spec.containers[*].name}'` contains `linkerd-proxy`

### VAL-MESH-018: `linkerd check` reports healthy control plane and data plane
The helm-test probe pod invokes `linkerd check --proxy` (or the equivalent
in-cluster API call) against the linkerd control plane installed by
preinstall_items and the command MUST exit 0 with "Status check results are √".
Tool: bash
Evidence: terminal-output — `linkerd check` final line contains "Status check results are √" in helm-test log

### VAL-MESH-019: every service-mesh variant produces a PASS result.yaml on kind
After `dispatch-swarm.sh` executes all 12 service-mesh variants on the
mission's kind cluster, each `reports/run-*/result.yaml` entry for these
scenarios MUST report `status: PASS` with non-empty `detail` per assertion
and an `artifacts/` directory populated with `scenario.yaml`,
`applied-overrides.yaml`, and `versions.json`.
Tool: yq
Evidence: file(reports/run-*/result.yaml); file(reports/run-*/artifacts/<scenario>/versions.json) — `versions.json` contains keys helm, kubectl, kind, minikube, k8s_server

### VAL-MESH-020: helm lint passes for the sample chart with mesh-variant overrides
For each of the 12 service-mesh variants, `helm lint examples/sample-product-chart/chart --values <applied-overrides>` exits 0 — proving the override pattern in the primer renders without templating errors.
Tool: helm
Evidence: terminal-output — `helm lint` reports `1 chart(s) linted, 0 chart(s) failed`

### VAL-MESH-021: yamllint clean on all service-mesh scenario files
`yamllint engine/skills/chart-test-swarm/references/integrations/service-mesh/**/*.yaml examples/sample-product-chart/chart-test/scenarios/service-mesh-*.yaml` exits 0 (after the milestone's clean-as-you-go pass) — no remaining style errors on mesh-touched files.
Tool: bash
Evidence: terminal-output — `yamllint` exit code 0, no error lines

### VAL-MESH-022: Mesh teardown removes mesh-installed admission webhooks
After `cluster-down.sh` runs for a cluster that hosted a mesh variant (istio or linkerd), the next clean kind cluster created in the same Docker Desktop session shows zero `MutatingWebhookConfiguration` or `ValidatingWebhookConfiguration` entries with names matching `istio-sidecar-injector` or `linkerd-proxy-injector-webhook`. Pass requires zero mesh-installed webhooks survive teardown.
Tool: kubectl
Evidence: kubectl-output(`kubectl get mutatingwebhookconfiguration -o name | grep -E 'istio|linkerd'` returns empty), exit-code 1 from grep

---

## Area: Policy Engines
## Area: Policy Engines

Behavioral validation assertions for Milestone 7 — policy-engine integrations:
F7.1 `opa-gatekeeper`, F7.2 `kyverno`.

All cluster operations are executed on a kind cluster whose name matches
`chart-test-swarm-<id>`. Admission-rejection assertions use `kubectl
--dry-run=server` so they exercise the live admission webhook without
mutating cluster state.

---

### VAL-POLICY-001: opa-gatekeeper primer present after category reorg
The primer markdown file MUST exist at the canonical post-reorg path under the
`policy/` subdir, documenting gatekeeper preinstall, the inverted feasibility
model (soft checks surface chart non-compliances), and helm-test pattern using
ConstraintTemplates + Constraints with dry-run server-side apply.
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/policy/opa-gatekeeper.md)

### VAL-POLICY-002: kyverno primer authored
A new Kyverno primer MUST exist documenting the kyverno helm chart preinstall,
feasibility checklist, helm-test pattern for ClusterPolicy authoring + dry-run
admission probing, and failure-mode discussion (webhook timeout, policy-report
lag, image-verify keyring trust).
Tool: bash
Evidence: file(engine/skills/chart-test-swarm/references/integrations/policy/kyverno.md)

### VAL-POLICY-003: every policy scenario YAML validates against schema
Each scenario file produced for F7.1/F7.2 (8 variants combined) MUST parse
successfully and validate against `engine/templates/scenario.schema.json` with
no additional-property or missing-required errors.
Tool: jsonschema
Evidence: terminal-output — exit code 0; no error lines per file

### VAL-POLICY-004: opa-gatekeeper has 3-4 schema-valid variants
Scenarios named `policy-opa-gatekeeper-{required-labels,image-allowlist,resource-limits,sync-config}.yaml` MUST exist under `examples/sample-product-chart/chart-test/scenarios/`, each with `cluster.provider: kind`, designed to be invoked with the `CLUSTER_NAME` env var matching `^chart-test-swarm-[a-z0-9-]+$`, and a `cluster.preinstall` entry pulling the `gatekeeper/gatekeeper` helm chart at the pinned version from the primer.
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/policy-opa-gatekeeper-*.yaml) for each of the 4 variants

### VAL-POLICY-005: kyverno has 3-4 schema-valid variants
Scenarios named `policy-kyverno-{validate,mutate,generate,image-verify}.yaml` MUST exist with the `kyverno/kyverno` helm chart in `cluster.preinstall` at a pinned version and a `validatingWebhookFailurePolicy: Fail` override (so policy enforcement is not silently skipped).
Tool: yq
Evidence: file(examples/sample-product-chart/chart-test/scenarios/policy-kyverno-*.yaml) for each of the 4 variants

### VAL-POLICY-006: opa-gatekeeper required-labels — ConstraintTemplate establishes
On the `policy-opa-gatekeeper-required-labels` variant, after the helm-test
pod applies its setup ConfigMap, the ConstraintTemplate `k8srequiredlabels`
MUST reach `status.byPod[*].observedGeneration` >= `metadata.generation` and
the matching CRD `k8srequiredlabels.constraints.gatekeeper.sh` MUST report
`condition=Established=True` within 90s.
Tool: kubectl
Evidence: kubectl-output(constrainttemplate); kubectl-output(crd) — `kubectl wait crd/k8srequiredlabels.constraints.gatekeeper.sh --for=condition=Established --timeout=90s` exits 0

### VAL-POLICY-007: opa-gatekeeper required-labels — non-compliant Deployment rejected
A Deployment intentionally missing the required `app.kubernetes.io/name` label
applied with `kubectl --dry-run=server` MUST be rejected by the
ValidatingAdmissionWebhook with a clear error message referencing the
constraint name and the missing label.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f noncompliant.yaml` exit code non-zero; stderr contains `admission webhook` and `Missing required label(s): {"app.kubernetes.io/name"}`

### VAL-POLICY-008: opa-gatekeeper required-labels — compliant Deployment accepted
The mirror Deployment with the required label set MUST pass the same dry-run
admission check (exit 0, no `admission webhook ... denied` line in stderr).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant.yaml` exit code 0; stdout contains `deployment.apps/<name> created (server dry run)`

### VAL-POLICY-009: opa-gatekeeper image-allowlist — non-allowlisted image denied
On the `policy-opa-gatekeeper-image-allowlist` variant, a Deployment whose pod
template uses an image from a registry NOT in the `K8sAllowedRepos` parameter
list MUST be denied at admission with the webhook message naming the
disallowed registry.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr contains `admission webhook` and the offending image string

### VAL-POLICY-010: opa-gatekeeper image-allowlist — allowlisted image accepted
A mirror Deployment using an image from the allowlisted registry MUST pass
the same dry-run admission check (exit 0).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant-image.yaml` exit code 0

### VAL-POLICY-011: opa-gatekeeper resource-limits — Deployment without limits denied
On the `policy-opa-gatekeeper-resource-limits` variant, a Deployment whose
containers omit `resources.limits.cpu` or `resources.limits.memory` MUST be
denied with the `K8sContainerLimits` constraint message naming the offending
container.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr names the container missing the limit

### VAL-POLICY-012: opa-gatekeeper sync-config — Config resource present
On the `policy-opa-gatekeeper-sync-config` variant, a Gatekeeper `Config`
resource MUST exist in the `gatekeeper-system` namespace with `spec.sync.syncOnly`
listing at least one referential type (e.g., `Namespace`, `Service`) so
referential constraints can resolve.
Tool: kubectl
Evidence: kubectl-output(config) — `kubectl -n gatekeeper-system get config config -o yaml` shows non-empty `spec.sync.syncOnly`

### VAL-POLICY-013: kyverno validate — non-compliant Deployment rejected
On the `policy-kyverno-validate` variant, a Deployment violating the
ClusterPolicy validation rule (e.g., missing required label, latest tag,
runAsRoot) MUST be denied by the kyverno admission webhook with a message
referencing the policy + rule name.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f noncompliant.yaml` exit code non-zero; stderr contains `admission webhook "validate.kyverno.svc-fail"` and the policy name

### VAL-POLICY-014: kyverno validate — compliant Deployment accepted
The corresponding compliant Deployment MUST pass the same dry-run check
(exit 0).
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server -f compliant.yaml` exit code 0

### VAL-POLICY-015: kyverno mutate — pod without annotation gets it auto-added
On the `policy-kyverno-mutate` variant, after applying a Pod manifest that
LACKS the target annotation, the resulting in-cluster Pod (after the mutating
webhook fires) MUST carry the annotation set by the ClusterPolicy mutate rule.
Tool: kubectl
Evidence: kubectl-output(pod) — `kubectl -n <ns> get pod <pod-name> -o jsonpath='{.metadata.annotations}'` contains the policy-injected key/value

### VAL-POLICY-016: kyverno generate — namespace triggers ConfigMap / NetworkPolicy creation
On the `policy-kyverno-generate` variant, creating a fresh namespace labelled
to match the ClusterPolicy `match` block MUST cause kyverno to generate the
template's downstream resource (default ConfigMap or default-deny NetworkPolicy)
in that namespace within 10s.
Tool: kubectl
Evidence: kubectl-output(configmap/networkpolicy) — `kubectl -n <new-ns> get cm,networkpolicy` lists the generated resource named per the policy

### VAL-POLICY-017: kyverno image-verify — unsigned image denied (best-effort)
On the `policy-kyverno-image-verify` variant, a Pod referencing an image
without the configured signature attestation MUST be denied by the kyverno
verifyImages rule with an error message naming the policy.
Tool: kubectl
Evidence: terminal-output — `kubectl apply --dry-run=server` exit code non-zero; stderr names the verifyImages rule

### VAL-POLICY-018: every policy variant produces a PASS result.yaml on kind
After `dispatch-swarm.sh` executes all 8 policy variants on the mission's
kind cluster, each `reports/run-*/result.yaml` entry MUST report
`status: PASS` with non-empty `detail` per assertion and a populated
`artifacts/` directory.
Tool: yq
Evidence: file(reports/run-*/result.yaml); file(reports/run-*/artifacts/<scenario>/versions.json)

### VAL-POLICY-019: helm lint passes for the sample chart with policy-variant overrides
For each of the 8 policy variants, `helm lint examples/sample-product-chart/chart --values <applied-overrides>` exits 0 — proving the override pattern in the primer renders without templating errors.
Tool: helm
Evidence: terminal-output — `helm lint` reports `1 chart(s) linted, 0 chart(s) failed`

### VAL-POLICY-020: Policy webhook failure mode is documented and exercised
Each policy primer (opa-gatekeeper, kyverno) declares in a "Webhook failure mode" section whether the chart-as-shipped configures `failurePolicy: Fail` or `failurePolicy: Ignore`. For at least one variant per engine, the rendered admission webhook (verified via `kubectl get validatingwebhookconfiguration -o yaml`) shows the declared failurePolicy. A scenario that intentionally takes the policy controller offline (e.g., `kubectl scale deploy/gatekeeper-controller --replicas=0`) THEN applies a target resource exhibits the documented behavior (apply succeeds under Ignore; apply fails with webhook-timeout under Fail). Pass requires primer-documented + cluster-observed + scenario-exercised match.
Tool: kubectl
Evidence: file(<primer>.md contains `## Webhook failure mode`), kubectl-output(`.webhooks[0].failurePolicy`), terminal-output(deliberate-outage probe result)

---

## Area: Cloud-Native Primers (AUTHORED ONLY)
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

---

## Area: CLI Tool
## Area: CLI Tool

### VAL-CLI-001: Console script registered in pyproject.toml
`engine/testgrid/pyproject.toml` `[project.scripts]` declares a `chart-test-swarm` entry pointing at a `main`/`app` callable inside the `testgrid` package (alongside the existing `testgrid` entry).
Tool: yq
Evidence: terminal-output of `yq -p toml '.project.scripts."chart-test-swarm"' engine/testgrid/pyproject.toml` returns a non-null string ending in `:main` or `:app`; file(engine/testgrid/pyproject.toml).

### VAL-CLI-002: Console script installs on PATH after uv sync
Running `uv sync --directory engine/testgrid` makes the `chart-test-swarm` binary discoverable inside the project virtualenv, and `engine/testgrid/.venv/bin/chart-test-swarm` is an executable file.
Tool: bash
Evidence: exit-code 0 from `test -x engine/testgrid/.venv/bin/chart-test-swarm`; terminal-output of `engine/testgrid/.venv/bin/chart-test-swarm --version` (or `--help`) is non-empty on stdout.

### VAL-CLI-003: Root --help exits 0 and lists all subcommands
`chart-test-swarm --help` exits 0 and the output contains the substrings `run`, `dashboard`, `list`, and `generate` (case-sensitive).
Tool: bash
Evidence: exit-code 0; terminal-output of `chart-test-swarm --help | grep -E '^\s*(run|dashboard|list|generate)\b'` shows all four subcommand lines.

### VAL-CLI-004: No-args invocation exits non-zero with help message
`chart-test-swarm` with no subcommand exits non-zero and prints a usage/help message to stderr (or stdout) that includes the program name and the subcommand list.
Tool: bash
Evidence: exit-code != 0 from `chart-test-swarm`; combined stdout+stderr contains the literal `Usage` and at least one of `run|dashboard|list|generate`.

### VAL-CLI-005: Unknown subcommand exits non-zero with clear error
`chart-test-swarm not-a-real-subcommand` exits non-zero and the error message names the offending token.
Tool: bash
Evidence: exit-code != 0; stderr contains `not-a-real-subcommand` (typer/click style "No such command" or equivalent).

### VAL-CLI-006: `run --help` exposes required flags
`chart-test-swarm run --help` exits 0 and the output advertises all four flags: `--scenario`, `--integration`, `--backend`, `--parallelism`.
Tool: bash
Evidence: exit-code 0; terminal-output passes `grep -q -- --scenario && grep -q -- --integration && grep -q -- --backend && grep -q -- --parallelism`.

### VAL-CLI-007: `run --scenario <path>` dispatches via dispatch-swarm.sh and writes run-* directory
Invoking `chart-test-swarm run --scenario examples/sample-product-chart/chart-test/scenarios/<a>.yaml` triggers `engine/scripts/dispatch-swarm.sh` (verifiable via a `--dry-run` flag that prints the resolved command, or via a stub on PATH) and, on a real run, creates exactly one new directory matching `reports/run-*` containing `result.yaml`.
Tool: pytest
Evidence: pytest test using `subprocess.run` with `PATH` shimmed so `dispatch-swarm.sh` is a captured stub asserts the stub was invoked with the scenario path; on a live run, `Path('reports').glob('run-*')` count increases by 1 and `result.yaml` exists in the new dir.

### VAL-CLI-008: `run --integration <name>` filters scenarios to that integration only
`chart-test-swarm run --integration cert-manager --dry-run` (or with the dispatch stub) shows that only scenarios whose path contains `cert-manager` (or whose `integration:` field equals `cert-manager`) are passed downstream.
Tool: pytest
Evidence: pytest test inspects the recorded scenario list from the stub and asserts every path matches `*cert-manager*`; for non-matching integration name, the list is empty and the CLI exits non-zero with a "no scenarios matched" message.

### VAL-CLI-009: `run --backend minikube` forwards backend to engine scripts
`chart-test-swarm run --backend minikube --dry-run` (or via stub) results in the downstream invocation receiving `--backend minikube` (or equivalent env var) verbatim; passing `--backend invalid-backend` exits non-zero with a schema-enum error before any cluster work begins.
Tool: pytest
Evidence: stub captures argv containing `--backend minikube`; for the invalid case, exit-code != 0 and stderr contains `kind|minikube|k3d|eks|gke|aks|vcluster` or `invalid choice`.

### VAL-CLI-010: `run --parallelism N` caps concurrent scenarios at N
`chart-test-swarm run --parallelism 2` causes dispatch-swarm.sh to be invoked with `NUM_AGENTS=2` (or the third positional arg `2`), and `--parallelism 0` / negative values are rejected with exit-code != 0.
Tool: pytest
Evidence: stub asserts `NUM_AGENTS=2` in the environment or `2` as positional arg; pytest parametrized test covers `--parallelism 0`, `--parallelism -1`, `--parallelism foo` all returning non-zero with a clear validation error.

### VAL-CLI-011: `dashboard` invokes build-dashboard.sh and produces index.html
`chart-test-swarm dashboard` shells out to `engine/scripts/build-dashboard.sh` and, on a non-empty `reports/` tree, writes `reports/<run-id>/dist/index.html` (or `reports/dist/index.html` per the script's default).
Tool: bash
Evidence: exit-code 0; file(reports/dist/index.html) or file(reports/<run-id>/dist/index.html) exists and contains `<html`; stub mode captures `build-dashboard.sh` invocation in argv log.

### VAL-CLI-012: `list integrations` enumerates every (category, integration) tuple
`chart-test-swarm list integrations` walks `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` and prints one line per primer in a stable, sorted order, with category and integration both visible.
Tool: pytest
Evidence: pytest test asserts that for a fixture integrations tree (`certificates/cert-manager.md`, `ingress-controllers/nginx-ingress.md`), the stdout contains both `certificates\tcert-manager` and `ingress-controllers\tnginx-ingress` (or equivalent two-column format) and lines are sorted.

### VAL-CLI-013: `list variants --integration <name>` enumerates matching scenario YAMLs
`chart-test-swarm list variants --integration cert-manager` prints every scenario YAML path under `examples/*/scenarios/` whose filename or `integration:` field matches `cert-manager`; omitting `--integration` lists all variants across all integrations.
Tool: pytest
Evidence: pytest fixture creates scenarios `certificates-cert-manager-self-signed.yaml` and `certificates-cert-manager-letsencrypt.yaml`; CLI stdout contains both paths and excludes `ingress-controllers-nginx-basic.yaml`.

### VAL-CLI-014: Cluster name prefix is enforced before any cluster-creating subcommand
Any subcommand that would create or touch a cluster (run, generate explore) refuses to proceed if the resolved cluster name does not start with `chart-test-swarm-`; the check happens before subprocess dispatch.
Tool: pytest
Evidence: pytest test invokes `chart-test-swarm run` with `CLUSTER_NAME=not-prefixed-cluster` (or equivalent override); exit-code != 0 and stderr contains `chart-test-swarm-` and the offending name; no `kind create cluster` / `minikube start` invocation is recorded by the PATH stub.

### VAL-CLI-015: CLI argument parsing is covered by pytest for every subcommand
`engine/testgrid/tests/test_cli.py` exists and contains `pytest` test cases that exercise `--help`, valid invocation, and at least one invalid-flag case for each of `run`, `dashboard`, `list integrations`, `list variants`, `generate pick`, `generate author`, `generate explore`.
Tool: pytest
Evidence: terminal-output of `uv run --directory engine/testgrid pytest tests/test_cli.py -v` shows ≥ 1 passing test per subcommand (matched via test-name grep); exit-code 0.

### VAL-CLI-016: No orphan processes or stranded clusters after CLI exits
After `chart-test-swarm run --scenario <path>` completes (PASS or FAIL), `docker ps --format '{{.Names}}' | grep chart-test-swarm-` is empty AND `kind get clusters | grep chart-test-swarm-` is empty AND `minikube profile list -o json | jq '.valid[]?.Name' | grep chart-test-swarm-` is empty.
Tool: bash
Evidence: exit-code 1 (i.e., grep finds nothing) from each of the three commands; no child processes of the CLI remain in `pgrep -P $$` after CLI exits.

### VAL-CLI-017: Repo lint + typecheck gates pass for CLI module
`uv run --directory engine/testgrid ruff check src/testgrid` and `uv run --directory engine/testgrid mypy src/testgrid` both exit 0 against the CLI module (including any new `cli.py` / `commands/` files added for `chart-test-swarm`).
Tool: bash
Evidence: exit-code 0 from both commands; terminal-output contains `All checks passed!` (ruff) and `Success: no issues found` (mypy).

### VAL-CLI-018: `run` emits machine-readable run id to stdout for chaining
After dispatching, `chart-test-swarm run --scenario <path>` prints the resolved `RUN_ID` (matching `^run-[0-9]{8}-[0-9]{6}$`) as the last line of stdout so callers (including `generate explore`) can capture it programmatically.
Tool: bash
Evidence: terminal-output `chart-test-swarm run --scenario <path> | tail -n1` matches `^run-[0-9]{8}-[0-9]{6}$`; the printed directory `reports/<run-id>` exists on disk after exit.

### VAL-CLI-019: CLI exits with a clear error for a missing scenario file (no Python traceback)
Invoking `chart-test-swarm run --scenario /tmp/does-not-exist.yaml` exits non-zero within 5 seconds. Stderr contains the literal path `/tmp/does-not-exist.yaml` AND a phrase like "not found" / "no such file" / "does not exist". Stderr DOES NOT contain `Traceback (most recent call last)` or `FileNotFoundError`. Pass requires non-zero exit + actionable message + no raw Python traceback.
Tool: bash
Evidence: exit-code, terminal-output(stderr)

### VAL-CLI-020: CLI `--version` prints a semver-ish version string and exits 0
Running `chart-test-swarm --version` exits 0 within 2 seconds and stdout contains a version token matching `^\d+\.\d+\.\d+` (semver) OR `^v\d+\.\d+\.\d+`. The version is the version recorded in `engine/testgrid/pyproject.toml`'s `[project].version` field. Pass requires both exit 0, semver-shaped output, AND match against pyproject.
Tool: bash
Evidence: exit-code, terminal-output(stdout), command-output(`yq -p toml '.project.version' engine/testgrid/pyproject.toml`)

### VAL-CLI-021: CLI `run` and `bash engine/scripts/run-scenario.sh` produce equivalent reports/run-* outputs for the same scenario
For the same scenario YAML, invoking once via `chart-test-swarm run --scenario <path>` and once via `bash engine/scripts/run-scenario.sh <path>` both produce a `reports/run-*` directory. Comparing the two: `result.yaml.scenarios[].status` is identical, `artifacts/scenario.yaml` is byte-identical (or differs only in absolute-path normalization), `artifacts/versions.json` keys are identical (values may differ if tool versions changed), and `artifacts/applied-overrides.yaml` is byte-identical. Pass requires status equivalence + artifact-shape equivalence.
Tool: bash
Evidence: terminal-output(`diff <(yq '.scenarios[] | {id,status}' reports/run-A/result.yaml) <(yq '.scenarios[] | {id,status}' reports/run-B/result.yaml)` empty), terminal-output(`diff reports/run-A/scenario-*/artifacts/scenario.yaml reports/run-B/scenario-*/artifacts/scenario.yaml` empty)

### VAL-CLI-022: Every CLI flag has a documented engine-script env-var mapping
The CLI's `--backend`, `--cluster-name`, `--parallelism`, `--run-id`, `--reports-dir`, `--project-dir`, `--scenario`, `--suite` flags each map to exactly one engine-script env var. The mapping table lives in `engine/cli/src/chart_test_swarm/forward.py` (or equivalent) as a literal dict, AND `chart-test-swarm run --scenario ... -x` (or via `CTS_DEBUG=1 bash -x`) produces output showing the env var was set with the CLI-supplied value. Concretely: `--backend minikube` ⇒ `PROVIDER=minikube`, `--parallelism N` ⇒ `NUM_AGENTS=N`, `--cluster-name foo` ⇒ `CLUSTER_NAME=foo`, `--run-id X` ⇒ `RUN_ID=X`, `--reports-dir D` ⇒ `REPORTS_DIR=D`, `--project-dir P` ⇒ `PROJECT_DIR=P`, `--suite S` ⇒ `SUITE=S`. Pass requires the mapping table is asserted + observed.
Tool: bash
Evidence: terminal-output (`CTS_DEBUG=1 chart-test-swarm run --backend minikube --parallelism 2 --cluster-name ct-x ...` shows `PROVIDER=minikube`, `NUM_AGENTS=2`, `CLUSTER_NAME=ct-x` in the trace), grep-match (`rg -n 'FLAG_TO_ENV' engine/cli/src/`)

### VAL-CLI-023: `service-reachable.sh` invokes `kubectl run` with valid flags only
Running an `service-reachable` assertion exits with a sensible status (not a kubectl usage error). Concretely: `service-reachable.sh` does NOT pass `--timeout=<duration>` to `kubectl run` (the correct flag for in-pod runtime cap is `--pod-running-timeout`; `--timeout` is not a `kubectl run` flag). Pass requires: the `kubectl ... run` line in `service-reachable.sh` uses ONLY documented `kubectl run` flags, verifiable by running `kubectl run --help | grep -E '^      --'` and confirming each flag used by the script appears in the help output.
Tool: bash
Evidence: terminal-output (`grep -E 'kubectl .* run' engine/asserts/service-reachable.sh` extracts the args; cross-check against `kubectl run --help`), bash-test (`bash engine/asserts/service-reachable.sh <synthetic-scenario> 0` exits 0 when the service is reachable, NOT 1 due to `error: unknown flag: --timeout`)

### VAL-CLI-024: `list integrations` enumerates all six expected category subdirectories
Running `chart-test-swarm list integrations` against a populated production integrations tree (post-F1.3 reorg) emits at least one line per the six expected categories: `certificates`, `ingress-controllers`, `gateway-api`, `service-mesh`, `policy`, `cloud-native`. The output is sorted deterministically, and no spurious top-level categories (e.g. legacy unmoved primers) appear. Pass requires: all six categories present in the output AND no top-level categories outside the expected set.
Tool: bash
Evidence: terminal-output (`chart-test-swarm list integrations | awk '{print $1}' | sort -u` produces the exact set `{certificates, ingress-controllers, gateway-api, service-mesh, policy, cloud-native}`)

---

## Area: LLM Generator
## Area: LLM Generator

### VAL-LLM-001: `generate --help` exits 0 and lists pick / author / explore
`chart-test-swarm generate --help` exits 0 and the output advertises all three sub-modes: `pick`, `author`, `explore`.
Tool: bash
Evidence: exit-code 0; terminal-output passes `grep -E '^\s*(pick|author|explore)\b'` for all three names.

### VAL-LLM-002: `generate pick` is non-interactive when fed selections via flags or stdin
`chart-test-swarm generate pick --category certificates --integration cert-manager --variant self-signed --non-interactive` (or, equivalently, the same selections fed via a JSON/YAML file on stdin) completes without prompting and exits 0; running `pick` without any selection flags in a non-TTY context exits non-zero with a clear "no selection provided" message rather than hanging.
Tool: pytest
Evidence: pytest test invokes the CLI with `stdin=subprocess.DEVNULL` and explicit flags; exit-code 0 and stdout is a YAML document; a second test with no flags and `stdin=DEVNULL` returns exit-code != 0 within 5 seconds (no hang).

### VAL-LLM-003: `generate pick` emits a scenario YAML matching the schema
The YAML printed by `generate pick` (to stdout when `--output` is omitted, to the file otherwise) validates against `engine/templates/scenario.schema.json`.
Tool: jsonschema
Evidence: terminal-output of `chart-test-swarm generate pick --category certificates --integration cert-manager --variant self-signed | jsonschema -i /dev/stdin engine/templates/scenario.schema.json` exits 0 with empty output.

### VAL-LLM-004: `generate pick --output <file>` writes to file instead of stdout
With `--output /tmp/pick.yaml`, the file is created with the scenario YAML and stdout contains only a confirmation/path line (no YAML body).
Tool: bash
Evidence: file(/tmp/pick.yaml) exists with size > 0 and passes `yq '.cluster.provider'` returning a non-null value; stdout from the command does not contain `apiVersion` or `cluster:` (verified via `grep -v`).

### VAL-LLM-005: `generate author` invokes CTS_LLM_CMD subprocess (no direct API calls)
With `CTS_LLM_CMD=/tmp/fake-llm.sh` set to a script that echoes a canned scenario YAML and exits 0, `chart-test-swarm generate author "istio with strict-mtls + cert-manager + JWT"` produces exactly that canned YAML on stdout; the chart-test-swarm process makes zero outbound network calls (verified via `lsof`/`strace` or via the process tree containing only the fake child).
Tool: pytest
Evidence: pytest test sets `CTS_LLM_CMD` to a fixture script that writes a known sentinel; CLI stdout contains the sentinel verbatim; the fake script's invocation log records receiving the user description on stdin or as argv.

### VAL-LLM-006: `generate author` output passes jsonschema validation
The YAML emitted by `generate author` (with CTS_LLM_CMD set to a fake that emits a schema-valid template) validates against `engine/templates/scenario.schema.json`.
Tool: jsonschema
Evidence: `chart-test-swarm generate author "<desc>" | jsonschema -i /dev/stdin engine/templates/scenario.schema.json` exits 0 with empty output.

### VAL-LLM-007: `generate author` retries on invalid LLM output up to a bounded max
With `CTS_LLM_CMD` pointing at a fake that emits invalid YAML on the first 2 calls and a valid scenario on the 3rd, `chart-test-swarm generate author "<desc>" --max-retries 3` exits 0 and the fake's call counter shows exactly 3 invocations.
Tool: pytest
Evidence: pytest fixture uses a stateful shell stub backed by a counter file; after CLI exit-code 0, the counter file contains `3`; with `--max-retries 1`, the same fake causes CLI exit-code != 0 with stderr containing `invalid` or `schema`.

### VAL-LLM-008: `generate author` rejects empty/whitespace descriptions
`chart-test-swarm generate author ""` and `chart-test-swarm generate author "   "` exit non-zero before invoking the LLM, with stderr explaining that a non-empty description is required.
Tool: pytest
Evidence: exit-code != 0 for both inputs; CTS_LLM_CMD stub records zero invocations; stderr contains `description` and `empty` or `required`.

### VAL-LLM-009: `generate explore --max-iterations N` is upper-bounded by N
With CTS_LLM_CMD set to a fake that always proposes a new combo and a dispatch stub that always returns PASS, `chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager,nginx-ingress --max-iterations 3` performs exactly 3 propose→run iterations, no more.
Tool: pytest
Evidence: iteration counter file written by the fake equals 3 after CLI exit-code 0; the captured dispatch-swarm.sh argv log shows exactly 3 scenario runs.

### VAL-LLM-010: `generate explore --budget` halts when budget exhausted
`chart-test-swarm generate explore --chart <path> --integrations <list> --max-iterations 10 --budget 2` stops after exactly 2 iterations (or whichever cost unit the budget tracks first) even though max-iterations is 10, and exits 0 with a "budget exhausted" log line.
Tool: pytest
Evidence: dispatch stub argv log shows exactly 2 runs; stdout/stderr contains the literal `budget exhausted` (or equivalent); iteration counter file equals 2.

### VAL-LLM-011: `generate explore` writes a summary report listing combos and outcomes
After exploration, `chart-test-swarm generate explore --output /tmp/explore-summary.json` writes a JSON file containing an array of `{iteration, scenario_yaml, run_id, status, integrations}` records, one per iteration.
Tool: jq
Evidence: terminal-output `jq 'length' /tmp/explore-summary.json` equals the number of iterations executed; `jq '.[0] | keys' /tmp/explore-summary.json` includes `iteration`, `run_id`, `status`.

### VAL-LLM-012: All three modes are deterministic under a canned CTS_LLM_CMD
With `CTS_LLM_CMD=/tmp/fake-llm.sh` emitting fixed output, running each of `generate pick`, `generate author "<desc>"`, and `generate explore --max-iterations 1 --integrations cert-manager` twice produces byte-identical scenario YAML (except timestamps explicitly excluded via `--no-timestamps` or `sed`-stripped).
Tool: bash
Evidence: `diff <(... first run) <(... second run)` exits 0 for all three modes after stripping documented timestamp lines; exit-code 0 from each invocation.

### VAL-LLM-013: Missing host LLM binary surfaces a clear actionable error
With `CTS_LLM_CMD` unset AND no `droid` (or other configured default) binary discoverable on `PATH`, `chart-test-swarm generate author "<desc>"` exits non-zero with stderr explaining how to set `CTS_LLM_CMD` and which binaries were searched.
Tool: pytest
Evidence: pytest test invokes the CLI with `PATH=/usr/bin:/bin` (no droid) and `CTS_LLM_CMD` removed from env; exit-code != 0; stderr contains both `CTS_LLM_CMD` and `droid` (or the configured default name).

### VAL-LLM-014: Auto-discovery of droid uses PATH when CTS_LLM_CMD is unset
When `CTS_LLM_CMD` is unset but a `droid` shim exists on PATH, `generate author "<desc>"` invokes that shim (not any vendored binary) and passes the description through unchanged.
Tool: pytest
Evidence: pytest places a `droid` script under a tmpdir on PATH; the shim logs its argv/stdin; after CLI exit-code 0, the log shows the description string verbatim and exactly one invocation.

### VAL-LLM-015: No API keys, tokens, or LLM credentials are stored in the repo
A grep across `engine/` and `examples/` for common credential patterns finds zero matches; the CLI source code contains no `os.environ.get('OPENAI_API_KEY')` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` lookups.
Tool: bash
Evidence: exit-code 1 (no matches) from `rg -n 'sk-[A-Za-z0-9]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY' engine/ examples/`; exit-code 1 from `rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' engine/testgrid/src`.

### VAL-LLM-016: `generate explore` feeds prior result back into next LLM prompt
On iteration N>1, the CTS_LLM_CMD stub receives stdin (or a prompt argument) that includes the result.yaml summary from iteration N-1 (PASS/FAIL counts and the prior scenario id).
Tool: pytest
Evidence: pytest stub records each invocation's stdin to a file; for iteration 2, the recorded stdin contains the iteration-1 scenario id and the literal string `PASS` or `FAIL`; for iteration 1, the recorded stdin contains no prior-run reference.

### VAL-LLM-017: All generate modes accept `--output` for file-based capture
`generate pick`, `generate author`, and `generate explore` each accept `--output <path>`; when provided, stdout contains only a one-line confirmation (path + scenario id / summary), and the file is written with the full payload.
Tool: bash
Evidence: for each mode, `chart-test-swarm generate <mode> ... --output /tmp/out.yaml` exits 0; file(/tmp/out.yaml) exists with size > 0; `wc -l < <(stdout)` ≤ 2.

### VAL-LLM-018: Schema-failing LLM output is reported with a diagnosable error
When CTS_LLM_CMD emits YAML that is parseable but fails `engine/templates/scenario.schema.json` validation AND retries are exhausted, the CLI exits non-zero and stderr names at least one failing schema path (e.g., `cluster.provider: not one of enum` or `id: does not match pattern`).
Tool: pytest
Evidence: pytest stub emits YAML with `cluster.provider: bogus-backend` (not in the enum); after `--max-retries 1`, exit-code != 0; stderr contains both `cluster.provider` and `enum` (or the offending value).

### VAL-LLM-019: Generated scenarios refuse to overwrite an existing file without --force
Running `chart-test-swarm generate pick --output /tmp/exists.yaml` when `/tmp/exists.yaml` already exists with non-empty content exits non-zero, leaves the existing file's content byte-identical, and stderr contains the path + a phrase like "already exists" / "use --force". With `--force`, the same command exits 0 and replaces the content. The same protection applies to `generate author --output` and `generate explore --output`. Pass requires: refuse + actionable message + preservation; --force succeeds + replaces.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`sha256sum /tmp/exists.yaml`) before/after

### VAL-LLM-020: `generate explore` writes its summary incrementally so a crash leaves a partial summary
With `CTS_LLM_CMD` set to a fake that succeeds for iteration 1 and then crashes (`exit 137`) on iteration 2, running `chart-test-swarm generate explore --max-iterations 3 --output /tmp/explore.json` exits non-zero and `/tmp/explore.json` exists with exactly one record (the iteration-1 result). The file is valid JSON parseable by `jq`. Pass requires: non-zero CLI exit, single-record JSON, valid JSON shape.
Tool: bash
Evidence: exit-code, file(/tmp/explore.json), command-output(`jq 'length' /tmp/explore.json` == 1)

### VAL-LLM-021: Generated scenarios carry `generated_by` provenance and the LLM cmd used
Every scenario produced by `generate pick`, `generate author`, or `generate explore` includes a top-level `generated_by` mapping with: `by` (always present, value is one of `pick|author|explore`), `cmd` (the resolved `CTS_LLM_CMD` for author/explore; absent or `null` for pick), and `timestamp` (ISO-8601 UTC). The scenario otherwise validates against the schema (i.e., `generated_by` is either schema-allowed or in a documented `additionalProperties: true` extension namespace). Pass requires all three keys present + schema-valid result.
Tool: yq
Evidence: command-output(`yq '.generated_by.by, .generated_by.cmd, .generated_by.timestamp' <generated.yaml>`) — three non-null values for author/explore; non-null `by` + `timestamp` for pick

### VAL-LLM-022: `generate explore` rejects mid-iteration scenarios that fail prefix/schema validation before any cluster spin-up
With `CTS_LLM_CMD` set to a stub that on iteration 1 proposes a schema-valid scenario (PASS), and on iteration 2 proposes a scenario with `cluster.name: escaped-cluster` (no `chart-test-swarm-` prefix), running `chart-test-swarm generate explore --chart <path> --integrations <list> --max-iterations 3` results in: (a) iteration 1 runs to completion creating a single `chart-test-swarm-*` kind cluster (verifiable via `kind get clusters` mid-iteration), (b) iteration 2 fails validation BEFORE any cluster work is attempted (verifiable: no `kind create cluster` / `minikube start` invocation recorded by the PATH stub for iteration 2), (c) the iteration-2 entry in the explore summary records the rejection with the offending name + the schema error message (NOT a generic `LLM_ERROR`), (d) the CLI continues to iteration 3 or exits cleanly with a non-zero status naming the violation. Pass requires: no `escaped-cluster` cluster ever appears in `kind get clusters` or `minikube profile list`, iteration-1 cluster IS torn down, summary records the rejection reason.
Tool: pytest
Evidence: exit-code, file(reports/explore-*/summary.json) — iteration 2 entry contains `error: cluster.name pattern violation` (or equivalent), command-output (`kind get clusters | grep escaped-cluster` returns empty), command-output (PATH stub log shows zero `kind create cluster` invocations correlated with iteration 2)

---

## Cross-Area Flows
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
