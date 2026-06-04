# Review Pass 1B — Codebase-Driven Gaps

## Summary

Where Review Pass 1A surfaced **user-flow** gaps (what a developer does), this pass digs into the **code as it stands today** and surfaces gaps that the 223-assertion contract does not currently catch — latent bugs, hidden invariants, integration-boundary brittleness, and refactor-regression hazards. Every assertion below is anchored in a specific file and line range that is observably mis-behaving, fragile, or untested.

Concretely, the codebase exposes:

- `cluster-up.sh`, `cluster-down.sh`, `run-scenario.sh` default `CLUSTER_NAME` to the literal `chart-test-swarm` (no trailing dash) — they would fail the `chart-test-swarm-*` prefix invariant if invoked without the env override. The contract asserts the prefix is *required* but never asserts the default *satisfies* the prefix.
- `dispatch-swarm.sh` writes a `scenarios-snapshot.yaml` that **drops `product` and `asserts`** (lines 100–114), making the snapshot non-self-contained — architecture §8 hot-spot #4 — but the contract has no assertion forcing the snapshot to carry these fields.
- `apply-scenario.sh` calls `helm repo add` without `--force-update` (line 60) and uses `trap 'rm -f "$tmp"' EXIT` *inside* a `for` loop (line 79), leaking earlier inline-values tempfiles.
- `dispatch-swarm.sh` line 166 pipes scenario-derived markdown through `envsubst`, which re-expands `$VAR` and `${VAR}` tokens that appear inside scenario `name` / `description` fields.
- `aggregate.sh` uses `awk -F,` and `IFS=,` on a CSV that embeds free-form `notes` (lines 100, 112, 122) — any comma inside `notes` mis-splits the row.
- `cluster-up.sh` line 46 (and equivalent in the k3d branch) calls `kubectl config use-context "$CONTEXT"`, mutating the user's global kubeconfig active context — a side-effect that escapes the test run.
- `engine/testgrid/src/testgrid/render.py` `STATUS_RANK` orders `UNTESTED` (rank 3) as *better* than `INCONCLUSIVE` (rank 2), so a mechanism-rollup that mixes the two surfaces `INCONCLUSIVE` instead of bubbling `UNTESTED`. `collect.py` lines 144–145 also accept any string as `status` and silently emit `status-unknown` CSS class downstream.
- `service-reachable.sh` line 25 passes `--timeout="$TIMEOUT"` to `kubectl run`, which is **not a valid kubectl flag** (correct flag is `--pod-running-timeout`).
- `dispatch-swarm.sh` lines 42 and `aggregate.sh` line 37 use `mapfile`, which is bash ≥ 4 — macOS ships bash 3.2. Preflight does not check the bash version.
- `run-scenario.sh` doc-comment (line 7) claims `KEEP_CLUSTER=1` is the default, but the script never calls `cluster-down.sh` in any code path — there is no teardown to skip. The contract should pin that "default = no teardown" is an observable behavior, not just a comment.
- `engine/skills/chart-test-swarm/SKILL.md` (lines 10–12, 58–62, 73, 107) and `references/workflow.md` (lines 10–13, 37, 220) hardcode the FLAT path `references/integrations/<x>.md`. The F1.3 reorg into `<category>/<integration>.md` subdirs will break the skill's own documentation; only the primer-files-exist case is asserted.

This pass proposes **18 new assertions** plus **2 modifications to existing assertions** to close these gaps. IDs continue from where Review Pass 1A left off.

---

## Proposed New Assertions

