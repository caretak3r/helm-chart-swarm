---
name: chart-test-swarm
description: |
  Generate and run integration-test scenarios for a Helm chart against
  customer-shaped clusters. Use when the user is inside a Helm chart
  repository and asks to "test this chart with <X>", "add a scenario for
  <X>", "see if this chart works with <X>", or types "/chart-test-swarm
  <verb>". Introspects the chart templates to decide if the integration is
  structurally POSSIBLE before generating anything. Ships with a
  cert-manager primer; gateway-api, traefik, opa-gatekeeper, and istio
  (mesh + ingress) are added by dropping a primer in
  references/integrations/<category>/. By default, after you confirm the generated
  artifacts, it spins up a local kind cluster, installs prereqs, deploys
  the chart, runs asserts, and refreshes the dashboard — mirroring
  helm-swarm-test's end-to-end discipline. Pass diff-only / --dry-run to
  stop after writing artifacts. Bundles its own runner — no external repo.
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
---

# chart-test-swarm

Generative integration-test harness for Helm charts. User prompts in
natural language ("test this chart with cert-manager"); the skill
introspects the chart, checks feasibility, generates override values +
helm tests + scenario YAML, then (by default) runs it on a real kind
cluster and refreshes the dashboard.

The full procedure lives in **`references/workflow.md`** — read it before
executing. This file is just the dispatcher.

## When to invoke

- "test this chart with X", "new scenario for X", "see if this chart works
  with X", "what if customer has X"
- `/chart-test-swarm <new|run|swarm|dashboard|init|status> [args]`
- User is in a directory tree with (or that should have) a `Chart.yaml`

## When NOT to invoke

- User wants to hand-write a scenario → point at `references/scenario-schema.md`
- Non-Helm test framework
- The chart in question IS an OSS addon (this skill tests *consumers* of
  addons, not the addons themselves)

## Verbs

| Verb | Action |
|------|--------|
| `new <integration>` | Generate artifacts → (default) run end-to-end. `diff-only`/`--dry-run` stops after writing. |
| `run <scenario-id>` | Execute an existing scenario through the engine |
| `swarm <suite>` | Dispatch a whole suite (`pr-subset`/`nightly-full`/`customer-replica`) |
| `dashboard` | Build + open the testgrid dashboard |
| `init` | Manual `chart-test/` scaffold (auto-scaffold is the default) |
| `status` | Scenarios known, last run, dashboard link |

## Supported integrations

The live list is **whatever has a primer** in `references/integrations/<category>/`.
Run `find references/integrations/ -name '*.md' -type f` — that directory
tree is the source of truth.  Today: `certificates/cert-manager`.  Others
(`ingress-controllers/traefik`, `service-mesh/istio-service-mesh`,
`service-mesh/istio-ingress-gateway`, `gateway-api/gateway-api`,
`policy/opa-gatekeeper`) ship as primers land.  If a user asks for one
without a primer, report the available list and stop.

## Phase overview

Full detail in `references/workflow.md`. Halt at first FAIL / IMPOSSIBLE.

| # | Phase | Output |
|---|-------|--------|
| 1 | Parse intent | action + integration + mode |
| 2 | Locate chart (`scripts/locate-chart.sh`) | chart_dir, project_dir |
| 3 | Scaffold `chart-test/` (`scripts/scaffold-chart-test.sh`) | dirs + config |
| 4 | Load primer (`references/integrations/<category>/<x>.md`) | checklist + patterns |
| 5 | Introspect (`scripts/introspect-chart.sh`) | chart profile JSON |
| 6 | **Feasibility verdict** | POSSIBLE / WITH-CAVEATS / IMPOSSIBLE |
| 7 | Generate values override | `chart-test/fixtures/<id>-values.yaml` |
| 8 | Generate helm tests (gated) | `chart/templates/tests/<id>-test.yaml` |
| 8.5 | Generate smoke-script | `chart-test/assertions/<id>-helm-test.sh` |
| 9 | Generate scenario | `chart-test/scenarios/<id>.yaml` |
| 10 | **Show diff, ask mode** | write&run / write-only / abort |
| 10.5 | Preflight (docker/kind/kubectl/helm/yq/jq) | go / no-go |
| 11 | Spin up kind + run (`engine/scripts/run-scenario.sh`) | result.yaml |
| 12 | Dashboard (`engine/scripts/build-dashboard.sh`) | dist/index.html |
| 13 | Lessons-learned | `reports/.../lessons-learned.yaml` |

## Discipline (full rules: `references/feasibility-discipline.md`)

- **Never generate after IMPOSSIBLE.** Report the blocker; touch no cluster.
- **Never write artifacts without showing the diff first** (Phase 10).
- **Never edit the chart's own `values.yaml`.** Test config lives in
  `chart-test/fixtures/`.
- **Helm tests must be gated** behind `{{- if .Values.chartTestSwarm.enabled }}`.
- **Preflight is non-negotiable** — prove Docker/kind/kubectl/helm/yq/jq
  before any cluster work. A missing tool is information, not a runtime
  problem to solve.
- **No PASS without positive proof; no FAIL without a repro command.**
- **Keep the cluster on FAIL** (`KEEP_CLUSTER=1`) so the user can triage.
- **Cite the profile** when justifying a verdict.
- **Self-improve** — write a lessons-learned stanza each run; recurring
  pitfalls escalate into the integration primer.

## References

- `references/workflow.md` — full phase-by-phase procedure (read first)
- `references/scenario-schema.md` — scenario contract + provenance
- `references/feasibility-discipline.md` — rules of engagement
- `references/integrations/<category>/*.md` — per-integration primers (source of truth
  for supported integrations)
- `scripts/` — locate-chart, scaffold-chart-test, introspect-chart, sync-engine
- `assets/` — scenario + helm-test + suite-config templates
- `engine/` — bundled runner (run-scenario, build-dashboard, asserts, testgrid)
