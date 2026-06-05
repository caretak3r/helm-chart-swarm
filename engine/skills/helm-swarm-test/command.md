# /helm-swarm-test

Run the full agentic test lifecycle against ANY Helm chart: verify
prerequisites, spin up a cluster, discover all support-matrix scenarios,
run each one, auto-fix failures in flight, progressively rebuild the
dashboard so you watch the PASS rate climb, print a summary, and tear
down the cluster.

This command is a **wrapper** (command → agent → skill). It invokes the
`helm-swarm-test` skill, which wraps the `chart-test-swarm test` CLI.

## Usage

```
/helm-swarm-test [--project-dir <dir>] [--suite <tag>] [--no-fix]
                 [--max-fix-attempts <N>] [--backend <provider>]
                 [--keep-cluster] [--rebuild-interval <N>]
```

All flags are passed through to `chart-test-swarm test`. The most common
invocations are:

| Command | What it does |
|---|---|
| `/helm-swarm-test` | Full matrix against the current directory |
| `/helm-swarm-test --project-dir <path>` | Target a specific chart project |
| `/helm-swarm-test --suite curated-live` | Run a specific scenario suite |
| `/helm-swarm-test --no-fix` | Run and report only; no editing |
| `/helm-swarm-test --keep-cluster` | Leave the cluster up after completion |

## Target resolution

The target chart project is resolved in this order:

1.  `--project-dir` flag (highest priority)
2.  `PROJECT_DIR` environment variable
3.  Current working directory (default)

The resolved directory must contain a `chart-test-swarm.yaml`
configuration file and a populated `chart-test/scenarios/` catalog
(or a `scenarios_dir` override in the config).

## Modes

### Default — Interactive agent-as-LLM

The recommended mode when running inside an AI agent. The agent brings
up the cluster, runs the matrix without auto-fixing, then iterates
through open recommendations applying chart-only edits and re-running
scenarios one at a time:

1.  `chart-test-swarm test --no-fix --keep-cluster`
2.  For each open chart-fix recommendation:
    - Read the fix prompt from `reports/fixes/<rec-id>/.fix-prompt.json`
    - Apply the edit to the chart directory only
    - `chart-test-swarm run -s <scenario>.yaml`
    - `chart-test-swarm dashboard`
3.  Tear down the cluster (unless explicitly kept)

### Headless / CI

Set `CTS_LLM_CMD` to a non-interactive agent and run the full loop in
one shot:

```bash
export CTS_LLM_CMD="<your-agent-cli>"
chart-test-swarm test
```

The CLI auto-fixes with no human intervention. All fixes are bounded by
`--max-fix-attempts` (default: 2) and restricted to the chart directory.

## Key flags (from chart-test-swarm test --help)

| Flag | Default | Description |
|---|---|---|
| `--suite NAME` | (all) | Suite tag filter |
| `--max-fix-attempts N` | 2 | Max LLM fix attempts per failing scenario |
| `--no-fix` | off | Run and report only; never invoke LLM |
| `--rebuild-interval N` | 5 | Rebuild dashboard every N scenarios |
| `--parallelism N` | 1 | Concurrent scenarios for plain runs |
| `--cluster-name NAME` | chart-test-swarm-default | Cluster name |
| `--backend PROVIDER` | kind | kind \| minikube \| k3d |
| `--keep-cluster` | off | Skip teardown at the end |
| `--project-dir DIR` | cwd | Consumer chart project root |
| `--reports-dir DIR` | auto | Reports root override |

## Install

Copy this file into your tool's commands directory. No absolute paths
or machine-specific configuration is required — the skill resolves
everything relative to the chart project being tested.

### Droid
```bash
cp command.md ~/.factory/commands/helm-swarm-test.md
```

### Claude Code
```bash
cp command.md ~/.claude/commands/helm-swarm-test.md
```

### Other tools (opencode, gemini, etc.)
Copy `command.md` into whatever directory your tool uses for custom
slash commands. The file is self-contained and references the skill
by name (`helm-swarm-test`) — no other files are required.
