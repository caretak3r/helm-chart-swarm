# o0g.17 — Sealed Sequential Full-Suite Regression Evidence

Bead: `chart-test-swarm-o0g.17` · Branch: `test/o0g17-sealed-suite` (base `origin/main` @ `24698857`)

## Run identity

| Field | Value |
|---|---|
| run_id | `sealed-clean-1` |
| suite | `all` (103 scenarios enumerated; bead's "99/99" is stale) |
| concurrency | 1 (sequential, single dispatcher) |
| launched | 2026-07-16T03:49:38Z |
| command | `SUITE=all nohup bash engine/scripts/dispatch-swarm.sh examples/sample-product-chart all 1 sealed-clean-1 --run > /tmp/sealed-clean-1.log 2>&1 &` |
| worktree | dedicated checkout of `test/o0g17-sealed-suite`, no other suite launched before or during |
| cluster provider | kind, node image `kindest/node:v1.36.1` |
| chart under test | `sample-product` 0.1.0 (`examples/sample-product-chart`) |

## Preflight (sealed-run precondition)

Checked immediately before launch:

- `ps aux | grep -E 'dispatch-swarm|run-scenario' | grep -v grep` → empty (no competing dispatcher or scenario runner).
- `kind get clusters` → only `helm-hip0025`, a pre-existing ambient cluster unrelated to this repo (not `chart-test-swarm-*`). No chart-test-swarm clusters existed. The bead's "empty" requirement is interpreted as *no chart-test-swarm-\* clusters*, consistent with the run's stop condition; `helm-hip0025` was left untouched throughout.
- Exactly one suite was run. No second suite, no comparison runs, no relaunch.

## Suite composition (103 scenarios, execution order)

| Block | Scenarios | Count | Notes |
|---|---|---|---|
| capability/light | 1–29 | 29 | annotations, labels, imagepullsecrets, rbac, resources, scheduling, scheme, security-context, serviceaccount, network-policy, priority-class, minimal, capability-generated |
| certificates + TLS | 30–44 | 15 | cert-manager (×4), manual TLS secrets, mounted certs (CSI/projected/PVC), with-cert-manager |
| CNI (Cilium) | 45–47 | 3 | ebpf kube-proxy replacement, ingress, network policy |
| Envoy Gateway | 48 | 1 | |
| Gateway API | 49–60 | 12 | Contour (×3), Envoy Gateway (×4), Istio (×5) |
| ingress controllers | 61–72 | 12 | Contour (×3), nginx (×5), Traefik (×4) |
| networking | 73–75 | 3 | Kong, MetalLB, Traefik |
| policy engines | 76–85 | 10 | Gatekeeper (×5), Kyverno (×5) |
| Istio service mesh | 86–97 | 12 | ingress-gateway, mTLS, peer-auth, sidecar/ambient live |
| Linkerd | 98–102 | 5 | basic mesh, live, mTLS rotation, multi-cluster preview, service profile |
| subchart | 103 | 1 | subchart-postgres-internal |

45 of 103 scenarios carry `helm_timeout` overrides (the addon-heavy back half).

Observed pacing (from per-scenario report dir timestamps): light block ~30s/scenario (29 scenarios in ~14.5 min from the 03:49Z launch); cert-manager scenarios ~50–55s each including the cert-manager install; CNI/Envoy Gateway/Gateway API addon scenarios ~1 min each with occasional ~6 min outliers on first addon install (e.g. scenario 51). Zero FAIL/SKIP at every mid-run checkpoint: 16, 21, 26, 29, 32, 36, 50 (04:21Z, past the Cilium + Envoy Gateway blocks) and 54 (04:31Z, mid Gateway API) — all showed `fail: 0, skip: 0` in the incremental aggregate.

## Result summary

Suite completed 2026-07-16T05:36:44Z (1h 47m wall clock, sequential).

- Total scenarios: 103
- PASS: **103**
- FAIL: **0**
- SKIP: **0**
- INTERRUPTED: **0** (zero INTERRUPTED mentions in the dispatcher log; final result.yaml lists all 103 scenarios with `status: PASS`)

Acceptance per bead: zero FAIL / zero INTERRUPTED out of N=103, SKIPs individually justified — **met** (103/103 PASS, no SKIPs to justify). Dispatcher exited cleanly after `Suite execution complete: 103 scenario(s) — PASS: 103, FAIL: 0, SKIP: 0` and deleted its final cluster (`chart-test-swarm-sealed-clean-1-103`).

## Pre/post state

| Check | Pre-launch | Post-run (2026-07-16T05:37Z) |
|---|---|---|
| dispatch-swarm/run-scenario processes | none | none |
| `kind get clusters` (chart-test-swarm-*) | none | none — every run cluster torn down by the dispatcher (KEEP_CLUSTER=0) |
| ambient cluster `helm-hip0025` | present, untouched | present, untouched |
| engine bundle drift (`sync-engine.sh --check`) | in sync | in sync (`OK: engine bundle in sync`) |
| `git status` dirt beyond run reports dir | clean | clean, after restoring 5 tracked artifact files (see anomaly note below) |

### Anomaly (no test impact): misdirected live-mesh artifact capture

The three consumer "live" assertion scripts (`istio-ambient-live.sh`, `istio-sidecar-live.sh`, `linkerd-live.sh`) locate their artifact-capture dir by globbing `chart-test/reports/` at `-maxdepth 1` for `scenario-<id>-*`. Under run-scoped dispatch the live report dir is one level deeper (`reports/sealed-clean-1/scenario-<id>-<ts>/`), so the glob matched only stale tracked dirs from 2026-06-02 and the capture step rewrote 5 committed `pods.yaml`/`namespace.yaml` files there. All three scenarios PASSed on their actual probes; only the VAL-MSH-008 artifact bundle landed in the wrong place. The 5 files were restored via `git checkout --`, and the bug is filed as bead `chart-test-swarm-bz1`.

## SKIP justifications

None — `skip: 0`; every enumerated scenario, including all kind-sensitive addon blocks (Cilium eBPF, Istio ambient/sidecar live, Linkerd live, MetalLB), ran and PASSed on kind v1.36.1.

## Committed artifacts

- `examples/sample-product-chart/chart-test/reports/sealed-clean-1/result.yaml` — incremental aggregate (total/pass/fail/skip + per-scenario status list)
- `examples/sample-product-chart/chart-test/reports/sealed-clean-1/run-meta.yaml` — run identity (run_id, suite, k8s version, chart)
- this document

Per bead rules this branch is **not pushed** and no PR is opened; it is left local for supervisor review.
