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
) -> None:
    """Run scenarios against a Kubernetes cluster.

    Wraps ``engine/scripts/dispatch-swarm.sh`` with validated flags,
    cluster-name prefix enforcement, and a machine-readable RUN_ID on stdout.

    \b
    Examples:
        chart-test-swarm run --scenario examples/.../scenarios/minimal.yaml
        chart-test-swarm run --integration cert-manager --backend minikube -p 2
        chart-test-swarm run --suite all --project-dir ./my-chart
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
) -> None:
    """Build and view the test results dashboard.

    Wraps ``engine/scripts/build-dashboard.sh`` which invokes the testgrid
    Python collector and Jinja2 renderer to produce static HTML.

    \b
    Examples:
        chart-test-swarm dashboard
        chart-test-swarm dashboard --run-id run-20260520-101500
        chart-test-swarm dashboard --reports-dir /path/to/reports
    """
    from chart_test_swarm.commands.dashboard_cmd import dashboard as _dashboard_impl

    _dashboard_impl(
        run_id=run_id,
        reports_dir=reports_dir,
        project_dir=project_dir,
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
) -> None:
    """List available integration categories and their primers.

    Walks ``engine/skills/chart-test-swarm/references/integrations/<category>/``
    and emits one tab-separated line per primer in sorted order.

    \b
    Examples:
        chart-test-swarm list integrations
        chart-test-swarm list integrations --root /custom/integrations
    """
    from chart_test_swarm.commands.list_cmd import list_integrations as _list_integrations_impl

    _list_integrations_impl(root=root)


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


# -- register sub-apps -------------------------------------------------------

app.add_typer(list_app, name="list")
app.add_typer(generate_app, name="generate")


def main() -> None:
    """Entry point for the console_script. Calls app()."""
    app()


if __name__ == "__main__":
    main()
