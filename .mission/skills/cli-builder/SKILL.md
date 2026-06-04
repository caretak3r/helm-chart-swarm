---
name: cli-builder
description: Build the `chart-test-swarm` Typer CLI subcommands (run, dashboard, list integrations, list variants) wrapping the bash engine + testgrid python with consistent UX, typed args, and pytest coverage.
---

# cli-builder

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for cli-builder workers (Milestone 9).

## Required Skills and Tools

- `bd` (beads).
- `uv` — Python work in `engine/testgrid/`; CLI lives alongside testgrid as an additional console script.
- `typer` (>= 0.12) — for the CLI; subcommands are typer apps.
- `pytest` — unit tests for each subcommand using `typer.testing.CliRunner`.
- `mypy --strict`, `ruff` — same as testgrid-python skill.
- `kind`, `kubectl`, `helm` — for the `run` subcommand's end-to-end tests.
- `agent-browser` — for the `dashboard` subcommand: open the built HTML and verify.
- Mission boundaries from `{missionDir}/AGENTS.md`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, `fulfills` from `{missionDir}/features.json`.
   - Read every assertion ID in `fulfills` from `{missionDir}/validation-contract.md`. Pay close attention to CLI assertions VAL-CLI-001 through VAL-CLI-024.
   - Read existing `engine/testgrid/pyproject.toml`, `cli.py`, and (post-F9.1) the `chart_test_swarm/` package layout.

2. **Write failing pytest tests first (red).**
   - Place tests under `engine/testgrid/tests/test_cli_<subcommand>.py`.
   - Use `typer.testing.CliRunner` for synchronous tests of arg parsing, help text, exit codes, and stdout/stderr capture.
   - For `run` subcommand: invoke via subprocess against a real kind cluster fixture or use a `--dry-run` flag that emits the underlying `bash engine/scripts/dispatch-swarm.sh ...` invocation as JSON without running it.
   - For `list integrations`: use a tmp_path fixture with synthetic category dirs + primer files; assert deterministic sorted output of the expected category set.
   - Run `uv run --directory engine/testgrid pytest tests/test_cli_<subcommand>.py -v` and confirm failure for the right reason.

3. **Implement the subcommand.**
   - Add `chart_test_swarm` (or whatever the CLI package is named in F9.1) as a typer app entry point in `pyproject.toml` under `[project.scripts]`.
   - Use typer's nested-app pattern: `app = typer.Typer()`; `list_app = typer.Typer()`; `app.add_typer(list_app, name="list")`.
   - For subcommands that wrap bash scripts (`run` → `dispatch-swarm.sh`, `dashboard` → `build-dashboard.sh`), forward args explicitly — do NOT just exec into the bash with all argv. Type-check every option.
   - Every subcommand has `--help` that emits a clean usage block.
   - Cluster name prefix enforcement: any CLI argument that ultimately becomes a cluster name MUST pass the `^chart-test-swarm-[a-z0-9-]+$` regex check at the CLI layer (defense-in-depth on top of the engine script enforcement).
   - For `list integrations` (F9.4): walk `engine/skills/chart-test-swarm/references/integrations/<category>/` and emit one row per category. Sorted output. Exit non-zero if zero categories are found.

4. **Verify locally (manual).**
   - `uv run --directory engine/testgrid pytest tests/test_cli_<subcommand>.py -v` — all green.
   - `uv run --directory engine/testgrid mypy src/chart_test_swarm src/testgrid` — clean.
   - `uv run --directory engine/testgrid ruff check src/chart_test_swarm src/testgrid tests/` — clean.
   - `uv run --directory engine/testgrid ruff format --check src/chart_test_swarm src/testgrid tests/` — clean.
   - End-to-end: `uv run --directory engine/testgrid chart-test-swarm --help` shows your subcommands; `chart-test-swarm <sub> --help` shows args.

5. **For F9.2 `run` subcommand: real end-to-end smoke.**
   - Run `chart-test-swarm run --scenario examples/sample-product-chart/chart-test/scenarios/minimal.yaml` against a `chart-test-swarm-clismoke` kind cluster.
   - Verify exit 0, `reports/run-*/result.yaml` PASS, and cluster torn down afterward.

6. **For F9.3 `dashboard` subcommand:**
   - `chart-test-swarm dashboard` — builds dashboard.
   - Open `reports/run-<latest>/dist/index.html` in `agent-browser` and verify content rendered.

