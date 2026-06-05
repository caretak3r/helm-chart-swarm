---
name: helm-swarm-test
description: |
  Run the full agentic test lifecycle against ANY Helm chart. Wraps the
  `chart-test-swarm test` CLI to orchestrate verify → cluster up →
  discover support-matrix scenarios → run each → auto-fix FAILs in flight
  → progressive dashboard updates → summary → teardown. Use when the user
  invokes `/helm-swarm-test`, asks to "run the whole test matrix and fix
  failures", "validate this chart end-to-end", or wants a one-command
  full-loop chart validation.
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob]
---

# helm-swarm-test

Portable, LLM-agnostic skill that orchestrates the complete chart-test
lifecycle against **any Helm chart** as a single command. It wraps the
[`chart-test-swarm test`](#chart-test-swarm-test-cli) CLI, which handles
the programmatic loop (cluster lifecycle, scenario dispatch, dashboard
rebuilds), while this skill provides the agent-with-file-tools
interactive fix mode.

## Chart resolution

The target chart is resolved **generically** — never hardcoded:

| Precedence | Mechanism |
|---|---|
| 1 (highest) | `--project-dir DIR` flag passed through to the CLI |
| 2 | `PROJECT_DIR` environment variable |
| 3 (default) | Current working directory (must contain `chart-test-swarm.yaml`) |

The resolved project must contain a valid `chart-test-swarm.yaml`
configuration and a populated `chart-test/scenarios/` directory (or a
`scenarios_dir` override in the config). The skill works with **any**
chart that follows this layout — no project-specific paths or names are
embedded.

## When to invoke

- `/helm-swarm-test` — run the full matrix against the default project
- `/helm-swarm-test --project-dir <path>` — target a specific chart
- `/helm-swarm-test --suite <tag>` — run a specific scenario suite
- `/helm-swarm-test --no-fix` — run-and-report only (no editing)
- User says "run the whole test matrix", "validate this chart
  end-to-end", "test everything and fix what fails", "helm swarm test"

## When NOT to invoke

- User wants to generate NEW scenarios → use `/chart-test-swarm new`
  (the sibling generative skill)
- User wants to run a single scenario without fixes →
  `chart-test-swarm run -s <scenario>`
- User wants to open the dashboard only → `chart-test-swarm dashboard`
- The project has no `chart-test-swarm.yaml` or no scenarios → scaffold
  with `/chart-test-swarm init` first

## Full lifecycle loop

The skill runs this end-to-end loop, wrapping the `chart-test-swarm test`
CLI:

```
VERIFY  →  check prerequisites (kind, kubectl, helm, yq, jq, uv)
  │
CLUSTER UP  →  spin up a local kind cluster (or k3d/minikube)
  │
DISCOVER  →  enumerate all scenarios from the support-matrix catalog
  │            (chart-test/scenarios/ or chart-test-swarm.yaml override)
  │
RUN EACH SCENARIO  →  iterate through the catalog in order
  │   ├─ PASS → record, continue to next scenario
  │   └─ FAIL → enter the fix sub-loop (see below)
  │
DASHBOARD  →  progressive rebuild every N scenarios (default: 5)
  │            so you watch the PASS rate climb in real time
  │
SUMMARY  →  total/PASS/FAIL/fixed/open + dashboard path printed to stdout
  │
TEARDOWN  →  cluster destroyed (unless --keep-cluster)
```

The fix sub-loop (for each FAIL scenario, when not `--no-fix`):

```
FAIL scenario
  │
  ├─ Generate fix prompt (the CLI writes a structured prompt to
  │   reports/fixes/<rec-id>/.fix-prompt.json or recommendations.json)
  │
  ├─ Apply chart-only edit (agent file tools, restricted to the chart
  │   directory — see "Fix discipline" below)
  │
  ├─ Re-run the scenario via chart-test-swarm run -s <scenario>
  │
  ├─ PASS after fix → mark recommendation "fixed", continue to next scenario
  │
  └─ Still FAIL → retry up to --max-fix-attempts (default: 2);
       if all attempts exhausted → mark recommendation "open", continue
```

## Modes

### Mode A — Interactive agent-as-LLM (default)

This is the **recommended** mode when running the skill inside an AI
agent (Droid, Claude Code, opencode, Gemini CLI, etc.). The agent
itself acts as the LLM that reads fix prompts and applies chart edits.

**Procedure:**

1.  Run the matrix with **no external LLM** — the CLI runs, reports, and
    builds the dashboard, but does NOT attempt fixes:
    ```bash
    chart-test-swarm test --no-fix --keep-cluster
    ```
    (The cluster stays up so we can re-run scenarios after fixing.)

2.  Inspect the results. For each **open** `chart-fix` recommendation:
    a.  Read the fix prompt from
        `reports/fixes/<rec-id>/.fix-prompt.json` or
        `reports/recommendations.json`.
    b.  Apply the suggested edit using your own file-editing tools
        (**chart directory only** — see "Fix discipline").
    c.  Re-run that scenario:
        ```bash
        chart-test-swarm run -s <scenario.yaml> --keep-cluster
        ```
        (Use `-s` for a single-scenario re-run; pass the path to the
        specific scenario YAML that failed.)
    d.  Rebuild the dashboard so the PASS count updates:
        ```bash
        chart-test-swarm dashboard
        ```
    e.  If the re-run passes → recommendation is fixed; move to the next.
    f.  If still failing after the bounded attempts → leave it open and
        move on (never block the matrix).

3.  Tear down the cluster:
    ```bash
    kind delete cluster --name chart-test-swarm-default
    ```

    (Unless the user explicitly asks to keep the cluster for inspection.)

The `--keep-cluster` flag on the initial `test` run prevents the CLI
from tearing the cluster down after reporting — this way the cluster
stays available for the fix-and-re-run cycle.

### Mode B — Headless / CI (auto-fix)

For non-interactive environments (CI pipelines, cron jobs, scripts),
set the `CTS_LLM_CMD` environment variable to a non-interactive agent
invocation and let the CLI handle everything:

```bash
export CTS_LLM_CMD="claude -p --output-format text"
chart-test-swarm test
```

In this mode the CLI:
- Runs the full verify → cluster-up → discover → run loop
- Invokes `CTS_LLM_CMD` automatically for each FAIL scenario
- Applies the returned chart edits (chart-directory-only, path-guarded)
- Re-runs, records history, rebuilds the dashboard, tears down
- No human in the loop — the CLI is the orchestrator

The `CTS_LLM_CMD` must accept a prompt on stdin and emit structured
output that the CLI can parse (see the `chart-test-swarm fix --help`
docs for the expected format). All fix attempts are bounded by
`--max-fix-attempts` (default: 2) and logged to
`reports/fixes/<rec-id>/history.json`.

## Fix discipline

**Chart-directory-only edits.** Every fix edit — whether applied by the
agent's file tools (Mode A) or the CLI via `CTS_LLM_CMD` (Mode B) — is
restricted to the **chart directory** (`<project>/chart/`). This
boundary is enforced programmatically: file paths that escape the chart
directory are rejected. The fix workflow MUST NOT modify engine scripts,
scenario YAML files, schemas, version configs, or any other part of the
project.

**Bounded attempts.** Fix attempts per failing scenario are bounded by
`--max-fix-attempts` (default: 2). A scenario that still fails after
exhausting all attempts is left as an **open** recommendation — it
never blocks the rest of the matrix from running. Every fix attempt is
audited to `reports/fixes/<rec-id>/history.json` with timestamp, prompt,
diff, and re-run status.

## Summary

At the end of the run, the CLI prints a summary block:

```
============================================================
  TEST MATRIX COMPLETE
============================================================
  Total scenarios:    N
  PASS:               N
  FAIL:               N
  Fixed:              N
  Open:               N
  Dashboard:          reports/dist/home.html
============================================================
```

Open the dashboard (`reports/dist/home.html`) to review all results,
drill into individual run details, and see the recommendations page
with categorized failures and fix prompts.

## References

- `chart-test-swarm test --help` — full flag surface and defaults
- `chart-test-swarm run --help` — single-scenario re-run flags
- `reports/recommendations.json` — structured recommendation state
- `reports/fixes/<rec-id>/history.json` — per-recommendation fix audit trail
