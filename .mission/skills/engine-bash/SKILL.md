---
name: engine-bash
description: Author and modify engine bash scripts (cluster-up, cluster-down, apply-scenario, run-asserts, run-scenario, dispatch-swarm) and the scenario JSON schema, with bats tests and shellcheck-clean code.
---

# engine-bash

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for engine-bash workers.

## Required Skills and Tools

- `bd` (beads) — resolve issue ID with `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id')` then claim with `bd update "$BD_ID" --claim` at start; close with `bd close "$BD_ID"` before handoff.
- `bats` (>= 1.10) — write `*.bats` tests in `engine/scripts/tests/` or `engine/asserts/tests/`.
- `shellcheck` — every modified `.sh` file must pass with no warnings of severity `warning` or above.
- `jsonschema` (Python) — validate scenario schema changes via `jsonschema -i <scenario.yaml> engine/templates/scenario.schema.json`.
- `kind`, `minikube`, `kubectl`, `helm` — exercise cluster lifecycle.
- `yq`, `jq` — inspect emitted YAML/JSON.
- `docker` — sanity-check Docker memory and container state.
- Mission boundaries from `{missionDir}/AGENTS.md` — cluster-name prefix invariant, no port binding, no background processes, scenarios under `examples/sample-product-chart/chart-test/scenarios/`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, and `fulfills` array from `{missionDir}/features.json`.
   - For each ID in `fulfills`, read the full assertion in `{missionDir}/validation-contract.md` (search for `### <ID>:`). Your tests and code must make every one of those assertions PASS.

2. **Write the failing bats tests first (red).**
   - Place new tests under `engine/scripts/tests/<feature>.bats` (or `engine/asserts/tests/` if asserting on assertion runners).
   - Cover each `expectedBehavior` bullet with at least one test case. Tests MUST use cluster names matching `^chart-test-swarm-[a-z0-9-]+$` and MUST tear down any cluster they create in a `teardown()` block.
   - Run `bats engine/scripts/tests/<feature>.bats` and confirm the test fails for the right reason (not a syntax/setup error).

3. **Implement the change in the bash scripts.**
   - Modify `engine/scripts/*.sh` or `engine/asserts/*.sh` or `engine/templates/scenario.schema.json` to satisfy your tests.
   - Every script `set -euo pipefail` + `trap 'cleanup' EXIT INT TERM` if it creates clusters.
   - Bash 3.2 portability: do NOT use `mapfile`, associative arrays, or other bash-4-only features unless you add an explicit preflight check with a clear stderr message.
   - Schema changes: preserve backward compatibility for the 5 pre-mission scenarios; use `jsonschema -i` on each pre-existing scenario after your change.

4. **Verify locally (manual) — LIVE RUNS ARE MANDATORY for cluster or artifact scripts.**
   - `bats engine/scripts/tests/<feature>.bats` — all green.
   - `shellcheck $(git diff --name-only --diff-filter=ACM | grep '\.sh$')` — clean.
   - **If your feature touches cluster lifecycle (cluster-up, cluster-down, run-scenario, apply-scenario, dispatch-swarm):** You MUST perform a real end-to-end run against a live `chart-test-swarm-*` kind cluster. bats source-grep tests alone do NOT count as proof. Record the exact command and output in `handoff.verification.commandsRun`. If you skip this, set `skillFeedback.followedProcedure: false` and explain why in deviations.
   - **If your feature adds or changes artifact replay behavior (apply-scenario.sh replay path, artifact bundle writing):** You MUST do a real replay: copy `reports/run-*/artifacts/` to a tmpdir, run the replay command against a fresh `chart-test-swarm-*` cluster, verify the resources are deployed, then tear down. Record the replay command and outcome in verification. If you skip this, set `skillFeedback.followedProcedure: false`.
   - **After any live cluster run:** `kind get clusters` and `minikube profile list -o json` must show zero `chart-test-swarm-*` entries. If any remain, tear down before handoff.
   - If you touched the scenario schema: `for f in examples/sample-product-chart/chart-test/scenarios/*.yaml; do jsonschema -i "$f" engine/templates/scenario.schema.json && echo OK $f; done` — every line must say OK.

5. **Run the worker-scoped validation gates.**
   - `bats engine/scripts/tests/` and `bats engine/asserts/tests/` (the directories you touched).
   - `shellcheck engine/scripts/*.sh engine/asserts/*.sh` (full set).
   - `yamllint examples/sample-product-chart/chart-test/scenarios/*.yaml engine/skills/chart-test-swarm/references/integrations/**/*.yaml` (only if you touched a YAML).
   - `helm lint examples/sample-product-chart/chart` (only if you touched chart-adjacent code).
   - DO NOT run the full `commands.test` or `commands.lint` — that is the scrutiny validator's job.

6. **Cluster + process hygiene at handoff.**
   - `kind get clusters` MUST list zero `chart-test-swarm-*` entries.
   - `minikube profile list -o json | jq -r '.valid[].Name' | grep '^chart-test-swarm-'` MUST be empty.
   - `docker ps --filter "name=chart-test-swarm-" --format '{{.Names}}'` MUST be empty.
   - `ps aux | grep -E 'minikube|kind|kubectl' | grep -v grep` MUST be empty.

