# Agent 1 Brief — run run-cni-cilium-live

You are executor 1 of 1 in a `chart-test-swarm` run.

- **Project:**    `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart`
- **Run dir:**    `reports/run-cni-cilium-live/`
- **Your dir:**   `reports/run-cni-cilium-live/agent-1/`

## Your assigned scenarios

- **`cni-cilium-ebpf-kube-proxy-replacement`** — Cilium eBPF kube-proxy replacement
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-ebpf-kube-proxy-replacement.yaml`
  - desc: Proves full eBPF kube-proxy replacement on kind: Cilium replaces kube-proxy, product ClusterIP reachable through eBPF datapath.
- **`cni-cilium-ingress`** — Cilium ingress controller — dedicated loadbalancerMode
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-ingress.yaml`
  - desc: Proves the Cilium ingress controller in dedicated loadbalancerMode on kind: per-Ingress Service routes HTTP with matching Host header to the product Service.
- **`cni-cilium-network-policy`** — CiliumNetworkPolicy enforcement — default-deny + allow-by-label
  - scenario: `/Users/rohit/Documents/chart-test-swarm/examples/sample-product-chart/chart-test/scenarios/cni/cni-cilium-network-policy.yaml`
  - desc: Proves CiliumNetworkPolicy (CNP) enforcement on kind: default-deny + allow-by-label. Blocks unlabeled traffic; allows labeled clients. CNP applied as raw_manifest preinstall.




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
   `reports/run-cni-cilium-live/agent-1/result.yaml` using this schema:

   ```yaml
   agent: 1
   run_id: run-cni-cilium-live
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
