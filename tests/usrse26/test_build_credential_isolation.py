from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "credential_isolation", ROOT / "platform/aws/assert_credential_free_build.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CredentialIsolationTests(unittest.TestCase):
    def inspect(
        self,
        environment: dict[str, str] | None = None,
        homes: list[Path] | None = None,
        tokens: list[Path] | None = None,
    ) -> dict[str, object]:
        return MODULE.inspect_sources(environment or {}, homes or [], tokens or [])

    def test_clean_environment_passes(self) -> None:
        report = self.inspect({"AWS_EC2_METADATA_DISABLED": "true"})
        self.assertTrue(report["commonAwsCredentialSourcesAbsent"])
        self.assertEqual(report["status"], "ENFORCED_COMMON_AWS_SOURCES_ABSENT")

    def test_aws_environment_is_rejected_without_exposing_value(self) -> None:
        report = self.inspect({"AWS_ACCESS_KEY_ID": "must-not-appear", "AWS_EC2_METADATA_DISABLED": "true"})
        self.assertFalse(report["commonAwsCredentialSourcesAbsent"])
        self.assertEqual(report["findings"], [{"kind": "environment", "source": "AWS_ACCESS_KEY_ID"}])
        self.assertNotIn("must-not-appear", str(report))

    def test_aws_home_configuration_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            config = home / ".aws/config"
            config.parent.mkdir(parents=True)
            config.write_text("[profile example]\n", encoding="utf-8")
            report = self.inspect(environment={"AWS_EC2_METADATA_DISABLED": "true"}, homes=[home])
        self.assertFalse(report["commonAwsCredentialSourcesAbsent"])
        self.assertEqual(report["findings"][0]["kind"], "aws-home")

    def test_service_account_token_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            token = Path(temp) / "token"
            token.write_text("must-not-appear", encoding="utf-8")
            report = self.inspect(environment={"AWS_EC2_METADATA_DISABLED": "true"}, tokens=[token])
        self.assertFalse(report["commonAwsCredentialSourcesAbsent"])
        self.assertEqual(report["findings"][0]["kind"], "service-token")
        self.assertNotIn("must-not-appear", str(report))

    def test_instance_metadata_must_be_disabled(self) -> None:
        report = self.inspect({})
        self.assertFalse(report["commonAwsCredentialSourcesAbsent"])
        self.assertIn(
            {"kind": "metadata-service", "source": "AWS_EC2_METADATA_DISABLED"},
            report["findings"],
        )

    def test_preflight_precedes_project_owned_preparation(self) -> None:
        script = (ROOT / "platform/aws/prepare-aws-artifacts.ps1").read_text(encoding="utf-8")
        guard = script.index("assert_credential_free_build.py")
        self.assertLess(guard, script.index("patch_fabric_network.py"))
        self.assertLess(guard, script.index("docker build"))


if __name__ == "__main__":
    unittest.main()
