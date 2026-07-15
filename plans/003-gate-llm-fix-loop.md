# Plan 003 — Gate + constrain the LLM fix loop's write-then-execute path

- **Bead:** `chart-test-swarm-998`
- **Category:** security — untrusted-output write-then-execute (P0)
- **Written against commit:** `bfa3941`
- **Effort:** M (roughly a day incl. tests)
- **Files in scope:** `engine/testgrid/src/chart_test_swarm/commands/fix_cmd.py`, tests under `engine/testgrid/tests/`
- **Files explicitly OUT of scope:** `recommendations.py` prompt construction (that is the sibling bead `chart-test-swarm-dij`, blocked-by this one — do it next, not here), the engine shell scripts

---

## Why this matters

The `fix` workflow is a **write-then-execute** pipeline driven by the raw
stdout of `$CTS_LLM_CMD`:

1. `apply_llm_suggestion` parses `CHANGED FILE: <path>` markers from the LLM
   output and writes each file into the chart directory.
2. `rerun_scenario` then runs the scenario on a kind cluster, which executes
   any assert / smoke shell script under the chart's `chart-test/` tree.

So if the LLM output (or an injected instruction reaching it — see the sibling
bead `chart-test-swarm-dij`) writes an **executable** `chart-test/asserts/*.sh`
or smoke script, the next re-run executes it on the host. The current
path-traversal guard blocks escaping the chart dir but **permits writing
executable scripts inside it**, and the write-root itself is attacker-
influenceable.

## Current state (read these yourself before editing)

`apply_llm_suggestion` — writes each marked file, no type/location allowlist
(lines 195-235):

```python
for line in lines:
    if line.startswith("CHANGED FILE: "):
        if current_file is not None and current_lines:
            _write_chart_file(chart_dir, current_file, "\n".join(current_lines) + "\n")
            changes_made = True
        current_file = line[len("CHANGED FILE: ") :].strip()
        current_lines = []
    ...
```

`_write_chart_file` — the guard blocks dir-escape but allows any path
(incl. executable scripts) **inside** `chart_dir` (lines 238-252):

```python
def _write_chart_file(chart_dir: Path, relative_path: str, content: str) -> None:
    target = (chart_dir / relative_path).resolve()
    if not target.is_relative_to(chart_dir.resolve()):
        raise ValueError(
            f"Refusing to write {relative_path}: resolved path "
            f"{target} escapes chart directory {chart_dir.resolve()}"
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
```

The write-root is derived from unvalidated `chart_path` (line 618):

```python
self.chart_dir = project_dir / fix_prompt_data.get("chart_path", "chart")
```

**Important pathlib fact:** if `chart_path` is **absolute**, `project_dir /
"/abs/path"` evaluates to `/abs/path` — the `project_dir` prefix is discarded.
So an absolute `chart_path` relocates the entire write root, after which
`_write_chart_file`'s `is_relative_to` check only constrains writes relative to
that attacker-chosen root. This is the root-relocation hole.

The write is immediately followed by execution (lines 718-731):

```python
diff = apply_llm_suggestion(ctx.chart_dir, llm_output)
...
rerun_status = rerun_scenario(
    scenario_path=resolved_scenario_path,
    reports_dir=str(ctx.reports_dir),
    project_dir=str(ctx.project_dir),
    timeout=run_timeout,
)
```

`.fix-prompt.json` is produced by this tool (`write_fix_prompt_file`, called
from `test_cmd.py:352` with `chart_path="chart"`), but `fix_cmd` reads it back
from disk and must not trust it — a stale/hand-edited/relocated file is exactly
the untrusted case.

**Repo conventions:** `fix_cmd.py` uses a module-level `_debug()` and a `_die()`
helper (`grep -n "_die\|_debug" engine/testgrid/src/chart_test_swarm/commands/fix_cmd.py`),
`typer` for the CLI, `mypy --strict` (annotate everything), and `ruff`
(line-length 100, rules `E,F,I,UP,B,SIM`). Match these.

---

## Design options — pick one, record the choice in the bead before coding

All three share two **mandatory** hardening steps (do these regardless of
option):

