## Area: Dashboard

Behavioral validation assertions for Milestone 2 (dashboard-uplift): per-scenario artifact links (F2.1), variant grouping (F2.2), cloud-platform rendering (F2.3), and multi-run aggregation safeguards (F2.4). Tested surfaces: `reports/run-*/dist/index.html` (rendered HTML opened via `file://`), the `python -m testgrid build` CLI, and the `reports/` filesystem layout.

### VAL-DASH-001: Scenario card exposes a "Scenario YAML" link
Open `reports/run-*/dist/index.html` and locate any scenario card produced from a run that has an `artifacts/` bundle. The card MUST contain a visible anchor whose accessible name is "Scenario YAML" (or equivalent label) whose `href` ends with `artifacts/scenario.yaml` for the matching scenario.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> a[href$="artifacts/scenario.yaml"]`)

### VAL-DASH-002: Scenario card exposes an "Applied Overrides" link
The same scenario card MUST contain a visible anchor labeled "Applied Overrides" whose `href` ends with `artifacts/applied-overrides.yaml`. The link MUST be present even when the overrides file is an empty document, so long as the file exists in the bundle.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> a[href$="artifacts/applied-overrides.yaml"]`)

### VAL-DASH-003: Scenario card lists every fixture file as a link
For each file present under `reports/<run-id>/artifacts/fixtures/`, the scenario card MUST render one anchor whose `href` points at that fixture file (relative or `file://`). The displayed link text MUST match the fixture filename. No fixture in the directory may be omitted from the rendered list.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> .artifact-fixtures a`)

### VAL-DASH-004: Scenario card lists every applied manifest as a link
For each file present under `reports/<run-id>/artifacts/manifests/`, the scenario card MUST render one anchor whose `href` points at that manifest file. Empty `manifests/` dirs MUST render an empty list section (not omit the section silently) so reviewers can confirm "no manifests captured" vs "section bug".
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id> .artifact-manifests a, details#<scenario-id> .artifact-manifests .empty`)

### VAL-DASH-005: Every artifact link href resolves to an existing file on disk
Walk every `<a>` inside the artifact link sections of the rendered HTML. For each `href`, the resolved path on disk MUST exist and be a regular file. No `404`s, no broken relative paths.
Tool: bash
Evidence: terminal-output (script that parses index.html, resolves each artifact href against the run dir, runs `test -f` per target, exits non-zero on the first miss)

### VAL-DASH-006: Legacy runs without an artifacts/ bundle render cards without dead links
Build the dashboard against a `reports/` containing one legacy run (no `artifacts/` directory, only `result.yaml` + `scenarios-snapshot.yaml`). The rendered scenario cards for that run MUST omit the artifact link sections entirely (or render an explicit "no artifacts" placeholder). They MUST NOT emit anchors with empty/missing `href`s or anchors that point at non-existent paths.
Tool: agent-browser
Evidence: dom-text(`details#<scenario-id>`) showing no `a[href=""]` and no `a[href$="artifacts/scenario.yaml"]` when the legacy run is selected

### VAL-DASH-007: Multiple variants of the same (category, integration) collapse under a single header row
When `reports/run-*/scenarios-snapshot.yaml` contains 3+ scenarios sharing the same `(mechanism-category, integration)` (e.g., three `ingress-controllers/traefik-*` variants), the matrix table MUST render exactly one header row for that pair followed by the variants beneath it — not one row per variant at the top level.
Tool: agent-browser
Evidence: dom-text(`section.matrix tr.integration-header`) — there is one header row matching the integration and its variant rows are children of that group

### VAL-DASH-008: Integration header row displays variant count and pass/fail breakdown
The header row introduced in VAL-DASH-007 MUST contain a text segment of the form `"<N> variants: <P> PASS / <F> FAIL"` (additional statuses such as PARTIAL/UNTESTED MUST appear in the same line when present). The displayed counts MUST equal the per-variant statuses collected from the run.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header .variant-summary`)

### VAL-DASH-009: Clicking an integration header toggles expand/collapse of its variant list
Render the dashboard, locate an integration header with 2+ variants, capture the DOM (or visibility state) of its variant rows. Click the header. Re-capture. The variant rows MUST transition between visible and hidden (e.g., `[hidden]` attribute, `display: none`, or `<details open>` state change). A second click MUST return to the prior state.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header[aria-expanded]`) snapshot before/after a synthesized click event

