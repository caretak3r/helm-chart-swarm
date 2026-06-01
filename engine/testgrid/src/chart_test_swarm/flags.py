"""Flag → env-var mapping for subprocess dispatch.

Every CLI flag that forwards to engine scripts has a documented mapping here.
Run ``chart-test-swarm run`` with ``CTS_DEBUG=1`` to see the env vars in the trace.
"""

from __future__ import annotations

from typing import Final

# ── Flag → env-var mapping table (VAL-CLI-022) ──────────────────────────────
#
#   CLI flag            Env var          Notes
#   ─────────────────   ─────────────    ─────────────────────────────────
#   --backend           PROVIDER         kind|minikube|k3d|eks|gke|aks|vcluster
#   --parallelism       NUM_AGENTS       Positive integer; passed as 3rd arg too
#   --cluster-name      CLUSTER_NAME     Must match ^chart-test-swarm-[a-z0-9-]+$
#   --run-id            RUN_ID           Defaults to run-YYYYmmdd-HHMMSS-<pid>
#   --reports-dir       REPORTS_DIR      Override reports root directory
#   --project-dir       PROJECT_DIR      Root of consumer chart project
#   --suite             SUITE            Suite name from chart-test-swarm.yaml
#   --scenario          CTS_SCENARIOS    Newline-sep list of scenario file paths
#   --integration       CTS_SCENARIOS    CLI filters scenarios by integration name

FLAG_TO_ENV: Final[dict[str, str]] = {
    "backend": "PROVIDER",
    "parallelism": "NUM_AGENTS",
    "cluster_name": "CLUSTER_NAME",
    "run_id": "RUN_ID",
    "reports_dir": "REPORTS_DIR",
    "project_dir": "PROJECT_DIR",
    "suite": "SUITE",
}

# ── Supported backends (must match the schema enum) ─────────────────────────

SUPPORTED_BACKENDS: Final[list[str]] = [
    "kind",
    "minikube",
    "k3d",
    "eks",
    "gke",
    "aks",
    "vcluster",
]

# ── Cluster name prefix requirement ────────────────────────────────────────

CLUSTER_NAME_PATTERN: Final[str] = r"^chart-test-swarm-[a-z0-9-]+$"