### VAL-ENGINE-030: Engine script CLUSTER_NAME defaults satisfy the `chart-test-swarm-` prefix invariant
Each engine script that defaults `CLUSTER_NAME` (`cluster-up.sh` line 6, `cluster-down.sh` line 5, `run-scenario.sh` line 100) yields a default that matches the regex `^chart-test-swarm-[a-z0-9-]+$` (i.e., literally has a non-empty suffix after the `chart-test-swarm-` prefix). Pass requires: invoking each script with the env var unset and `--print-cluster-name` (or via grepping `set -x` output) produces a name that satisfies the prefix invariant asserted elsewhere in VAL-ENGINE-002 / VAL-ENGINE-022. The literal default `chart-test-swarm` (no suffix) MUST NOT appear; if a deterministic suffix (`-default`, `-local`, `-$USER`, etc.) is chosen, the choice is documented in the script header comment.
Tool: bash
Evidence: terminal-output (`bash -x engine/scripts/cluster-up.sh --dry-run 2>&1 | grep CLUSTER_NAME=` shows `chart-test-swarm-` followed by ≥ 1 char), grep-match in source (`rg 'CLUSTER_NAME:-chart-test-swarm[a-z0-9-]+' engine/scripts/`)
Rationale: Codebase reality — every script today sets `CLUSTER_NAME="${CLUSTER_NAME:-chart-test-swarm}"`, which the prefix invariant rejects. Without this assertion, a CI job invoking `bash engine/scripts/cluster-up.sh` (no env var) would silently violate the invariant that VAL-ENGINE-022 codifies — the prefix check would never see the default code path.

### VAL-ENGINE-031: `scenarios-snapshot.yaml` carries `product` and `asserts` per scenario (no metadata-only snapshots)
After `bash engine/scripts/dispatch-swarm.sh <project-dir> <suite> <n>` runs, the produced `reports/run-<id>/scenarios-snapshot.yaml` contains, for every entry in `.scenarios[]`, a non-null `product.chart`, `product.release`, `product.namespace`, AND a non-empty `asserts[]` array whose items match the original scenario YAML byte-for-byte (after YAML normalization). Pass requires: for each matched scenario file, the snapshot's projection includes all five keys (`id`, `cluster`, `product`, `asserts`, plus `mechanisms`/`tags`/`labels`/`name`/`description`).
Tool: yq
Evidence: command-output (`yq '.scenarios[] | {id, has_product: (.product != null), has_asserts: ((.asserts // []) | length > 0)}' reports/run-*/scenarios-snapshot.yaml` — every record shows `has_product: true` and `has_asserts: true`)
Rationale: Architecture §8 risk hot-spot #4 explicitly names "`dispatch-swarm.sh` drops `product` + `asserts` fields from the snapshot." `dispatch-swarm.sh` lines 100–114 today produce a snapshot YAML with only `id, name, description, labels, cluster, tags, mechanisms` — `product` and `asserts` are NOT projected. The aggregator and re-runner cannot reproduce a scenario from snapshot alone. The contract names artifact reproducibility as a core invariant but never asserts the snapshot satisfies it.

### VAL-ENGINE-032: `apply-scenario.sh` is idempotent over `helm repo add` for repeated runs of the same scenario
Running `bash engine/scripts/apply-scenario.sh <scenario.yaml>` twice in succession against a scenario whose `cluster.preinstall[].repo.name` matches an existing helm repo (e.g., two runs of `examples/sample-product-chart/chart-test/scenarios/with-cert-manager.yaml`) both exit 0. The second invocation does NOT emit a helm warning like `repo "jetstack" already exists with the same configuration, skipping` AS AN ERROR (informational is fine); on URL mismatch with an existing repo, the script exits non-zero with a stderr line naming the repo name and both URLs.
Tool: bash
Evidence: exit-code (both runs 0), terminal-output (second-run stderr does not contain `Error:`), terminal-output (URL-mismatch case produces named error)
Rationale: `apply-scenario.sh` line 60: `helm repo add "$repo_name" "$repo_url" >/dev/null` lacks `--force-update`. On second invocation, helm logs `"repo X already exists"` — fine if URLs match, but if the URL differs from a prior `add`, helm exits non-zero and the scenario fails for an environmental reason orthogonal to the chart under test. Without this assertion, suite re-runs in a long-lived CI environment become flaky.

