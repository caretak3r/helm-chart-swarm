# Workflow — authoritative procedure

SKILL.md is the slim dispatcher; this file is the full procedure. Execute
phases in order. Halt at the first FAIL or IMPOSSIBLE verdict.

## Phase 1 — parse intent

From the user prompt, extract:
- `action` — one of: `new`, `run`, `swarm`, `dashboard`, `init`, `status`
- `integration` — for `new`: must match a primer filename (sans `.md`)
  under `references/integrations/<category>/`. Run
  `find references/integrations/ -name '*.md' -type f` to get the live
  list — that directory tree is the source of truth, NOT a
  hardcoded list. If the requested integration has no primer, report the
  available ones and stop.
- `scenario_id` — for `run`
- `suite` — for `swarm` (`pr-subset` / `nightly-full` / `customer-replica`)
- `mode` — `write & run` (default), or `write only` / `diff-only` /
  `--dry-run` to stop after writing artifacts

If `action=new` without an integration, ask which one (offer the live list).

## Phase 2 — locate chart

Run `scripts/locate-chart.sh`. Walks up from CWD, finds nearest
`Chart.yaml`, emits `{chart_dir, name, version, project_dir, has_chart_test}`.
If none found, stop: *"No Helm chart found in this directory tree. cd into
your chart repo first."*

## Phase 3 — scaffold chart-test/ if missing

Run `scripts/scaffold-chart-test.sh "$project_dir"`. Idempotent. Creates
`chart-test/{scenarios,fixtures,assertions,reports}/` + `chart-test-swarm.yaml`
+ `.gitignore`. Tell the user what was created.

## Phase 4 — load integration primer (action=new only)

Read `references/integrations/<category>/<integration>.md`. Fixed-shape document with
these H2 sections, in order:

```
## Cluster preinstall
## Feasibility checklist for the consumer chart
## Standard values-override pattern
## Standard helm-test pattern
## Common failure modes
```

If a section is missing or the heading case is wrong, stop and report the
primer is malformed.

## Phase 5 — introspect chart

Run `scripts/introspect-chart.sh "$chart_dir"`. Emits a JSON profile:

```json
{
  "chart_dir": "...", "name": "...", "version": "...",
  "pod_owning_kinds": ["Deployment"],
  "templates": [{
    "path": "...", "kind": "Deployment",
    "has_volumes_block": true, "volumes_value_driven": false,
    "has_volume_mounts": true, "volume_mounts_value_driven": false,
    "pod_annotations_value_driven": true, "pod_labels_value_driven": true,
    "env_value_driven": true, "host_network": false
  }],
  "already_has_helm_tests": false,
  "values_keys": ["replicaCount", "image", ...],
  "tls_references_found": false
}
```

## Phase 6 — feasibility verdict

Walk every requirement in the primer's **Feasibility checklist** against
the profile.

| Profile field | Common check phrasing |
|---|---|
| `pod_owning_kinds` | "has at least one pod-owning kind" |
| `templates[].volumes_value_driven` | "volume blocks are value-driven" |
| `templates[].volume_mounts_value_driven` | "volume mounts are value-driven" |
| `templates[].pod_annotations_value_driven` | "pod annotations configurable" |
| `templates[].pod_labels_value_driven` | "pod labels configurable" |
| `templates[].env_value_driven` | "env vars configurable" |
| `templates[].host_network` | "no host networking" (must be false) |
| `tls_references_found` | "already references TLS / certs" |
| `already_has_helm_tests` | "no existing helm tests" |
| `values_keys` | "exposes <X> via values.yaml" |

Algorithm:
1. Any failed `Required:` check → **IMPOSSIBLE**; do not proceed
2. Collect failed `Soft:` checks as caveats
3. No caveats → **POSSIBLE**; else → **POSSIBLE-WITH-CAVEATS**

For IMPOSSIBLE: report which checks failed (cite the profile fields), the
minimal chart change that would unblock, generate NOTHING, touch NO cluster.

See `feasibility-discipline.md` for the rules of engagement.

## Phase 7 — generate values override

Write `chart-test/fixtures/<integration>-integration-values.yaml`. Always
start with:
```yaml
chartTestSwarm:
  enabled: true   # gates the helm-test pod injection
```
Then the integration-specific block from the primer's **Standard
values-override pattern**, with field paths mapped to the chart's actual
`values_keys`. Cite the real path in a trailing comment on each key. Never
edit the chart's own `values.yaml`.

## Phase 8 — generate helm tests

Write `chart/templates/tests/<integration>-integration-test.yaml` from the
primer's **Standard helm-test pattern**. Always:
- Wrap entire manifest in `{{- if .Values.chartTestSwarm.enabled }} … {{- end }}`
- Annotate `helm.sh/hook: test`, `helm.sh/hook-delete-policy: hook-succeeded`
- Exit non-zero on failure; print enough that `helm test --logs` reveals why

## Phase 8.5 — generate the smoke-script

