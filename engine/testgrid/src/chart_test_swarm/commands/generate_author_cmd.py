"""``chart-test-swarm generate author`` subcommand — LLM-driven scenario authoring.

Takes a natural-language description, shells out to ``CTS_LLM_CMD`` (or discovers
``droid`` on PATH) to author a schema-valid scenario YAML. Retries bounded by
``--max-retries`` on invalid output (both unparseable YAML and schema-failing YAML).
Rejects empty/whitespace descriptions early.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from shutil import which
from typing import NoReturn

import yaml

# ── error helpers ──────────────────────────────────────────────────────────


def _die(msg: str, code: int = 1) -> NoReturn:
    """Print *msg* to stderr and exit with *code*."""
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def _debug(msg: str) -> None:
    """Print a debug trace line to stderr when ``CTS_DEBUG`` is set."""
    if os.environ.get("CTS_DEBUG", "").strip() in ("1", "true", "yes"):
        print(f"[cts debug] {msg}", file=sys.stderr)


# ── path resolution ───────────────────────────────────────────────────────


def _resolve_schema_path() -> Path:
    """Return the absolute path to the scenario schema JSON file.

    Resolution order:
      1. ``CTS_SCHEMA_PATH`` env var
      2. Walk up from this source file to the repo root
    """
    env_override = os.environ.get("CTS_SCHEMA_PATH")
    if env_override:
        return Path(env_override).resolve()

    this_file = Path(__file__).resolve()
    # this_file:  .../src/chart_test_swarm/commands/generate_author_cmd.py
    #   → commands → chart_test_swarm → src → testgrid → engine → repo root
    engine_dir = this_file.parents[3]
    root_dir = engine_dir.parents[1]
    return root_dir / "engine" / "templates" / "scenario.schema.json"


# ── LLM command resolution ────────────────────────────────────────────────


def _resolve_llm_cmd() -> list[str]:
    """Resolve the LLM command to invoke.

    1. ``CTS_LLM_CMD`` env var (split on whitespace).
    2. Auto-discover ``droid`` on PATH via ``shutil.which``.

    Returns a list suitable for ``subprocess.run``.

    Raises ``SystemExit`` if no LLM binary is reachable.
    """
    cts_llm_cmd = os.environ.get("CTS_LLM_CMD", "").strip()
    if cts_llm_cmd:
        _debug(f"CTS_LLM_CMD resolved from env: {cts_llm_cmd}")
        return cts_llm_cmd.split()

    droid_path = which("droid")
    if droid_path:
        _debug(f"Auto-discovered droid at: {droid_path}")
        return [droid_path, "generate", "scenario"]

    # No LLM binary found — produce a clear actionable error.
    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    _die(
        "ERROR: No LLM binary found.\n\n"
        "  • CTS_LLM_CMD environment variable is not set.\n"
        "  • Searched PATH for: droid\n"
        f"  • PATH directories checked: {', '.join(path_dirs)}\n\n"
        "To fix this, set CTS_LLM_CMD to point at your droid/agent CLI:\n\n"
        '    export CTS_LLM_CMD="droid generate scenario"\n\n'
        "Or install the droid CLI from https://docs.factory.ai/cli",
        code=10,
    )


# ── LLM invocation ────────────────────────────────────────────────────────


def _call_llm(llm_cmd: list[str], description: str, timeout: int = 120) -> str:
    """Invoke *llm_cmd* with *description* as part of stdin prompt; return stdout.

    Raises ``SystemExit`` if the subprocess fails (non-zero exit, not found, or timeout).
    """
    _debug(f"Calling LLM: {' '.join(llm_cmd)}")
    prompt = (
        "Generate a chart-test-swarm scenario YAML document.\n\n"
        f"Description: {description}\n\n"
        "Requirements:\n"
        "- Output ONLY valid YAML between --- markers.\n"
        "- The YAML must validate against the chart-test-swarm scenario schema "
        "(engine/templates/scenario.schema.json).\n"
        "- Required top-level keys: id, cluster, product, asserts.\n"
        "- cluster.provider must be one of: kind, minikube, k3d, eks, gke, aks, vcluster.\n"
        "- id must match pattern: ^[a-z0-9][a-z0-9-]*$\n"
        "- asserts must be a non-empty array.\n"
        "- product.set values MUST be strings, numbers, or booleans (NOT nested objects).\n"
        "- Do NOT include any markdown fences (```yaml).\n"
        "- Do NOT include any explanatory text before or after the --- delimited YAML.\n"
    )
    try:
        result = subprocess.run(
            llm_cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        _debug(f"LLM exit code: {result.returncode}")
        if result.stderr:
            _debug(f"LLM stderr: {result.stderr[:500]}")
    except subprocess.TimeoutExpired:
        _die(f"ERROR: LLM command timed out after {timeout}s.", code=11)
    except FileNotFoundError as exc:
        _die(
            f"ERROR: LLM command not found: {llm_cmd[0]}\n"
            f"  Details: {exc}\n"
            f"  Check that CTS_LLM_CMD is set correctly.",
            code=12,
        )

    if result.returncode != 0:
        _die(
            f"ERROR: LLM command exited with code {result.returncode}.\n"
            f"  stderr: {result.stderr[:500] if result.stderr else '(none)'}",
            code=13,
        )

    return result.stdout


# ── YAML parsing (retry-safe) ─────────────────────────────────────────────


def _try_parse_yaml(raw: str) -> tuple[dict[str, object] | None, str | None]:
    """Try to parse *raw* as YAML.

    Returns ``(data, None)`` on success or ``(None, error_message)`` on failure.
    """
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        return None, (
            f"LLM output is invalid YAML: {exc}\n\n"
            "The LLM did not return parseable YAML."
        )
    if not isinstance(data, dict):
        return None, (
            f"LLM output is not a YAML mapping (got {type(data).__name__})."
        )
    return data, None


# ── generated_by provenance ──────────────────────────────────────────────


def _add_generated_by(data: dict[str, object]) -> dict[str, object]:
    """Add ``generated_by`` provenance to the scenario data.

    Uses ``by``, ``cmd`` (resolved CTS_LLM_CMD), and ``timestamp`` (ISO-8601 UTC).
    Returns a new dict (does not mutate *data* in place).
    """
    result = dict(data)
    llm_cmd_str = os.environ.get("CTS_LLM_CMD", "droid")
    result["generated_by"] = {
        "by": "author",
        "cmd": llm_cmd_str,
        "timestamp": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    return result


# ── schema validation ────────────────────────────────────────────────────


def _validate_against_schema(yaml_text: str) -> tuple[bool, str]:
    """Validate *yaml_text* against the scenario schema.

    Uses ``check-jsonschema`` CLI (YAML-aware).

    Returns ``(is_valid, error_message)``.
    """
    schema = _resolve_schema_path()
    if not schema.exists():
        return True, ""  # no schema, skip validation

    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".yaml",
        prefix="author-validate-",
        delete=False,
    ) as f:
        f.write(yaml_text)
        tmp_path = f.name

    try:
        result = subprocess.run(
            [
                "check-jsonschema",
                "--schemafile",
                str(schema),
                tmp_path,
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            return True, ""
        # Extract a useful error message from check-jsonschema output
        error_msg = result.stderr.strip() if result.stderr else result.stdout.strip()
        return False, error_msg
    except FileNotFoundError:
        _debug("check-jsonschema not found; skipping schema validation")
        return True, ""
    finally:
        Path(tmp_path).unlink(missing_ok=True)


# ── output emission ──────────────────────────────────────────────────────


def _emit_yaml(
    yaml_text: str,
    output: str | None,
    force: bool = False,  # noqa: FBT001, FBT002
) -> None:
    """Write *yaml_text* to *output* (or stdout).

    If *output* is an existing non-empty file and *force* is ``False``,
    refuses to overwrite.
    """
    if output:
        out_path = Path(output).resolve()
        if out_path.exists() and out_path.stat().st_size > 0 and not force:
            _die(
                f"ERROR: {out_path} already exists.\n"
                "  Use --force to overwrite.",
                code=16,
            )
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(yaml_text)
        print(f"Scenario written to {out_path}")
    else:
        sys.stdout.write(yaml_text)


# ── error formatting ─────────────────────────────────────────────────────


def _format_yaml_error(raw_error: str) -> str:
    """Format a YAML parse error for stderr output."""
    return raw_error


def _format_schema_error(raw_error: str) -> str:
    """Reformat check-jsonschema output into a concise diagnostic.

    Extracts field paths and the validation issue.
    """
    lines = raw_error.split("\n")
    clean_lines: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- $."):
            # Convert JSON path: $.cluster.provider → cluster.provider
            clean = stripped[5:]  # remove "- $."
            clean_lines.append(f"    • {clean}")
        elif stripped and not stripped.startswith("Schema"):
            clean_lines.append(f"    {stripped}")
    if not clean_lines:
        clean_lines = [raw_error]
    return "\n".join(clean_lines)


# ── main entry point ─────────────────────────────────────────────────────


def generate_author(  # noqa: PLR0913
    *,
    description: str | None,
    max_retries: int = 3,
    output: str | None = None,
    force: bool = False,  # noqa: FBT001, FBT002
    timeout: int = 120,
) -> None:
    """Author a scenario YAML from a natural-language description.

    Core flow:
      1. Validate *description* is non-empty / non-whitespace.
      2. Resolve ``CTS_LLM_CMD`` (or discover ``droid`` on PATH).
      3. Loop up to *max_retries*:
         a. Invoke LLM with the description as part of the prompt.
         b. Try to parse the LLM's output as YAML.
         c. If parseable → add ``generated_by`` provenance, validate against schema.
         d. If valid → emit and return.
         e. If invalid (parse or schema) → record error, retry or exit.
    """
    # ── 1. Validate description ────────────────────────────────────────────
    if not description or not description.strip():
        _die(
            "ERROR: A non-empty description is required.\n\n"
            "Usage: chart-test-swarm generate author <DESCRIPTION>\n\n"
            "Example:\n"
            "  chart-test-swarm generate author "
            '"istio with strict mTLS + cert-manager self-signed CA"',
            code=17,
        )
    desc = description.strip()
    _debug(f"Description: {desc}")

    # ── 2. Resolve LLM command ─────────────────────────────────────────────
    llm_cmd = _resolve_llm_cmd()

    # ── 3. Retry loop ──────────────────────────────────────────────────────
    last_error: str | None = None
    for attempt in range(1, max_retries + 1):
        _debug(f"Attempt {attempt}/{max_retries}")

        # 3a. Invoke LLM
        raw_output = _call_llm(llm_cmd, desc, timeout=timeout)

        # 3b. Try to parse as YAML (retryable on failure)
        data, yaml_error = _try_parse_yaml(raw_output)
        if data is None:
            # Unparseable YAML — retryable
            assert yaml_error is not None
            last_error = (
                f"LLM output is not valid YAML (attempt {attempt}/{max_retries}):\n"
                f"    • {yaml_error}"
            )
            _debug(f"YAML parse failed on attempt {attempt}: {yaml_error}")
            if attempt < max_retries:
                print(
                    f"LLM output is not valid YAML (attempt {attempt}/{max_retries}) "
                    "— retrying...",
                    file=sys.stderr,
                )
            continue

        _debug("YAML parsed successfully")

        # 3c. Add provenance and validate against schema
        data = _add_generated_by(data)
        yaml_text = yaml.dump(
            data, default_flow_style=False, sort_keys=False, allow_unicode=True
        )

        is_valid, schema_error = _validate_against_schema(yaml_text)
        if is_valid:
            _debug(f"Schema validation passed on attempt {attempt}")
            # 3d. Emit and exit
            _emit_yaml(yaml_text, output, force=force)
            return

        # 3e. Schema failure — retryable
        formatted_error = _format_schema_error(schema_error)
        last_error = (
            f"LLM output failed schema validation (attempt {attempt}/{max_retries}):\n"
            f"{formatted_error}"
        )
        _debug(f"Schema validation failed on attempt {attempt}")

        if attempt < max_retries:
            print(
                f"Schema validation failed on attempt {attempt}/{max_retries} — retrying...",
                file=sys.stderr,
            )

    # ── 4. Exhausted retries ───────────────────────────────────────────────
    if last_error:
        _die(f"ERROR: {last_error}", code=18)
    else:
        _die(
            f"ERROR: Failed to produce a schema-valid scenario after "
            f"{max_retries} attempt(s).",
            code=19,
        )