### VAL-ENGINE-033: `apply-scenario.sh` cleans up every inline-values tempfile, not just the loop's last one
For a scenario whose `cluster.preinstall` has ≥ 2 items where each item provides an inline `values:` object (not a path string), after `apply-scenario.sh` completes (PASS or FAIL), `ls /tmp/tmp.*` shows NO leftover tempfiles created by the script's `mktemp` calls (line 79). Even if the script is killed with SIGTERM during the second item, the first item's tempfile is also cleaned up.
Tool: bash
Evidence: bash-test (record `ls /tmp/tmp.* | wc -l` before, run the scenario, then re-list and `diff`), command-output (`pgrep -f apply-scenario.sh && kill -TERM <pid>` mid-run, then `find /tmp -maxdepth 1 -name 'tmp.*' -newer /tmp/marker -not -path "$HOME/.cache/*"` returns empty)
Rationale: `apply-scenario.sh` line 79: `tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT` is placed INSIDE the `for i in $(seq 0 $((count - 1)))` loop. Each iteration overwrites the prior trap binding, so only the LAST iteration's tempfile is removed at EXIT. On multi-preinstall scenarios with inline values (e.g., the `with-cert-manager.yaml` style), N-1 tempfiles leak into `/tmp` per run.

### VAL-ENGINE-034: `aggregate.sh` correctly handles assertion `notes` containing commas, newlines, and quotes
A scenario whose `result.yaml` includes an assertion with `notes: "FAIL: pod x, container y; got HTTP 500\nresponse body: \"not ok\""` (embedded comma, newline, and quote) feeds into `aggregate.sh` and produces a `scenario-matrix.csv` that, when parsed by `python -c 'import csv; print(list(csv.reader(open("scenario-matrix.csv"))))'`, recovers the original `notes` string intact (modulo CRLF normalization). Pass requires that comma, newline, and quote round-trip through the aggregator's CSV writer.
Tool: bash
Evidence: bash-test (synthesize `result.yaml` with the pathological notes string, run `aggregate.sh`, then `python -c 'import csv; ...'` confirms exact round-trip)
Rationale: `aggregate.sh` line 100 emits via `jq @csv` (which DOES quote and escape), BUT line 112 reads back with `while IFS=, read -r sid status _` and line 122/132 parse with `awk -F,`. Both line 112 and the awk extractors split on `,` without respecting CSV quoting, so any `notes` field containing a comma corrupts every downstream column. The dashboard ingests the YAML directly so it sidesteps this, but `lessons-learned.md` (the artifact a human reads) is built FROM the parsed CSV.

### VAL-ENGINE-035: F1.3 primer reorg updates SKILL.md, workflow.md, and CLI list-integrations to use the new subdir paths
After F1.3 moves integration primers into category subdirs (`certificates/`, `ingress-controllers/`, `service-mesh/`, `gateway-api/`, `policy/`, `cloud-native/`), the following text references update accordingly: `engine/skills/chart-test-swarm/SKILL.md` lines 10–12 ("dropping a primer in references/integrations/"), line 58 ("whatever has a primer in `references/integrations/`"), line 73 ("`references/integrations/<x>.md`"), line 107 ("`references/integrations/*.md`"); `engine/skills/chart-test-swarm/references/workflow.md` line 11 ("under `references/integrations/`"), line 37 ("Read `references/integrations/<integration>.md`"), line 220 ("`references/integrations/<name>.md` primer"). Pass requires: every textual reference resolves to an existing file on disk OR points to the directory convention (`references/integrations/<category>/<integration>.md`).
Tool: bash
Evidence: terminal-output (`rg -n 'references/integrations/[a-z-]+\.md' engine/skills/chart-test-swarm/{SKILL.md,references/workflow.md}` — every match resolves with `test -f`), terminal-output (`rg -n 'references/integrations/' engine/skills/chart-test-swarm/` — no FLAT references remain after reorg)
Rationale: VAL-ENGINE-011 and VAL-ENGINE-012 cover the *files* existing in the new layout. Nothing currently asserts that the SKILL's own textual links update with the move. A skill that documents the wrong primer path will mislead the LLM that drives it.

