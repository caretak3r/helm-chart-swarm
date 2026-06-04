---
name: primer-author
description: Author or update integration primer markdown documents under engine/skills/chart-test-swarm/references/integrations/<category>/ with consistent structure, accurate command examples, and validated YAML embeds.
---

# primer-author

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for primer-author workers (primarily Milestone 8 cloud-native primers, plus any explicit primer-only features).

## Required Skills and Tools

- `bd` (beads) — resolve issue ID with `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id')` then claim with `bd update "$BD_ID" --claim` at start; close with `bd close "$BD_ID"` before handoff.
- `yamllint` — every embedded YAML block in your primer is also validated.
- `kubeval` or `kubectl --dry-run=client -f` — for cloud-native primers, every embedded manifest snippet MUST pass dry-run validation against a pinned Kubernetes version.
- `helm template` — for any embedded Helm-values snippet, run a dry-render against the referenced chart and verify it produces valid manifests.
- `markdownlint` (if installed) — pass on the primer file.
- Mission boundaries from `{missionDir}/AGENTS.md`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, and `fulfills` from `{missionDir}/features.json`.
   - For each ID in `fulfills`, read the full assertion in `{missionDir}/validation-contract.md` — the assertion text often dictates the H2 sections your primer MUST contain.
   - For cloud-native primers (F8.x): the assertion VAL-CLOUD-001 dictates a primer for that cloud; VAL-CLOUD-002 typically dictates a per-cloud "Target Kubernetes version" H2 heading.
   - Read existing primers in adjacent category subdirs as style references.

2. **Author the primer at the correct path.**
   - Path: `engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md`.
   - For F8.1 GKE: `engine/skills/chart-test-swarm/references/integrations/cloud-native/gke.md`.
   - For F8.2 EKS: `engine/skills/chart-test-swarm/references/integrations/cloud-native/eks.md`.
   - For F8.3 AKS: `engine/skills/chart-test-swarm/references/integrations/cloud-native/aks.md`.

3. **Required H2 sections (in order):**
   - `## Overview` — what the integration does, why it matters, key concepts (Workload Identity, IRSA, etc).
   - `## Target Kubernetes version` (cloud-native only) — pin a single version, e.g. `GKE 1.30+`.
   - `## Variants` — enumerate 3-4 scenario variants this integration supports. Each variant has a sub-H3 with a short blurb and a link to its scenario YAML file (e.g. `[gke-workload-identity.yaml](../../../../examples/sample-product-chart/chart-test/scenarios/gke-workload-identity.yaml)`).
   - `## How to apply` — for cloud-native: explicit "Run this against your own cluster, NOT from this repo" warning, plus the actual `kubectl apply -f` invocations and any prerequisite IAM/identity setup.
   - `## Assertions` — what to verify after apply (pods ready, ingress reachable, IAM bindings resolved). For cloud-native, document that this repo does NOT run these assertions automatically.
   - `## Known gotchas` — version skew, regional vs zonal, IAM permission ordering, finalizer issues, etc.
   - `## References` — links to official docs.

4. **Validate embedded YAML/manifest snippets.**
   - Extract every YAML block (fenced ```yaml ... ```) into a temp file and run `yamllint <tmp>`. All must pass.
   - For cloud-native primers, also extract every Kubernetes manifest snippet and run `kubectl --dry-run=client -f <tmp> -o yaml` AGAINST A LOCAL KUBECONFIG (use `--validate=true` and a kind cluster context, NOT a real cloud context). Snippet must dry-render without errors.
   - For helm-values snippets, run `helm template tmp-release <chart-path> --values <tmp-values.yaml>` and confirm exit 0.

5. **Cloud-native discipline (M8 only — CRITICAL).**
   - NEVER `kubectl --context <cloud>` against a real GKE/AKS/EKS cluster from this machine.
   - All validation is dry-run against a local kind cluster or `kubeval`.
   - The primer's "How to apply" section MUST contain a prominent banner like: `> **This repo does not run these scenarios.** Apply them yourself to your own cloud cluster.`

6. **Run worker-scoped checks.**
   - `yamllint engine/skills/chart-test-swarm/references/integrations/<category>/*.md` (only the file you touched; verify no inline-yaml violations).
   - `markdownlint engine/skills/chart-test-swarm/references/integrations/<category>/<integration>.md` (if installed; otherwise skip).
   - For cloud-native: the `kubectl --dry-run=client` and `kubeval` invocations from step 4 on every embedded manifest.

7. **Cluster + process hygiene at handoff.**
   - Any local kind cluster you used for dry-run validation MUST be torn down.
   - `kind get clusters` shows zero `chart-test-swarm-*` entries.

8. **Commit and close.**
   - Commit on the worker branch.
   - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Authored F8.1 GKE cloud-native primer at engine/skills/chart-test-swarm/references/integrations/cloud-native/gke.md covering Workload Identity, IAP, GKE Gateway Controller, and regional networking variants. All four embedded manifest snippets passed kubectl --dry-run=client against a local chart-test-swarm-gkev kind cluster pinned to k8s 1.30; helm-values snippet helm-templated cleanly; no real GKE access from this repo.",
  "whatWasImplemented": "Created gke.md with the full H2 section set (Overview, Target Kubernetes version pinned to GKE 1.30+, Variants enumerating 4 scenarios with relative links, How to apply with prominent 'do NOT run from this repo' banner, Assertions, Known gotchas including IAM eventual-consistency, References to official Google docs). Embedded 4 YAML manifest snippets (workload-identity ServiceAccount + IAM binding stub, IAP BackendConfig, GKE Gateway gateway.networking.k8s.io, regional cluster networking ConfigMap). Each snippet's annotation includes 'chart-test-swarm/target-k8s-version: gke-1.30'.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "yamllint engine/skills/chart-test-swarm/references/integrations/cloud-native/gke.md", "exitCode": 0, "observation": "Clean."},
      {"command": "for snippet in /tmp/gke-snippet-*.yaml; do kubectl --dry-run=client --validate=true -f $snippet -o yaml > /dev/null && echo OK $snippet; done", "exitCode": 0, "observation": "4 snippets all dry-rendered against chart-test-swarm-gkev kind cluster (k8s 1.30); 'OK' printed for each."},
      {"command": "kubeval --kubernetes-version 1.30.0 /tmp/gke-snippet-*.yaml", "exitCode": 0, "observation": "All 4 manifests valid against k8s 1.30 schema."},
      {"command": "helm template gke-test examples/sample-product-chart/chart --values /tmp/gke-values-snippet.yaml > /dev/null", "exitCode": 0, "observation": "Helm-values snippet renders cleanly against the product chart."},
      {"command": "rg -n '^## Target Kubernetes version' engine/skills/chart-test-swarm/references/integrations/cloud-native/gke.md", "exitCode": 0, "observation": "Section header present on line 14."}
    ],
    "interactiveChecks": [
      {"action": "Open gke.md in editor; manually verify the 'do NOT run from this repo' banner appears in the How to apply section; visually scan for any kubectl --context my-gke references.", "observed": "Banner present; no live cloud-context references; all kubectl examples use placeholders like <YOUR-GKE-CONTEXT> or --dry-run=client."}
    ]
  },
  "tests": {
    "added": []
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- The primer's required snippet count exceeds what fits naturally in one markdown file (>10 fenced blocks).
- A cloud-native primer requires a feature this repo doesn't support (e.g. credential acquisition, real IAM provisioning) — flag and pause.
- An embedded snippet requires a Kubernetes version newer than what `kubeval` supports.
