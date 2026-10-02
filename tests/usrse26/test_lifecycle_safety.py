from __future__ import annotations

import copy
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "osc_demo_lifecycle", ROOT / "platform/lifecycle/osc_demo_lifecycle.py"
)
assert SPEC and SPEC.loader
LIFECYCLE_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE_MODULE)
Lifecycle = LIFECYCLE_MODULE.Lifecycle
validate_sanitized_export = LIFECYCLE_MODULE.validate_sanitized_export
tag_index_entry_is_active = LIFECYCLE_MODULE.tag_index_entry_is_active

PRIVATE_EXPORT_ENV = {
    "STATE_BUCKET": "osc-usrse26-usrse26r1-control-269624229733",
    "STATUS_BUCKET": "osc-usrse26-usrse26r1-edge-269624229733",
}
PUBLIC_ACCESS_BLOCK = {"PublicAccessBlockConfiguration": {
    key: True for key in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
}}


def valid_ux_metrics() -> dict:
    def funnel(stages):
        return [{"stage": stage, "consentingBrowsers": 0, "denominator": 0,
                 "dropOff": 0, "conversionFromPrevious": None} for stage in stages]

    return {
        "observedAt": "2026-10-02T12:00:00.000Z",
        "scope": "Last 30 days; analytics represent consenting browsers, not people or all visitors.",
        "truncated": False,
        "analyticsParticipation": {
            "consentingBrowsers": 0, "activeConsentCookies": 0,
            "consentAcceptActions": 0, "consentRejectActions": 1, "consentRevokeActions": 0,
            "caveat": "Accept/reject counts are button actions, not unique visitors.",
        },
        "visits": {"count": 0, "singlePageExits": 0, "engaged": 0, "idleMinutes": 30},
        "pageviews": 0, "routeViews": {}, "entryPages": {}, "exitPages": {},
        "journeys": {}, "actionCounts": {},
        "funnel": funnel(["FORM_START", "SUBMISSION_ATTEMPT", "UI_REPORTED_SUBMISSION"]),
        "explorationFunnel": funnel(["PAGE_VIEW", "RECORD_VIEW", "HISTORY_VIEW"]),
        "hourly": [{"hour": "2026-10-02T12:00Z", "phase": "LIVE", "runId": "usrse26r1",
                    "deviceCategory": "MOBILE", "pageviews": 0, "actions": 0,
                    "visits": 0, "singlePageExits": 0, "engagedVisits": 0, "consentingBrowsers": 0}],
        "hourlyAnonymousActions": [{"key": "2026-10-02T12:00Z|LIVE|usrse26r1",
                                    "counts": {"CONSENT_REJECTED": 1}}],
        "survey": {"opens": 1, "submissions": 1, "byPhase": {
            "LIVE|usrse26r1": {"submitted": 1, "visualRatings": {"5": 1},
                                "automationInterest": {"MAYBE": 1}},
        }},
        "caveat": "Client-reported completion actions are not ledger confirmations; compare against protected operational metrics.",
    }


def valid_ux_comments() -> dict:
    return {"exportedAt": "2026-10-02T12:00:00.000Z", "comments": [{
        "phase": "LIVE", "runId": "usrse26r1", "submittedAt": "2026-10-02T11:59:00.000Z",
        "overallComment": "PRIVATE_COMMENT_SENTINEL",
    }]}


def export_responses() -> list:
    return [valid_sanitized_export(), valid_ux_metrics(), valid_ux_comments()]


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


class TeardownTagIndexTests(unittest.TestCase):
    def test_ignores_deleted_ec2_tombstones_but_keeps_live_and_non_ec2_resources(self) -> None:
        active = {"volume": {"vol-live"}, "natgateway": set()}
        self.assertTrue(tag_index_entry_is_active(
            "arn:aws:ec2:us-west-2:269624229733:volume/vol-live", active
        ))
        self.assertFalse(tag_index_entry_is_active(
            "arn:aws:ec2:us-west-2:269624229733:volume/vol-deleted", active
        ))
        self.assertFalse(tag_index_entry_is_active(
            "arn:aws:ec2:us-west-2:269624229733:natgateway/nat-deleted", active
        ))
        self.assertTrue(tag_index_entry_is_active(
            "arn:aws:ecr:us-west-2:269624229733:repository/runtime", active
        ))