### VAL-ENGINE-036: `run-meta.yaml` reflects the actual mix of providers/k8s_versions across all scenarios in the run, not just the first
For a multi-scenario run where scenarios have heterogeneous `cluster.provider` and `cluster.k8s_version` (e.g., one `kind v1.30` + one `minikube v1.29`), the produced `reports/run-<id>/run-meta.yaml` shows EITHER (a) `cluster_provider` and `k8s_version` as YAML lists reflecting the set actually used, OR (b) the dispatcher refuses the run with a clear error naming "mixed-provider suites are not yet supported." Pass requires that the meta file does NOT misleadingly report the FIRST scenario's provider as if it applied to all scenarios.
Tool: yq
Evidence: command-output (`yq '.cluster_provider, .k8s_version' reports/run-*/run-meta.yaml`) — output is a list OR matches the homogeneous case
Rationale: `dispatch-swarm.sh` lines 89–90 generate the meta with `cluster_provider: $(yq '.cluster.provider // "kind"' "${MATCHED[0]}")` — hardcoded to the FIRST matched file. A nightly suite with both a `kind` scenario and a `minikube` scenario will silently report only `kind` in the dashboard. The dashboard's "Cluster" column then lies for half the scenarios.

### VAL-ENGINE-037: `dispatch-swarm.sh` agent-brief substitution does NOT re-expand `$VAR` or `${VAR}` inside scenario name/description fields
A scenario whose `name` field contains the literal string `"Cluster $PATH check"` and whose `description` contains `${HOME}` is dispatched, and the produced `reports/run-<id>/agent-N/brief.md` retains those literal substrings VERBATIM — no shell expansion happens. Pass requires that the brief preserves `$PATH` and `${HOME}` as plain text.
Tool: bash
Evidence: bash-test (write scenario with literal `$VAR` in name/desc, run dispatch-swarm, then `grep -F 'Cluster $PATH check' reports/run-*/agent-*/brief.md` exits 0)
Rationale: `dispatch-swarm.sh` line 166: `envsubst < "$TEMPLATE" > "$brief"`. `envsubst` performs shell-style variable substitution on its INPUT, which today is constructed by interpolating scenario fields (`assigned_md` includes `$sid`, `$snam`, `$sdesc`) into the template's `${ASSIGNED_SCENARIOS}` slot. If a scenario name happens to contain a literal `$VAR` token, envsubst will substitute it (typically to empty string), corrupting the brief. The substitution is a hidden injection vector.

### VAL-ENGINE-038: `cluster-up.sh` does not mutate the user's global active kubeconfig context
Running `bash engine/scripts/cluster-up.sh` with a non-empty `kubectl config current-context` (e.g., `prod-eks`) does NOT change `kubectl config current-context` from the caller's perspective after the script returns. Pass requires: `before=$(kubectl config current-context)`, run cluster-up, `after=$(kubectl config current-context)`, then `before == after`. The created cluster's context is selectable via `--context $CONTEXT` flag but is NOT made the global default.
Tool: bash
Evidence: terminal-output (`kubectl config current-context` before and after; assert equality)
Rationale: `cluster-up.sh` line 46 (kind branch) / line 56 (k3d branch): `kubectl config use-context "$CONTEXT" >/dev/null`. This GLOBALLY sets the user's active context. A developer running cluster-up against their checkout from a terminal where they were just hitting prod-eks now suddenly has every subsequent `kubectl` command targeting the test cluster, until they `use-context prod-eks` back. This is a silent destructive side effect that the contract should disallow.

