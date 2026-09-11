from __future__ import annotations

import copy
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "osc_demo_lifecycle", ROOT / "platform/lifecycle/osc_demo_lifecycle.py"
)
assert SPEC and SPEC.loader
LIFECYCLE_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE_MODULE)
Lifecycle = LIFECYCLE_MODULE.Lifecycle
validate_sanitized_export = LIFECYCLE_MODULE.validate_sanitized_export


def valid_sanitized_export() -> dict:
    return {
        "schemaVersion": 1,
        "exportedAt": "2026-09-11T09:00:00Z",
        "status": {
            "state": "READ_ONLY",
            "opensAt": "2026-09-11T06:00:00Z",
            "closesAt": "2026-09-11T18:00:00Z",
        },
        "counters": {
            "anonymousBrowserSessions": 12,
            "acceptedArtifacts": 8,
            "confirmedArtifacts": 8,
            "acceptedWorkflows": 3,
            "confirmedWorkflows": 3,
            "provenanceHistoryViews": 5,
        },
        "survey": {
            "sampleSize": 2,
            "ratings": {
                "ease": {"1": 0, "2": 0, "3": 1, "4": 0, "5": 1},
                "provenance": {"1": 0, "2": 0, "3": 0, "4": 2, "5": 0},
                "usefulness": {"1": 0, "2": 0, "3": 0, "4": 1, "5": 1},
            },
        },
        "caveat": LIFECYCLE_MODULE.SANITIZED_EXPORT_CAVEAT,
    }


class CleanupFaultInjectionTests(unittest.TestCase):
    def lifecycle(self) -> Lifecycle:
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        instance.load_manifest = Mock(return_value={})
        instance.detach_origin = Mock(side_effect=RuntimeError("injected detach failure"))
        instance.restore_fallback = Mock()
        instance.delete_workloads = Mock()
        instance.reset_codebuild_network = Mock()
        instance.put_json = Mock()
        for name in ("detach_origin", "restore_fallback", "delete_workloads", "reset_codebuild_network"):
            getattr(instance, name).__name__ = name
        return instance

    def assert_every_cleanup_ran(self, instance: Lifecycle) -> None:
        instance.detach_origin.assert_called_once()
        instance.restore_fallback.assert_called_once()
        instance.delete_workloads.assert_called_once()
        instance.reset_codebuild_network.assert_called_once()
        instance.put_json.assert_called_once()

    def test_destroy_releases_network_and_continues_after_fault(self) -> None:
        instance = self.lifecycle()
        with self.assertRaisesRegex(RuntimeError, "injected detach failure"):
            instance.destroy()
        self.assert_every_cleanup_ran(instance)

    def test_failed_start_releases_network_and_continues_after_fault(self) -> None:
        instance = self.lifecycle()
        with self.assertRaisesRegex(RuntimeError, "injected detach failure"):
            instance.failed_start_cleanup()
        self.assert_every_cleanup_ran(instance)


