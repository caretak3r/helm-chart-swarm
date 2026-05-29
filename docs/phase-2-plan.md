# Phase 2 plan — deferred from MVP

Context: MVP (Phases 1–5) landed kind/k3d + functional pass/fail + dashboard
+ CI templates + docs. Everything below was deliberately scoped out so we
could ship the engine. Schema and code were designed with these in mind —
each item lists the extension point that's already there.

## 1. Cloud cluster providers (EKS / GKE / AKS / vcluster)

**Why it matters.** Most customer support escalations involve cloud-managed
quirks — LoadBalancer behaviour, CSI drivers, IAM-bound service accounts,
node-level eviction differences. Local kind cannot simulate these.

**Extension point already in place.** `engine/templates/scenario.schema.json`
already accepts `provider: eks|gke|aks|vcluster`. `engine/scripts/cluster-up.sh`
has a `case` that errors on these — replace with real provisioners.

**Work**:
- `engine/scripts/providers/eks.sh` — wraps `eksctl create cluster --config-file <cfg>` (faster than terraform for ephemeral)
- `engine/scripts/providers/gke.sh` — wraps `gcloud container clusters create`
- `engine/scripts/providers/aks.sh` — wraps `az aks create`
- `engine/scripts/providers/vcluster.sh` — wraps `vcluster create` on an existing kind host
- Refactor `cluster-up.sh` to dispatch to `providers/<provider>.sh`
- Per-provider teardown symmetry
- Add a `cluster.cloud_config` field to schema (region, instance type, node count) — keep it flat so terraform isn't needed for MVP
- Cost guard: enforce `max_minutes` from suite definition; force teardown on timeout
- Credentials: scenarios should NOT carry credentials. Use a `cluster.credentials_secret_ref` indirection that CI resolves from secrets (`AWS_*`, `GOOGLE_APPLICATION_CREDENTIALS`, etc.)

**Open question.** Do we run cloud scenarios in CI by default (cost) or only
on a `:cloud` suite filter the user opts into? Default: opt-in. The `cloud:*`
mechanism prefix already exists in the dashboard vocabulary.

**Effort.** 1–2 weeks per provider end-to-end with teardown reliability.

## 2. Timing metrics (install time, time-to-ready)

**Why it matters.** Detect perf regressions across chart releases —
e.g. a values change that quadruples cold-start time on a customer's
slow nodes.

**Extension point.** `engine/scripts/run-scenario.sh` already wraps each
phase in `time` blocks via `started_at`/`finished_at` in the result. They
just need to be emitted into `result.yaml` as numeric fields.

**Work**:
- In `run-scenario.sh`, capture per-phase wall-clocks: `cluster_up_s`,
  `preinstall_s`, `product_install_s`, `asserts_s`
- Wire into `result.yaml` schema additions
- Add `Timing` dataclass in `engine/testgrid/src/testgrid/collect.py`
- Add a new section to `run.html.j2`: "Timing breakdown" — bar chart per
  scenario using inline `<div style="width: Xpx">`-style CSS (no JS)
- For PASS-only timing, gate the bar chart with a `--show-timing` flag in
  the testgrid CLI to keep noise low when comparing failing runs

**Open question.** Where do we draw the regression line? Statistical
threshold (2σ over rolling 7 days)? Hard ceiling per scenario (declared
in the YAML)? Both?

**Effort.** ~3 days for capture + display. Threshold logic is separate
work item.

## 3. Compatibility-assertion DSL (typed beyond `smoke-script`)

**Why it matters.** "Pods come up" isn't enough. Need first-class
assertions like:
- `gatekeeper-policy-conformance` — no admission denials for chart's resources
- `istio-sidecar-injected` — confirms sidecar present + ready in every pod
- `cert-issued` — cert-manager Certificate resource reaches Ready
- `network-policy-allows` — connectivity through default-deny netpol stack

**Extension point.** `engine/asserts/` is the runner registry. The schema's
`asserts[].type` enum and the `oneOf` per-type field list are the contract.

**Work**:
- For each new type, drop `engine/asserts/<type>.sh` with the standard
  contract (env: `$RELEASE/$NAMESPACE/$PROJECT_DIR`; args: scenario.yaml,
  index; exit 0 = PASS)
- Extend `scenario.schema.json`: add the type to the enum and a new
  `oneOf` branch declaring its required fields
- Update `docs/scenario-authoring.md` "Built-in assertion types" table
- No changes needed to `run-scenario.sh` — dispatch is by filename

**Open question.** Is `cert-issued` an assertion (verifies issuance) or a
preinstall step (issues a cert before product install)? Both. Author it
twice with clear names — `cert-issued` (assertion) and `issue-cert`
(preinstall hook).

**Effort.** ~1 day per assert type once you've got the cluster fixture for
the addon it verifies.