### VAL-DASH-010: Collapsed integration header reflects rolled-up aggregate status
When an integration header is in its collapsed state, its status badge/cell MUST display the worst-of-set status across its variants using the same `STATUS_RANK` ordering as `render.py` (`FAIL` < `PARTIAL` < `INCONCLUSIVE` < `UNTESTED` < `PASS`). E.g., 2 PASS + 1 FAIL collapses to a `FAIL` badge on the header.
Tool: agent-browser
Evidence: dom-text(`tr.integration-header .badge.status-*`)

### VAL-DASH-011: Cloud-platform scenarios render with a distinct visual marker
For scenarios whose `cluster.provider` is in `{gke, aks, eks}` (or whose `mechanisms` contains `cloud:*`), the scenario card and matrix row MUST render an additional visual cue distinct from local kind/minikube cards — e.g., a `.badge.cloud` element with text "AUTHORED ONLY" or a cloud-icon span. Local-backend scenarios MUST NOT render that cue.
Tool: agent-browser
Evidence: screenshot(reports/run-*/dist/index.html) plus dom-text(`details#<cloud-scenario-id> .badge.cloud`)

### VAL-DASH-012: Cloud-platform scenario card surfaces "authored, not run locally" tooltip
The visual marker from VAL-DASH-011 MUST carry an accessible tooltip whose text matches (case-insensitive) "authored, not run locally". This MUST be exposed via an attribute that screen readers and `dom-text` can read (`title`, `aria-label`, or a sibling `<span class="tooltip">` text node).
Tool: agent-browser
Evidence: dom-text(`details#<cloud-scenario-id> [title], [aria-label]`) value matches the required string

### VAL-DASH-013: Cloud-platform scenarios show "AUTHORED" status instead of PASS/FAIL
For cloud-platform scenarios, the per-row Status column and detail-summary badge MUST display `AUTHORED` (or `AUTHORED ONLY`) rather than `PASS`/`FAIL`/`UNTESTED`. A run that has no `result.yaml` entry for that scenario MUST still surface `AUTHORED` (not the default `UNTESTED`).
Tool: agent-browser
Evidence: dom-text(`section.matrix tr[data-scenario-id="<cloud-id>"] td.status, details#<cloud-id> summary .badge`)

### VAL-DASH-014: build-dashboard.sh succeeds across mixed minimal and rich report shapes
Run `bash engine/scripts/build-dashboard.sh` (no args) against a `reports/` directory that contains at least one legacy-shape run (snapshot + `agent-*/result.yaml`, no `artifacts/`) AND one rich-shape run (with full `artifacts/`). The script MUST exit `0` and produce `reports/dist/index.html`. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: bash
Evidence: terminal-output (`bash engine/scripts/build-dashboard.sh; echo "exit=$?"`) showing `exit=0` and the index file written

### VAL-DASH-015: Both legacy and rich runs appear on the rendered index page
After VAL-DASH-014, open `reports/dist/index.html`. The Runs table MUST contain one row per run directory that has valid metadata — both the legacy-shape and the rich-shape run IDs MUST be present, linkable, and reflect their respective scenario counts. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr td:first-child code`) listing both `run-<legacy>` and `run-<rich>` ids

### VAL-DASH-016: Orphaned run directory (no result.yaml, no snapshot) is skipped without crashing
Create a `reports/run-<orphan>/` containing only an empty directory or unrelated files (no `scenarios-snapshot.yaml`, no `agent-*/result.yaml`). Re-run `bash engine/scripts/build-dashboard.sh`. The script MUST exit `0`, emit a warning to stderr identifying the skipped run, and the index MUST NOT include a row for the orphan. The synthetic fixture used in this test MUST include at least one scenario whose `name`/`description`/`fail_msg` contains HTML metacharacters (`<`, `>`, `&`, `"`, `'`); the rendered HTML for that fixture MUST exhibit the autoescape posture asserted in VAL-DASH-024.
Tool: bash
Evidence: terminal-output showing `exit=0`, the orphan id appearing on stderr (e.g., `warn: ... run-<orphan>`), and `grep -c "run-<orphan>" reports/dist/index.html` returning `0`