### VAL-ENGINE-039: Engine scripts run cleanly under bash 3.2 (macOS default) or fail preflight with a clear bash-version error
Either: (a) every engine script that uses bash-4-only features (`mapfile` in `dispatch-swarm.sh` line 42, `aggregate.sh` line 37; associative arrays in `aggregate.sh` line 121) is rewritten with bash-3.2-compatible idioms, OR (b) `engine/scripts/verify.sh` (the preflight) and every entry-point script's prologue checks `BASH_VERSINFO[0] -ge 4` and exits non-zero with a clear stderr message naming the required version + how to upgrade (e.g., `brew install bash`). Pass requires: on a system with `bash --version` reporting 3.2, either the scripts succeed OR they fail at preflight with the version-named message — but NEVER with the cryptic `mapfile: command not found`.
Tool: bash
Evidence: bash-test (`/bin/bash --version` on macOS reports 3.2; `bash engine/scripts/verify.sh` exits non-zero with stderr containing both "bash" and "3.2" or "4" or "version", AND no `mapfile: command not found` text appears)
Rationale: `dispatch-swarm.sh:42`, `aggregate.sh:37` use `mapfile -t`; `aggregate.sh:121` uses `declare -A COUNTS`. Both are bash 4+ features. macOS ships bash 3.2 by default. CI runs on Linux (bash 5) so this is silent, but a developer on macOS gets `mapfile: command not found` deep in the run — no clue what to fix.

### VAL-ENGINE-040: `KEEP_CLUSTER=1` default behavior is observable, not just commented
After `bash engine/scripts/run-scenario.sh <scenario.yaml>` completes (PASS or FAIL), with `KEEP_CLUSTER` UNSET, the cluster created by the run is STILL present in `kind get clusters | grep chart-test-swarm-` (or `minikube profile list -o json`). Conversely, with `KEEP_CLUSTER=0` explicitly set, the cluster IS torn down (absent post-run). Pass requires both branches.
Tool: bash
Evidence: bash-test (run scenario with unset env, assert cluster present; rerun with `KEEP_CLUSTER=0`, assert cluster absent)
Rationale: `run-scenario.sh:7` comment declares `KEEP_CLUSTER=1` as the default behavior, but the script body has NO teardown call in any code path — there is nothing to "skip." The implicit default behavior is "never teardown." If a future refactor adds a teardown without honoring `KEEP_CLUSTER=1`, the comment becomes a lie. The contract should pin the *observable* behavior, not the comment.

### VAL-DASH-022: `STATUS_RANK` ordering ensures `INCONCLUSIVE` never bubbles up as "worse than" `UNTESTED` in mechanism rollups
For a mechanism that has two scenarios — one `INCONCLUSIVE` and one `UNTESTED` — the rendered mechanism rollup row shows `UNTESTED` (NOT `INCONCLUSIVE`), because UNTESTED reflects "we never even tried" which is a worse-confidence outcome than "we tried but couldn't conclude." Equivalently: `STATUS_RANK['UNTESTED'] < STATUS_RANK['INCONCLUSIVE']` in `engine/testgrid/src/testgrid/collect.py` line 25. Pass requires the unit test confirms the ordering AND a synthetic run with the two scenarios renders the mechanism cell as `UNTESTED`.
Tool: pytest
Evidence: pytest-output (`pytest engine/testgrid/tests/test_render.py::test_status_rank_untested_above_inconclusive`), file(reports/dist/<run-id>/index.html — the synthetic rollup cell shows badge text "UNTESTED")
Rationale: `engine/testgrid/src/testgrid/collect.py` lines 25–31 currently rank `FAIL=0, PARTIAL=1, INCONCLUSIVE=2, UNTESTED=3, PASS=4`. `render.py:50` `rollup_status` returns `min(STATUS_RANK)`, so `INCONCLUSIVE` (rank 2) wins over `UNTESTED` (rank 3). This is backwards: UNTESTED means "we have no evidence at all" which is worse than INCONCLUSIVE (we have partial evidence). A user reading the rollup as "INCONCLUSIVE" assumes the test ran, when in fact one scenario was never attempted.