- **M1 — validate `chart_path`:** reject an absolute `chart_path`, and after
  resolving `chart_dir`, assert `chart_dir.resolve().is_relative_to(
  project_dir.resolve())`. Fail closed (`_die`) otherwise.
- **M2 — write allowlist:** in `_write_chart_file`, reject writes to paths that
  are executable/script-like or outside the chart's template/values surface.
  Concretely: allow `templates/**`, `values*.yaml`, `Chart.yaml`, `*.tpl`;
  **reject** `*.sh`, anything under `chart-test/asserts/` or `chart-test/
  assertions/`, and any path whose basename the OS would treat as executable.
  Also strip the executable bit on written files (`os.chmod(target, 0o644)`).

The options differ in **how much human/automation gate** sits before
apply+rerun:

### Option A — allowlist + strip exec bit, no interactive gate (recommended for headless CI)

M1 + M2 only. The fix loop stays fully automated (its point in CI), but the
LLM can no longer write executable scripts or relocate the root, so the
write-then-execute chain is broken: written files are non-executable
template/values content that the re-run renders, never scripts it executes.

- **Pros:** preserves the headless auto-fix workflow the tool is built for
  (`CTS_LLM_CMD` non-interactive mode); structural fix; smallest UX change.
- **Cons:** still applies unreviewed template/values edits automatically — a
  bad (but non-executable) chart edit can still be written and re-run. That is
  a much lower-severity failure (a wrong render, not host code execution).

### Option B — allowlist + mandatory diff-approval gate (recommended for interactive use)

M1 + M2, **plus** an approval gate: after `apply_llm_suggestion` produces a
diff and before `rerun_scenario`, print the diff and require confirmation.
Add a `--yes/--no-confirm` flag (typer) that auto-approves for non-interactive
callers; default is to prompt. When stdin is not a TTY and `--yes` was not
passed, **fail closed** (do not silently auto-apply).

- **Pros:** strongest for a human-in-the-loop; the operator sees exactly what
  will be written+executed. Combined with M2, even an approved diff can't be an
  executable script.
- **Cons:** the headless `test`/CI path must pass `--yes` explicitly, so this
  is a (small) behavior change for existing automation. Wire `--yes` through
  `test_cmd.py`'s fix sub-loop so the full-matrix loop still runs unattended.

### Option C — sandbox-then-promote

M1 + M2, plus: apply writes to a **throwaway copy** of the chart, run the
scenario against the copy, and only promote the copy back over the real chart
if the re-run passes. The real chart is never executed with unreviewed content
until it's known-good.

- **Pros:** the real working tree is never the thing executed with untrusted
  edits; nicest isolation.
- **Cons:** most code (copy/promote lifecycle, temp-dir management, path
  rewrites so `rerun_scenario` targets the copy); heaviest to get right and
  test. Overkill once M2 already forbids executable writes.

**Recommendation:** ship **M1 + M2 as Option A** now (it structurally kills the
host-RCE path and keeps CI headless). Layer Option B's approval gate if/when an
interactive fix UX is wanted. Skip C unless a concrete threat needs it — M2
already removes the executable-write primitive C is guarding against.

---

## Steps (Option A; add the gate from B if chosen — note which in the bead)

### Step 1 — M1: validate and constrain the write root

In the `FixContext.__init__` (line 607) or at the top of `fix_cmd`, before any
write:

```python
chart_rel = fix_prompt_data.get("chart_path", "chart")
if os.path.isabs(chart_rel):
    _die(f"ERROR: chart_path must be relative, got absolute: {chart_rel}", code=23)
chart_dir = (project_dir / chart_rel).resolve()
if not chart_dir.is_relative_to(project_dir.resolve()):
    _die(f"ERROR: chart_path escapes project dir: {chart_rel}", code=23)
self.chart_dir = chart_dir
```

Pick an unused exit code (grep existing `_die(..., code=` values first).

### Step 2 — M2: allowlist + exec-bit strip in `_write_chart_file`

