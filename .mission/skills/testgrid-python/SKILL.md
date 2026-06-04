---
name: testgrid-python
description: Author and modify the testgrid Python package (collect, render, dashboard, pyproject, pytest harness, jinja templates) with strict typing, lint, and unit tests.
---

# testgrid-python

NOTE: Startup and cleanup are handled by `worker-base`. This skill defines the WORK PROCEDURE for testgrid-python workers.

## Required Skills and Tools

- `bd` (beads) — resolve issue ID with `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id')` then claim with `bd update "$BD_ID" --claim` at start; close with `bd close "$BD_ID"` before handoff.
- `uv` — all Python commands MUST be run via `uv run --directory engine/testgrid <cmd>`. Never run a system `python3`.
- `pytest` (>= 8) — unit + integration tests live under `engine/testgrid/tests/`.
- `mypy --strict` — type-checking gate; must pass on `src/testgrid` after every change.
- `ruff` — formatter + linter; `ruff check` and `ruff format --check` must be clean.
- `jinja2` + `jinja2-stubs` — for dashboard templates under `engine/testgrid/src/testgrid/templates/`.
- `pyyaml` + `types-PyYAML` — YAML parsing.
- `agent-browser` — when rendering the dashboard, open the produced `reports/run-*/dist/index.html` and visually verify the cards, anchors, and matrix layout.
- Mission boundaries from `{missionDir}/AGENTS.md`.

## Work Procedure

1. **Claim and read.**
   - `BD_ID=$(bd list --label feature-id:<feature-id> --json | jq -r '.[0].id // .issues[0].id') && bd update "$BD_ID" --claim`.
   - Read the feature's `description`, `preconditions`, `expectedBehavior`, and `fulfills` array from `{missionDir}/features.json`.
   - For each ID in `fulfills`, read the full assertion in `{missionDir}/validation-contract.md`. Your tests + code must make every one PASS.
   - Read the relevant existing module (`collect.py`, `render.py`, `cli.py`, `templates/`) before changing it.

2. **Write the failing pytest tests first (red).**
   - Place new tests under `engine/testgrid/tests/test_<feature>.py`.
   - Cover each `expectedBehavior` bullet with at least one test case.
   - Use real fixture inputs (synthetic `reports/run-*/result.yaml` files) rather than mocking `pathlib.Path`. Create fixtures in a `tmp_path` directory.
   - Run `uv run --directory engine/testgrid pytest tests/test_<feature>.py -v` and confirm tests fail for the right reason.

3. **Implement the change.**
   - Modify `engine/testgrid/src/testgrid/` modules.
   - Use `pathlib.Path`, not string path concatenation.
   - Type-hint every module-level function; `Optional`, `Mapping`, `Sequence` from `typing` rather than concrete `dict`/`list` in signatures when applicable.
   - For jinja templates, keep template logic minimal — push computation into Python and pass plain dicts to templates.
   - For F2.x dashboard features, manually open the rendered HTML in `agent-browser` and verify cards render with all expected anchors, matrix cells, and variant badges before declaring done.

4. **Verify locally (manual).**
   - `uv run --directory engine/testgrid pytest tests/ -v` — all green.
   - `uv run --directory engine/testgrid mypy src/testgrid` — clean (`--strict` mode).
   - `uv run --directory engine/testgrid ruff check src/testgrid tests/` — clean.
   - `uv run --directory engine/testgrid ruff format --check src/testgrid tests/` — clean.
   - If dashboard touched: `bash engine/scripts/build-dashboard.sh` against `reports/` containing at least one mock run, then open `reports/run-*/dist/index.html` in agent-browser and visually verify.

5. **Run the worker-scoped gates.**
   - The four `uv run` commands above (`pytest`, `mypy`, `ruff check`, `ruff format --check`).
   - If you touched any `.yaml` (e.g. mock fixtures): `yamllint <file>`.
   - DO NOT run the full `commands.test` set — that is the scrutiny validator's job.

6. **Cluster + process hygiene at handoff.**
   - Even though this skill rarely touches clusters, run `kind get clusters` and `minikube profile list -o json | jq -r '.valid[].Name'` and verify no `chart-test-swarm-*` residue. Tear down anything you created.
   - No `pytest` background processes; no jupyter or watch-mode servers.

