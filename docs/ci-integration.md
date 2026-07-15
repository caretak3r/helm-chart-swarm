# CI integration

The engine ships two ready-to-copy GitHub Actions workflow templates:

| Template | When | Suite | Wall-clock cap |
|----------|------|-------|----------------|
| `engine/templates/ci/github-pr.yml`      | every PR touching `chart/**` or `chart-test/**` | `pr-subset`    | 20 min |
| `engine/templates/ci/github-nightly.yml` | nightly cron + manual dispatch                  | `nightly-full` | 90 min |

## Wiring it up

1. Pin a release of `chart-test-swarm` (e.g. `v0.1.0`) — the templates
   reference it via `ENGINE_REPO` + `ENGINE_REF`.
2. Copy both templates into your chart repo's `.github/workflows/`.
3. Edit `ENGINE_REPO` to point at your fork / mirror.
4. Make sure `chart-test/scenarios/` and `chart-test-swarm.yaml` exist
   in your chart repo (see `scenario-authoring.md`).
5. Commit + open a PR — the `pr-subset` workflow exercises itself.

## How the CI runner differs from local

Locally, `make swarm` dispatches **briefs** for you to hand to multiple
Claude agents in parallel. In CI there are no agents — the workflow
falls back to a **single serial executor** that:

1. Calls `dispatch-swarm.sh` to write the snapshot + briefs (for trace).
2. Iterates every scenario in the suite and runs `run-scenario.sh`
   directly.
3. Synthesizes `agent-1/result.yaml` from the per-scenario results.
4. Calls `aggregate.sh` to produce `scenario-matrix.csv` +
   `lessons-learned.md` + dashboard.
5. Uploads the dashboard as a workflow artifact (and on nightly,
   publishes to `gh-pages`).

The brief artifacts still exist for diagnostic value — but the actual
work is serial.

## Publishing the dashboard

`github-nightly.yml` uses `peaceiris/actions-gh-pages@v3` to push the
generated dashboard to the `gh-pages` branch with `keep_files: true`,
so every nightly's dashboard stays available under
`https://<org>.github.io/<repo>/run-<id>/`.

The PR template uploads dashboards as workflow artifacts only (no
public publishing) — comment a link to the artifact from PR-bot if
you want reviewers to see it inline.

## Secrets

Scenarios are checked into source — never put credentials there.
Two patterns:

- **Fixtures from secrets**: have CI write a values-override file from
  a secret before dispatch. The scenario references that file via
  `product.values`.
- **`--set` in scenario**: for non-secret overrides (image tags,
  feature flags) — keep them in the scenario YAML itself.

## When to fail the CI job

Default: any `FAIL` or `PARTIAL` scenario fails the workflow. `aggregate.sh`
enforces this — it writes the CSV and dashboard, then exits non-zero if any
scenario failed. The shipped `github-pr.yml` / `github-nightly.yml` templates
end on `aggregate.sh`, so a failing scenario fails the job with no extra wiring.

To exempt a transitional scenario you haven't fixed yet, tag it `expected-fail`
in its scenario YAML:

```yaml
tags: [pr-subset, expected-fail]
```

A `FAIL` on an `expected-fail` scenario is reported but does not fail the job;
any other `FAIL`/`PARTIAL` still does. To see every result without failing the
job (report-only), set `CTS_AGGREGATE_STRICT=0` in the aggregate step's env.
