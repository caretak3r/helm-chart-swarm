"""chart-test-swarm CLI — typer-based entry point for the Helm testgrid tool.

Provides four subcommands: run, dashboard, list, generate.
"""

from __future__ import annotations

import sys

import typer

from chart_test_swarm import __version__

app = typer.Typer(
    name="chart-test-swarm",
    help="Multi-integration Helm testgrid — exercise any Helm chart against the "
    "full Kubernetes ecosystem matrix.",
    no_args_is_help=True,
)

# -- version callback --------------------------------------------------------


def version_callback(value: bool) -> None:
    """Print the version from pyproject.toml and exit."""
    if value:
        print(f"chart-test-swarm {__version__}")
        raise typer.Exit()


@app.callback()
def root_callback(
    version: bool | None = typer.Option(
        None,
        "--version",
        callback=version_callback,
        is_eager=True,
        help="Show the version and exit.",
    ),
) -> None:
    """chart-test-swarm — Multi-integration Helm testgrid CLI."""
    pass


# -- run (F9.2 — wraps dispatch-swarm.sh with validated flags) ------------------


@app.command(name="run", help="Run scenarios against a Kubernetes cluster.")
def run_cmd(
    scenario: str | None = typer.Option(
        None,
        "--scenario",
        "-s",
        metavar="PATH",
        help="Path to a single scenario YAML file.",
    ),
    integration: str | None = typer.Option(
        None,
        "--integration",
        "-i",
        metavar="NAME",
        help="Filter scenarios by integration name (e.g. cert-manager).",
    ),
    backend: str | None = typer.Option(
        None,
        "--backend",
        "-b",
        metavar="PROVIDER",
        help="Cluster provider: kind|minikube|k3d|eks|gke|aks|vcluster.",
    ),
    parallelism: str | None = typer.Option(
        None,
        "--parallelism",
        "-p",
        metavar="N",
        help="Maximum number of concurrent scenarios (default: 2).",
    ),
    cluster_name: str = typer.Option(
        "chart-test-swarm-default",
        "--cluster-name",
        metavar="NAME",
        help="Cluster name (must start with chart-test-swarm-).",
    ),
    run_id: str | None = typer.Option(
        None,
        "--run-id",
        metavar="ID",
        help="Run identifier (default: auto-generated run-YYYYmmdd-HHMMSS-<pid>).",
    ),
    reports_dir: str | None = typer.Option(
        None,
        "--reports-dir",
        metavar="DIR",
        help="Override the reports root directory.",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project.",
    ),
    suite: str | None = typer.Option(
        None,
        "--suite",
        metavar="NAME",
        help="Suite name defined in chart-test-swarm.yaml (default: pr-subset).",
    ),
    include_cloud_native: bool = typer.Option(
        False,
        "--include-cloud-native",
        help="Include cloud-native scenarios (gke/eks/aks). "
        "Authored-only — no real cloud cluster operations are performed.",
    ),
    run_all: bool = typer.Option(
        False,
        "--all",
        help="Run ALL scenarios recursively across category subdirectories "
        "(VAL-CAT-002). Bypasses tag-based suite filtering; discovers every "
        "*.yaml under scenarios/ including category subdirs. Authored-only "
        "scenarios are skipped unless --include-cloud-native is also set.",
    ),
) -> None:
    """Run scenarios against a Kubernetes cluster.

    Wraps ``engine/scripts/dispatch-swarm.sh`` with validated flags,
    cluster-name prefix enforcement, and a machine-readable RUN_ID on stdout.

    \b
    Examples:
        chart-test-swarm run --scenario examples/.../scenarios/capability/minimal.yaml
        chart-test-swarm run --integration cert-manager --backend minikube -p 2
        chart-test-swarm run --suite all --project-dir ./my-chart
        chart-test-swarm run --all
        chart-test-swarm run --all --include-cloud-native
    """
    from chart_test_swarm.commands.run_cmd import run as _run_impl

    _run_impl(
        scenario=scenario,
        integration=integration,
        backend=backend,
        parallelism=parallelism,
        cluster_name=cluster_name,
        run_id=run_id,
        reports_dir=reports_dir,
        project_dir=project_dir,
        suite=suite,
        include_cloud_native=include_cloud_native,
        run_all=run_all,
    )


# -- dashboard (F9.3 — wraps build-dashboard.sh) --------------------------------