### VAL-DASH-023: `collect.py` rejects (or visibly surfaces) `result.yaml` files whose `status` is not in the known status set
A `result.yaml` with `status: WEIRD_CUSTOM_STATUS` causes either (a) `collect.py` to exit non-zero with a clear stderr line naming the offending status + scenario + file, OR (b) the resulting `Scenario.status` to be normalized to `UNKNOWN` AND the dashboard renders the scenario card with a visible "unknown status" badge (NOT a generic untested-styling fallback). Pass requires the gibberish status is either rejected at collect time or visibly surfaced — silent CSS coercion to `status-unknown` (current behavior) does not satisfy.
Tool: bash
Evidence: bash-test (synthesize result.yaml with bogus status, run `uv run testgrid build`, assert stderr names the status OR dashboard shows "unknown status" text), grep-match in `engine/testgrid/src/testgrid/collect.py` (no longer accepts arbitrary string into `Scenario.status` without validation)
Rationale: `collect.py:144` `_scenario_from_result` does `(doc.get("status") or "UNTESTED").strip()`. Any string passes — `"FOO"`, `"definitely not pass"`, etc. `render.py:STATUS_CSS.get(status, "status-unknown")` then silently styles it as unknown. A typo in an agent script (status: PSS vs PASS) leads to a dashboard row that looks vaguely off but doesn't surface the bug.

### VAL-DASH-024: Dashboard HTML escapes user-controlled fields (`name`, `description`, `notes`, `fail_msg`, `log_dir`) against XSS payloads
A scenario whose `name` is `"<script>alert(1)</script>"` and whose `description` contains `"</details><img src=x onerror=alert(1)>"` is collected and rendered. The resulting `reports/dist/<run-id>/index.html` does NOT contain `<script>alert(1)</script>` as live HTML (i.e., the payload is HTML-escaped to `&lt;script&gt;alert(1)&lt;/script&gt;`), and a headless-browser visit (`agent-browser` open + read DOM) shows the literal text "alert(1)" inside a text node (not executed). Pass requires escape-correctness for every field that originates from user-supplied YAML.
Tool: agent-browser
Evidence: dom-text (visible text contains literal `<script>alert(1)</script>` characters), terminal-output (`rg -F '<script>alert(1)</script>' reports/dist/<run-id>/index.html` returns no live-script match)
Rationale: `render.py:62` `select_autoescape(["html"])` does enable Jinja2 autoescape, but no test asserts the autoescape covers every user-supplied field. Templates also embed user data into href/anchor (`href="#{{ s.id }}"`) and CSS-class contexts (`class="{{ status_class(s.status) }}"`) — autoescape protects most of these, but the contract should pin XSS-safety by direct test. A scenario authored from the LLM path could carry hostile content if not validated.

### VAL-CLI-022: Every CLI flag has a documented engine-script env-var mapping
The CLI's `--backend`, `--cluster-name`, `--parallelism`, `--run-id`, `--reports-dir`, `--project-dir`, `--scenario`, `--suite` flags each map to exactly one engine-script env var. The mapping table lives in `engine/cli/src/chart_test_swarm/forward.py` (or equivalent) as a literal dict, AND `chart-test-swarm run --scenario ... -x` (or via `CTS_DEBUG=1 bash -x`) produces output showing the env var was set with the CLI-supplied value. Concretely: `--backend minikube` ⇒ `PROVIDER=minikube`, `--parallelism N` ⇒ `NUM_AGENTS=N`, `--cluster-name foo` ⇒ `CLUSTER_NAME=foo`, `--run-id X` ⇒ `RUN_ID=X`, `--reports-dir D` ⇒ `REPORTS_DIR=D`, `--project-dir P` ⇒ `PROJECT_DIR=P`, `--suite S` ⇒ `SUITE=S`. Pass requires the mapping table is asserted + observed.
Tool: bash
Evidence: terminal-output (`CTS_DEBUG=1 chart-test-swarm run --backend minikube --parallelism 2 --cluster-name ct-x ...` shows `PROVIDER=minikube`, `NUM_AGENTS=2`, `CLUSTER_NAME=ct-x` in the trace), grep-match (`rg -n 'FLAG_TO_ENV' engine/cli/src/`)
Rationale: The engine scripts read positional + env args (`cluster-up.sh:6` reads `$CLUSTER_NAME`, `dispatch-swarm.sh:12` reads positional or env). The CLI wraps them via flags. A flag→env mapping drift (e.g., CLI calls it `--backend` but sets `BACKEND=...` not `PROVIDER=...`) is silently broken — `cluster-up.sh` line 9 PROVIDER lookup gets empty, falls back to the default `kind`, and the scenario runs on the wrong backend. The contract has no end-to-end assertion that the CLI flag chosen by the user actually changed the engine's behavior.

