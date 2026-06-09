# Agent 1 Brief — run run-bats-f17-3-orphan-19869

You are executor 1 of 1 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-bats-f17-3-orphan-19869/`
- **Your dir:**   `reports/run-bats-f17-3-orphan-19869/agent-1/`

## Your assigned scenarios

- **`labels-on`** — Capability: extra labels stamped on every object (ON)
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/capability/labels-on.yaml`
  - desc: Renders the product chart with a global extra-label knob set (extraLabels.team=platform, extraLabels.cost-center=42) and asserts every rendered object (all kinds, not just pod templates) carries the configured labels at .metadata.labels. The sample chart does NOT expose an extraLabels/commonLabels knob — this scenario is EXPECTED to FAIL (honest red gap) documenting that the chart lacks global label propagation.




## Your task

For each assigned scenario YAML:

1. Run end-to-end via the engine:
   ```bash
   bash engine/scripts/run-scenario.sh <scenario.yaml>
   ```
   That brings the cluster up, applies preinstall addons, installs the
   product chart, runs the asserts, and emits a per-scenario
   `result.yaml` into `reports/scenario-<id>-<ts>/`.

2. Aggregate your scenarios' results into a single `result.yaml` at
   `reports/run-bats-f17-3-orphan-19869/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
   run_id: run-bats-f17-3-orphan-19869
   results:
     - scenario_id: <id from scenario yaml>
       status: PASS | FAIL | PARTIAL | INCONCLUSIVE
       duration_s: <seconds>
       fail_stage: ""           # only on non-PASS
       fail_msg: ""             # only on non-PASS, include reproduction command
       log_dir: /tmp/.../...
       asserts:
         - { type: pods-ready,           status: PASS, notes: "..." }
         - { type: helm-status-deployed, status: PASS, notes: "..." }
   ```

3. Between scenarios, tear down state cleanly:
   ```bash
   bash engine/scripts/cluster-down.sh
   ```
   so the next scenario starts from a known cluster. (Or use a separate
   cluster name per scenario via `CLUSTER_NAME` env.)

## Discipline

- **No PASS without a positive assertion.** Every PASS must capture at
  least one observable proof (kubectl event, helm status, exit code).
- **No FAIL without a reproduction command.** `fail_msg` must contain
  the exact command sequence that reproduces the failure.
- **INCONCLUSIVE is a valid status.** Use it when something
  intermittent or unobservable prevents a clean PASS/FAIL judgment.
- **Don't lie to the dashboard.** If you skipped a scenario, leave it
  out — the aggregator will surface it as UNTESTED.