@app.command(name="dashboard", help="Build and view the test results dashboard.")
def dashboard_cmd(
    run_id: str | None = typer.Option(
        None,
        "--run-id",
        metavar="ID",
        help="Render only this run id (e.g. run-20260520-101500).",
    ),
    reports_dir: str | None = typer.Option(
        None,
        "--reports-dir",
        metavar="DIR",
        help="Reports root directory (default: auto-detected).",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project.",
    ),
    watch: bool = typer.Option(
        False,
        "--watch",
        help="Enter watch mode: poll for new or modified runs and rebuild "
        "the dashboard automatically.  Runs until interrupted (SIGINT).",
    ),
    interval: int = typer.Option(
        30,
        "--interval",
        metavar="SECONDS",
        help="Poll interval in seconds (default: 30, minimum: 5).",
    ),
    serve: bool = typer.Option(
        False,
        "--serve",
        help="Start a local HTTP server serving the dashboard.  Combined "
        "with --watch, the served dashboard updates live as new results "
        "land — no manual rebuild needed.",
    ),
    port: int = typer.Option(
        8080,
        "--port",
        metavar="PORT",
        help="Port for the HTTP server when --serve is used (default: 8080).",
    ),
) -> None:
    """Build and view the test results dashboard.

    Wraps ``engine/scripts/build-dashboard.sh`` which invokes the testgrid
    Python collector and Jinja2 renderer to produce static HTML.

    When ``--watch`` is set, enters a long-running polling process that
    monitors the reports directory for new or modified ``run-*``
    directories and rebuilds the dashboard automatically.

    When ``--serve`` is set, starts a local HTTP server serving the
    dashboard.  Combined with ``--watch``, successive HTTP fetches
    of the served index.html show monotonically growing covered-result
    content without a manual rebuild (VAL-E2E-014).

    \b
    Examples:
        chart-test-swarm dashboard
        chart-test-swarm dashboard --run-id run-20260520-101500
        chart-test-swarm dashboard --reports-dir /path/to/reports
        chart-test-swarm dashboard --watch
        chart-test-swarm dashboard --watch --interval 10
        chart-test-swarm dashboard --serve
        chart-test-swarm dashboard --watch --serve
        chart-test-swarm dashboard --watch --serve --port 3000
    """
    from chart_test_swarm.commands.dashboard_cmd import dashboard as _dashboard_impl

    _dashboard_impl(
        run_id=run_id,
        reports_dir=reports_dir,
        project_dir=project_dir,
        watch=watch,
        interval=interval,
        serve=serve,
        port=port,
    )


# -- list (sub-typer with integrations / variants) -----------------------------

list_app = typer.Typer(help="List integrations and scenario variants.", no_args_is_help=True)


@list_app.command(name="integrations")
def list_integrations_cmd(
    root: str | None = typer.Option(
        None,
        "--root",
        metavar="DIR",
        help="Path to the integrations root directory "
        "(default: engine/skills/chart-test-swarm/references/integrations).",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project. "
        "When provided, consumer primers from chart-test/primers/ are "
        "merged with engine primers (consumer-preferred).",
    ),
) -> None:
    """List available integration categories and their primers.

    Walks ``engine/skills/chart-test-swarm/references/integrations/<category>/``
    and emits one tab-separated line per primer in sorted order.  When
    ``--project-dir`` is provided, consumer primers are merged in
    (consumer-preferred, de-duplicated).

    \b
    Examples:
        chart-test-swarm list integrations
        chart-test-swarm list integrations --root /custom/integrations
        chart-test-swarm list integrations --project-dir ./my-chart
    """
    from chart_test_swarm.commands.list_cmd import list_integrations as _list_integrations_impl

    _list_integrations_impl(root=root, project_dir=project_dir)


@list_app.command(name="variants")
def list_variants_cmd(
    integration: str | None = typer.Option(
        None,
        "--integration",
        "-i",
        metavar="NAME",
        help="Filter variants by integration name (e.g. cert-manager).",
    ),
    scenarios_dir: str | None = typer.Option(
        None,
        "--scenarios-dir",
        metavar="DIR",
        help="Path to the scenarios directory (default: examples/.../chart-test/scenarios).",
    ),
) -> None:
    """List scenario variants, optionally filtered by integration.

    Walks ``examples/*/scenarios/`` recursively and prints matching YAML paths.
    When ``--integration`` is given, only files whose stem contains the
    integration name (case-insensitive) are emitted.

    \b
    Examples:
        chart-test-swarm list variants
        chart-test-swarm list variants --integration cert-manager
        chart-test-swarm list variants --integration nginx-ingress
            --scenarios-dir /path/to/scenarios
    """
    from chart_test_swarm.commands.list_cmd import list_variants as _list_variants_impl

    _list_variants_impl(
        integration=integration,
        scenarios_dir=scenarios_dir,
    )


# -- generate (sub-typer with pick / author / explore) -------------------------

