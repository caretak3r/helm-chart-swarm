# Plan 002 — Remove host `eval`/`source` of scenario-derived values in probe asserts

- **Bead:** `chart-test-swarm-bj7`
- **Category:** security — host command execution (P0)
- **Written against commit:** `bfa3941`
- **Effort:** M (roughly a day incl. tests)
- **Files in scope:** `engine/asserts/lib/assert-helpers.sh`, `engine/asserts/pods-ready.sh`, `engine/asserts/probes-present.sh`, a validation hook in `engine/scripts/run-scenario.sh` (scenario-load), bats tests under `engine/asserts/tests/`
- **Files explicitly OUT of scope:** the other 29 assert scripts (this plan touches only the two that reach the `eval` path), the in-pod `sh -c` injection in `service-reachable.sh`/`tls-cert-valid.sh` (that is a **separate, lower-severity** bead, `chart-test-swarm-6wu` — do not fold it in), the assert-preamble de-duplication refactor (`chart-test-swarm-15d`)

---

## Why this matters

Two built-in assert scripts build a shell command string from scenario YAML
fields and execute it on the **test-runner host** via `eval` (and, in
`pods-ready.sh`, via `source` of a file the values were `printf`'d into). A
scenario field containing a double-quote plus shell metacharacters escapes the
intended command and runs arbitrary code on the host.

This is worse than the documented "consumers run their own assert scripts"
tradeoff, because the vector is **declarative scenario YAML** — the kind of
input that:

- `chart-test-swarm generate author` produces via an LLM, and
- imported / shared scenario catalogs carry,

both of which are reasonably trusted to be inert configuration, not code.

**Blast radius is small and well-bounded:** only `pods-ready.sh` and
`probes-present.sh` call `wait_with_backoff` (verified:
`grep -rln wait_with_backoff engine/asserts/*.sh` returns exactly those two).
Fix those two call sites plus the helper contract.

## Current state (read these yourself before editing)

`pods-ready.sh` derives `NS`/`SEL` from scenario YAML (lines 14-32), then
writes them into a temp file that is `source`d inside an `eval`'d probe
(lines 59-74):

```bash
NS=$(yq      ".asserts[$IDX].namespace" "$SCENARIO")
SEL=$(yq     ".asserts[$IDX].selector // \"\"" "$SCENARIO")
...
_probe_file=$(mktemp /tmp/ct-pods-ready-probe.XXXXXX)
trap 'rm -f "$_probe_file"' EXIT
printf 'KUBECTL_ARGS="%s"\n' "${kubectl_args[*]}" > "$_probe_file"
printf 'NS="%s"\n'  "$NS"  >> "$_probe_file"      # <-- a " in NS/SEL closes the assignment
printf 'SEL="%s"\n' "$SEL" >> "$_probe_file"

probe_cmd="source $_probe_file 2>/dev/null; ready=\$(kubectl \$KUBECTL_ARGS get pods -n \"\$NS\" -l \"\$SEL\" ...) ..."
if wait_with_backoff "$probe_cmd" "$RETRIES" "$timeout_sec"; then
```

`assert-helpers.sh` — `wait_with_backoff` runs its first argument through
`eval` (lines 33-63):

```bash
wait_with_backoff() {
  local probe_cmd="$1"
  ...
    # Execute probe
    if eval "$probe_cmd" 2>/dev/null; then   # <-- host eval of a string built from scenario data
      return 0
    fi
  ...
}
```

`probes-present.sh` string-interpolates `$NS` and `$release_sel` into a
`probe_cmd` that `wait_with_backoff` then `eval`s (around line 286 — open the
file and read the block that builds `probe_cmd`).

**Repo convention to preserve:** the retry/backoff/timeout semantics of
`wait_with_backoff` (attempts, exponential delay capped at 30s, timeout
ceiling) and its test seam `WAIT_BACKOFF_SLEEP_CMD` (lines 30-31, 88-90) —
tests stub sleep through it. Whatever you change, keep the retry behavior and
that seam working; the existing bats assert suite is your safety net.

---

## Design options — pick one, record the choice in the bead before coding

The goal: **no scenario-derived value is ever part of a string that gets
`eval`'d or `source`d on the host.** Three ways to get there, in increasing
order of change size.

### Option A — argv-based probe (recommended)

Change `wait_with_backoff` to accept a **command as arguments** (`"$@"`), not
a string, and execute it with no `eval`:

```bash
# wait_with_backoff <retries> <timeout_sec> -- <cmd> [args...]
wait_with_backoff() {
  local retries="${1:-0}" timeout_sec="${2:-30}"; shift 2
  [ "${1:-}" = "--" ] && shift
  ...
    if "$@" 2>/dev/null; then return 0; fi      # no eval
  ...
}
```

Each caller passes a **static probe script** (a small `.sh` in
`engine/asserts/lib/`, e.g. `probe-pods-ready.sh`) and passes `NS`/`SEL` to it
as **positional args or exported env vars** — never interpolated into shell
text:

```bash
NS="$NS" SEL="$SEL" wait_with_backoff "$RETRIES" "$timeout_sec" \
  -- bash "$SCRIPT_DIR/lib/probe-pods-ready.sh"
```

The probe script reads `$NS`/`$SEL` as ordinary variables and calls `kubectl`
with them quoted — values are data, never parsed as shell.

- **Pros:** eliminates `eval`/`source` entirely; the injection class is gone
  structurally, not filtered. Cleanest long-term contract.
- **Cons:** touches the `wait_with_backoff` signature (2 callers) and adds 1-2
  tiny probe scripts. The `WAIT_BACKOFF_SLEEP_CMD` seam still works (sleep is
  internal). Bats tests that call `wait_with_backoff "<string>" <retries>
  <timeout>` must be updated to the new argv form.

### Option B — keep the string, but pass values only as env vars

Leave `wait_with_backoff` taking a string, but ensure the string contains
**no scenario data** — only fixed variable *names*. Export `NS`/`SEL` as env
vars before the call and reference them by name in the (now static) probe
string; delete the `printf`-into-`source` file entirely.

```bash
export NS SEL KUBECTL_ARGS
probe_cmd='ready=$(kubectl $KUBECTL_ARGS get pods -n "$NS" -l "$SEL" ...) ; ...'
wait_with_backoff "$probe_cmd" "$RETRIES" "$timeout_sec"
```

- **Pros:** smallest diff; `wait_with_backoff` signature unchanged, so bats
  tests for the helper stay as-is.
- **Cons:** `eval` remains in the codebase, so this is safe **only** as long as
  the probe string stays literal and no future edit interpolates a value back
  in. It is a discipline guarantee, not a structural one — a reviewer has to
  keep enforcing it. Weaker than A.

### Option C — replace the retry helper with `kubectl wait` where possible

For `pods-ready.sh` specifically, readiness has a native primitive:
`kubectl wait --for=condition=Ready pod -l "$SEL" -n "$NS" --timeout=...`
(with the existing "at least one pod exists" guard so an empty set isn't a
vacuous pass — that guard is already at lines 51-56). No custom probe string
at all.

- **Pros:** removes the bespoke probe entirely for the readiness case; least
  shell to get wrong.
- **Cons:** does not cover `probes-present.sh` (which checks probe *presence*
  and liveness semantics, not just Ready) — you'd still need A or B there, so
  C alone is incomplete. Best used **in combination**: C for `pods-ready.sh`,
  A for `probes-present.sh`.

**Recommendation:** Option A for both call sites (uniform, structural fix). If
the executor wants the smallest safe change and will accept the discipline
cost, Option B is acceptable. Option C only as a complement, never alone.

---

## Steps (assuming Option A — adapt if B/C chosen; record which in the bead)

### Step 1 — add scenario-load input validation (defense in depth, do this regardless of option)

In `engine/scripts/run-scenario.sh`, at the point where assert entries are
read (grep for where `.asserts[` fields are consumed / where each assert type
is dispatched), validate `namespace`, `selector`, and `release` against a
strict allowlist before any assert runs. Kubernetes names/labels/selectors do
not need shell metacharacters:

```bash
# Reject values with characters that have no business in a k8s selector/ns/release.
_validate_assert_field() {  # <field-name> <value>
  case "$2" in
    *['"'\'\`\$\;\&\|\<\>\(\)]* )
      echo "ERROR: assert field '$1' contains disallowed characters: $2" >&2
      return 1 ;;
  esac
}
```

Apply to `namespace`, `selector`, and `release` (and any other field these two
asserts read into a probe). Fail the scenario load (not just the assert) on a
violation. This is belt-and-suspenders behind the structural fix.

### Step 2 — change the helper contract

Rewrite `wait_with_backoff` per Option A (argv, no `eval`). Preserve: attempt
count = `retries + 1`, exponential backoff capped at 30s, timeout ceiling
check, and the `WAIT_BACKOFF_SLEEP_CMD` sleep seam. The sleep line currently
uses `eval "$sleep_cmd $delay"` — keep that seam (it takes a fixed, non-scenario
value `$delay`), or convert to `"$sleep_cmd" "$delay"` if the test stub allows.

### Step 3 — add static probe script(s)

Create `engine/asserts/lib/probe-pods-ready.sh` (and, if not folding into
`kubectl wait`, `probe-present.sh` for probes-present). Each reads `NS`/`SEL`
(and any other needed values) from the environment, calls `kubectl` with them
quoted, and exits 0/1. No `eval`, no `source`, no string-building from inputs.

### Step 4 — update the two call sites

`pods-ready.sh`: delete the `mktemp`/`printf`/`source` block; export the
needed values; call `wait_with_backoff` with the argv form. `probes-present.sh`:
same — remove the interpolated `probe_cmd` string, export values, call the
static probe.

### Step 5 — update bats tests for the new helper signature

Existing helper tests call `wait_with_backoff "<probe string>" <retries>
<timeout>`. Update them to the argv form. Add tests per Step 6.

## Test plan

Add to `engine/asserts/tests/` (follow the existing bats style there):

1. **Injection regression (the load-bearing test):** run `pods-ready.sh` (or
   its validation path) with a scenario whose `selector` / `namespace`
   contains a shell-metacharacter payload that, under the old code, would have
   created a sentinel side effect (e.g. writes a file). Assert the sentinel is
   **never** created and the assert fails cleanly (validation rejects it, or
   the value is treated as inert data yielding no pods). This test must fail
   against the pre-fix code and pass against the fix.
2. **Backoff behavior preserved:** re-assert the existing retry/timeout
   behavior through the new argv signature, using `WAIT_BACKOFF_SLEEP_CMD` to
   stub sleep.
3. **Happy path:** a valid selector still finds ready pods and passes (use the
   existing mocked `kubectl` shim pattern if the suite has one).

## Done criteria (machine-checkable)

```bash
# 1. No eval/source of a scenario-derived string remains in the two call sites
grep -nE '\beval\b' engine/asserts/lib/assert-helpers.sh
# expected: at most the fixed-value sleep seam; NO eval of a caller-supplied probe string
grep -nE 'source .*_probe_file|printf .*SEL=|printf .*NS=' engine/asserts/pods-ready.sh
# expected: no output (the printf-into-source block is gone)

# 2. Shell lint + assert bats green
shellcheck engine/asserts/*.sh engine/asserts/lib/*.sh engine/scripts/run-scenario.sh
bats engine/asserts/tests
# expected: pass, including the new injection-regression test

# 3. Full suites still green
bats engine/scripts/tests engine/asserts/tests
uv run --directory engine/testgrid pytest -n 2
# expected: pass
```

## Escape hatches

- If you discover a **third** assert reaches the `eval` path (i.e.
  `grep -rln wait_with_backoff engine/asserts/*.sh` returns more than
  `pods-ready.sh` and `probes-present.sh` at the current HEAD), STOP and
  report — the blast radius assumption changed and the plan's scope needs
  updating.
- If preserving exact backoff timing through the argv change proves to break
  many existing helper tests in ways that look like real behavior changes (not
  just call-syntax updates), STOP and report rather than loosening the timing
  assertions.

## Maintenance note

The invariant to protect in every future review: **no `engine/asserts` script
may build a command string from `.asserts[...]` / `.product.*` values and pass
it to `eval` or `source`.** Values flow to the shell only as quoted argv or
env vars consumed by a static probe. When the assert-preamble de-dup refactor
(`chart-test-swarm-15d`) lands, the shared helper it introduces must keep this
property — call that out in its review.
