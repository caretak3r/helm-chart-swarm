# CLAUDE.md — chart-test-swarm

Instructions and context for AI agents working on this repo. Read this before
touching anything; the design choices below are enforced by CI and by review.

## What this is

**chart-test-swarm** is a swarm-test framework for product Helm charts. It
validates a chart against many customer-shaped cluster scenarios — preinstalled
addons (gatekeeper, cert-manager, istio, kyverno, …), subchart combinations,
cluster flavors — on every PR, nightly, and customer regression. The pattern was
lifted from the HIP-0025 swarm harness and generalized so any product chart can
plug in.

The product being shipped is twofold:
1. **The engine** — bash orchestration + assertion primitives + a Python
   dashboard/CLI (`testgrid`) that consumers vendor or check out.
2. **The onboarding surface** — CI templates (`engine/templates/ci/`) and a
   Claude skill (`engine/skills/chart-test-swarm/`) that let a consumer chart
   repo adopt the whole harness in minutes. Treat these as product, not
   internals: a broken template ships breakage to every consumer.

## Architecture map

```
engine/
├── scripts/     12 entry scripts: cluster-up/down, run-scenario, dispatch-swarm,
│                aggregate, build-dashboard, sweep-scenarios, verify, orphan-audit…
│   └── lib/     prefix-check.sh — shared cluster-name guard + RUN_ID slug
├── asserts/     31 assertion runners, tagged with a depth ladder (# DEPTH: L0-L3)
│   ├── registry.yaml   declared depth per assert type — enforced by sweep
│   └── lib/     assert-helpers.sh (wait_with_backoff, selector_for_release,
│                anchored HTTP parsing)
├── templates/   scenario.schema.json, agent-brief, consumer CI templates
├── testgrid/    Python (typer + uv): dashboard build, collect, catalog, fix loop
└── skills/chart-test-swarm/
    └── engine/  VENDORED COPY of engine/ — never edit by hand (see below)

examples/sample-product-chart/   reference consumer: chart + chart-test/ scenarios
docs/            spec, scenario authoring, CI integration, phase plans, evidence
```

A **scenario** = one YAML file: cluster shape + addons + chart values +
assertions + suite tags. Suites are tag filters: `pr-subset`, `nightly-full`,
`customer-replica`, `curated-live`.

Execution: `dispatch-swarm.sh <project> <suite> <n> <run-id> --run` resolves the
suite, runs each scenario on a fresh kind cluster (concurrency-safe names:
`chart-test-swarm-<run-id-slug>-<idx>`), writes per-scenario `result.yaml`, then
`aggregate.sh` rolls up CSV + dashboard and **exits non-zero on any unexpected
FAIL/PARTIAL** — that exit code is the CI contract.

## Design philosophy (these are load-bearing, not suggestions)

1. **Never false-green.** The worst bug this project ever had was `test`
   reporting PASS while running nothing. Results must come from artifacts
   (`result.yaml`), not from exit-code accidents. `aggregate.sh` is
   strict-by-default; a FAIL fails the job unless the scenario is explicitly
   tagged `expected-fail`. If you find a path that can report success without
   evidence, that is a P0.
2. **Never weaken a gate to get green.** Do not relax a linter, skip a test,
   loosen `prefix-check.sh`, or add a suppression to make CI pass. Fix the code.
   Tests that assert on failure behavior must be able to actually fail
   (beware: bats' `set -e` ignores `!`-negated commands — use positive count
   assertions).
3. **Invocation-scoped side effects.** Anything you create, you record and you
   clean up — by exact name, never by pattern. Cluster cleanup deletes only
   names recorded in `_CREATED_CLUSTERS`; a developer's cluster or a concurrent
   run's clusters must survive. `orphan-audit.sh` and `init.sh` are the only
   deliberate global sweepers, and they are user-invoked.
4. **`prefix-check.sh` is a safety net, not an obstacle.** Every cluster name
   must match `^chart-test-swarm-[a-z0-9-]+$`. If a caller produces an invalid
   name, fix the caller.
5. **One canonical source.** `engine/skills/chart-test-swarm/engine/` is a
   byte-for-byte vendored copy synced by `sync-engine.sh`. Edit `engine/`, run
   the sync, commit both. CI's bundle-drift gate enforces parity.
6. **Hermetic by default.** The bats suites stub `kind`/`docker`/network; tests
   needing a real cluster are gated behind `CTS_BATS_REAL_CLUSTERS=1`. New tests
   follow this or they don't merge.
7. **SKIP is honest, not free.** SKIP is non-failing, but only acceptable when a
   capability genuinely cannot run (and the justification is recorded per
   scenario). Depth levels (L0 render → L3 behavioral) are declared in
   `registry.yaml` and enforced — an assert must not claim more depth than it
   proves.
8. **Evidence over claims — for agents too.** Sealed-suite runs, fixes, and
   closures cite artifacts (result.yaml, CI run links, commit SHAs) in bead
   notes. "Should be fine" is not a status.

## Build & test

```bash
make verify                          # engine preflight (bash>=4 required — macOS /bin/bash 3.2 will not work)
bats -r engine/scripts/tests         # hermetic shell suite (~450 tests)
bats -r engine/asserts/tests         # assert runner suites
uv run --directory engine/testgrid pytest   # Python suite (~1000 tests)
uv run --directory engine/testgrid mypy src && uv run --directory engine/testgrid ruff check
shellcheck engine/scripts/*.sh engine/scripts/lib/*.sh engine/asserts/*.sh engine/skills/chart-test-swarm/scripts/*.sh init.sh
engine/skills/chart-test-swarm/scripts/sync-engine.sh --check   # bundle drift
```

CI (`engine-ci.yml`): 7 parallel gates — bats, pytest, mypy, ruff, shellcheck
(pinned 0.11.0), helm lint, bundle drift — on `ubuntu-latest` ONLY (GitHub's
macOS runners ship bash 3.2; a mac leg fails for reasons that say nothing about
the code). `template-dogfood.yml` additionally runs the shipped consumer CI
template end-to-end on real kind clusters whenever templates or engine scripts
change. `pages.yml` publishes the dashboard.

Run one scenario locally:
```bash
bash engine/scripts/run-scenario.sh examples/sample-product-chart/chart-test/scenarios/capability/minimal.yaml
```

## Conventions

- Conventional Commits (`fix|feat|test|chore|docs|ci|perf|refactor`), bead id in
  the subject when applicable (e.g. `(7t1)`).
- Squash-merge only (repo setting); PRs against `main`; never force-push.
- Stage explicit paths — never `git add -A` (the tree accumulates untracked run
  artifacts by design).
- Python: uv-managed, mypy --strict, ruff (check + format). Shell: bash>=4,
  shellcheck-clean, existing style (`_snake_case` locals, `set -euo pipefail`).
- Public repo: a push is a publish. Scan anything that looks like a credential
  before it leaves your machine (kind CA certs and the sample chart's own Helm
  release Secret are known-benign).

## What to strive for (roadmap north stars)

Tracked as beads under the project-foundation epic (`bd show` the epic for ids):
- **Automated releases** — tag-driven GitHub Releases with changelog + versioned
  skill-bundle artifact, so consumers pin `ENGINE_REF` to real releases.
- **Documentation website** — Nextra site on GitHub Pages: getting started,
  scenario authoring, CI integration, architecture with diagrams.
- **One canonical spec** — reconcile the WS spec + phase plans into a current
  spec with mermaid diagrams (component map, scenario lifecycle, depth ladder);
  kill stale claims.
- Keep this file truthful: when a design choice changes, update it in the same PR.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