generate_app = typer.Typer(
    help="Generate scenario YAMLs via LLM-driven exploration.",
    no_args_is_help=True,
)


@generate_app.command(name="pick")
def generate_pick(
    category: str | None = typer.Option(
        None,
        "--category",
        "-c",
        metavar="NAME",
        help="Integration category (e.g. certificates, ingress-controllers).",
    ),
    integration: str | None = typer.Option(
        None,
        "--integration",
        "-i",
        metavar="NAME",
        help="Integration name (e.g. cert-manager, nginx-ingress).",
    ),
    variant: str | None = typer.Option(
        None,
        "--variant",
        "-v",
        metavar="NAME",
        help="Variant name (e.g. self-signed, basic, wildcard). Substring match.",
    ),
    output: str | None = typer.Option(
        None,
        "--output",
        "-o",
        metavar="PATH",
        help="Write the scenario YAML to this file instead of stdout.",
    ),
    non_interactive: bool = typer.Option(
        False,
        "--non-interactive",
        help="Force non-interactive mode (no prompts).",
    ),
    scenarios_dir: str | None = typer.Option(
        None,
        "--scenarios-dir",
        metavar="DIR",
        help="Path to the scenarios directory (default: auto-detected).",
    ),
) -> None:
    """Select a scenario YAML from (category, integration, variant) tuples.

    Selection is non-interactive — use flags or pipe JSON/YAML to stdin.
    The matched scenario YAML is emitted to stdout (or --output file).

    \b
    Examples:
        chart-test-swarm generate pick --category certificates \\
            --integration cert-manager --variant self-signed
        echo '{"category":"certificates","integration":"cert-manager","variant":"wildcard"}' \\
            | chart-test-swarm generate pick
        chart-test-swarm generate pick -c certificates -i cert-manager \\
            -v self-signed --output /tmp/scenario.yaml
    """
    from chart_test_swarm.commands.generate_pick_cmd import (
        generate_pick as _generate_pick_impl,
    )

    # Read stdin if available (for piped JSON/YAML feed)
    stdin_feed: str | None = None
    if not sys.stdin.isatty():
        import contextlib

        with contextlib.suppress(Exception):
            stdin_feed = sys.stdin.read()

    _generate_pick_impl(
        category=category,
        integration=integration,
        variant=variant,
        output=output,
        non_interactive=non_interactive,
        stdin_feed=stdin_feed,
        scenarios_dir=scenarios_dir,
    )


@generate_app.command(name="author")
def generate_author(
    description: str | None = typer.Argument(
        None, help="Natural-language description of the scenario to author."
    ),
    max_retries: int = typer.Option(
        3,
        "--max-retries",
        "-r",
        metavar="N",
        help="Maximum number of LLM retries on invalid output (default: 3).",
    ),
    output: str | None = typer.Option(
        None,
        "--output",
        "-o",
        metavar="PATH",
        help="Write the generated scenario to this file instead of stdout.",
    ),
    force: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Overwrite the output file if it already exists.",
    ),
    timeout: int = typer.Option(
        120,
        "--timeout",
        metavar="SECONDS",
        help="Timeout in seconds for each LLM invocation (default: 120).",
    ),
) -> None:
    """Author a scenario YAML from a natural-language description.

    Shells out to ``CTS_LLM_CMD`` (env var) or auto-discovers ``droid`` on PATH.
    Retries bounded by ``--max-retries`` on invalid output. Rejects empty
    descriptions before invoking the LLM.

    The emitted scenario is validated against
    ``engine/templates/scenario.schema.json`` and carries ``generated_by``
    provenance.

    \b
    Examples:
        chart-test-swarm generate author \\
            "istio with strict mTLS + cert-manager self-signed CA"
        chart-test-swarm generate author \\
            "nginx ingress with TLS" --output /tmp/nginx-scenario.yaml
        chart-test-swarm generate author \\
            "custom integration" --max-retries 5 --force
    """
    from chart_test_swarm.commands.generate_author_cmd import (
        generate_author as _generate_author_impl,
    )

    _generate_author_impl(
        description=description,
        max_retries=max_retries,
        output=output,
        force=force,
        timeout=timeout,
    )