### VAL-CLI-023: `service-reachable.sh` invokes `kubectl run` with valid flags only
Running an `service-reachable` assertion exits with a sensible status (not a kubectl usage error). Concretely: `service-reachable.sh` does NOT pass `--timeout=<duration>` to `kubectl run` (the correct flag for in-pod runtime cap is `--pod-running-timeout`; `--timeout` is not a `kubectl run` flag). Pass requires: the `kubectl ... run` line in `service-reachable.sh` uses ONLY documented `kubectl run` flags, verifiable by running `kubectl run --help | grep -E '^      --'` and confirming each flag used by the script appears in the help output.
Tool: bash
Evidence: terminal-output (`grep -E 'kubectl .* run' engine/asserts/service-reachable.sh` extracts the args; cross-check against `kubectl run --help`), bash-test (`bash engine/asserts/service-reachable.sh <synthetic-scenario> 0` exits 0 when the service is reachable, NOT 1 due to `error: unknown flag: --timeout`)
Rationale: `engine/asserts/service-reachable.sh:25` passes `--timeout="$TIMEOUT"` to `kubectl run`. The flag does not exist; `kubectl run --help` lists `--pod-running-timeout` instead. On modern kubectl (1.27+), this errors out before the curl even runs. The contract asserts the service-reachable HTTP outcome but never that the kubectl invocation itself is syntactically valid.

### VAL-CROSS-028: `RUN_ID` collisions across concurrent dispatches are detected, not silently overwritten
Two `dispatch-swarm.sh` (or CLI-equivalent) invocations against the same `reports/` directory in the same second either: (a) both produce distinct `run-<id>` subdirs because the `RUN_ID` format includes a uniqueness suffix (e.g., `run-20260520-101500-$$` or `run-20260520-101500-<hash>`), OR (b) the second invocation detects the existing `reports/run-<existing-id>/` and refuses with a stderr line naming the existing run + a suggestion (`--run-id <override>` or wait a second). Pass requires that running two dispatches concurrently NEVER results in only ONE `run-*` directory holding interleaved artifacts from both invocations.
Tool: bash
Evidence: bash-test (launch two `dispatch-swarm.sh` in background within the same second, wait for both, assert `ls reports/run-* -d | wc -l` reports the expected count and that no single dir contains contradictory `agent-*/result.yaml` from both invocations)
Rationale: `dispatch-swarm.sh:13` defaults `RUN_ID="run-$(date +%Y%m%d-%H%M%S)"` (second resolution). Two concurrent dispatches in the same second collide on the directory name. The script does `mkdir -p "$RUN_DIR"` (line 71), which silently succeeds even if the dir already exists, and then both invocations write briefs over each other. This is silent data loss exactly when two engineers race a CI re-trigger. VAL-CROSS-026 (Pass 1A) covers concurrent CLI invocations but does not pin the second-resolution timestamp specifically.

### VAL-CROSS-029: `helm --set` overrides with backslash-escaped dots or special characters survive scenario → engine round-trip
For a scenario with `product.set: { "podAnnotations.sidecar\\.istio\\.io/inject": "true" }` (i.e., the existing `customer-A-istio.yaml` fixture), `run-scenario.sh` produces an `applied-overrides.yaml` (or, equivalently, `helm get values <release> -n <ns>`) in which `podAnnotations` contains a key `sidecar.istio.io/inject: "true"` (literal dot preserved, NOT split into a nested map). Pass requires the round-trip preserves the escaped key.
Tool: bash
Evidence: bash-test (run the `customer-A-istio` scenario, then `helm get values sample -n sample -o yaml | yq '.podAnnotations'` produces a key with literal `.` characters), file(reports/run-*/scenario-customer-A-istio-*/artifacts/applied-overrides.yaml)
Rationale: `run-scenario.sh:130–135` extracts `set:` values via `yq -o=tsv` then passes them as `--set "$k=$v"`. The escape semantics of helm `--set` (which treats `.` as separator and requires `\\.` to escape) interact with bash quoting and yq's TSV output in non-obvious ways. The existing `customer-A-istio.yaml` exercises this — the contract has no assertion that the escape works end-to-end. A regression here silently corrupts annotation overrides.

