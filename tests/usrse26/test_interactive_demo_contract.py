from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RuntimeTopologyTests(unittest.TestCase):
    def test_three_az_nodes_and_multi_az_rabbitmq(self) -> None:
        network = read("terraform/usrse26-eks/network.tf")
        eks = read("terraform/usrse26-eks/eks.tf")
        broker = json.loads(read("terraform/usrse26-eks/templates/rabbitmq.json"))
        self.assertIn('count = 3', network)
        self.assertIn('default = 3', read("terraform/usrse26-eks/variables.tf"))
        self.assertIn('desired_size = var.node_count', eks)
        properties = broker["Resources"]["Broker"]["Properties"]
        self.assertEqual(properties["DeploymentMode"], "CLUSTER_MULTI_AZ")
        self.assertEqual(properties["EngineType"], "RABBITMQ")
        self.assertFalse(properties["PubliclyAccessible"])

    def test_replicas_spreading_pdbs_and_internal_pod_ip_alb(self) -> None:
        for manifest in (
            "api-gateway.yaml",
            "submission-services.yaml",
            "ledger-gateways.yaml",
            "history-workers.yaml",
        ):
            text = read(f"platform/gitops/aws/{manifest}")
            self.assertNotIn("replicas: 1", text)
            self.assertRegex(text, r"replicas: [2-9]")
            self.assertIn("topologySpreadConstraints", text)
        availability = read("platform/gitops/aws/availability.yaml")
        self.assertEqual(availability.count("kind: PodDisruptionBudget"), 7)
        ingress = read("platform/gitops/aws/internal-ingress.yaml")
        self.assertIn("alb.ingress.kubernetes.io/scheme: internal", ingress)
        self.assertIn("alb.ingress.kubernetes.io/target-type: ip", ingress)
        self.assertIn("alb.ingress.kubernetes.io/security-groups: osc-usrse26-__RUN_ID__-cloudfront-origin", ingress)
        self.assertIn('alb.ingress.kubernetes.io/manage-backend-security-group-rules: "true"', ingress)
        self.assertNotIn("NodePort", ingress)

    def test_fabric_contract_is_three_orderers_two_peers_per_org(self) -> None:
        config = json.loads(read("docs/usrse26/interactive-demo-config.json"))
        self.assertEqual(config["topology"]["fabricOrderers"], 3)
        self.assertEqual(config["topology"]["fabricPeersPerOrganization"], 2)
        patcher = read("platform/scripts/patch_fabric_network.py")
        self.assertIn('for org in ("org0", "org1", "org2")', patcher)
        self.assertIn("launch_chaincode_service ${org} peer2", patcher)

    def test_fabric_topology_validator_accepts_only_the_required_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            network = Path(temp) / "network"
            (network / "scripts").mkdir(parents=True)
            required = [
                "kube/org0/org0-orderer1.yaml",
                "kube/org0/org0-orderer2.yaml",
                "kube/org0/org0-orderer3.yaml",
                "kube/org1/org1-peer1.yaml",
                "kube/org1/org1-peer2.yaml",
                "kube/org2/org2-peer1.yaml",
                "kube/org2/org2-peer2.yaml",
            ]
            lines = [f"apply_template {path}" for path in required]
            (network / "scripts/test_network.sh").write_text("\n".join(lines), encoding="utf-8")
            for relative in required:
                path = network / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("image: example.invalid/osc@sha256:" + "a" * 64, encoding="utf-8")
            deploy = Path(temp) / "deploy.sh"
            deploy.write_text("TEST_NETWORK_ORDERER_TYPE=raft\n", encoding="utf-8")
            command = [
                sys.executable,
                str(ROOT / "platform/scripts/validate_fabric_topology.py"),
                "--network", str(network),
                "--deploy-script", str(deploy),
            ]
            accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            (network / "kube/org2/org2-peer2.yaml").unlink()
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)

    def test_network_policy_is_default_deny_without_blanket_app_rule(self) -> None:
        policies = read("platform/gitops/aws/network-policies.yaml")
        self.assertIn("metadata: {name: default-deny", policies)
        self.assertNotIn("metadata: {name: application-paths", policies)
        self.assertIn("metadata: {name: worker-to-ledger-gateways", policies)
        self.assertIn("metadata: {name: ledger-to-fabric", policies)

    def test_history_routing_and_demo_secrets_are_organization_bound(self) -> None:
        api = read("platform/gitops/aws/api-gateway.yaml")
        history = read("platform/gitops/aws/history-workers.yaml")
        secrets = read("platform/gitops/aws/namespace-and-secrets.yaml")
        self.assertIn("GHW_NSG_URL", api)
        self.assertIn("GHW_CITIZEN_SCIENCE_URL", api)
        self.assertIn("api-demo-auth", api)
        self.assertIn("ledger-gateway-nsg-auth", history)
        self.assertIn("ledger-gateway-citizen-science-auth", history)
        self.assertEqual(history.count("name: LEDGER_GATEWAY_TOKEN"), 2)
        for name in ("demo-jwt-secret", "demo-analytics-hmac-secret", "demo-control-api-key"):
            self.assertIn(name, secrets)

    def test_local_browser_stack_uses_digest_overlay_and_real_history_workers(self) -> None:
        kustomization = read("platform/gitops/local/kustomization.yaml")
        deploy = read("platform/scripts/deploy-local-apps.sh")
        builder = read("platform/scripts/build-local-images.sh")
        self.assertIn("history-workers.yaml", kustomization)
        self.assertIn("webapp.yaml", kustomization)
        self.assertIn(".generated/local-images", deploy)
        self.assertIn("docker push", builder)
        self.assertIn("digest:", builder)
        self.assertIn("osc-history-worker", builder)
        self.assertIn("osc-webapp", builder)