@generate_app.command(name="explore")
def generate_explore(
    chart: str = typer.Option(
        ...,
        "--chart",
        metavar="PATH",
        help="Path to the Helm chart directory.",
    ),
    integrations: str = typer.Option(
        ...,
        "--integrations",
        "-i",
        metavar="NAMES",
        help="Comma-separated integration names to explore (e.g. cert-manager,istio).",
    ),
    max_iterations: int = typer.Option(
        3,
        "--max-iterations",
        metavar="N",
        help="Maximum number of exploration iterations (default: 3).",
    ),
    budget: float | None = typer.Option(
        None,
        "--budget",
        metavar="USD",
        help="Halt exploration when cumulative LLM cost exceeds this budget.",
    ),
    output: str | None = typer.Option(
        None,
        "--output",
        "-o",
        metavar="PATH",
        help="Write the exploration summary JSON to this file.",
    ),
    force: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Overwrite the output file if it already exists.",
    ),
    timeout: int = typer.Option(
        120,
        "--timeout",
        metavar="SECONDS",
        help="Timeout in seconds for each LLM invocation (default: 120).",
    ),
    run_timeout: int = typer.Option(
        600,
        "--run-timeout",
        metavar="SECONDS",
        help="Timeout in seconds for each scenario run (default: 600).",
    ),
) -> None:
    """Iteratively explore and test scenario combinations via LLM.

    Shells out to ``CTS_LLM_CMD`` to propose scenario combos, validates each
    against the schema and cluster-name prefix, runs validated combos via
    ``CTS_RUN_CMD``, feeds results back to the LLM, and emits an
    incremental summary report. Bounded by ``--max-iterations`` and ``--budget``.

    \b
    Examples:
        chart-test-swarm generate explore \\
            --chart ./chart --integrations cert-manager
        chart-test-swarm generate explore \\
            --chart ./chart -i cert-manager,istio --max-iterations 5
        chart-test-swarm generate explore \\
            --chart ./chart -i cert-manager --budget 2.00 --output /tmp/summary.json
    """
    from chart_test_swarm.commands.generate_explore_cmd import (
        generate_explore as _generate_explore_impl,
    )

    _generate_explore_impl(
        chart=chart,
        integrations=integrations,
        max_iterations=max_iterations,
        budget=budget,
        output=output,
        force=force,
        timeout=timeout,
        run_timeout=run_timeout,
    )


# -- new (F14.1 — scaffold integration / capability tests) -------------------


@app.command(name="new", help="Scaffold a new integration or capability test.")
def new_cmd_wrapper(
    target: str = typer.Argument(
        ...,
        metavar="TARGET",
        help="Target to scaffold: <category>/<integration> or capability/<name>.",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project (default: auto-detected).",
    ),
    force: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Overwrite existing files if they already exist.",
    ),
    dry_run: bool = typer.Option(
        False,
        "--dry-run",
        help="Print prospective file paths without writing anything.",
    ),
    tier: str | None = typer.Option(
        None,
        "--tier",
        metavar="TIER",
        help="Override the default tier (live | capability | authored-only).",
    ),
    assert_type: str | None = typer.Option(
        None,
        "--assert-type",
        metavar="TYPE",
        help="Capability assert type (labels-present, rbac-objects, etc.).",
    ),
) -> None:
    """Scaffold a new integration or capability test.

    Creates fixture values, scenario YAML, and (for integrations) an
    executable smoke script under the chart-test/ tree. The chart's
    values.yaml is never modified.

    \b
    TARGET format:
      <category>/<integration>  — Integration mode (requires a primer)
      capability/<name>         — Capability mode (addon-less, no primer)

    \b
    Examples:
        chart-test-swarm new certificates/cert-manager
        chart-test-swarm new capability/labels
        chart-test-swarm new certificates/cert-manager --dry-run
        chart-test-swarm new certificates/cert-manager --force
        chart-test-swarm new networking/traefik --tier authored-only
        chart-test-swarm new capability/my-check --assert-type rbac-objects
    """
    from chart_test_swarm.commands.new_cmd import new_cmd as _new_impl

    _new_impl(
        target=target,
        project_dir=project_dir,
        force=force,
        dry_run=dry_run,
        tier=tier,
        assert_type=assert_type,
    )


# -- fix (f5-1 — agent-driven fix workflow) ----------------------------------