---

## Proposed Modifications to Existing Assertions

### Modification 1: Strengthen VAL-ENGINE-002 (cluster prefix invariant)
The current assertion (paraphrasing the contract) requires that any cluster created by the engine carries a `chart-test-swarm-` prefix. **Add**: the assertion explicitly tests the "no env override" branch — invoke `bash engine/scripts/cluster-up.sh` with `CLUSTER_NAME` UNSET and confirm the created cluster's name (via `kind get clusters` or equivalent) matches `^chart-test-swarm-[a-z0-9-]+$`, not just `^chart-test-swarm$`. Without this addition, VAL-ENGINE-030 fails for a brand-new contributor running the scripts unmodified.

### Modification 2: Strengthen VAL-DASH-014/15/16 (reports dir mixed shapes) — add HTML-escape posture
The existing dashboard-collect assertions cover that mixed `run-*` and `scenario-*` layouts in `reports/` are tolerated. **Add**: for any synthesized fixture used in those tests, include at least one scenario whose `name`/`description`/`fail_msg` carries HTML metacharacters (`<>&"'`). Confirm the rendered HTML output for that fixture passes the autoescape posture asserted in VAL-DASH-024. This ties the legacy-shape assertion to XSS-safety so a future "tolerate legacy shape" refactor cannot regress escaping.

---

## Citation Index (file:line for each gap)

| Assertion | Code location |
|---|---|
| VAL-ENGINE-030 | `engine/scripts/cluster-up.sh:6`, `engine/scripts/cluster-down.sh:5`, `engine/scripts/run-scenario.sh:100` |
| VAL-ENGINE-031 | `engine/scripts/dispatch-swarm.sh:100-114` |
| VAL-ENGINE-032 | `engine/scripts/apply-scenario.sh:60` |
| VAL-ENGINE-033 | `engine/scripts/apply-scenario.sh:79` |
| VAL-ENGINE-034 | `engine/scripts/aggregate.sh:100, 112, 122, 132` |
| VAL-ENGINE-035 | `engine/skills/chart-test-swarm/SKILL.md:10-12,58,73,107`, `engine/skills/chart-test-swarm/references/workflow.md:11,37,220` |
| VAL-ENGINE-036 | `engine/scripts/dispatch-swarm.sh:89-90` |
| VAL-ENGINE-037 | `engine/scripts/dispatch-swarm.sh:166`, `engine/templates/agent-brief.md.tmpl` |
| VAL-ENGINE-038 | `engine/scripts/cluster-up.sh:46` (kind branch), equivalent k3d branch |
| VAL-ENGINE-039 | `engine/scripts/dispatch-swarm.sh:42`, `engine/scripts/aggregate.sh:37,121` |
| VAL-ENGINE-040 | `engine/scripts/run-scenario.sh:7` (comment vs body) |
| VAL-DASH-022 | `engine/testgrid/src/testgrid/collect.py:25-31`, `engine/testgrid/src/testgrid/render.py:50` |
| VAL-DASH-023 | `engine/testgrid/src/testgrid/collect.py:144`, `engine/testgrid/src/testgrid/render.py:17` |
| VAL-DASH-024 | `engine/testgrid/src/testgrid/render.py:62`, all `*.j2` templates |
| VAL-CLI-022 | (post-M9) `engine/cli/src/chart_test_swarm/forward.py` (proposed) |
| VAL-CLI-023 | `engine/asserts/service-reachable.sh:25` |
| VAL-CROSS-028 | `engine/scripts/dispatch-swarm.sh:13` |
| VAL-CROSS-029 | `engine/scripts/run-scenario.sh:130-135`, `examples/sample-product-chart/chart-test/scenarios/customer-A-istio.yaml` |

