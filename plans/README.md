# Improvement plans — P0 track

Self-contained implementation plans produced by a read-only advisor audit.
Each plan is written for an executor with **zero context from the audit
session**: all file paths, code excerpts, conventions, and verification
commands are inlined. Do not assume knowledge that isn't in the plan file.

- **Written against commit:** `bfa3941` (branch `mission/universal-chart-matrix-p1`)
- **Beads issues:** each plan maps to one `bd` issue (id in the plan header).
- **Drift check:** before starting a plan, run `git rev-parse --short HEAD`.
  If it differs from `bfa3941`, re-read the cited excerpts against the current
  file; if the cited code has moved or changed materially, STOP and report.

## Verification gates (every plan runs the relevant subset)

```bash
# Python (from repo root)
uv run --directory engine/testgrid pytest -n 2
uv run --directory engine/testgrid mypy src/testgrid src/chart_test_swarm
uv run --directory engine/testgrid ruff check src/testgrid src/chart_test_swarm

# Shell
bats engine/scripts/tests engine/asserts/tests
shellcheck engine/scripts/*.sh engine/asserts/*.sh
```

There is **no CI** enforcing these today (that is a separate P1 issue,
`chart-test-swarm-8xi`). Until it lands, the executor MUST run the gates
locally before declaring a plan done.

## Plans in this track

| # | File | Bead | Title | Effort | Depends on |
|---|------|------|-------|--------|-----------|
| 001 | `001-test-executes-scenarios.md` | `chart-test-swarm-iab` | `chart-test-swarm test` actually runs scenarios (stop reporting false PASS) | S | — |
| 002 | `002-deeval-probe-asserts.md` | `chart-test-swarm-bj7` | Remove host `eval`/`source` of scenario-derived values in probe asserts | M | — |
| 003 | `003-gate-llm-fix-loop.md` | `chart-test-swarm-998` | Gate + constrain the LLM fix loop's write-then-execute path | M | — |

## Recommended execution order

1. **001 first** — smallest, unblocks honest end-to-end signal; nothing else
   depends on it but everything benefits from `test` actually working.
2. **002 and 003 in parallel** — disjoint files (002 is `engine/asserts/**`,
   003 is `engine/testgrid/src/chart_test_swarm/commands/fix_cmd.py` +
   `recommendations.py`). Both are security refactors; each contains a
   **Design options** section — pick the option, record the choice in the
   bead, then implement.

Plans 002 and 003 both carry a follow-on bead not in this track:
`chart-test-swarm-dij` (fence untrusted failure detail in the LLM prompt)
is blocked-by 003 and should be done immediately after it.

## Status

| Plan | Status | Notes |
|------|--------|-------|
| 001 | TODO | |
| 002 | TODO | design option not yet chosen |
| 003 | TODO | design option not yet chosen |
