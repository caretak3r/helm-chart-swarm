## Area: LLM Generator

### VAL-LLM-001: `generate --help` exits 0 and lists pick / author / explore
`chart-test-swarm generate --help` exits 0 and the output advertises all three sub-modes: `pick`, `author`, `explore`.
Tool: bash
Evidence: exit-code 0; terminal-output passes `grep -E '^\s*(pick|author|explore)\b'` for all three names.

### VAL-LLM-002: `generate pick` is non-interactive when fed selections via flags or stdin
`chart-test-swarm generate pick --category certificates --integration cert-manager --variant self-signed --non-interactive` (or, equivalently, the same selections fed via a JSON/YAML file on stdin) completes without prompting and exits 0; running `pick` without any selection flags in a non-TTY context exits non-zero with a clear "no selection provided" message rather than hanging.
Tool: pytest
Evidence: pytest test invokes the CLI with `stdin=subprocess.DEVNULL` and explicit flags; exit-code 0 and stdout is a YAML document; a second test with no flags and `stdin=DEVNULL` returns exit-code != 0 within 5 seconds (no hang).

### VAL-LLM-003: `generate pick` emits a scenario YAML matching the schema
The YAML printed by `generate pick` (to stdout when `--output` is omitted, to the file otherwise) validates against `engine/templates/scenario.schema.json`.
Tool: jsonschema
Evidence: terminal-output of `chart-test-swarm generate pick --category certificates --integration cert-manager --variant self-signed | jsonschema -i /dev/stdin engine/templates/scenario.schema.json` exits 0 with empty output.

### VAL-LLM-004: `generate pick --output <file>` writes to file instead of stdout
With `--output /tmp/pick.yaml`, the file is created with the scenario YAML and stdout contains only a confirmation/path line (no YAML body).
Tool: bash
Evidence: file(/tmp/pick.yaml) exists with size > 0 and passes `yq '.cluster.provider'` returning a non-null value; stdout from the command does not contain `apiVersion` or `cluster:` (verified via `grep -v`).

### VAL-LLM-005: `generate author` invokes CTS_LLM_CMD subprocess (no direct API calls)
With `CTS_LLM_CMD=/tmp/fake-llm.sh` set to a script that echoes a canned scenario YAML and exits 0, `chart-test-swarm generate author "istio with strict-mtls + cert-manager + JWT"` produces exactly that canned YAML on stdout; the chart-test-swarm process makes zero outbound network calls (verified via `lsof`/`strace` or via the process tree containing only the fake child).
Tool: pytest
Evidence: pytest test sets `CTS_LLM_CMD` to a fixture script that writes a known sentinel; CLI stdout contains the sentinel verbatim; the fake script's invocation log records receiving the user description on stdin or as argv.

### VAL-LLM-006: `generate author` output passes jsonschema validation
The YAML emitted by `generate author` (with CTS_LLM_CMD set to a fake that emits a schema-valid template) validates against `engine/templates/scenario.schema.json`.
Tool: jsonschema
Evidence: `chart-test-swarm generate author "<desc>" | jsonschema -i /dev/stdin engine/templates/scenario.schema.json` exits 0 with empty output.

### VAL-LLM-007: `generate author` retries on invalid LLM output up to a bounded max
With `CTS_LLM_CMD` pointing at a fake that emits invalid YAML on the first 2 calls and a valid scenario on the 3rd, `chart-test-swarm generate author "<desc>" --max-retries 3` exits 0 and the fake's call counter shows exactly 3 invocations.
Tool: pytest
Evidence: pytest fixture uses a stateful shell stub backed by a counter file; after CLI exit-code 0, the counter file contains `3`; with `--max-retries 1`, the same fake causes CLI exit-code != 0 with stderr containing `invalid` or `schema`.

### VAL-LLM-008: `generate author` rejects empty/whitespace descriptions
`chart-test-swarm generate author ""` and `chart-test-swarm generate author "   "` exit non-zero before invoking the LLM, with stderr explaining that a non-empty description is required.
Tool: pytest
Evidence: exit-code != 0 for both inputs; CTS_LLM_CMD stub records zero invocations; stderr contains `description` and `empty` or `required`.