7. **For F9.4 `list integrations`:**
   - `chart-test-swarm list integrations` — exactly 6 lines (sorted): `certificates`, `cloud-native`, `gateway-api`, `ingress-controllers`, `policy`, `service-mesh`.
   - `chart-test-swarm list variants --category certificates` — emits the scenario YAMLs under chart-test/scenarios that match the category by primer reference.

8. **Worker-scoped gates.**
   - `uv run --directory engine/testgrid pytest tests/test_cli_*.py -v`.
   - `uv run --directory engine/testgrid mypy src/chart_test_swarm`.
   - `uv run --directory engine/testgrid ruff check src/chart_test_swarm tests/`.
   - DO NOT run full repo-wide `commands.test`.

9. **Cluster + process hygiene at handoff.**
   - `kind get clusters` no `chart-test-swarm-*`.
   - No background typer/pytest processes.

10. **Commit and close.**
    - Commit on the worker branch.
    - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Implemented F9.4 `chart-test-swarm list integrations` and `list variants` subcommands. Walks engine/skills/chart-test-swarm/references/integrations/<category>/, emits the 6 expected categories sorted (certificates, cloud-native, gateway-api, ingress-controllers, policy, service-mesh). pytest tests use synthetic fixture trees plus the production tree; all 11 cases green; CLI --help verified manually.",
  "whatWasImplemented": "Added engine/testgrid/src/chart_test_swarm/commands/list_cmd.py exposing `list integrations` and `list variants`. Used typer's add_typer for nesting under the root app. Integrations walk takes a --root flag (default: <repo>/engine/skills/chart-test-swarm/references/integrations) for testability. Variants subcommand takes --category and walks chart-test/scenarios/ filtering by primer-referenced filenames. Wired both into the CLI entry point. Added a sort+dedupe guarantee and an explicit failure mode (exit 1 with a stderr message) when zero categories are found. Tests use both synthetic fixtures and the production tree to assert the exact 6-category set.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "uv run --directory engine/testgrid pytest tests/test_cli_list.py -v", "exitCode": 0, "observation": "11 tests passing in 0.3s."},
      {"command": "uv run --directory engine/testgrid mypy src/chart_test_swarm", "exitCode": 0, "observation": "Success: no issues."},
      {"command": "uv run --directory engine/testgrid ruff check src/chart_test_swarm tests/test_cli_list.py", "exitCode": 0, "observation": "All checks passed."},
      {"command": "uv run --directory engine/testgrid chart-test-swarm list integrations", "exitCode": 0, "observation": "Output (exact, sorted):\n  certificates\n  cloud-native\n  gateway-api\n  ingress-controllers\n  policy\n  service-mesh"},
      {"command": "uv run --directory engine/testgrid chart-test-swarm list integrations | awk '{print $1}' | sort -u | wc -l", "exitCode": 0, "observation": "6 — exactly the 6 expected categories present."},
      {"command": "uv run --directory engine/testgrid chart-test-swarm list variants --category certificates", "exitCode": 0, "observation": "Listed 4 cert-manager + 4 manual-tls + 4 mounted-tls scenarios (sorted by filename)."}
    ],
    "interactiveChecks": [
      {"action": "Manually invoke chart-test-swarm list integrations --help; confirm usage block is well-formatted and includes --root option documentation.", "observed": "Help text rendered correctly, includes --root description and example."}
    ]
  },
  "tests": {
    "added": [
      {
        "file": "engine/testgrid/tests/test_cli_list.py",
        "cases": [
          {"name": "test_list_integrations_emits_six_categories", "description": "Against the production integrations tree, the CLI prints exactly 6 sorted category lines."},
          {"name": "test_list_integrations_synthetic_fixture", "description": "Given a tmp_path with 2 category dirs and 1 stray file, output contains the 2 categories sorted, ignores the stray file."},
          {"name": "test_list_integrations_zero_categories_exits_nonzero", "description": "Given an empty --root, exit 1 with stderr containing 'no integrations found'."},
          {"name": "test_list_variants_filters_by_category", "description": "chart-test-swarm list variants --category certificates emits only scenarios whose filename matches the cert-manager / manual-tls / mounted-tls primer variants."}
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- A subcommand needs to wrap a bash script that isn't in `engine/scripts/` yet.
- Typer's behavior collides with a required CLI arg shape (e.g. mutually exclusive flags that typer doesn't natively support).
- The CLI needs to spawn a long-running subprocess and you cannot guarantee cleanup.