@app.command(name="fix", help="Apply an LLM-suggested fix to a chart and re-run the scenario.")
def fix_cmd_wrapper(
    rec_id: str = typer.Argument(
        ...,
        metavar="REC-ID",
        help="Recommendation ID to fix (e.g. rec-abc123).",
    ),
    reports_dir: str | None = typer.Option(
        None,
        "--reports-dir",
        metavar="DIR",
        help="Reports root directory (default: auto-detected).",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project (default: auto-detected).",
    ),
    timeout: int = typer.Option(
        120,
        "--timeout",
        metavar="SECONDS",
        help="Timeout in seconds for each LLM invocation (default: 120).",
    ),
    run_timeout: int = typer.Option(
        600,
        "--run-timeout",
        metavar="SECONDS",
        help="Timeout in seconds for the scenario re-run (default: 600).",
    ),
) -> None:
    """Apply an LLM-suggested fix to a chart and re-run the scenario.

    Reads the fix prompt file generated by the recommendations page,
    invokes ``CTS_LLM_CMD`` (or auto-discovers ``droid`` on PATH) to
    produce a chart fix, applies the suggestion, re-runs the scenario
    on a kind cluster, and updates the recommendation status.

    Exits non-zero if the rec-id is not found or CTS_LLM_CMD is not set.

    \b
    Examples:
        chart-test-swarm fix rec-abc123
        chart-test-swarm fix rec-abc123 --reports-dir /path/to/reports
        chart-test-swarm fix rec-abc123 --timeout 180 --run-timeout 900
    """
    from chart_test_swarm.commands.fix_cmd import fix_cmd as _fix_impl

    _fix_impl(
        rec_id=rec_id,
        reports_dir=reports_dir,
        project_dir=project_dir,
        timeout=timeout,
        run_timeout=run_timeout,
    )


# -- test (F-HST-1 — agentic full-matrix test loop) -----------------------------


@app.command(
    name="test",
    help="Run the full agentic test matrix loop: verify → cluster up → discover "
    "→ run scenarios → auto-fix FAILs → progressive dashboard rebuild → "
    "summary → teardown.",
)
def test_cmd(
    suite: str | None = typer.Option(
        None,
        "--suite",
        metavar="NAME",
        help="Suite name to filter scenarios (default: all).",
    ),
    max_fix_attempts: int = typer.Option(
        2,
        "--max-fix-attempts",
        metavar="N",
        help="Maximum LLM fix attempts per failing scenario (default: 2).",
    ),
    no_fix: bool = typer.Option(
        False,
        "--no-fix",
        help="Run and report only; never invoke the fix workflow or LLM.",
    ),
    rebuild_interval: int = typer.Option(
        5,
        "--rebuild-interval",
        metavar="N",
        help="Rebuild the dashboard every N scenarios (default: 5).",
    ),
    parallelism: int = typer.Option(
        1,
        "--parallelism",
        "-p",
        metavar="N",
        help="Concurrent scenarios for plain runs (default: 1).",
    ),
    cluster_name: str = typer.Option(
        "chart-test-swarm-default",
        "--cluster-name",
        metavar="NAME",
        help="Cluster name (must match ^chart-test-swarm-[a-z0-9-]+$). "
        "Default: chart-test-swarm-default.",
    ),
    backend: str = typer.Option(
        "kind",
        "--backend",
        "-b",
        metavar="PROVIDER",
        help="Cluster provider: kind|minikube|k3d (default: kind).",
    ),
    keep_cluster: bool = typer.Option(
        False,
        "--keep-cluster",
        help="Skip cluster teardown at the end (leave cluster for inspection).",
    ),
    project_dir: str | None = typer.Option(
        None,
        "--project-dir",
        metavar="DIR",
        help="Root of the consumer chart project (default: PROJECT_DIR env or cwd).",
    ),
    reports_dir: str | None = typer.Option(
        None,
        "--reports-dir",
        metavar="DIR",
        help="Override the reports root directory.",
    ),
) -> None:
    """Run the full agentic test matrix loop.

    Orchestrates the complete lifecycle: verify prerequisites,
    bring up a cluster, discover and run all support-matrix scenarios,
    automatically fix failures via LLM (bounded attempts), progressively
    rebuild the dashboard, print a summary, and tear down the cluster.

    \b
    Examples:
        chart-test-swarm test
        chart-test-swarm test --project-dir ./my-chart
        chart-test-swarm test --suite curated-live --no-fix
        chart-test-swarm test --max-fix-attempts 3 --rebuild-interval 3
        chart-test-swarm test --cluster-name chart-test-swarm-test1 --keep-cluster
    """
    from chart_test_swarm.commands.test_cmd import run_test_loop as _test_impl

    _test_impl(
        suite=suite,
        max_fix_attempts=max_fix_attempts,
        no_fix=no_fix,
        rebuild_interval=rebuild_interval,
        parallelism=parallelism,
        cluster_name=cluster_name,
        backend=backend,
        keep_cluster=keep_cluster,
        project_dir=project_dir,
        reports_dir=reports_dir,
    )


# -- register sub-apps -------------------------------------------------------

app.add_typer(list_app, name="list")
app.add_typer(generate_app, name="generate")


def main() -> None:
    """Entry point for the console_script. Calls app()."""
    app()


if __name__ == "__main__":
    main()