### VAL-LLM-009: `generate explore --max-iterations N` is upper-bounded by N
With CTS_LLM_CMD set to a fake that always proposes a new combo and a dispatch stub that always returns PASS, `chart-test-swarm generate explore --chart examples/sample-product-chart/chart --integrations cert-manager,nginx-ingress --max-iterations 3` performs exactly 3 propose→run iterations, no more.
Tool: pytest
Evidence: iteration counter file written by the fake equals 3 after CLI exit-code 0; the captured dispatch-swarm.sh argv log shows exactly 3 scenario runs.

### VAL-LLM-010: `generate explore --budget` halts when budget exhausted
`chart-test-swarm generate explore --chart <path> --integrations <list> --max-iterations 10 --budget 2` stops after exactly 2 iterations (or whichever cost unit the budget tracks first) even though max-iterations is 10, and exits 0 with a "budget exhausted" log line.
Tool: pytest
Evidence: dispatch stub argv log shows exactly 2 runs; stdout/stderr contains the literal `budget exhausted` (or equivalent); iteration counter file equals 2.

### VAL-LLM-011: `generate explore` writes a summary report listing combos and outcomes
After exploration, `chart-test-swarm generate explore --output /tmp/explore-summary.json` writes a JSON file containing an array of `{iteration, scenario_yaml, run_id, status, integrations}` records, one per iteration.
Tool: jq
Evidence: terminal-output `jq 'length' /tmp/explore-summary.json` equals the number of iterations executed; `jq '.[0] | keys' /tmp/explore-summary.json` includes `iteration`, `run_id`, `status`.

### VAL-LLM-012: All three modes are deterministic under a canned CTS_LLM_CMD
With `CTS_LLM_CMD=/tmp/fake-llm.sh` emitting fixed output, running each of `generate pick`, `generate author "<desc>"`, and `generate explore --max-iterations 1 --integrations cert-manager` twice produces byte-identical scenario YAML (except timestamps explicitly excluded via `--no-timestamps` or `sed`-stripped).
Tool: bash
Evidence: `diff <(... first run) <(... second run)` exits 0 for all three modes after stripping documented timestamp lines; exit-code 0 from each invocation.

### VAL-LLM-013: Missing host LLM binary surfaces a clear actionable error
With `CTS_LLM_CMD` unset AND no `droid` (or other configured default) binary discoverable on `PATH`, `chart-test-swarm generate author "<desc>"` exits non-zero with stderr explaining how to set `CTS_LLM_CMD` and which binaries were searched.
Tool: pytest
Evidence: pytest test invokes the CLI with `PATH=/usr/bin:/bin` (no droid) and `CTS_LLM_CMD` removed from env; exit-code != 0; stderr contains both `CTS_LLM_CMD` and `droid` (or the configured default name).

### VAL-LLM-014: Auto-discovery of droid uses PATH when CTS_LLM_CMD is unset
When `CTS_LLM_CMD` is unset but a `droid` shim exists on PATH, `generate author "<desc>"` invokes that shim (not any vendored binary) and passes the description through unchanged.
Tool: pytest
Evidence: pytest places a `droid` script under a tmpdir on PATH; the shim logs its argv/stdin; after CLI exit-code 0, the log shows the description string verbatim and exactly one invocation.

### VAL-LLM-015: No API keys, tokens, or LLM credentials are stored in the repo
A grep across `engine/` and `examples/` for common credential patterns finds zero matches; the CLI source code contains no `os.environ.get('OPENAI_API_KEY')` / `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` lookups.
Tool: bash
Evidence: exit-code 1 (no matches) from `rg -n 'sk-[A-Za-z0-9]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY' engine/ examples/`; exit-code 1 from `rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' engine/testgrid/src`.

### VAL-LLM-016: `generate explore` feeds prior result back into next LLM prompt
On iteration N>1, the CTS_LLM_CMD stub receives stdin (or a prompt argument) that includes the result.yaml summary from iteration N-1 (PASS/FAIL counts and the prior scenario id).
Tool: pytest
Evidence: pytest stub records each invocation's stdin to a file; for iteration 2, the recorded stdin contains the iteration-1 scenario id and the literal string `PASS` or `FAIL`; for iteration 1, the recorded stdin contains no prior-run reference.

### VAL-LLM-017: All generate modes accept `--output` for file-based capture
`generate pick`, `generate author`, and `generate explore` each accept `--output <path>`; when provided, stdout contains only a one-line confirmation (path + scenario id / summary), and the file is written with the full payload.
Tool: bash
Evidence: for each mode, `chart-test-swarm generate <mode> ... --output /tmp/out.yaml` exits 0; file(/tmp/out.yaml) exists with size > 0; `wc -l < <(stdout)` ≤ 2.

