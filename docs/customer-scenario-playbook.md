# Customer-scenario playbook

The point of chart-test-swarm: when a customer hits something we never
tested, we codify their environment as a scenario, and never regress on
it again.

## The flow

```
customer issue          codify scenario          first nightly         fix lands         locked in
─────────────►  reproduce  ─────────────►  scenario FAILS  ─────►  scenario PASSES  ───►  promoted
                  locally     chart-test/                                                  to pr-subset
                              scenarios/
                              customer-X.yaml
```

## Step-by-step

### 1. Capture the customer's cluster shape

From the issue / support ticket, extract:

- **Cloud / distribution**: EKS / GKE / AKS / vanilla / OpenShift
- **K8s version**: `kubectl version --short`
- **Preinstalled addons** that interact with our chart:
  - cert-manager (CRDs + issuers)
  - istio / linkerd (sidecar injection on/off, namespace label)
  - gatekeeper (which constraint templates are active)
  - ingress controllers (nginx / istio-gw / traefik / cloud LB)
  - storage classes (default StorageClass + RWO/RWX support)
  - network policies (default-deny baselines)
- **Their values overrides** to our chart (sanitize secrets)

### 2. Reproduce locally

```bash
cd ~/path/to/your-chart-repo
cp engine/templates/_scenario-template.yaml \
   chart-test/scenarios/customer-X-<ticket>.yaml
$EDITOR chart-test/scenarios/customer-X-<ticket>.yaml
```

Iterate locally until you see the failure:

```bash
make scenario SCENARIO=chart-test/scenarios/customer-X-<ticket>.yaml
```

Don't fix it yet. The goal of step 2 is to PROVE we have a regression
test that catches the customer's bug.

### 3. Land the scenario (failing)

Open a PR with just the scenario YAML. CI runs it — it fails. That's
fine. Tag the PR `customer-replica`, link the customer ticket.

The scenario goes into nightly. The dashboard now shows a permanent red
square for this customer until a fix lands.

### 4. Fix and watch it flip

Land the fix in a separate PR. The same nightly run that exercises the
scenario will flip it from FAIL to PASS. Dashboard rollup updates.

### 5. Promote to PR subset (optional)

If the failure mode would have been catchable by a fast pre-merge check,
promote the scenario:

```yaml
# chart-test/scenarios/customer-X-<ticket>.yaml
tags: [pr-subset, nightly, customer-replica]    # was [nightly, customer-replica]
```

Every future PR now has a hard gate against this regression.

## Anti-patterns

- **Don't fix without a failing scenario first.** If you can't reproduce
  the customer's issue in a scenario, you don't actually know what
  you're fixing.
- **Don't delete a scenario after the fix.** It's a regression test.
  Leave it in `customer-replica` so it keeps running.
- **Don't sanitize the customer's setup down to nothing.** If they have
  cert-manager + istio + a weird storage class — model all three. The
  combination is what broke.
- **Don't put secrets in the scenario YAML.** Use placeholders + fixtures
  loaded from CI secrets. Scenarios are checked into source.
