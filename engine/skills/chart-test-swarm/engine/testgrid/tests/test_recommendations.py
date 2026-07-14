"""Tests for recommendations engine (f3-1-recommendations-engine).

Covers VAL-REC-001 through VAL-REC-012:
  VAL-REC-001: Engine produces recommendations from FAIL scenario results
  VAL-REC-002: Auto-classification assigns chart-fix to capability failures
  VAL-REC-003: Auto-classification assigns gap-probe to honest integration gaps
  VAL-REC-004: Auto-classification assigns infrastructure to CNI/proxy failures
  VAL-REC-005: Auto-classification assigns schema-missing to unclassifiable failures
  VAL-REC-006: Recommendation has all required fields populated
  VAL-REC-007: Deduplication merges same failure across runs into one recommendation
  VAL-REC-008: Fix prompt includes chart context for LLM agent consumption
  VAL-REC-009: Deterministic IDs—same input always produces same recommendation ID
  VAL-REC-010: Severity assignment—high for security/RBAC, medium for
               labels/annotations, low for gaps
  VAL-REC-011: Persistence to recommendations.json survives engine restart
  VAL-REC-012: Dashboard rebuild updates recommendations—new FAILs added, resolved marked
"""

from __future__ import annotations

import json
from pathlib import Path

from testgrid.collect import Assertion, Run, Scenario
from testgrid.recommendations import (
    GAP_PROBE_PATTERNS,
    assign_severity,
    classify_failure,
    count_open_recommendations,
    generate_recommendations,
    load_recommendations,
    save_recommendations,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_scenario(
    scenario_id: str,
    status: str = "FAIL",
    fail_stage: str = "",
    fail_msg: str = "",
    asserts: list[Assertion] | None = None,
) -> Scenario:
    """Create a minimal Scenario for testing."""
    return Scenario(
        id=scenario_id,
        name=scenario_id,
        status=status,
        fail_stage=fail_stage,
        fail_msg=fail_msg,
        asserts=asserts or [],
    )


def _make_run(run_id: str, scenarios: list[Scenario]) -> Run:
    """Create a minimal Run for testing."""
    return Run(run_id=run_id, scenarios=scenarios)


def _make_fail_scenario(
    scenario_id: str,
    assert_type: str,
    notes: str = "",
    fail_stage: str = "",
    fail_msg: str = "",
) -> Scenario:
    """Create a FAIL scenario with one failing assertion."""
    return _make_scenario(
        scenario_id=scenario_id,
        status="FAIL",
        fail_stage=fail_stage,
        fail_msg=fail_msg,
        asserts=[Assertion(type=assert_type, status="FAIL", notes=notes)],
    )


# ---------------------------------------------------------------------------
# VAL-REC-001: Engine produces recommendations from FAIL scenario results
# ---------------------------------------------------------------------------


class TestEngineProducesRecommendations:
    """VAL-REC-001: Engine produces one recommendation per distinct FAIL scenario."""

    def test_produces_recs_for_fail_scenarios(self) -> None:
        """Engine returns one recommendation per FAIL scenario."""
        scenarios = [
            _make_fail_scenario("annotations-on", "annotations-present"),
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        assert len(recs) == 3

    def test_pass_scenarios_excluded(self) -> None:
        """PASS scenarios must not produce recommendations."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_scenario("minimal", status="PASS"),
            _make_scenario("with-cert-manager", status="PASS"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        assert len(recs) == 1
        assert recs[0].scenario_id == "labels-on"

    def test_six_fail_scenarios_produce_six_recs(self) -> None:
        """Curated-live style: 6 FAIL scenarios → 6 recommendations."""
        scenarios = [
            _make_fail_scenario(
                "annotations-on",
                "annotations-present",
                notes="Service/sample missing annotation example.com/owner",
            ),
            _make_fail_scenario(
                "labels-on", "labels-present", notes="Deployment/sample missing label cost-center"
            ),
            _make_fail_scenario(
                "rbac-on", "rbac-objects", notes="No ServiceAccount found in namespace sample"
            ),
            _make_fail_scenario(
                "scheme-https-only", "scheme-enforced", notes="Service has HTTP port 80 exposed"
            ),
            _make_fail_scenario(
                "ingress-controllers-contour-basic-httpproxy",
                "pods-ready",
                notes="HTTPProxy not emitted by chart",
            ),
            _make_fail_scenario(
                "policy-opa-gatekeeper-required-labels",
                "pods-ready",
                notes="Ingress rejected by gatekeeper constraint",
            ),
        ]
        run = _make_run("run-curated-001", scenarios)
        recs = generate_recommendations([run])
        assert len(recs) == 6

    def test_empty_runs_produces_no_recs(self) -> None:
        """No runs → no recommendations."""
        recs = generate_recommendations([])
        assert recs == []

    def test_run_with_no_fails_produces_no_recs(self) -> None:
        """Runs with only PASS scenarios → no recommendations."""
        scenarios = [
            _make_scenario("minimal", status="PASS"),
            _make_scenario("with-cert-manager", status="PASS"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        assert recs == []


# ---------------------------------------------------------------------------
# VAL-REC-002: Auto-classification assigns chart-fix to capability failures
# ---------------------------------------------------------------------------


class TestClassifyChartFix:
    """VAL-REC-002: Capability FAILs → chart-fix category."""

    def test_labels_present_is_chart_fix(self) -> None:
        s = _make_fail_scenario("labels-on", "labels-present")
        assert classify_failure(s) == "chart-fix"

    def test_annotations_present_is_chart_fix(self) -> None:
        s = _make_fail_scenario("annotations-on", "annotations-present")
        assert classify_failure(s) == "chart-fix"

    def test_rbac_objects_is_chart_fix(self) -> None:
        s = _make_fail_scenario("rbac-on", "rbac-objects")
        assert classify_failure(s) == "chart-fix"

    def test_scheme_enforced_is_chart_fix(self) -> None:
        s = _make_fail_scenario("scheme-https-only", "scheme-enforced")
        assert classify_failure(s) == "chart-fix"

    def test_security_context_is_chart_fix(self) -> None:
        s = _make_fail_scenario("security-ctx", "security-context")
        assert classify_failure(s) == "chart-fix"

    def test_network_policy_is_chart_fix(self) -> None:
        s = _make_fail_scenario("netpol", "network-policy")
        assert classify_failure(s) == "chart-fix"

    def test_imagepullsecrets_is_chart_fix(self) -> None:
        s = _make_fail_scenario("pull-secret", "imagepullsecrets-present")
        assert classify_failure(s) == "chart-fix"

    def test_resources_present_is_chart_fix(self) -> None:
        s = _make_fail_scenario("resources", "resources-present")
        assert classify_failure(s) == "chart-fix"


# ---------------------------------------------------------------------------
# VAL-REC-003: Auto-classification assigns gap-probe to honest integration gaps
# ---------------------------------------------------------------------------


class TestClassifyGapProbe:
    """VAL-REC-003: Contour HTTPProxy and Gatekeeper required-labels → gap-probe."""

    def test_contour_httpproxy_is_gap_probe(self) -> None:
        s = _make_fail_scenario("ingress-controllers-contour-basic-httpproxy", "pods-ready")
        assert classify_failure(s) == "gap-probe"

    def test_gatekeeper_required_labels_is_gap_probe(self) -> None:
        s = _make_fail_scenario("policy-opa-gatekeeper-required-labels", "pods-ready")
        assert classify_failure(s) == "gap-probe"

    def test_gap_probe_has_gap_probe_in_scenario_id(self) -> None:
        """Any scenario containing GAP_PROBE_PATTERNS substring → gap-probe."""
        for pattern in GAP_PROBE_PATTERNS:
            s = _make_fail_scenario(f"scenario-{pattern}-extra", "pods-ready")
            assert classify_failure(s) == "gap-probe", f"Failed for pattern: {pattern}"


# ---------------------------------------------------------------------------
# VAL-REC-004: Auto-classification assigns infrastructure to CNI/proxy failures
# ---------------------------------------------------------------------------


class TestClassifyInfrastructure:
    """VAL-REC-004: CNI/proxy fail_msg → infrastructure category."""

    def test_cni_in_fail_msg_is_infrastructure(self) -> None:
        s = _make_scenario(
            "customer-A-istio",
            status="FAIL",
            fail_stage="preinstall",
            fail_msg="CNI plugin calico not ready",
        )
        assert classify_failure(s) == "infrastructure"

    def test_proxy_in_fail_msg_is_infrastructure(self) -> None:
        s = _make_scenario(
            "scenario-proxy-err",
            status="FAIL",
            fail_msg="proxy configuration missing for the cluster",
        )
        assert classify_failure(s) == "infrastructure"

    def test_istio_cni_in_fail_msg_is_infrastructure(self) -> None:
        s = _make_scenario(
            "customer-A-istio",
            status="FAIL",
            fail_msg="istio-cni-node not installed",
        )
        assert classify_failure(s) == "infrastructure"

    def test_calico_in_fail_msg_is_infrastructure(self) -> None:
        s = _make_scenario(
            "calico-test",
            status="FAIL",
            fail_msg="calico daemonset not ready",
        )
        assert classify_failure(s) == "infrastructure"

    def test_flannel_in_fail_msg_is_infrastructure(self) -> None:
        s = _make_scenario(
            "flannel-test",
            status="FAIL",
            fail_msg="flannel network plugin failed",
        )
        assert classify_failure(s) == "infrastructure"


# ---------------------------------------------------------------------------
# VAL-REC-005: Auto-classification assigns schema-missing to unclassifiable failures
# ---------------------------------------------------------------------------


class TestClassifySchemaMissing:
    """VAL-REC-005: Unclassifiable FAIL → schema-missing."""

    def test_unknown_assert_type_is_schema_missing(self) -> None:
        s = _make_fail_scenario("unknown-scenario", "some-unknown-assert-type")
        assert classify_failure(s) == "schema-missing"

    def test_product_install_fail_without_keywords_is_schema_missing(self) -> None:
        s = _make_scenario(
            "test-scenario",
            status="FAIL",
            fail_stage="product-install",
            fail_msg="chart not found at /path/to/chart",
        )
        assert classify_failure(s) == "schema-missing"

    def test_no_asserts_no_keywords_is_schema_missing(self) -> None:
        s = _make_scenario(
            "misc-fail",
            status="FAIL",
            fail_stage="validation",
            fail_msg="unexpected error occurred",
        )
        assert classify_failure(s) == "schema-missing"


# ---------------------------------------------------------------------------
# VAL-REC-006: Recommendation has all required fields populated
# ---------------------------------------------------------------------------


class TestAllFieldsPopulated:
    """VAL-REC-006: Every recommendation must have all required fields non-empty."""

    def test_all_fields_non_empty(self) -> None:
        """Every recommendation must have all required fields populated."""
        scenarios = [
            _make_fail_scenario(
                "labels-on",
                "labels-present",
                notes="Deployment/sample missing label cost-center=42",
            ),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        assert len(recs) == 1
        rec = recs[0]

        assert rec.id, "id must be non-empty"
        assert rec.scenario_id, "scenario_id must be non-empty"
        assert rec.category, "category must be non-empty"
        assert rec.severity, "severity must be non-empty"
        assert rec.title, "title must be non-empty"
        assert rec.detail, "detail must be non-empty"
        assert rec.status, "status must be non-empty"
        assert rec.run_refs, "run_refs must be non-empty"
        assert rec.fix_prompt, "fix_prompt must be non-empty"
        # affected_objects may be empty list if notes don't mention k8s types
        assert isinstance(rec.affected_objects, list), "affected_objects must be a list"

    def test_required_fields_for_all_six_scenarios(self) -> None:
        """All 6 curated scenarios must have fully populated recommendations."""
        scenarios = [
            _make_fail_scenario(
                "annotations-on",
                "annotations-present",
                notes="Service/sample missing annotation example.com/owner",
            ),
            _make_fail_scenario(
                "labels-on",
                "labels-present",
                notes="Deployment/sample missing label cost-center=42",
            ),
            _make_fail_scenario("rbac-on", "rbac-objects"),
            _make_fail_scenario("scheme-https-only", "scheme-enforced"),
            _make_fail_scenario("ingress-controllers-contour-basic-httpproxy", "pods-ready"),
            _make_fail_scenario("policy-opa-gatekeeper-required-labels", "pods-ready"),
        ]
        run = _make_run("run-curated-001", scenarios)
        recs = generate_recommendations([run])
        assert len(recs) == 6

        required_fields = [
            "id",
            "scenario_id",
            "category",
            "severity",
            "title",
            "detail",
            "status",
            "run_refs",
            "fix_prompt",
        ]
        for rec in recs:
            for field_name in required_fields:
                val = getattr(rec, field_name)
                assert val, f"Rec {rec.scenario_id}: field '{field_name}' must be non-empty"


# ---------------------------------------------------------------------------
# VAL-REC-007: Deduplication merges same failure across runs
# ---------------------------------------------------------------------------


class TestDeduplication:
    """VAL-REC-007: Same scenario in multiple runs → one recommendation."""

    def test_same_scenario_in_two_runs_produces_one_rec(self) -> None:
        """Same failing scenario in run-1 and run-2 → one rec with both run_refs."""
        scenario1 = _make_fail_scenario(
            "labels-on", "labels-present", notes="Deployment/sample missing label cost-center=42"
        )
        scenario2 = _make_fail_scenario(
            "labels-on", "labels-present", notes="Deployment/sample missing label cost-center=42"
        )
        run1 = _make_run("run-001", [scenario1])
        run2 = _make_run("run-002", [scenario2])
        recs = generate_recommendations([run1, run2])

        assert len(recs) == 1
        assert set(recs[0].run_refs) == {"run-001", "run-002"}

    def test_different_scenarios_in_two_runs_produce_separate_recs(self) -> None:
        """Different scenarios produce separate recommendations."""
        scenario1 = _make_fail_scenario("labels-on", "labels-present")
        scenario2 = _make_fail_scenario("rbac-on", "rbac-objects")
        run1 = _make_run("run-001", [scenario1])
        run2 = _make_run("run-002", [scenario2])
        recs = generate_recommendations([run1, run2])

        assert len(recs) == 2

    def test_same_scenario_three_runs_has_three_run_refs(self) -> None:
        """Same scenario across 3 runs → one rec with 3 run_refs."""
        s = _make_fail_scenario("annotations-on", "annotations-present")
        run1 = _make_run("run-001", [s])
        run2 = _make_run("run-002", [s])
        run3 = _make_run("run-003", [s])
        recs = generate_recommendations([run1, run2, run3])

        assert len(recs) == 1
        assert len(recs[0].run_refs) == 3
        assert "run-001" in recs[0].run_refs
        assert "run-002" in recs[0].run_refs
        assert "run-003" in recs[0].run_refs

    def test_dedup_does_not_duplicate_run_refs(self) -> None:
        """Same run appearing twice doesn't add duplicate run_refs."""
        s = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-001", [s])
        recs = generate_recommendations([run1, run1])
        assert len(recs) == 1
        assert recs[0].run_refs.count("run-001") == 1


# ---------------------------------------------------------------------------
# VAL-REC-008: Fix prompt includes chart context
# ---------------------------------------------------------------------------


class TestFixPromptContent:
    """VAL-REC-008: Fix prompt must include chart-specific context."""

    def test_fix_prompt_mentions_scenario_id(self) -> None:
        s = _make_fail_scenario(
            "labels-on", "labels-present", notes="Deployment/sample missing label cost-center=42"
        )
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run])
        assert "labels-on" in recs[0].fix_prompt

    def test_fix_prompt_mentions_chart_path(self) -> None:
        s = _make_fail_scenario("labels-on", "labels-present")
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run], chart_path="examples/my-chart")
        assert "examples/my-chart" in recs[0].fix_prompt

    def test_fix_prompt_mentions_affected_objects(self) -> None:
        s = _make_fail_scenario(
            "labels-on",
            "labels-present",
            notes="Deployment/sample missing label cost-center=42. Service/sample also affected.",
        )
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run])
        # Notes mention Deployment and Service → should appear in fix_prompt
        # or affected_objects list
        assert "Deployment" in recs[0].fix_prompt or "Deployment" in recs[0].affected_objects

    def test_fix_prompt_non_empty_for_all_categories(self) -> None:
        """Fix prompt must be non-empty for all four categories."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),  # chart-fix
            _make_scenario("infra-fail", status="FAIL", fail_msg="CNI not ready"),  # infrastructure
            _make_fail_scenario(
                "ingress-controllers-contour-basic-httpproxy", "pods-ready"
            ),  # gap-probe
            _make_fail_scenario("misc", "unknown-type"),  # schema-missing
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        for rec in recs:
            assert rec.fix_prompt, f"fix_prompt empty for {rec.scenario_id}"

    def test_fix_prompt_includes_failure_detail(self) -> None:
        """Fix prompt includes the assertion notes as failure detail."""
        notes = "Service/sample missing annotation example.com/owner"
        s = _make_fail_scenario("annotations-on", "annotations-present", notes=notes)
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run])
        assert notes in recs[0].fix_prompt

    def test_fix_prompt_chart_fix_mentions_specific_fix(self) -> None:
        """Chart-fix fix_prompt must mention actionable instructions."""
        s = _make_fail_scenario("rbac-on", "rbac-objects")
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run])
        # Should mention templates directory and RBAC objects
        assert "templates" in recs[0].fix_prompt.lower() or "rbac" in recs[0].fix_prompt.lower()


# ---------------------------------------------------------------------------
# VAL-REC-009: Deterministic IDs
# ---------------------------------------------------------------------------


class TestDeterministicIDs:
    """VAL-REC-009: Same input always produces same recommendation IDs."""

    def test_same_input_same_id(self) -> None:
        """Running engine twice on same data produces same IDs."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
        ]
        run = _make_run("run-001", scenarios)

        recs1 = generate_recommendations([run])
        recs2 = generate_recommendations([run])

        ids1 = sorted(r.id for r in recs1)
        ids2 = sorted(r.id for r in recs2)
        assert ids1 == ids2

    def test_id_format_is_rec_prefix_plus_hash(self) -> None:
        """Recommendation IDs start with 'rec-' followed by hex chars."""
        s = _make_fail_scenario("labels-on", "labels-present")
        run = _make_run("run-001", [s])
        recs = generate_recommendations([run])
        assert len(recs) == 1
        assert recs[0].id.startswith("rec-")
        # Hex part must be all hexadecimal
        hex_part = recs[0].id[4:]
        assert all(c in "0123456789abcdef" for c in hex_part)

    def test_different_scenarios_different_ids(self) -> None:
        """Different (scenario_id, failure_type) pairs produce different IDs."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
            _make_fail_scenario("annotations-on", "annotations-present"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        ids = [r.id for r in recs]
        assert len(ids) == len(set(ids)), "All IDs must be unique"

    def test_id_independent_of_run_id(self) -> None:
        """ID depends only on scenario_id and failure_type, not on run_id."""
        s1 = _make_fail_scenario("labels-on", "labels-present")
        s2 = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-AAA", [s1])
        run2 = _make_run("run-ZZZ", [s2])
        recs1 = generate_recommendations([run1])
        recs2 = generate_recommendations([run2])
        assert recs1[0].id == recs2[0].id


# ---------------------------------------------------------------------------
# VAL-REC-010: Severity assignment
# ---------------------------------------------------------------------------


class TestSeverityAssignment:
    """VAL-REC-010: Severity must match expected levels."""

    def test_rbac_objects_is_high_severity(self) -> None:
        s = _make_fail_scenario("rbac-on", "rbac-objects")
        assert assign_severity(s, "chart-fix") == "high"

    def test_scheme_enforced_is_high_severity(self) -> None:
        s = _make_fail_scenario("scheme-https-only", "scheme-enforced")
        assert assign_severity(s, "chart-fix") == "high"

    def test_labels_present_is_medium_severity(self) -> None:
        s = _make_fail_scenario("labels-on", "labels-present")
        assert assign_severity(s, "chart-fix") == "medium"

    def test_annotations_present_is_medium_severity(self) -> None:
        s = _make_fail_scenario("annotations-on", "annotations-present")
        assert assign_severity(s, "chart-fix") == "medium"

    def test_gap_probe_is_low_severity(self) -> None:
        s = _make_fail_scenario("ingress-controllers-contour-basic-httpproxy", "pods-ready")
        assert assign_severity(s, "gap-probe") == "low"

    def test_gatekeeper_gap_probe_is_low_severity(self) -> None:
        s = _make_fail_scenario("policy-opa-gatekeeper-required-labels", "pods-ready")
        assert assign_severity(s, "gap-probe") == "low"

    def test_infrastructure_is_low_severity(self) -> None:
        s = _make_scenario("infra-fail", status="FAIL", fail_msg="CNI plugin not ready")
        assert assign_severity(s, "infrastructure") == "low"

    def test_end_to_end_severity_from_generate_recommendations(self) -> None:
        """End-to-end: severity assignments via generate_recommendations."""
        scenarios = [
            _make_fail_scenario("rbac-on", "rbac-objects"),
            _make_fail_scenario("scheme-https-only", "scheme-enforced"),
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("annotations-on", "annotations-present"),
            _make_fail_scenario("ingress-controllers-contour-basic-httpproxy", "pods-ready"),
            _make_fail_scenario("policy-opa-gatekeeper-required-labels", "pods-ready"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        by_sid = {r.scenario_id: r for r in recs}

        assert by_sid["rbac-on"].severity == "high"
        assert by_sid["scheme-https-only"].severity == "high"
        assert by_sid["labels-on"].severity == "medium"
        assert by_sid["annotations-on"].severity == "medium"
        assert by_sid["ingress-controllers-contour-basic-httpproxy"].severity == "low"
        assert by_sid["policy-opa-gatekeeper-required-labels"].severity == "low"


# ---------------------------------------------------------------------------
# VAL-REC-011: Persistence to recommendations.json
# ---------------------------------------------------------------------------


class TestPersistence:
    """VAL-REC-011: recommendations.json survives engine restart."""

    def test_save_and_load_roundtrip(self, tmp_path: Path) -> None:
        """Recommendations saved and loaded are identical."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])

        save_recommendations(tmp_path, recs)
        loaded = load_recommendations(tmp_path)

        assert len(loaded) == len(recs)
        orig_ids = sorted(r.id for r in recs)
        loaded_ids = sorted(r.id for r in loaded)
        assert orig_ids == loaded_ids

    def test_saved_file_is_valid_json(self, tmp_path: Path) -> None:
        """recommendations.json must be valid JSON with 'recommendations' array."""
        scenarios = [_make_fail_scenario("labels-on", "labels-present")]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        save_recommendations(tmp_path, recs)

        rec_json = tmp_path / "recommendations.json"
        assert rec_json.is_file()

        data = json.loads(rec_json.read_text(encoding="utf-8"))
        assert "recommendations" in data
        assert isinstance(data["recommendations"], list)

    def test_count_open_recommendations(self, tmp_path: Path) -> None:
        """count_open_recommendations() returns correct open count."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        # All start as "open"
        save_recommendations(tmp_path, recs)

        assert count_open_recommendations(tmp_path) == 2

    def test_count_open_excludes_fixed(self, tmp_path: Path) -> None:
        """count_open_recommendations() excludes fixed/dismissed recommendations."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
            _make_fail_scenario("rbac-on", "rbac-objects"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        # Mark one as fixed
        recs[0].status = "fixed"
        save_recommendations(tmp_path, recs)

        assert count_open_recommendations(tmp_path) == 1

    def test_load_missing_file_returns_empty(self, tmp_path: Path) -> None:
        """load_recommendations() returns empty list when file is missing."""
        recs = load_recommendations(tmp_path)
        assert recs == []

    def test_count_open_missing_file_returns_zero(self, tmp_path: Path) -> None:
        """count_open_recommendations() returns 0 when file is missing."""
        assert count_open_recommendations(tmp_path) == 0

    def test_persistence_survives_multiple_saves(self, tmp_path: Path) -> None:
        """Re-saving does not corrupt the file; loaded count matches saved count."""
        scenarios = [
            _make_fail_scenario("labels-on", "labels-present"),
        ]
        run = _make_run("run-001", scenarios)
        recs = generate_recommendations([run])
        save_recommendations(tmp_path, recs)
        save_recommendations(tmp_path, recs)  # Save again — should overwrite cleanly

        loaded = load_recommendations(tmp_path)
        assert len(loaded) == 1


# ---------------------------------------------------------------------------
# VAL-REC-012: Dashboard rebuild updates recommendations
# ---------------------------------------------------------------------------


class TestDashboardRebuildUpdates:
    """VAL-REC-012: New FAILs added, resolved scenarios marked fixed."""

    def test_new_fail_adds_new_rec(self) -> None:
        """A new FAIL scenario in a new run creates a new recommendation."""
        existing_s = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-001", [existing_s])
        recs_after_run1 = generate_recommendations([run1])

        new_s = _make_fail_scenario("rbac-on", "rbac-objects")
        run2 = _make_run("run-002", [new_s])
        recs_after_run2 = generate_recommendations([run1, run2], existing=recs_after_run1)

        assert len(recs_after_run2) == 2
        scenario_ids = {r.scenario_id for r in recs_after_run2}
        assert "labels-on" in scenario_ids
        assert "rbac-on" in scenario_ids

    def test_resolved_scenario_marked_fixed(self) -> None:
        """When a previously-failing scenario now passes, its status is set to 'fixed'."""
        s_fail = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-001", [s_fail])
        existing_recs = generate_recommendations([run1])
        assert all(r.status == "open" for r in existing_recs)

        # Run 2: labels-on now passes
        s_pass = _make_scenario("labels-on", status="PASS")
        run2 = _make_run("run-002", [s_pass])

        recs_after_run2 = generate_recommendations([run2], existing=existing_recs)

        # labels-on not failing in run2 → should be marked fixed
        assert len(recs_after_run2) == 1
        assert recs_after_run2[0].scenario_id == "labels-on"
        assert recs_after_run2[0].status == "fixed"

    def test_open_count_decreases_after_fix(self, tmp_path: Path) -> None:
        """Open recommendation count decreases when scenario passes."""
        s_fail = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-001", [s_fail])
        recs = generate_recommendations([run1])
        save_recommendations(tmp_path, recs)
        assert count_open_recommendations(tmp_path) == 1

        s_pass = _make_scenario("labels-on", status="PASS")
        run2 = _make_run("run-002", [s_pass])
        updated_recs = generate_recommendations([run2], existing=recs)
        save_recommendations(tmp_path, updated_recs)
        assert count_open_recommendations(tmp_path) == 0

    def test_in_progress_rec_marked_fixed_when_resolved(self) -> None:
        """When a previously in_progress recommendation's failure resolves, it is marked fixed."""
        s_fail = _make_fail_scenario("rbac-on", "rbac-objects")
        run1 = _make_run("run-001", [s_fail])
        existing_recs = generate_recommendations([run1])
        # Simulate user setting status to in_progress
        existing_recs[0].status = "in_progress"

        # Run 2: rbac-on now passes
        s_pass = _make_scenario("rbac-on", status="PASS")
        run2 = _make_run("run-002", [s_pass])

        recs_after_run2 = generate_recommendations([run2], existing=existing_recs)
        assert len(recs_after_run2) == 1
        assert recs_after_run2[0].status == "fixed"

    def test_dismissed_rec_preserved_when_resolved(self) -> None:
        """When a dismissed recommendation's failure resolves, it stays dismissed."""
        s_fail = _make_fail_scenario("labels-on", "labels-present")
        run1 = _make_run("run-001", [s_fail])
        existing_recs = generate_recommendations([run1])
        # Simulate user dismissing the recommendation
        existing_recs[0].status = "dismissed"
        existing_recs[0].dismissed_reason = "Not applicable to this chart"

        # Run 2: labels-on now passes
        s_pass = _make_scenario("labels-on", status="PASS")
        run2 = _make_run("run-002", [s_pass])

        recs_after_run2 = generate_recommendations([run2], existing=existing_recs)
        assert len(recs_after_run2) == 1
        assert recs_after_run2[0].status == "dismissed"
        assert recs_after_run2[0].dismissed_reason == "Not applicable to this chart"

    def test_fixed_rec_stays_fixed_when_resolved(self) -> None:
        """When a fixed recommendation's failure remains resolved, it stays fixed."""
        s_fail = _make_fail_scenario("annotations-on", "annotations-present")
        run1 = _make_run("run-001", [s_fail])
        existing_recs = generate_recommendations([run1])
        existing_recs[0].status = "fixed"

        # Run 2: annotations-on still passes
        s_pass = _make_scenario("annotations-on", status="PASS")
        run2 = _make_run("run-002", [s_pass])

        recs_after_run2 = generate_recommendations([run2], existing=existing_recs)
        assert len(recs_after_run2) == 1
        assert recs_after_run2[0].status == "fixed"