7. **Commit and close.**
   - Commit on the worker branch (handled by worker-base).
   - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Implemented F1.1 minikube backend in cluster-up.sh and cluster-down.sh, extended scenario.schema.json provider enum, and added script-level chart-test-swarm- prefix enforcement. Ran 14 bats cases (all green), shellcheck clean on 6 touched scripts, and a full kind+minikube round-trip on chart-test-swarm-mvalid showing zero residual clusters at teardown.",
  "whatWasImplemented": "Added a minikube branch to engine/scripts/cluster-up.sh and cluster-down.sh with $CTS_PROVIDER routing; updated engine/templates/scenario.schema.json provider enum to include 'minikube'; introduced a shared engine/scripts/lib/prefix-check.sh sourced by every cluster-touching script that exits 1 with a stderr line referencing chart-test-swarm- on any non-conforming CLUSTER_NAME; preserved KEEP_CLUSTER semantics (default keep, =0 to delete); covered all branches with bats tests under engine/scripts/tests/cluster-up.bats and cluster-down.bats.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "bats engine/scripts/tests/cluster-up.bats engine/scripts/tests/cluster-down.bats", "exitCode": 0, "observation": "14 tests, 14 passing in 41s; minikube spin-up averaged 38s, teardown 9s."},
      {"command": "shellcheck engine/scripts/cluster-up.sh engine/scripts/cluster-down.sh engine/scripts/lib/prefix-check.sh engine/scripts/run-scenario.sh engine/scripts/dispatch-swarm.sh engine/scripts/apply-scenario.sh", "exitCode": 0, "observation": "All clean, no warnings."},
      {"command": "PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-mvalid bash engine/scripts/cluster-up.sh && kubectl config current-context && PROVIDER=minikube CLUSTER_NAME=chart-test-swarm-mvalid bash engine/scripts/cluster-down.sh", "exitCode": 0, "observation": "Profile created in 37s, active context = chart-test-swarm-mvalid, teardown exit 0 in 8s, minikube profile list returned no chart-test-swarm-* entries afterward."},
      {"command": "PROVIDER=kind CLUSTER_NAME=notprefixed bash engine/scripts/cluster-up.sh", "exitCode": 1, "observation": "Exit 1 in <1s; stderr contained 'chart-test-swarm-'; kind get clusters showed no 'notprefixed' entry."},
      {"command": "for f in examples/sample-product-chart/chart-test/scenarios/*.yaml; do jsonschema -i \"$f\" engine/templates/scenario.schema.json && echo OK $f; done", "exitCode": 0, "observation": "All 5 pre-mission scenarios still validate (no regression from provider enum change)."}
    ],
    "interactiveChecks": [
      {"action": "kind get clusters && minikube profile list -o json | jq -r '.valid[].Name' && docker ps --filter name=chart-test-swarm-", "observed": "No chart-test-swarm-* entries in any source; no residual containers."}
    ]
  },
  "tests": {
    "added": [
      {
        "file": "engine/scripts/tests/cluster-up.bats",
        "cases": [
          {"name": "cluster-up with PROVIDER=minikube creates chart-test-swarm-* profile and sets context", "description": "Spin up a chart-test-swarm-up1 minikube profile, assert profile list contains it and current context equals it."},
          {"name": "cluster-up rejects unprefixed CLUSTER_NAME for kind", "description": "PROVIDER=kind CLUSTER_NAME=evil exits 1 with stderr containing chart-test-swarm- and no kind cluster created."},
          {"name": "cluster-up rejects unprefixed CLUSTER_NAME for minikube", "description": "PROVIDER=minikube CLUSTER_NAME=evil exits 1 with stderr containing chart-test-swarm-."},
          {"name": "cluster-up rejects bare prefix with no suffix", "description": "CLUSTER_NAME=chart-test-swarm exits 1; only chart-test-swarm-<id> is accepted."},
          {"name": "cluster-up default CLUSTER_NAME matches ^chart-test-swarm-[a-z0-9-]+$", "description": "When CLUSTER_NAME is unset, the script's defaulted name conforms to the prefix regex."},
          {"name": "cluster-up does not mutate user's pre-existing kubeconfig context", "description": "Record current context before, assert it is restored or new chart-test-swarm-* context is appended, not overwriting unrelated contexts."}
        ]
      },
      {
        "file": "engine/scripts/tests/cluster-down.bats",
        "cases": [
          {"name": "cluster-down idempotent for minikube", "description": "Tear down a chart-test-swarm-d1 minikube twice; second call exits 0."},
          {"name": "cluster-down refuses non-prefixed names", "description": "PROVIDER=kind CLUSTER_NAME=user-cluster exits 1 with prefix message; kind get clusters unchanged."}
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- The change requires touching `engine/skills/chart-test-swarm/SKILL.md` or `references/workflow.md` beyond trivial path updates.
- You need a `cluster.preinstall` kind beyond `helm` or `raw_manifest`.
- Bash 3.2 compatibility blocks an implementation and rewriting with portable idioms is non-trivial.
- A `chart-test-swarm-*` cluster from a prior failed run is stuck and you cannot tear it down.
