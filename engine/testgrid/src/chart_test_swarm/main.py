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
    )


# -- dashboard (direct command, flags added in F9.3) ---------------------------


@app.command(name="dashboard", help="Build and view the test results dashboard.")
def dashboard_cmd() -> None:
    """Build and view the test results dashboard.

    (Stub — full implementation in F9.3.)
    """
    print("dashboard: stub — F9.3 will wire build-dashboard.sh", file=sys.stderr)
    raise typer.Exit(code=1)


# -- list (sub-typer with integrations / variants) -----------------------------

list_app = typer.Typer(help="List integrations and scenario variants.", no_args_is_help=True)


@list_app.command(name="integrations")
def list_integrations() -> None:
    """List available integration categories and their primers.

    (Stub — full implementation in F9.4.)
    """
    print("list integrations: stub — F9.4 will walk integration subdirs", file=sys.stderr)
    raise typer.Exit(code=1)


@list_app.command(name="variants")
def list_variants(
    integration: str | None = typer.Option(
        None,
        "--integration",
        help="Filter variants by integration name.",
    ),
) -> None:
    """List scenario variants, optionally filtered by integration.

    (Stub — full implementation in F9.4.)
    """
    if integration:
        print(f"list variants --integration {integration}: stub", file=sys.stderr)
    else:
        print("list variants: stub — F9.4 will walk scenario directories", file=sys.stderr)
    raise typer.Exit(code=1)


# -- generate (sub-typer with pick / author / explore) -------------------------

generate_app = typer.Typer(
    help="Generate scenario YAMLs via LLM-driven exploration.",
    no_args_is_help=True,
)


@generate_app.command(name="pick")
def generate_pick() -> None:
    """Select a scenario from (category, integration, variant) tuples.

    (Stub — full implementation in F10.1.)
    """
    print("generate pick: stub — F10.1 will implement selector", file=sys.stderr)
    raise typer.Exit(code=1)


@generate_app.command(name="author")
def generate_author(
    description: str | None = typer.Argument(
        None, help="Natural-language description of the scenario to author."
    ),
) -> None:
    """Author a scenario YAML from a natural-language description.

    (Stub — full implementation in F10.2.)
    """
    print("generate author: stub — F10.2 will wire CTS_LLM_CMD", file=sys.stderr)
    raise typer.Exit(code=1)


@generate_app.command(name="explore")
def generate_explore() -> None:
    """Iteratively explore and test scenario combinations via LLM.

    (Stub — full implementation in F10.3.)
    """
    print("generate explore: stub — F10.3 will implement iterative exploration", file=sys.stderr)
    raise typer.Exit(code=1)


# -- register sub-apps -------------------------------------------------------

app.add_typer(list_app, name="list")
app.add_typer(generate_app, name="generate")


def main() -> None:
    """Entry point for the console_script. Calls app()."""
    app()


if __name__ == "__main__":
    main()