class RuntimeRepositoryInventoryTests(unittest.TestCase):
    def test_missing_repositories_are_absent_and_queries_stay_in_exact_run(self) -> None:
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        missing = subprocess.CompletedProcess([], 1, "", "RepositoryNotFoundException")
        with patch.object(LIFECYCLE_MODULE, "run", return_value=missing) as query:
            self.assertEqual(instance.runtime_repository_inventory(), [])
        self.assertEqual(query.call_count, len(LIFECYCLE_MODULE.RUNTIME_ECR_IMAGES))
        for call in query.call_args_list:
            args = call.args[0]
            self.assertTrue(args[args.index("--repository-names") + 1].startswith("osc-usrse26-usrse26r1/"))

    def test_access_denied_cannot_be_interpreted_as_empty_inventory(self) -> None:
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        denied = subprocess.CompletedProcess([], 1, "", "AccessDeniedException")
        with patch.object(LIFECYCLE_MODULE, "run", return_value=denied):
            with self.assertRaisesRegex(RuntimeError, "Could not verify runtime repository"):
                instance.runtime_repository_inventory()

    def test_existing_repository_is_reported(self) -> None:
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        found = subprocess.CompletedProcess([], 0, '{"repositories":[{"repositoryName":"osc-usrse26-usrse26r1/chaincode"}]}', "")
        with patch.object(LIFECYCLE_MODULE, "RUNTIME_ECR_IMAGES", {"chaincode"}), patch.object(LIFECYCLE_MODULE, "run", return_value=found):
            self.assertEqual(instance.runtime_repository_inventory(), [{"repositoryName": "osc-usrse26-usrse26r1/chaincode"}])


class AmazonMqLogCleanupTests(unittest.TestCase):
    def test_deletes_only_log_groups_under_the_exact_broker_prefix(self) -> None:
        instance = object.__new__(Lifecycle)
        prefix = "/aws/amazonmq/broker/b-cdeabca8-9245-4b2a-b8bf-7b9d25af9c56/"
        with (
            patch.object(LIFECYCLE_MODULE, "aws_json", return_value={
                "logGroups": [
                    {"logGroupName": prefix + "channel"},
                    {"logGroupName": prefix + "general"},
                ]
            }),
            patch.object(LIFECYCLE_MODULE, "aws") as delete,
        ):
            instance.delete_amazon_mq_log_groups(
                "b-cdeabca8-9245-4b2a-b8bf-7b9d25af9c56"
            )
        self.assertEqual(delete.call_count, 2)
        for call in delete.call_args_list:
            self.assertTrue(call.args[-1].startswith(prefix))

    def test_rejects_an_unexpected_broker_identifier(self) -> None:
        instance = object.__new__(Lifecycle)
        with self.assertRaisesRegex(RuntimeError, "unexpected format"):
            instance.delete_amazon_mq_log_groups("../../unbounded")