## 4. Trend dashboard (perf + status over time)

**Why it matters.** Single-run dashboard answers "did this run pass?". The
trend view answers "is `customer-A-istio` getting flakier?" and "is
install time creeping up across releases?".

**Extension point.** `engine/testgrid/src/testgrid/cli.py` already calls
`list_runs()` and re-renders the index every build. Add a third template
that consumes the same data with a time axis.

**Work**:
- New template: `templates/trends.html.j2`
- New render function: `render_trends(runs, out_dir)` in `render.py`
- Scenario-level trend: for each scenario, a time-ordered row of
  PASS/FAIL squares (like github actions calendar heatmap)
- Mechanism-level trend: rollup status per mechanism over time
- Timing trends (if Phase-2 #2 done): sparkline per scenario
- Link from `index.html` header: "View trends →"

**Open question.** Retention. Reports/ grows unbounded. Add a sliding
window option (`--max-runs 90`) and a `make prune` target?

**Effort.** ~3 days for the static HTML view. Sparklines need either a
tiny JS library or hand-rolled SVG; lean toward inline SVG to stay
JS-free.

## 5. Smarter aggregate exit codes (expected-fail support)

**Why it matters.** Right now `aggregate.sh` exits 0 regardless. The
customer-scenario-playbook says "land scenario failing, then land fix" —
that path is broken today because the CI workflow will go red the
moment a `customer-replica` scenario is added.

**Extension point.** `aggregate.sh` builds `scenario-matrix.csv`. Add a
final classification step.

**Work**:
- Honour an `expected-fail` tag in scenario YAML — a FAIL on those
  scenarios doesn't fail the workflow
- Add a `expected: fail` field that overrides `expected-fail` tag
  (more explicit)
- `aggregate.sh` exits non-zero only if any scenario has actual status
  worse than its expected status
- New section in `lessons-learned.md`: "Expected-fail scenarios still
  failing" — they're not blocking, but they should be on a TODO list

**Open question.** How do we make sure expected-fail doesn't become a
hiding place for actual regressions? Idea: hard cap on duration —
scenarios stuck in expected-fail for >30 days surface in the trend
dashboard as red flag.

**Effort.** ~1 day.

## 6. PR-bot dashboard link comment

**Why it matters.** Reviewers don't dig through CI artifacts. They need
a one-click link to the PR's dashboard.

**Extension point.** `engine/templates/ci/github-pr.yml` already uploads
the dashboard as a workflow artifact. Add a comment step after.

**Work**:
- Use `peter-evans/create-or-update-comment@v4`
- Post markdown table: PR-subset suite, X/Y scenarios PASS, link to
  artifact + (if hosted) gh-pages URL
- Update existing comment on subsequent commits instead of spamming

**Effort.** ~half a day.

## 7. Resource / cost profile

**Why it matters.** Customers ask "how much does this chart cost to run?"
Today: hand-wave. Phase-2 dream: dashboard says "scenario X uses 2 vCPU
+ 4Gi RAM steady-state."

**Extension point.** Same as timing metrics — capture in `run-scenario.sh`
post-install, before teardown.

**Work**:
- New phase in `run-scenario.sh` between asserts and teardown:
  `kubectl top pods -n $NAMESPACE --containers --no-headers` after a
  warmup
- Emit `resource_profile: { cpu_m, memory_mi, pvc_gi }` into
  `result.yaml`
- New dashboard section: per-scenario cost card

**Caveat.** `kubectl top` requires metrics-server, which kind doesn't
install by default. Either add it as an implicit preinstall for any
scenario tagged `profile-resources`, or document the limitation.

**Effort.** ~2 days including the metrics-server wiring.

## Suggested order

If picking up Phase 2 from scratch:

1. **#5 (expected-fail exit codes)** — half a day, unblocks #6 and the
   customer-scenario flow
2. **#6 (PR-bot comment)** — half a day, dramatically improves DX
3. **#2 (timing metrics)** — small win, sets up #4
4. **#4 (trend dashboard)** — visible, motivating
5. **#3 (compat assertions)** — incremental, can land one type at a time
6. **#7 (resource profile)** — only if customers actually ask
7. **#1 (cloud providers)** — biggest, save for when local coverage
   feels insufficient

## Notes for picking this back up

- All MVP scripts are at `engine/scripts/`; extension shape is "drop
  another `.sh` and reference it from `run-scenario.sh` or
  `scenario.schema.json`"
- Dashboard renders without `yq` (only needs `uv`), so you can render
  fake data while iterating on Phase 2 without a cluster
- Original architecture plan: `~/.claude/plans/looking-at-the-setup-tranquil-feigenbaum.md`
- Existing seed data demonstrates a FAIL path (`customer-A-istio` →
  istio-cni-node) — useful for verifying new dashboard features without
  breaking real charts