### VAL-DASH-017: Repeated dashboard builds produce byte-identical HTML (deterministic ordering)
Run `python -m testgrid build --reports reports/ --out /tmp/dash-a` and `python -m testgrid build --reports reports/ --out /tmp/dash-b` back to back against an unchanged `reports/`. The two outputs MUST be byte-identical (`diff -r` returns 0) for all non-timestamp lines; if a render timestamp is embedded, only that single line may differ. Row and column ordering within the matrix MUST be deterministic (e.g., scenario IDs sorted lexicographically), so the assertion is independent of dict iteration order.
Tool: bash
Evidence: terminal-output (`diff -r /tmp/dash-a /tmp/dash-b | grep -v 'rendered_at'` returns empty; non-zero exit indicates non-determinism)

### VAL-DASH-018: Rendered dashboard loads in a browser without console errors
Open the rendered `reports/run-*/dist/index.html` via `file://` and the runs index `reports/dist/index.html`. The browser console MUST report zero `error`-level entries (CSS/asset 404s for `style.css` or `run.json` count as failures). Network panel MUST show 200/`file://` success for every requested resource.
Tool: agent-browser
Evidence: dom-text(devtools console panel) showing 0 errors plus network-call log showing no non-200 / failed file:// fetches

### VAL-DASH-019: Scenario card surfaces FAIL detail (error message or log link)
For any scenario card whose status is `FAIL`, the rendered HTML MUST include either: (a) a visible text element containing a non-empty error summary string (truncated >= 40 chars OK), OR (b) an anchor labeled "Log" / "Error log" whose `href` resolves to a non-empty `logs/*.log` file under the run's artifacts. Cards with status `PASS` MUST NOT render an empty error-summary element (no `class="error-summary"` with empty text). Pass requires every FAIL card to expose either an error string or a log link.
Tool: agent-browser
Evidence: dom-text(`details[data-status="FAIL"] .error-summary, details[data-status="FAIL"] a.error-log`)

### VAL-DASH-020: Re-running a scenario into a new run-* dir leaves prior runs intact in the index
After a baseline run produces `reports/run-A/` (rendered to `reports/dist/index.html`), a second run produces `reports/run-B/`, and `bash engine/scripts/build-dashboard.sh` is invoked: the regenerated index page lists BOTH run-A and run-B in its Runs table, and clicking each run's link reveals its corresponding scenario cards. The run-A artifact links still resolve on disk (no broken hrefs introduced by the rebuild). Pass requires both runs visible, both link sets resolve.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr`) lists both `run-A` and `run-B`, terminal-output (script walks all `a[href]` under `details[data-run-id="run-A"]` and confirms `test -f` for each resolved path)

### VAL-DASH-021: Corrupt result.yaml in a run dir is reported but does not crash the dashboard build
Place an intentionally invalid `result.yaml` (e.g., truncated, missing keys, invalid YAML syntax) into `reports/run-<corrupt>/`. Running `bash engine/scripts/build-dashboard.sh` exits 0; stderr emits a clear warning naming the offending run id and the corruption type (`invalid YAML`, `missing required key 'scenarios'`, etc.); the resulting `reports/dist/index.html` either omits the corrupt run with a placeholder row labeled "metadata error" OR omits it entirely with a stderr warning. Pass requires: exit 0, named warning, non-crashing render.
Tool: bash
Evidence: exit-code 0, terminal-output(stderr contains the run id + reason), file(reports/dist/index.html)