Write `chart-test/assertions/<integration>-integration-helm-test.sh`, chmod +x:
```bash
#!/usr/bin/env bash
set -euo pipefail
helm test "$RELEASE" -n "$NAMESPACE" --logs --timeout 5m
```

## Phase 9 — generate scenario.yaml

Write `chart-test/scenarios/<integration>-integration.yaml` from
`assets/_scenario.yaml.tmpl`. Placeholder → source map:

| Placeholder | Source |
|---|---|
| `${SCENARIO_ID}` | `<integration>-integration` |
| `${SCENARIO_NAME}` | human title from primer + chart name |
| `${SCENARIO_DESC}` | one-paragraph rationale (you write it) |
| `${INTEGRATION}` | integration name |
| `${PRODUCT_CHART_PATH}` | rel path project_dir→chart_dir, `./`-prefixed |
| `${PRODUCT_RELEASE}` | chart name, kebab-case |
| `${PRODUCT_NAMESPACE}` | same as release |
| `${GENERATED_AT}` | `date -u +%Y-%m-%dT%H:%M:%SZ` |

Replace the `cluster.preinstall:` placeholder comment with the verbatim
block from the primer's **Cluster preinstall** section. Set
`generated_by: { by: chart-test-swarm-skill, integration, at, skill_version }`.

## Phase 10 — show diff, ask for mode

Summarise every file to be written/edited (one line each):
- `chart-test/fixtures/<id>-values.yaml`
- `chart-test/fixtures/<id>-prereqs/...` (only when raw-manifest preinstalls
  needed — bundled as a tiny helm sub-chart, since the engine has no
  raw-kubectl-apply preinstall yet)
- `chart/templates/tests/<id>-test.yaml` (gated)
- `chart-test/scenarios/<id>.yaml`
- `chart-test/assertions/<id>-helm-test.sh`

Offer three modes:
1. **write & run** *(default)* — write, then Phases 10.5–13
2. **write only** / **diff-only** / **dry-run** — write and stop; user runs
   later via `/chart-test-swarm run <id>`
3. **abort** — write nothing

Bare `y`/`yes` → write & run. Only proceed after confirmation.

## Phase 10.5 — preflight (before any cluster work)

STOP at first failure; surface the install command; do NOT enter Phase 11.

```bash
docker info >/dev/null 2>&1 \
  || { echo "ERROR: Docker daemon not running. Start Docker Desktop / colima / orbstack."; exit 1; }
for bin in kind kubectl helm yq jq; do
  command -v "$bin" >/dev/null 2>&1 \
    || { echo "ERROR: '$bin' not installed. brew install $bin"; exit 1; }
done
# warn if <5GB free for the ~1GB kind node image
# reuse existing 'chart-test-swarm' cluster unless KEEP_CLUSTER semantics say otherwise
```

Report each as `✓ <tool> <version>` / `✗ <tool> missing`. This is the
chart-test-swarm equivalent of helm-swarm-test's `make verify` gate.

## Phase 11 — spin up kind + run scenario (write & run only)

```bash
PROJECT_DIR="$project_dir" \
  bash "$SKILL_DIR/engine/scripts/run-scenario.sh" \
       "$project_dir/chart-test/scenarios/<id>.yaml"
```

Drives the engine pipeline: `cluster-up.sh` (idempotent) → `apply-scenario.sh`
(preinstalls in order) → `helm upgrade --install` with the override values
and `--wait` → each `asserts[*]` via `engine/asserts/<type>.sh`.

Results: `$project_dir/chart-test/reports/scenario-<id>-<ts>/result.yaml`
plus `logs/`. On FAIL, do NOT delete the cluster (default `KEEP_CLUSTER=1`)
— tell the user the `kubectl --context kind-chart-test-swarm` context +
namespace to triage.

## Phase 12 — update testgrid + show dashboard

```bash
PROJECT_DIR="$project_dir" \
  bash "$SKILL_DIR/engine/scripts/build-dashboard.sh"
```

Dashboard at `$project_dir/chart-test/reports/dist/index.html`. Print the
`open` (macOS) / `xdg-open` (Linux) command.

## Phase 13 — write lessons-learned

Append a YAML stanza to
`$project_dir/chart-test/reports/scenario-<id>-<ts>/lessons-learned.yaml`:
pitfalls to pre-load next time, off-spec chart shapes, engine workarounds
used. If the same pitfall recurs across 3+ runs against different charts,
escalate it into the relevant `references/integrations/<category>/<name>.md` primer.

This is the chart-test-swarm equivalent of helm-swarm-test's
`lessons-learned.md` + `capability-matrix-delta.yaml`.

## Execution notes

- If `$SKILL_DIR/engine/` is missing (dev mishap), run
  `scripts/sync-engine.sh` to repopulate from the canonical source.
- Engine preflight inside `run-scenario.sh` errors clearly on missing
  yq/jq/kind/helm — don't auto-install, tell the user.
- If `uv` is missing, `build-dashboard.sh` warns + exits 0; the run itself
  is unaffected. Tell the user `brew install uv` to render the dashboard.
