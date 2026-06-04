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

### VAL-ENGINE-040: `KEEP_CLUSTER=1` default behavior is observable, not just commented
After `bash engine/scripts/run-scenario.sh <scenario.yaml>` completes (PASS or FAIL), with `KEEP_CLUSTER` UNSET, the cluster created by the run is STILL present in `kind get clusters | grep chart-test-swarm-` (or `minikube profile list -o json`). Conversely, with `KEEP_CLUSTER=0` explicitly set, the cluster IS torn down (absent post-run). Pass requires both branches.
Tool: bash
Evidence: bash-test (run scenario with unset env, assert cluster present; rerun with `KEEP_CLUSTER=0`, assert cluster absent)

### VAL-ENGINE-041: Inline `product.set` style is preserved on the 5 pre-mission scenarios
After the full mission run completes, the five scenarios that used inline `product.set: { ... }` style at mission start (e.g. `examples/sample-product-chart/chart-test/scenarios/customer-A-istio.yaml`, `with-cert-manager.yaml`, `customer-B-gatekeeper.yaml`, `subchart-postgres-internal.yaml`, `minimal.yaml`) still parse as inline `product.set` objects (NOT migrated to a `values:` file reference) unless a documented F-ID explicitly converted them. `yq '.product.set | type'` on each of those original files returns `!!map` and `yq '.product.values' < file` returns null (or absent), preserving the original authoring style.
Tool: yq
Evidence: terminal-output (`for f in customer-A-istio.yaml with-cert-manager.yaml customer-B-gatekeeper.yaml subchart-postgres-internal.yaml minimal.yaml; do yq '.product.set | type' examples/sample-product-chart/chart-test/scenarios/$f; done` outputs `!!map` five times), terminal-output (`yq '.product.values' examples/sample-product-chart/chart-test/scenarios/{customer-A-istio,with-cert-manager,customer-B-gatekeeper,subchart-postgres-internal,minimal}.yaml` returns `null` for each)