### VAL-DASH-022: `STATUS_RANK` ordering ensures `INCONCLUSIVE` never bubbles up as "worse than" `UNTESTED` in mechanism rollups
For a mechanism that has two scenarios — one `INCONCLUSIVE` and one `UNTESTED` — the rendered mechanism rollup row shows `UNTESTED` (NOT `INCONCLUSIVE`), because UNTESTED reflects "we never even tried" which is a worse-confidence outcome than "we tried but couldn't conclude." Equivalently: the testgrid collector module orders `STATUS_RANK['UNTESTED']` strictly less than `STATUS_RANK['INCONCLUSIVE']`. Pass requires the unit test confirms the ordering AND a synthetic run with the two scenarios renders the mechanism cell as `UNTESTED`.
Tool: pytest
Evidence: pytest-output (`pytest engine/testgrid/tests/test_render.py::test_status_rank_untested_above_inconclusive`), file(reports/dist/<run-id>/index.html — the synthetic rollup cell shows badge text "UNTESTED")

### VAL-DASH-023: `collect.py` rejects (or visibly surfaces) `result.yaml` files whose `status` is not in the known status set
A `result.yaml` with `status: WEIRD_CUSTOM_STATUS` causes either (a) the testgrid collector to exit non-zero with a clear stderr line naming the offending status + scenario + file, OR (b) the resulting `Scenario.status` to be normalized to `UNKNOWN` AND the dashboard renders the scenario card with a visible "unknown status" badge (NOT a generic untested-styling fallback). Pass requires the gibberish status is either rejected at collect time or visibly surfaced — silent CSS coercion to `status-unknown` (current behavior) does not satisfy.
Tool: bash
Evidence: bash-test (synthesize result.yaml with bogus status, run `uv run testgrid build`, assert stderr names the status OR dashboard shows "unknown status" text), grep-match in the testgrid collector module (no longer accepts arbitrary string into `Scenario.status` without validation)

### VAL-DASH-024: Dashboard HTML escapes user-controlled fields (`name`, `description`, `notes`, `fail_msg`, `log_dir`) against XSS payloads
A scenario whose `name` is `"<script>alert(1)</script>"` and whose `description` contains `"</details><img src=x onerror=alert(1)>"` is collected and rendered. The resulting `reports/dist/<run-id>/index.html` does NOT contain `<script>alert(1)</script>` as live HTML (i.e., the payload is HTML-escaped to `&lt;script&gt;alert(1)&lt;/script&gt;`), and a headless-browser visit (`agent-browser` open + read DOM) shows the literal text "alert(1)" inside a text node (not executed). Pass requires escape-correctness for every field that originates from user-supplied YAML.
Tool: agent-browser
Evidence: dom-text (visible text contains literal `<script>alert(1)</script>` characters), terminal-output (`rg -F '<script>alert(1)</script>' reports/dist/<run-id>/index.html` returns no live-script match)

### VAL-DASH-025: Dashboard renders a non-crashing card when `result.yaml` lists zero scenarios
Build the dashboard against a `reports/` containing one valid-shape run whose `result.yaml` has `scenarios: []` (empty list — e.g. a dispatch invocation whose suite filter matched zero scenarios). The build MUST exit 0; the rendered `reports/dist/index.html` MUST contain a row for that run id whose scenario count shows `0` (NOT a missing or `null` cell) and that has no scenario-card subtree. The run-detail page (or details block) for that run MUST render an explicit "0 scenarios in this run" placeholder text node, not crash and not silently omit the run. Pass requires: exit 0 + run id visible in index + explicit zero-count text.
Tool: agent-browser
Evidence: dom-text(`section.runs tbody tr td:contains("run-<empty>") td.scenario-count`) shows `0`, dom-text(`details[data-run-id="run-<empty>"] .empty-state`) contains "0 scenarios" or equivalent, terminal-output (`bash engine/scripts/build-dashboard.sh; echo "exit=$?"` shows `exit=0`)