class LifecycleContractTests(unittest.TestCase):
    def test_exact_account_region_schedule_and_cost_boundaries(self) -> None:
        config = json.loads(read("docs/usrse26/interactive-demo-config.json"))
        self.assertEqual(config["accountId"], "269624229733")
        self.assertEqual(config["primaryRegion"], "us-west-2")
        self.assertEqual(config["schedule"]["maximumRuntimeHours"], 72)
        self.assertIn(
            'values = [format("user:RunId$%s", var.run_id)]',
            read("terraform/usrse26-control/budget.tf"),
        )
        self.assertEqual(config["costControlsUsd"], {
            "information": 75,
            "warning": 125,
            "readOnlyAndTeardown": 150,
            "absoluteCeiling": 200,
        })
        for script in ("prepare-demo-control.ps1", "apply-demo-control.ps1", "destroy-demo-control.ps1"):
            self.assertIn("platform/aws/aws_guard.py", read(f"platform/aws/{script}"))

    def test_first_control_plan_has_static_certificate_keys_and_null_optional_email(self) -> None:
        edge = read("terraform/usrse26-control/edge.tf")
        preparation = read("platform/aws/prepare-demo-control.ps1")
        self.assertRegex(edge, r"for_each\s*=\s*toset\(\[var\.public_hostname\]\)")
        self.assertIn("one(aws_acm_certificate.edge.domain_validation_options)", edge)
        self.assertNotIn("for option in aws_acm_certificate.edge.domain_validation_options", edge)
        self.assertIn("[string]::IsNullOrWhiteSpace($NotificationEmail)", preparation)
        self.assertIn("platform/aws/write_control_tfvars.py", preparation)

    def test_control_tfvars_normalize_optional_email_by_behavior(self) -> None:
        writer = ROOT / "platform/aws/write_control_tfvars.py"
        base = [
            sys.executable,
            str(writer),
            "--run-id", "usrse26r1",
            "--hosted-zone-id", "Z1029455HHX7QD91NBY1",
            "--admin-cidr", "192.0.2.10/32",
            "--lifecycle-runner-image", "example.invalid/lifecycle-runner@sha256:" + "a" * 64,
            "--artifact-manifest-s3-uri", "s3://example/releases/usrse26r1/artifacts.json",
            "--artifact-manifest-sha256", "b" * 64,
            "--planning-cost-usd", "34.140",
        ]
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "control.tfvars"
            for notification in (None, "", " \t "):
                command = [*base, "--output", str(output)]
                if notification is not None:
                    command.extend(("--notification-email", notification))
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                generated = output.read_text(encoding="utf-8")
                self.assertIn("planning_cost_usd = 34.14\n", generated)
                self.assertIn("notification_email = null\n", generated)

            result = subprocess.run(
                [*base, "--output", str(output), "--notification-email", " demo@example.org "],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('notification_email = "demo@example.org"\n', output.read_text(encoding="utf-8"))

    def test_state_machines_have_retry_canary_drain_backup_and_sweep(self) -> None:
        machines = read("terraform/usrse26-control/state-machines.tf")
        schedules = read("terraform/usrse26-control/schedules.tf")
        self.assertEqual(machines.count('arn:aws:states:::aws-sdk:sts:getCallerIdentity'), 3)
        self.assertEqual(machines.count("Parameters = {}"), 3)
        self.assertIn('MaxAttempts = 3', machines)
        self.assertIn('Value = "CANARY"', machines)
        self.assertIn('Seconds = 900', machines)
        self.assertIn('Value = "SWEEP"', machines)
        self.assertIn('Value = "DESTROY_RUNTIME"', machines)
        self.assertIn('WaitForRunnerNetworkRelease', machines)
        self.assertIn('backup-stop', schedules)
        self.assertIn('America/Los_Angeles', schedules)
        self.assertIn('StringEquals = "CLOSED"', machines)
        self.assertIn('StopComplete = { Type = "Succeed" }', machines)
        self.assertIn('resource "aws_codebuild_project" "cleanup"', read("terraform/usrse26-control/lifecycle.tf"))

    def test_monitoring_covers_lifecycle_failures(self) -> None:
        monitoring = read("terraform/usrse26-control/monitoring.tf")
        runner = read("platform/lifecycle/osc_demo_lifecycle.py")
        self.assertIn('metric_name         = "FailedBuilds"', monitoring)
        self.assertIn('metric_name         = "ExecutionsFailed"', monitoring)
        self.assertIn('metric_name         = "ApproximateNumberOfMessagesVisible"', monitoring)
        self.assertEqual(monitoring.count("alarm_actions"), 3)
        for signal in (
            "applicationMetrics",
            "podReadiness",
            "albTargets",
            "rabbitMq",
            "waf",
            "persistent-safety-failure",
        ):
            self.assertIn(signal, runner)
        for metric in (
            "MessageCount",
            "MessageReadyCount",
            "MessageUnacknowledgedCount",
            "PublishRate",
            "ConfirmRate",
            "AckRate",
            "AllowedRequests",
            "BlockedRequests",
        ):
            self.assertIn(metric, runner)
        self.assertIn('WEB_ACL_NAME', read("terraform/usrse26-control/locals.tf"))

    def test_static_fallback_and_retention_survive_runtime_contract(self) -> None:
        edge = read("terraform/usrse26-control/edge.tf")
        lifecycle = read("terraform/usrse26-control/lifecycle.tf")
        runner = json.loads(read("platform/lifecycle/runner-contract.json"))
        self.assertIn('default_root_object = "index.html"', edge)
        self.assertIn('retention_in_days = 7', edge)
        self.assertGreaterEqual(lifecycle.count('expiration { days = 30 }'), 2)
        self.assertIn("detach the CloudFront VPC origin", runner["actions"]["DESTROY"]["steps"])
        self.assertIn("preserve the static edge and control plane", runner["actions"]["DESTROY"]["steps"])
        self.assertEqual(runner["stateOrder"], ["SCHEDULED", "PREPARING", "OPEN", "READ_ONLY", "CLOSED"])
        self.assertEqual(runner["requiredArtifactInterfaces"]["webApp"], ["sourceRevision", "s3Uri", "sha256"])
        self.assertIn("evidence.sha256", runner["requiredArtifactInterfaces"]["buildCredentialIsolation"])

    def test_disabled_api_cache_policy_has_no_compression_cache_key(self) -> None:
        edge = read("terraform/usrse26-control/edge.tf")
        api_policy = edge.split('resource "aws_cloudfront_cache_policy" "api"', 1)[1].split(
            'resource "aws_cloudfront_origin_request_policy" "api"', 1
        )[0]
        self.assertIn("default_ttl = 0", api_policy)
        self.assertIn("max_ttl     = 0", api_policy)
        self.assertIn("min_ttl     = 0", api_policy)
        self.assertNotIn("enable_accept_encoding", api_policy)
        self.assertEqual(edge.count("enable_accept_encoding_brotli = true"), 1)
        self.assertEqual(edge.count("enable_accept_encoding_gzip   = true"), 1)

    def test_waf_redacts_all_sensitive_request_headers(self) -> None:
        edge = read("terraform/usrse26-control/edge.tf")
        for header in ("authorization", "cookie", "x-demo-control-key", "x-demo-csrf", "x-api-key"):
            self.assertIn(f'single_header {{ name = "{header}" }}', edge)
        runner = read("platform/lifecycle/osc_demo_lifecycle.py")
        self.assertIn("def private_control_json", runner)
        self.assertNotIn('headers={"X-Demo-Control-Key"', runner)

    def test_runtime_roles_are_control_owned_and_immutable_to_runner(self) -> None:
        iam = read("terraform/usrse26-eks/iam.tf")
        self.assertNotIn('resource "aws_iam_role"', iam)
        self.assertNotIn('resource "aws_iam_role_policy"', iam)
        self.assertNotIn('aws_iam_openid_connect_provider', iam)
        control = read("terraform/usrse26-control/lifecycle.tf")
        roles = read("terraform/usrse26-control/runtime-roles.tf")
        self.assertIn("permissions_boundary = local.runtime_boundary_arn", roles)
        self.assertIn("local.runtime_role_arn_map", control)
        self.assertIn("Statement = concat(local.runtime_service_statements, local.runtime_iam_statements)", control)
        self.assertIn("runtime_workload_boundary_statements", control)
        for forbidden in ("iam:CreateRole", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy"):
            self.assertNotIn(forbidden, control)

    def test_aws_secrets_are_split_by_workload(self) -> None:
        secrets = read("terraform/usrse26-eks/secrets.tf")
        iam = read("terraform/usrse26-control/runtime-roles.tf")
        manifests = read("platform/gitops/aws/namespace-and-secrets.yaml")
        renderer = read("platform/scripts/render_aws_gitops.py")
        self.assertNotIn('name                    = "${local.name_prefix}/application"', secrets)
        self.assertNotIn("__APP_SECRET_NAME__", manifests + renderer)
        for path in (
            "/api/auth", "/submission-listener/auth", "/demo/auth",
            "/ledger/nsg/auth", "/ledger/citizen-science/auth",
        ):
            self.assertIn(path, secrets)
        self.assertIn("runtime_workload_secret_access", iam)
        self.assertIn("local.runtime_secret_arn_patterns.ledger_nsg_auth", iam)
        self.assertIn("local.runtime_secret_arn_patterns.ledger_citizen_auth", iam)

    def test_codebuild_has_no_install_or_source_build_step(self) -> None:
        lifecycle = read("terraform/usrse26-control/lifecycle.tf")
        self.assertIn('type = "NO_SOURCE"', lifecycle)
        self.assertIn('/usr/local/bin/osc-demo-lifecycle', lifecycle)
        for forbidden in ("npm install", "npm ci", "pip install", "docker build"):
            self.assertNotIn(forbidden, lifecycle)

    def test_lifecycle_image_is_control_owned_until_final_teardown(self) -> None:
        lifecycle = read("terraform/usrse26-control/lifecycle.tf")
        runner = read("platform/lifecycle/osc_demo_lifecycle.py")
        self.assertIn('resource "aws_ecr_repository" "lifecycle_runner"', lifecycle)
        self.assertIn('controlPlaneResourcesPreserved', runner)
        self.assertNotIn('delete-repository", "--repository-name", runner_repository', runner)
    def test_lifecycle_runner_is_source_pinned_scanned_and_non_root(self) -> None:
        dockerfile = read("platform/lifecycle/Dockerfile")
        preparation = read("platform/aws/prepare-aws-artifacts.ps1")
        for commit in (
            "f871cf92a026aba7b12e6f06d71ded3e6e659d71",
            "991439f8f01d3f7a31ef77111afadf67a93f8c9d",
            "82e042fb6372443813f6759056308d6adc642fa1",
            "1c2e10a409eb1b03f2f28f401ce935312e20d9fb",
        ):
            self.assertIn(commit, dockerfile)
        self.assertIn(
            "AL2023_REPOSITORY_GUID=59479e247947fb5165d81aa2364f556030fe518713c50b111a30f75cb118dc0f",
            dockerfile,
        )
        self.assertIn("USER 10001:10001", dockerfile)
        self.assertIn("--severity HIGH,CRITICAL", preparation)
        self.assertIn("require a clean committed source tree", preparation)

    def test_artifact_expiry_is_compared_as_a_utc_instant(self) -> None:
        publisher = read("platform/aws/push-aws-artifacts.ps1")
        self.assertIn("([DateTimeOffset]$manifest.expiresAt).ToUniversalTime()", publisher)
        self.assertIn("$ExpiresAt.ToUniversalTime().Ticks", publisher)
        self.assertNotIn("Parse($manifest.expiresAt).ToString('o')", publisher)

    def test_ecr_repository_tags_use_a_cross_platform_json_payload(self) -> None:
        publisher = read("platform/aws/push-aws-artifacts.ps1")
        self.assertIn("ecr-repository-tags.json", publisher)
        self.assertIn('--tags "file://$repositoryTagsPath"', publisher)
        self.assertNotIn("Key=ExpiresAt,Value=$repositoryExpiresAt", publisher)

    def test_ecr_repository_tag_reconciliation_retries_but_remains_strict(self) -> None:
        publisher = read("platform/aws/push-aws-artifacts.ps1")
        self.assertIn("$tagReadAttempt -le 6", publisher)
        self.assertIn("if ($tagMismatches.Count -eq 0) { break }", publisher)
        self.assertIn("([DateTimeOffset]$tagMap[$_.Key]).ToUniversalTime().Ticks", publisher)
        self.assertIn("([DateTimeOffset][string]$_.Value).ToUniversalTime().Ticks", publisher)
        self.assertIn("missing exact tags after bounded reconciliation", publisher)
        self.assertNotIn("aws ecr tag-resource", publisher)

    def test_ecr_publication_resumes_only_for_an_exact_immutable_digest(self) -> None:
        publisher = read("platform/aws/push-aws-artifacts.ps1")
        self.assertIn("$existingDigest -ne $image.Value.localDigest", publisher)
        self.assertIn("Immutable ECR tag mismatch", publisher)
        self.assertIn("if ($LASTEXITCODE -eq 0)", publisher)
        self.assertIn("docker push $tagged", publisher)

    def test_runtime_and_control_teardown_proofs_are_tag_complete(self) -> None:
        runner = read("platform/lifecycle/osc_demo_lifecycle.py")
        control = read("platform/aws/destroy-demo-control.ps1")
        self.assertIn('"resourcegroupstaggingapi", "get-resources"', runner)
        self.assertIn('"remainingTaggedResources": 0', runner)
        self.assertIn('"status": "DESTROYED_AND_VERIFIED"', runner)
        self.assertIn('evidence/$RunId/runtime-teardown-proof.json', control)
        self.assertIn('list-object-versions', control)
        self.assertIn('CONTROL_DESTROYED_AND_VERIFIED', control)


class RenderingAndPolicyTests(unittest.TestCase):
    def test_gitops_renders_with_only_immutable_images(self) -> None:
        digest = "a" * 64
        images = {}
        for name in (
            "api-gateway",
            "ledger-gateway",
            "submission-worker",
            "submission-listener",
            "history-worker",
        ):
            images[name] = {"ecrReference": f"269624229733.dkr.ecr.us-west-2.amazonaws.com/{name}@sha256:{digest}"}
        payload = {
            "runId": "usrse26demo",
            "expiresAt": "2026-10-23T15:00:00Z",
            "images": images,
            "externalImages": {
                "aws-load-balancer-controller": f"public.ecr.aws/eks/aws-load-balancer-controller@sha256:{digest}"
            },
        }
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            artifact = temp_path / "artifacts.json"
            output = temp_path / "rendered"
            artifact.write_text(json.dumps(payload), encoding="utf-8")
            subprocess.run([
                sys.executable,
                str(ROOT / "platform/scripts/render_aws_gitops.py"),
                "--templates", str(ROOT / "platform/gitops/aws"),
                "--artifacts", str(artifact),
                "--destination", str(output),
                "--run-id", "usrse26demo",
            ], check=True, capture_output=True, text=True)
            rendered = "\n".join(path.read_text(encoding="utf-8") for path in output.rglob("*.yaml"))
            self.assertNotIn("__", rendered)
            image_lines = [line.strip() for line in rendered.splitlines() if line.strip().startswith("image:") and line.strip() != "image:"]
            self.assertTrue(image_lines)
            self.assertTrue(all("@sha256:" in line for line in image_lines))
            subprocess.run(["kubectl", "kustomize", str(output)], check=True, capture_output=True, text=True)

    def test_control_plan_policy_accepts_only_exact_import_reconciliation(self) -> None:
        digest = "a" * 64
        tags = {
            "Project": "OSC-IS",
            "Purpose": "USRSE26-Interactive-Demo",
            "Environment": "ephemeral",
            "ManagedBy": "Terraform",
            "RunId": "usrse26demo",
        }
        required = [
            ("aws_budgets_budget", {}),
            ("aws_cloudfront_distribution", {"enabled": True, "web_acl_id": "arn:waf"}),
            ("aws_cloudwatch_metric_alarm", {}),
            ("aws_codebuild_project", {"name": "osc-usrse26-usrse26demo-lifecycle", "environment": [{"image": f"runner@sha256:{digest}"}]}),
            ("aws_codebuild_project", {"name": "osc-usrse26-usrse26demo-cleanup", "environment": [{"image": f"runner@sha256:{digest}"}]}),
            ("aws_dynamodb_table", {}),
            ("aws_iam_policy", {
                "name": "osc-usrse26-usrse26demo-runtime-boundary",
                "policy": json.dumps({"Statement": [{"Action": "iam:PassRole"}]}),
            }),
            ("aws_scheduler_schedule", {}),
            ("aws_sfn_state_machine", {}),
            ("aws_wafv2_web_acl", {}),
        ]
        changes = []
        for index, (resource_type, values) in enumerate(required):
            after = {"tags_all": tags, **values}
            changes.append({"address": f"test.{index}", "type": resource_type, "change": {"actions": ["create"], "after": after}})
        boundary = "arn:aws:iam::269624229733:policy/osc-usrse26-usrse26demo-runtime-boundary"
        for suffix in sorted({
            "eks-cluster", "eks-nodes", "alb-controller", "api-gateway", "postgres",
            "submission-worker", "submission-listener", "ledger-gateway-nsg",
            "ledger-gateway-citizen-science", "ebs-csi", "lifecycle",
        }):
            changes.append({
                "address": f"aws_iam_role.{suffix}",
                "type": "aws_iam_role",
                "change": {
                    "actions": ["create"],
                    "after": {
                        "name": f"osc-usrse26-usrse26demo-{suffix}",
                        "permissions_boundary": boundary,
                        "tags_all": tags,
                    },
                },
            })
        cloudfront = next(change for change in changes if change["type"] == "aws_cloudfront_distribution")
        cloudfront["change"]["after"].pop("web_acl_id")
        cloudfront["change"]["after_unknown"] = {"web_acl_id": True}
        lifecycle_before = {
            "name": "osc-usrse26-usrse26demo/lifecycle-runner",
            "force_delete": None,
            "image_tag_mutability": "IMMUTABLE",
            "image_scanning_configuration": [{"scan_on_push": True}],
            "tags_all": tags,
        }
        lifecycle_after = {**lifecycle_before, "force_delete": True}
        changes.append({
            "address": "aws_ecr_repository.lifecycle_runner",
            "type": "aws_ecr_repository",
            "change": {
                "actions": ["update"],
                "before": lifecycle_before,
                "after": lifecycle_after,
                "after_unknown": {},
            },
        })
        plan = {
            "resource_changes": changes,
            "planned_values": {"outputs": {"public_url": {"value": "https://demo.osc-staging.org"}}},
            "configuration": {"root_module": {"resources": [{
                "address": cloudfront["address"],
                "expressions": {"web_acl_id": {"references": ["aws_wafv2_web_acl.edge.arn"]}},
            }]}},
        }
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "plan.json"
            path.write_text(json.dumps(plan), encoding="utf-8")
            command = [sys.executable, str(ROOT / "platform/aws/check_control_plan.py"), str(path), "--run-id", "usrse26demo"]
            accepted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            waf_expression = plan["configuration"]["root_module"]["resources"][0]["expressions"]["web_acl_id"]
            waf_expression["references"] = ["aws_wafv2_web_acl.unapproved.arn"]
            path.write_text(json.dumps(plan), encoding="utf-8")
            unbound_waf = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(unbound_waf.returncode, 0)
            waf_expression["references"] = ["aws_wafv2_web_acl.edge.arn"]
            lifecycle_after["image_tag_mutability"] = "MUTABLE"
            path.write_text(json.dumps(plan), encoding="utf-8")
            unsafe_reconciliation = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(unsafe_reconciliation.returncode, 0)
            lifecycle_after["image_tag_mutability"] = "IMMUTABLE"
            plan["resource_changes"][0]["change"]["actions"] = ["update"]
            path.write_text(json.dumps(plan), encoding="utf-8")
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            plan["resource_changes"][0]["change"]["actions"] = ["create"]
            boundary_change = next(
                change for change in plan["resource_changes"]
                if change["type"] == "aws_iam_policy"
            )
            boundary_change["change"]["after"]["policy"] = json.dumps({
                "Statement": [{"Action": "iam:CreateRole"}]
            })
            path.write_text(json.dumps(plan), encoding="utf-8")
            escalation = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(escalation.returncode, 0)

    def test_controller_source_is_provenance_bound(self) -> None:
        provenance = json.loads(read("platform/gitops/aws/aws-load-balancer-controller-v3.3.0.provenance.json"))
        self.assertEqual(provenance["upstreamSha256"], "fe7da00347dab61e60436b5f7a1b123d12ef257117c4cf3dcb9c5b5efd54ed41")
        controller = read("platform/gitops/aws/aws-load-balancer-controller-v3.3.0.yaml")
        self.assertIn("__AWS_LOAD_BALANCER_CONTROLLER_IMAGE__", controller)
        self.assertNotIn("aws-load-balancer-controller:v3.3.0", controller)


if __name__ == "__main__":
    unittest.main()