### VAL-LLM-018: Schema-failing LLM output is reported with a diagnosable error
When CTS_LLM_CMD emits YAML that is parseable but fails `engine/templates/scenario.schema.json` validation AND retries are exhausted, the CLI exits non-zero and stderr names at least one failing schema path (e.g., `cluster.provider: not one of enum` or `id: does not match pattern`).
Tool: pytest
Evidence: pytest stub emits YAML with `cluster.provider: bogus-backend` (not in the enum); after `--max-retries 1`, exit-code != 0; stderr contains both `cluster.provider` and `enum` (or the offending value).

### VAL-LLM-019: Generated scenarios refuse to overwrite an existing file without --force
Running `chart-test-swarm generate pick --output /tmp/exists.yaml` when `/tmp/exists.yaml` already exists with non-empty content exits non-zero, leaves the existing file's content byte-identical, and stderr contains the path + a phrase like "already exists" / "use --force". With `--force`, the same command exits 0 and replaces the content. The same protection applies to `generate author --output` and `generate explore --output`. Pass requires: refuse + actionable message + preservation; --force succeeds + replaces.
Tool: bash
Evidence: exit-code, terminal-output(stderr), command-output(`sha256sum /tmp/exists.yaml`) before/after

### VAL-LLM-020: `generate explore` writes its summary incrementally so a crash leaves a partial summary
With `CTS_LLM_CMD` set to a fake that succeeds for iteration 1 and then crashes (`exit 137`) on iteration 2, running `chart-test-swarm generate explore --max-iterations 3 --output /tmp/explore.json` exits non-zero and `/tmp/explore.json` exists with exactly one record (the iteration-1 result). The file is valid JSON parseable by `jq`. Pass requires: non-zero CLI exit, single-record JSON, valid JSON shape.
Tool: bash
Evidence: exit-code, file(/tmp/explore.json), command-output(`jq 'length' /tmp/explore.json` == 1)

### VAL-LLM-021: Generated scenarios carry `generated_by` provenance and the LLM cmd used
Every scenario produced by `generate pick`, `generate author`, or `generate explore` includes a top-level `generated_by` mapping with: `by` (always present, value is one of `pick|author|explore`), `cmd` (the resolved `CTS_LLM_CMD` for author/explore; absent or `null` for pick), and `timestamp` (ISO-8601 UTC). The scenario otherwise validates against the schema (i.e., `generated_by` is either schema-allowed or in a documented `additionalProperties: true` extension namespace). Pass requires all three keys present + schema-valid result.
Tool: yq
Evidence: command-output(`yq '.generated_by.by, .generated_by.cmd, .generated_by.timestamp' <generated.yaml>`) — three non-null values for author/explore; non-null `by` + `timestamp` for pick

### VAL-LLM-022: `generate explore` rejects mid-iteration scenarios that fail prefix/schema validation before any cluster spin-up
With `CTS_LLM_CMD` set to a stub that on iteration 1 proposes a schema-valid scenario (PASS), and on iteration 2 proposes a scenario with `cluster.name: escaped-cluster` (no `chart-test-swarm-` prefix), running `chart-test-swarm generate explore --chart <path> --integrations <list> --max-iterations 3` results in: (a) iteration 1 runs to completion creating a single `chart-test-swarm-*` kind cluster (verifiable via `kind get clusters` mid-iteration), (b) iteration 2 fails validation BEFORE any cluster work is attempted (verifiable: no `kind create cluster` / `minikube start` invocation recorded by the PATH stub for iteration 2), (c) the iteration-2 entry in the explore summary records the rejection with the offending name + the schema error message (NOT a generic `LLM_ERROR`), (d) the CLI continues to iteration 3 or exits cleanly with a non-zero status naming the violation. Pass requires: no `escaped-cluster` cluster ever appears in `kind get clusters` or `minikube profile list`, iteration-1 cluster IS torn down, summary records the rejection reason.
Tool: pytest
Evidence: exit-code, file(reports/explore-*/summary.json) — iteration 2 entry contains `error: cluster.name pattern violation` (or equivalent), command-output (`kind get clusters | grep escaped-cluster` returns empty), command-output (PATH stub log shows zero `kind create cluster` invocations correlated with iteration 2)
