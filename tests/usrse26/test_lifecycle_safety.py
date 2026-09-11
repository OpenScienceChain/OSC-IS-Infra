from __future__ import annotations

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
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "iam-simulation.json"
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "platform/aws/simulate_iam_boundary.py"),
                    "--terraform-root",
                    str(ROOT / "terraform/usrse26-control"),
                    "--run-id",
                    "usrse26r1",
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            report = __import__("json").loads(output.read_text(encoding="utf-8"))
            self.assertTrue(report["allPassed"])
            denied = {item["name"] for item in report["cases"] if item["actual"] != "allowed"}
            self.assertIn("unbounded run role creation", denied)
            self.assertIn("arbitrary inline admin capability", denied)
            self.assertIn("administrator managed policy attachment", denied)
            self.assertIn("pass role outside run prefix", denied)
            self.assertIn("pass role to unapproved service", denied)


if __name__ == "__main__":
    unittest.main()