7. **Commit and close.**
   - Commit on the worker branch.
   - `bd close "$BD_ID"`.

## Example Handoff

```json
{
  "salientSummary": "Implemented F2.1 per-scenario artifact links in the dashboard: extended collect.py to expose per-scenario artifact paths, threaded them through render.py + the jinja card template, and verified visually via agent-browser. Ran pytest (28 cases, all green), mypy --strict clean, ruff check clean, and inspected rendered HTML in agent-browser.",
  "whatWasImplemented": "Extended testgrid.collect.ScenarioRecord with an `artifact_links: dict[str, Path]` field populated from each run's artifacts/ tree (scenario.yaml, applied-overrides.yaml, fixtures/, manifests/, versions.json). Updated render.py to pass artifact_links into the jinja context. Added the anchor list to templates/scenario_card.html.j2 with stable selectors a[data-artifact='scenario'|'overrides'|'fixtures'|'manifests'|'versions']. Added 14 pytest cases covering missing-artifact graceful degradation, multi-run aggregation, and HTML output assertions.",
  "whatWasLeftUndone": "",
  "verification": {
    "commandsRun": [
      {"command": "uv run --directory engine/testgrid pytest tests/test_dashboard_artifacts.py -v", "exitCode": 0, "observation": "14 tests passing in 1.2s."},
      {"command": "uv run --directory engine/testgrid pytest tests/ -v", "exitCode": 0, "observation": "All 42 testgrid tests green."},
      {"command": "uv run --directory engine/testgrid mypy src/testgrid", "exitCode": 0, "observation": "Success: no issues found in 6 source files (strict mode)."},
      {"command": "uv run --directory engine/testgrid ruff check src/testgrid tests/", "exitCode": 0, "observation": "All checks passed."},
      {"command": "uv run --directory engine/testgrid ruff format --check src/testgrid tests/", "exitCode": 0, "observation": "9 files already formatted."},
      {"command": "bash engine/scripts/build-dashboard.sh", "exitCode": 0, "observation": "Built dashboard for 3 runs; produced reports/run-*/dist/index.html (4.1 KB)."}
    ],
    "interactiveChecks": [
      {"action": "Open reports/run-<latest>/dist/index.html in agent-browser; click each scenario card's artifact anchor (scenario, overrides, fixtures, manifests, versions); verify all five resolve and the target files render.", "observed": "All 5 anchors per card resolved to existing files; URL bar showed file:// path to artifacts/scenario.yaml etc.; no console errors."}
    ]
  },
  "tests": {
    "added": [
      {
        "file": "engine/testgrid/tests/test_dashboard_artifacts.py",
        "cases": [
          {"name": "test_artifact_links_populated_from_run_dir", "description": "Given a synthetic reports/run-X/artifacts/ with all 5 expected files, collect produces a ScenarioRecord whose artifact_links has 5 keys with absolute Paths to those files."},
          {"name": "test_artifact_links_missing_file_yields_none", "description": "If applied-overrides.yaml is missing for a run, artifact_links['overrides'] is None and the card renders no overrides anchor (selector check)."},
          {"name": "test_render_emits_stable_anchor_selectors", "description": "Rendered HTML contains a[data-artifact='scenario'], a[data-artifact='overrides'], a[data-artifact='fixtures'], a[data-artifact='manifests'], a[data-artifact='versions'] for every PASS card."},
          {"name": "test_multi_run_aggregation_keeps_per_run_artifact_isolation", "description": "Two runs in the same reports/ tree produce cards whose anchors point to their own run-id artifacts dir, not the latest run's."}
        ]
      }
    ]
  },
  "discoveredIssues": []
}
```

## When to Return to Orchestrator

In addition to the standard cases:
- A required dependency (`jinja2-stubs`, `types-PyYAML`) is not in `pyproject.toml` AND your feature didn't add it.
- The dashboard template logic requires a new templating engine or major refactor of `render.py`.
- A new artifact type needs to be added to `artifacts/` and the contract for it isn't documented yet.