class SanitizedExportAllowlistTests(unittest.TestCase):
    def test_checksum_matches_exact_bytes_uploaded_by_put_json(self) -> None:
        import hashlib
        import json

        with tempfile.TemporaryDirectory() as temp:
            instance = object.__new__(Lifecycle)
            instance.work = Path(temp)
            instance.run_id = "usrse26r1"
            instance.load_manifest = Mock(return_value={})
            instance.private_control_json = Mock(side_effect=export_responses())
            uploaded = {}

            def capture_upload(*args):
                target = Path(args[args.index("--body") + 1])
                self.assertEqual(args[args.index("--bucket") + 1], PRIVATE_EXPORT_ENV["STATE_BUCKET"])
                self.assertEqual(args[args.index("--server-side-encryption") + 1], "AES256")
                if os.name == "posix":
                    self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
                uploaded[args[args.index("--key") + 1]] = target.read_bytes()

            with (patch.object(LIFECYCLE_MODULE, "aws", side_effect=capture_upload),
                  patch.object(LIFECYCLE_MODULE, "aws_json", return_value=PUBLIC_ACCESS_BLOCK),
                  patch.dict(os.environ, PRIVATE_EXPORT_ENV)):
                instance.export()
            export_key = "evidence/usrse26r1/sanitized-export.json"
            checksum = json.loads(uploaded["evidence/usrse26r1/sanitized-export.checksum.json"])
            self.assertEqual(checksum["objectKey"], export_key)
            self.assertEqual(checksum["sha256"], hashlib.sha256(uploaded[export_key]).hexdigest())
            completion = json.loads(uploaded["evidence/usrse26r1/export-complete.json"])
            self.assertEqual(len(completion["objects"]), 3)
            self.assertFalse(completion["publicReleaseApproved"])
            for entry in completion["objects"]:
                self.assertEqual(entry["sha256"], hashlib.sha256(uploaded[entry["objectKey"]]).hexdigest())
            self.assertEqual(list(uploaded)[-1], "evidence/usrse26r1/export-complete.json")
            self.assertNotIn(b"PRIVATE_COMMENT_SENTINEL", uploaded[export_key])
            self.assertNotIn(b"PRIVATE_COMMENT_SENTINEL", uploaded["evidence/usrse26r1/restricted/ux-metrics.json"])

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
                instance.run_id = "usrse26r1"
                instance.load_manifest = Mock(return_value={})
                instance.private_control_json = Mock(return_value=copy.deepcopy(payload))
                instance.put_json = Mock()
                with (patch.object(LIFECYCLE_MODULE, "aws_json", return_value=PUBLIC_ACCESS_BLOCK),
                      patch.dict(os.environ, PRIVATE_EXPORT_ENV),
                      self.assertRaisesRegex(RuntimeError, "evidence is incomplete")):
                    instance.export()
                instance.put_json.assert_not_called()