class SanitizedExportAllowlistTests(unittest.TestCase):
    def test_accepts_the_exact_aggregate_schema(self) -> None:
        validate_sanitized_export(valid_sanitized_export())

    def test_rejects_invalid_types_times_states_and_distribution_totals(self) -> None:
        mutations = {}
        boolean_counter = valid_sanitized_export()
        boolean_counter["counters"]["acceptedArtifacts"] = True
        mutations["boolean counter"] = boolean_counter
        string_sample_size = valid_sanitized_export()
        string_sample_size["survey"]["sampleSize"] = "2"
        mutations["string sample size"] = string_sample_size
        float_rating_count = valid_sanitized_export()
        float_rating_count["survey"]["ratings"]["ease"]["5"] = 1.0
        mutations["float rating count"] = float_rating_count
        wrong_distribution_total = valid_sanitized_export()
        wrong_distribution_total["survey"]["ratings"]["provenance"]["5"] = 1
        mutations["wrong distribution total"] = wrong_distribution_total
        non_utc_time = valid_sanitized_export()
        non_utc_time["exportedAt"] = "2026-09-11T02:00:00-07:00"
        mutations["non UTC time"] = non_utc_time
        unknown_state = valid_sanitized_export()
        unknown_state["status"]["state"] = "UNKNOWN"
        mutations["unknown state"] = unknown_state

        for name, payload in mutations.items():
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                validate_sanitized_export(payload)

    def test_rejects_unapproved_root_nested_rows_and_identifiers_before_s3(self) -> None:
        mutations = {}
        unexpected_root = valid_sanitized_export()
        unexpected_root["ipAddress"] = "192.0.2.10"
        mutations["unexpected root"] = unexpected_root
        unexpected_nested = valid_sanitized_export()
        unexpected_nested["survey"]["ratings"]["ease"]["6"] = 1
        mutations["unexpected nested"] = unexpected_nested
        for field, value in (
            ("rawFeedback", [{"easeRating": 5}]),
            ("privateComment", "private"),
            ("sessionHash", "abc123"),
            ("submittedAt", "2026-09-11T08:59:00Z"),
            ("organizationId", "00000000-0000-0000-0000-000000000001"),
        ):
            payload = valid_sanitized_export()
            payload["survey"][field] = value
            mutations[field] = payload

        for name, payload in mutations.items():
            with self.subTest(name=name):
                instance = object.__new__(Lifecycle)
                instance.load_manifest = Mock(return_value={})
                instance.private_control_json = Mock(return_value=copy.deepcopy(payload))
                instance.put_json = Mock()
                with self.assertRaisesRegex(RuntimeError, "unapproved fields"):
                    instance.export()
                instance.put_json.assert_not_called()

class InfrastructureSafetyContractTests(unittest.TestCase):
    def test_stop_paths_always_reach_outside_vpc_destroy_and_sweep(self) -> None:
        machines = (ROOT / "terraform/usrse26-control/state-machines.tf").read_text(encoding="utf-8")
        self.assertIn("aws_codebuild_project.cleanup.name", machines)
        self.assertIn('ResultPath = "$.readOnlyFailure", Next = "NotifyReadOnlyFailure"', machines)
        self.assertIn('ResultPath = "$.exportFailure", Next = "NotifyExportFailure"', machines)
        self.assertIn('ResultPath = "$.workloadDestroyFailure", Next = "DestroyRuntime"', machines)
        self.assertIn('ResultPath = "$.runtimeDestroyFailure", Next = "Sweep"', machines)
        self.assertIn('ResultPath = "$.sweepFailure", Next = "NotifyIncompleteSweep"', machines)
        self.assertIn('ResultPath = "$.cleanupFailure", Next = "FailedStartDestroyRuntime"', machines)

    def test_local_iam_simulation_denies_escape_cases(self) -> None:
        for run_id in ("usrse26r1", "a" * 20):
            with self.subTest(run_id=run_id), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "iam-simulation.json"
                process = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "platform/aws/simulate_iam_boundary.py"),
                        "--terraform-root",
                        str(ROOT / "terraform/usrse26-control"),
                        "--run-id",
                        run_id,
                        "--output",
                        str(output),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                report = __import__("json").loads(output.read_text(encoding="utf-8"))
                self.assertTrue(report["allPassed"])
                self.assertLessEqual(report["boundaryPolicyCharacters"], report["managedPolicyQuotaCharacters"])
                denied = {item["name"] for item in report["cases"] if item["actual"] != "allowed"}
                self.assertIn("runtime role creation", denied)
                self.assertIn("inline policy mutation", denied)
                self.assertIn("trust policy mutation", denied)
                self.assertIn("assume altered runtime role", denied)
                self.assertIn("unlisted same-run pass role", denied)
                self.assertIn("pass role outside run prefix", denied)
                self.assertIn("pass role to unapproved service", denied)
                self.assertIn("budget mutation", denied)
                self.assertIn("unrelated S3 object", denied)
                self.assertIn("unrelated Secrets Manager secret", denied)
                self.assertIn("unrelated secret creation", denied)
                self.assertIn("broad inline policy intersected for unrelated data", denied)


if __name__ == "__main__":
    unittest.main()