```python
_ALLOWED_SUFFIXES = {".yaml", ".yml", ".tpl", ".txt", ".md"}
_DENIED_DIR_PARTS = {"asserts", "assertions"}

def _write_chart_file(chart_dir: Path, relative_path: str, content: str) -> None:
    target = (chart_dir / relative_path).resolve()
    if not target.is_relative_to(chart_dir.resolve()):
        raise ValueError(f"Refusing to write {relative_path}: escapes chart dir")
    rel_parts = set(Path(relative_path).parts)
    if target.suffix.lower() not in _ALLOWED_SUFFIXES:
        raise ValueError(f"Refusing to write {relative_path}: disallowed file type")
    if rel_parts & _DENIED_DIR_PARTS:
        raise ValueError(f"Refusing to write {relative_path}: writes into assert dir")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    os.chmod(target, 0o644)  # never leave an executable bit
```

Tune `_ALLOWED_SUFFIXES` to the chart surface the fix loop should touch
(templates/values/Chart metadata). The intent: **no path the re-run will
execute as a script can be written.** Keep the existing dir-escape check.

### Step 3 (only if Option B) — approval gate + `--yes`

Add a `--yes/--no-confirm` typer option to the `fix` command (and thread it
into `test_cmd.py`'s fix sub-loop as `yes=True` so the full-matrix loop stays
unattended). Between `apply_llm_suggestion` and `rerun_scenario`, if not
`yes`: print the diff, prompt; on non-TTY stdin without `--yes`, `_die` fail-
closed. Do not auto-apply silently.

## Test plan

Add to `engine/testgrid/tests/test_fix_cmd.py` (read it first for the existing
`apply_llm_suggestion`/`_write_chart_file` test style):

1. **Executable-write rejected (load-bearing):** feed `apply_llm_suggestion`
   an LLM output with `CHANGED FILE: chart-test/asserts/evil.sh` (and a
   `.sh` at the chart root). Assert it raises `ValueError` and **no file is
   written**. Fails against pre-fix code, passes after.
2. **Absolute / escaping `chart_path` rejected (M1):** construct a
   `.fix-prompt.json` (or `FixContext`) with an absolute `chart_path` and one
   with `../` escape; assert the command dies / raises before any write.
3. **Exec bit never set:** write an allowed `values.yaml` and assert
   `stat` mode is `0o644` (no exec bits).
4. **Happy path preserved:** an allowed `templates/foo.yaml` / `values.yaml`
   edit still applies and produces a diff.
5. **(If Option B) gate:** non-TTY without `--yes` fails closed; `--yes`
   auto-applies; the diff is shown before rerun.

## Done criteria (machine-checkable)

```bash
# 1. Tests (incl. the executable-write rejection) pass
uv run --directory engine/testgrid pytest -n 2 engine/testgrid/tests/test_fix_cmd.py
uv run --directory engine/testgrid pytest -n 2
# expected: all pass

# 2. Types + lint clean
uv run --directory engine/testgrid mypy src/testgrid src/chart_test_swarm
uv run --directory engine/testgrid ruff check src/testgrid src/chart_test_swarm
# expected: no errors

# 3. The allowlist + root validation are present
grep -n "is_relative_to\|isabs\|_ALLOWED_SUFFIXES\|chmod" \
  engine/testgrid/src/chart_test_swarm/commands/fix_cmd.py
# expected: chart_path abs/escape check AND the write allowlist AND chmod 0o644
```

## Escape hatches

- If the sample chart's legitimate fix targets include file types outside a
  minimal templates/values allowlist (check what
  `examples/sample-product-chart/chart` actually contains and what the fix
  prompts ask the LLM to edit), widen `_ALLOWED_SUFFIXES` **deliberately** and
  note it — but never add `.sh` or the assert dirs.
- If you find `rerun_scenario` targets a path derived from LLM output (not just
  the fixed scenario path), STOP and report — that would be a second execution
  vector this plan didn't scope.

## Maintenance note

The invariant: **the fix loop may write only non-executable chart
template/values content, into a root proven to be inside `project_dir`, and
executes only the pre-existing scenario — never a file the LLM just wrote.**
The immediate follow-up is `chart-test-swarm-dij` (fence the untrusted failure
detail that flows into the LLM prompt); it is blocked-by this plan and closes
the injection *source* while this plan closes the *sink*. Review them together.