class ProtectedUxExportTests(unittest.TestCase):
    def instance(self, responses=None):
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        instance.load_manifest = Mock(return_value={})
        instance.private_control_json = Mock(side_effect=responses or export_responses())
        instance.put_json = Mock()
        return instance

    def test_all_endpoints_use_private_transport_and_exact_private_bucket(self):
        instance = self.instance()
        with patch.dict(os.environ, PRIVATE_EXPORT_ENV), patch.object(LIFECYCLE_MODULE, "aws_json", return_value=PUBLIC_ACCESS_BLOCK) as verify:
            instance.export()
        verify.assert_called_once_with("s3api", "get-public-access-block", "--bucket", PRIVATE_EXPORT_ENV["STATE_BUCKET"])
        self.assertEqual([call.args[0] for call in instance.private_control_json.call_args_list], [
            "/api/v1/demo/internal/export", "/api/v1/demo/internal/ux-metrics",
            "/api/v1/demo/internal/ux-feedback/comments",
        ])
        self.assertEqual(instance.put_json.call_count, 7)
        for call in instance.put_json.call_args_list:
            self.assertEqual(call.args[2], PRIVATE_EXPORT_ENV["STATE_BUCKET"])
            self.assertTrue(call.args[0].startswith("evidence/usrse26r1/"))

    def test_wrong_public_or_unverifiable_destination_blocks_fetch_and_write(self):
        for env, protection in (
            ({**PRIVATE_EXPORT_ENV, "STATE_BUCKET": PRIVATE_EXPORT_ENV["STATUS_BUCKET"]}, PUBLIC_ACCESS_BLOCK),
            ({**PRIVATE_EXPORT_ENV, "STATUS_BUCKET": PRIVATE_EXPORT_ENV["STATE_BUCKET"]}, PUBLIC_ACCESS_BLOCK),
            ({**PRIVATE_EXPORT_ENV, "STATE_BUCKET": "unrelated-private-bucket"}, PUBLIC_ACCESS_BLOCK),
            (PRIVATE_EXPORT_ENV, {}),
            (PRIVATE_EXPORT_ENV, {"PublicAccessBlockConfiguration": {"BlockPublicAcls": True}}),
        ):
            instance = self.instance()
            with patch.dict(os.environ, env), patch.object(LIFECYCLE_MODULE, "aws_json", return_value=protection), self.assertRaises(RuntimeError):
                instance.export()
            instance.private_control_json.assert_not_called()
            instance.put_json.assert_not_called()
        for flag in PUBLIC_ACCESS_BLOCK["PublicAccessBlockConfiguration"]:
            protection = copy.deepcopy(PUBLIC_ACCESS_BLOCK)
            protection["PublicAccessBlockConfiguration"][flag] = False
            instance = self.instance()
            with patch.dict(os.environ, PRIVATE_EXPORT_ENV), patch.object(LIFECYCLE_MODULE, "aws_json", return_value=protection), self.assertRaises(RuntimeError):
                instance.export()
            instance.private_control_json.assert_not_called()

    def test_malformed_ux_responses_block_all_uploads_without_echoing_content(self):
        mutations = [
            (1, ["secret"], "SECRET_SENTINEL"),
            (1, ["routeViews", "/artifacts/SECRET_SENTINEL"], 1),
            (1, ["hourly", 0, "browserHash"], "SECRET_SENTINEL"),
            (1, ["hourlyAnonymousActions", 0, "key"], "2026-10-02T12:00Z|LIVE|SECRET_SENTINEL"),
            (1, ["survey", "byPhase", "LIVE|usrse26r1", "automationInterest", "SECRET_SENTINEL"], 1),
            (1, ["pageviews"], True),
            (1, ["funnel", 0, "conversionFromPrevious"], float("nan")),
            (1, ["truncated"], "false"),
            (2, ["comments", 0, "sessionHash"], "SECRET_SENTINEL"),
            (2, ["comments", 0, "overallComment"], "x" * 301),
            (2, ["comments", 0, "runId"], "SECRET_SENTINEL"),
        ]
        for index, path, value in mutations:
            with self.subTest(path=path):
                responses = export_responses()
                target = responses[index]
                for part in path[:-1]:
                    target = target[part]
                target[path[-1]] = value
                instance = self.instance(responses)
                with patch.dict(os.environ, PRIVATE_EXPORT_ENV), patch.object(LIFECYCLE_MODULE, "aws_json", return_value=PUBLIC_ACCESS_BLOCK), self.assertRaises(RuntimeError) as error:
                    instance.export()
                instance.put_json.assert_not_called()
                self.assertNotIn("SECRET_SENTINEL", str(error.exception))
                self.assertTrue(error.exception.__suppress_context__)

    def test_transport_and_upload_failures_never_mark_complete_or_echo_content(self):
        for stage in ("protection", "metrics", "comments", "upload"):
            instance = self.instance()
            verify = Mock(return_value=PUBLIC_ACCESS_BLOCK)
            failure = RuntimeError("SECRET_SENTINEL PRIVATE_COMMENT_SENTINEL")
            if stage == "protection":
                verify.side_effect = failure
            elif stage in {"metrics", "comments"}:
                responses = export_responses()
                responses[1 if stage == "metrics" else 2] = failure
                instance.private_control_json.side_effect = responses
            else:
                instance.put_json.side_effect = failure
            with patch.dict(os.environ, PRIVATE_EXPORT_ENV), patch.object(LIFECYCLE_MODULE, "aws_json", verify), self.assertRaisesRegex(RuntimeError, "evidence is incomplete") as error:
                instance.export()
            self.assertNotIn("SENTINEL", str(error.exception))
            self.assertFalse(any(call.args[0].endswith("export-complete.json") for call in instance.put_json.call_args_list))

    def test_private_transport_suppresses_cli_and_parse_details(self):
        for result in (RuntimeError("SECRET_SENTINEL"), "SECRET_SENTINEL"):
            instance = object.__new__(Lifecycle)
            instance.configure_kubectl = Mock()
            instance.kubectl = Mock(side_effect=result) if isinstance(result, Exception) else Mock(return_value=result)
            with self.assertRaisesRegex(RuntimeError, "Private control request failed") as error:
                instance.private_control_json("/api/v1/demo/internal/ux-feedback/comments")
            self.assertNotIn("SECRET_SENTINEL", str(error.exception))
            script = instance.kubectl.call_args.args[7]
            self.assertIn("redirect:'error'", script)
            self.assertNotIn("console.error(e.message)", script)
            self.assertNotIn("text.slice", script)

    def test_schema_accepts_optional_answers_and_truncation_without_changing_scope(self):
        metrics = valid_ux_metrics()
        metrics["truncated"] = True
        metrics["survey"]["byPhase"]["LIVE|usrse26r1"]["visualRatings"] = {}
        metrics["survey"]["byPhase"]["REHEARSAL|unassigned"] = {
            "submitted": 1, "visualRatings": {}, "automationInterest": {},
        }
        LIFECYCLE_MODULE.validate_ux_metrics(metrics)
        comments = valid_ux_comments()
        comments["comments"][0]["overallComment"] = "Unreviewed text may contain SECRET_SENTINEL"
        LIFECYCLE_MODULE.validate_ux_comments(comments)
        comments["comments"][0]["overallComment"] = "\U0001f600" * 300
        LIFECYCLE_MODULE.validate_ux_comments(comments)

    @unittest.skipUnless(shutil.which("node"), "Node.js is required for the private transport harness")
    def test_node_transport_errors_do_not_read_or_print_response_bodies(self):
        instance = object.__new__(Lifecycle)
        instance.configure_kubectl = Mock()
        instance.kubectl = Mock(return_value="{}")
        instance.private_control_json("/api/v1/demo/internal/ux-feedback/comments")
        script = instance.kubectl.call_args.args[7]
        for failure in (
            "return {ok:false,status:403,text:async()=>{throw new Error('SECRET_SENTINEL')}};",
            "throw new Error('SECRET_SENTINEL');",
        ):
            stub = "global.fetch=async(url,options)=>{" + failure + "};"
            process = subprocess.run(
                ["node", "-e", stub + script, "GET", "/api/v1/demo/internal/ux-feedback/comments", ""],
                capture_output=True, text=True,
            )
            self.assertEqual(process.returncode, 1)
            self.assertEqual(process.stdout, "")
            self.assertEqual(process.stderr.strip(), "Private control request failed")

    def test_bucket_verification_permission_is_scoped_to_control_bucket(self):
        source = (ROOT / "terraform/usrse26-control/lifecycle.tf").read_text(encoding="utf-8")
        statement = source.split('Sid      = "VerifyPrivateEvidenceBucket"', 1)[1].split("},", 1)[0]
        self.assertIn('Action   = ["s3:GetBucketPublicAccessBlock"]', statement)
        self.assertIn('Resource = "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}"', statement)

class InfrastructureSafetyContractTests(unittest.TestCase):
    def test_monitor_starts_teardown_at_persisted_runtime_deadline_without_billing_call(self) -> None:
        instance = object.__new__(Lifecycle)
        instance.run_id = "usrse26r1"
        instance.load_manifest = Mock(return_value={"expiresAt": "2026-09-10T00:00:00Z"})
        instance.start_safety_teardown = Mock()
        instance.put_json = Mock()
        with patch.dict(os.environ, {
            "PLANNING_ESTIMATE_USD": "104.83",
            "HARD_CLOSE_AT": "2026-10-23T15:00:00Z",
        }, clear=True):
            instance.monitor()
        instance.load_manifest.assert_called_once_with(allow_expired=True)
        instance.start_safety_teardown.assert_called_once_with("runtime-deadline")
        instance.put_json.assert_called_once()
        evidence = instance.put_json.call_args.args[1]
        self.assertTrue(evidence["runtimeDeadlineReached"])
        self.assertEqual(evidence["costControl"]["actualBilledCost"]["status"], "NOT_RECONCILED")

    def test_guard_enforces_time_bounded_mode_estimate_and_teardown_authority(self) -> None:
        environment = {
            "RUN_ID": "autousrse26r1",
            "EXPECTED_ACCOUNT_ID": "269624229733",
            "EXPECTED_REGION": "us-west-2",
            "AWS_DEFAULT_REGION": "us-west-2",
            "COST_CONTROL_MODE": "TIME_BOUNDED",
            "MAX_RUNTIME_HOURS": "72",
            "PLANNING_ESTIMATE_CEILING_USD": "200",
            "PLANNING_ESTIMATE_USD": "104.83",
            "HARD_CLOSE_AT": "2026-10-23T15:00:00Z",
            "STOP_STATE_MACHINE_ARN": "arn:aws:states:us-west-2:269624229733:stateMachine:osc-usrse26-autousrse26r1-stop",
        }
        with patch.object(LIFECYCLE_MODULE, "aws_json", return_value={"Account": "269624229733"}):
            with patch.dict(os.environ, environment, clear=True):
                Lifecycle().guard("START")
            with patch.dict(os.environ, {**environment, "RUN_ID": "manualrun1"}, clear=True):
                with self.assertRaisesRegex(RuntimeError, "auto-prefixed"):
                    Lifecycle().guard("START")
            for key, value in (
                ("COST_CONTROL_MODE", "LIVE_BUDGET"),
                ("PLANNING_ESTIMATE_USD", "200.01"),
                ("MAX_RUNTIME_HOURS", "73"),
                ("STOP_STATE_MACHINE_ARN", "arn:aws:states:us-west-2:269624229733:stateMachine:wrong"),
            ):
                with self.subTest(key=key), patch.dict(os.environ, {**environment, key: value}, clear=True):
                    with self.assertRaises(RuntimeError):
                        Lifecycle().guard("START")

    def test_stop_paths_always_reach_outside_vpc_destroy_and_sweep(self) -> None:
        machines = (ROOT / "terraform/usrse26-control/state-machines.tf").read_text(encoding="utf-8")
        self.assertIn("aws_codebuild_project.cleanup.name", machines)
        self.assertIn('ResultPath = "$.readOnlyFailure", Next = "NotifyReadOnlyFailure"', machines)
        self.assertIn('ResultPath = "$.exportFailure", Next = "NotifyExportFailure"', machines)
        self.assertIn('ResultPath = "$.workloadDestroyFailure", Next = "DestroyRuntime"', machines)
        self.assertIn('ResultPath = "$.runtimeDestroyFailure", Next = "Sweep"', machines)
        self.assertIn('ResultPath = "$.sweepFailure", Next = "NotifyIncompleteSweep"', machines)
        self.assertIn('ResultPath = "$.cleanupFailure", Next = "FailedStartDestroyRuntime"', machines)
        for result_path in (
            "readOnlyResult",
            "exportResult",
            "workloadDestroyResult",
            "runtimeDestroyResult",
            "sweepResult",
        ):
            with self.subTest(result_path=result_path):
                self.assertIn(f'ResultPath = "$.{result_path}"', machines)

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
                self.assertIn("unrelated S3 object", denied)
                self.assertIn("deny edge bucket protection read", denied)
                self.assertIn("deny unrelated bucket protection read", denied)
                self.assertIn("unrelated Secrets Manager secret", denied)
                self.assertIn("unrelated secret creation", denied)
                self.assertIn("broad inline policy intersected for unrelated data", denied)
                self.assertEqual(report["forbiddenBillingActions"], [])


if __name__ == "__main__":
    unittest.main()
