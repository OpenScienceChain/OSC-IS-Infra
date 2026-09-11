#!/usr/bin/env python3
"""Fail-closed lifecycle runner for the disposable US-RSE 2026 demonstration."""

from __future__ import annotations

import hashlib
import http.cookiejar
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


ACCOUNT = "269624229733"
REGION = "us-west-2"
REQUIRED_IMAGES = {
    "api-gateway",
    "ledger-gateway",
    "submission-worker",
    "submission-listener",
    "history-worker",
    "chaincode",
    "gitops-repository",
    "webapp",
    "lifecycle-runner",
}
RUNTIME_ECR_IMAGES = REQUIRED_IMAGES - {"lifecycle-runner"}
VALID_ACTIONS = {
    "START",
    "CANARY",
    "MONITOR",
    "READ_ONLY",
    "EXPORT",
    "DESTROY",
    "DESTROY_RUNTIME",
    "SWEEP",
    "FAILED_START_CLEANUP",
    "SELF_TEST",
}
ROOT = Path(os.environ.get("OSC_RUNNER_ROOT", "/opt/osc/infra"))
RUN_ID_RE = re.compile(r"^[a-z0-9]{8,20}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=capture,
    )
    if check and process.returncode:
        detail = (process.stderr or process.stdout or "command failed").strip()
        raise RuntimeError(f"{args[0]} failed: {detail[-2000:]}")
    return process


def aws(*args: str, check: bool = True) -> str:
    command = ["aws", *args, "--region", REGION, "--no-cli-pager"]
    return run(command, check=check).stdout


def aws_json(*args: str, check: bool = True) -> Any:
    output = aws(*args, "--output", "json", check=check)
    if not output and not check:
        return None
    return json.loads(output or "null")


def aws_json_in_region(region: str, *args: str, check: bool = True) -> Any:
    command = ["aws", *args, "--region", region, "--no-cli-pager", "--output", "json"]
    process = run(command, check=check)
    if not process.stdout and not check:
        return None
    return json.loads(process.stdout or "null")


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_s3_uri(uri: str) -> tuple[str, str]:
    match = re.fullmatch(r"s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+)", uri)
    if not match or ".." in Path(match.group(2)).parts:
        raise RuntimeError(f"Unsafe S3 URI: {uri}")
    return match.group(1), match.group(2)


class Lifecycle:
    def __init__(self) -> None:
        self.run_id = required("RUN_ID")
        if not RUN_ID_RE.fullmatch(self.run_id):
            raise RuntimeError("RUN_ID must contain 8-20 lower-case letters or digits")
        self.work = Path(tempfile.gettempdir()) / f"osc-lifecycle-{self.run_id}"
        self.work.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.manifest: dict[str, Any] | None = None
        self.kubeconfig = self.work / "kubeconfig"

    def guard(self) -> None:
        expected_account = required("EXPECTED_ACCOUNT_ID")
        expected_region = required("EXPECTED_REGION")
        if expected_account != ACCOUNT or expected_region != REGION:
            raise RuntimeError("Compiled and configured AWS boundaries disagree")
        identity = aws_json("sts", "get-caller-identity")
        if identity.get("Account") != ACCOUNT:
            raise RuntimeError(f"Refusing AWS account {identity.get('Account')}")
        if os.environ.get("AWS_DEFAULT_REGION", REGION) != REGION:
            raise RuntimeError("AWS_DEFAULT_REGION is outside us-west-2")
        if float(required("PLANNING_COST_USD")) > float(required("COST_CEILING_USD")):
            raise RuntimeError("Reviewed planning cost exceeds the absolute ceiling")

    def load_manifest(self) -> dict[str, Any]:
        if self.manifest is not None:
            return self.manifest
        bucket, key = parse_s3_uri(required("ARTIFACT_MANIFEST_S3_URI"))
        path = self.work / "artifacts.json"
        aws("s3api", "get-object", "--bucket", bucket, "--key", key, str(path))
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        expected = required("ARTIFACT_MANIFEST_SHA256")
        if not SHA_RE.fullmatch(expected) or actual != expected:
            raise RuntimeError("Artifact manifest SHA-256 mismatch")
        manifest = json.loads(path.read_text(encoding="utf-8"))
        isolation = manifest.get("buildCredentialIsolation", {})
        if (
            manifest.get("runId") != self.run_id
            or isolation.get("status") != "ENFORCED_COMMON_AWS_SOURCES_ABSENT"
            or isolation.get("commonAwsCredentialSourcesAbsent") is not True
            or not SHA_RE.fullmatch(isolation.get("evidence", {}).get("sha256", ""))
        ):
            raise RuntimeError("Artifact manifest provenance does not match the run")
        images = manifest.get("images", {})
        if set(images) != REQUIRED_IMAGES:
            raise RuntimeError(f"Artifact manifest image set differs: {sorted(set(images) ^ REQUIRED_IMAGES)}")
        prefix = f"{ACCOUNT}.dkr.ecr.{REGION}.amazonaws.com/osc-usrse26-{self.run_id}/"
        for name, evidence in images.items():
            reference = evidence.get("ecrReference", "")
            if not reference.startswith(f"{prefix}{name}@sha256:") or not SHA_RE.fullmatch(reference.rsplit("sha256:", 1)[-1]):
                raise RuntimeError(f"Mutable or cross-run image reference for {name}")
        web = manifest.get("webApp", {})
        if not re.fullmatch(r"[0-9a-f]{40}", web.get("sourceRevision", "")):
            raise RuntimeError("WebApp source revision is not immutable")
        if not SHA_RE.fullmatch(web.get("sha256", "")) or not web.get("s3Uri"):
            raise RuntimeError("WebApp versioned object interface is incomplete")
        expires = datetime.fromisoformat(manifest["expiresAt"].replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if expires <= now or expires > now + timedelta(hours=int(required("MAX_RUNTIME_HOURS")), minutes=5):
            raise RuntimeError("Manifest expiry is outside the approved runtime window")
        self.manifest = manifest
        return manifest

    @property
    def expires_at(self) -> str:
        return self.load_manifest()["expiresAt"]

    def put_json(self, key: str, value: Any, bucket: str | None = None) -> None:
        target = self.work / (hashlib.sha256(key.encode()).hexdigest() + ".json")
        target.write_text(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8")
        aws(
            "s3api", "put-object", "--bucket", bucket or required("STATE_BUCKET"),
            "--key", key, "--body", str(target), "--content-type", "application/json",
            "--server-side-encryption", "AES256",
        )

    def write_status(self, state: str, message: str) -> None:
        if state not in {"SCHEDULED", "PREPARING", "OPEN", "READ_ONLY", "CLOSED"}:
            raise RuntimeError(f"Invalid public state: {state}")
        self.put_json(
            "status.json",
            {
                "schemaVersion": 1,
                "state": state,
                "message": message,
                "applicationUrl": required("PUBLIC_URL") if state == "OPEN" else None,
                "runId": self.run_id,
                "updatedAt": iso_now(),
            },
            required("STATUS_BUCKET"),
        )

    def update_lifecycle_record(self, state: str, **fields: str) -> None:
        names = {"#s": "status"}
        values: dict[str, dict[str, str]] = {":s": {"S": state}, ":u": {"S": iso_now()}}
        assignments = ["#s = :s", "updatedAt = :u"]
        for index, (name, value) in enumerate(fields.items()):
            token = f":v{index}"
            assignments.append(f"{name} = {token}")
            values[token] = {"S": value}
        aws_json(
            "dynamodb", "update-item", "--table-name", required("LIFECYCLE_TABLE"),
            "--key", json.dumps({"runId": {"S": self.run_id}}),
            "--update-expression", "SET " + ", ".join(assignments),
            "--expression-attribute-names", json.dumps(names),
            "--expression-attribute-values", json.dumps(values),
        )

    def update_monitor_failure_count(self, failed: bool) -> int:
        names = {"#m": "monitorFailureCount"}
        values = {
            ":u": {"S": iso_now()},
            ":zero": {"N": "0"},
            ":one": {"N": "1"},
        }
        expression = (
            "SET updatedAt = :u ADD #m :one"
            if failed
            else "SET updatedAt = :u, #m = :zero"
        )
        response = aws_json(
            "dynamodb", "update-item", "--table-name", required("LIFECYCLE_TABLE"),
            "--key", json.dumps({"runId": {"S": self.run_id}}),
            "--update-expression", expression,
            "--expression-attribute-names", json.dumps(names),
            "--expression-attribute-values", json.dumps(values),
            "--return-values", "ALL_NEW",
        )
        return int(response.get("Attributes", {}).get("monitorFailureCount", {}).get("N", "0"))

    def notify_cost_once(self, field: str, subject: str, message: str) -> bool:
        current = aws_json(
            "dynamodb", "get-item", "--table-name", required("LIFECYCLE_TABLE"),
            "--key", json.dumps({"runId": {"S": self.run_id}}), "--consistent-read",
        ).get("Item", {})
        if field in current:
            return False
        marker = iso_now()
        result = run([
            "aws", "dynamodb", "update-item", "--table-name", required("LIFECYCLE_TABLE"),
            "--key", json.dumps({"runId": {"S": self.run_id}}),
            "--update-expression", f"SET {field} = :v",
            "--condition-expression", f"attribute_not_exists({field})",
            "--expression-attribute-values", json.dumps({":v": {"S": marker}}),
            "--region", REGION, "--no-cli-pager",
        ], check=False)
        if result.returncode:
            return False
        aws_json(
            "sns", "publish", "--topic-arn", required("NOTIFICATION_TOPIC_ARN"),
            "--subject", subject, "--message", message,
        )
        return True

    def sync_webapp(self) -> None:
        manifest = self.load_manifest()
        web = manifest["webApp"]
        bucket, key = parse_s3_uri(web["s3Uri"])
        archive = self.work / "webapp-static.tar.gz"
        command = ["s3api", "get-object", "--bucket", bucket, "--key", key]
        if web.get("versionId"):
            command.extend(["--version-id", web["versionId"]])
        aws(*command, str(archive))
        if hashlib.sha256(archive.read_bytes()).hexdigest() != web["sha256"]:
            raise RuntimeError("WebApp bundle SHA-256 mismatch")
        site = self.work / "site"
        if site.exists():
            shutil.rmtree(site)
        site.mkdir()
        with tarfile.open(archive, "r:gz") as bundle:
            for member in bundle.getmembers():
                destination = (site / member.name).resolve()
                if member.issym() or member.islnk() or not destination.is_relative_to(site.resolve()):
                    raise RuntimeError("Unsafe WebApp bundle member")
            bundle.extractall(site)
        aws(
            "s3", "sync", str(site), f"s3://{required('STATUS_BUCKET')}/", "--delete",
            "--exclude", "status.json", "--sse", "AES256",
        )

    def tf_root(self, create_variables: bool = False) -> tuple[Path, dict[str, Any]]:
        source = ROOT / "terraform/usrse26-eks"
        target = self.work / "terraform"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
        variables = target / "runtime.auto.tfvars.json"
        state_key = f"runtime-state/{self.run_id}/terraform.tfstate"
        run(
            [
                "terraform", "init", "-input=false",
                f"-backend-config=bucket={required('STATE_BUCKET')}",
                f"-backend-config=key={state_key}", f"-backend-config=region={REGION}",
                f"-backend-config=dynamodb_table={required('STATE_LOCK_TABLE')}",
                "-backend-config=encrypt=true",
            ],
            cwd=target,
        )
        if create_variables:
            public_ip = urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10).read().decode().strip()
            if not re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", public_ip):
                raise RuntimeError("Could not resolve the bootstrap runner IPv4 address")
            manifest = self.load_manifest()
            payload = {
                "aws_profile": None,
                "run_id": self.run_id,
                "expires_at": manifest["expiresAt"],
                "maximum_runtime_hours": int(required("MAX_RUNTIME_HOURS")),
                "admin_cidr": required("ADMIN_CIDR"),
                "runner_public_cidr": f"{public_ip}/32",
                "alb_controller_image": manifest["externalImages"]["aws-load-balancer-controller"],
                "runtime_role_arns": json.loads(required("RUNTIME_ROLE_ARNS_JSON")),
            }
            variables.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
            aws(
                "s3api", "put-object", "--bucket", required("STATE_BUCKET"),
                "--key", f"runtime-state/{self.run_id}/runtime.auto.tfvars.json",
                "--body", str(variables), "--server-side-encryption", "AES256",
            )
        else:
            aws(
                "s3api", "get-object", "--bucket", required("STATE_BUCKET"),
                "--key", f"runtime-state/{self.run_id}/runtime.auto.tfvars.json", str(variables),
            )
        return target, json.loads(variables.read_text(encoding="utf-8"))

    def tf_outputs(self, root: Path) -> dict[str, Any]:
        raw = json.loads(run(["terraform", "output", "-json"], cwd=root).stdout)
        return {key: value["value"] for key, value in raw.items()}

    def provision(self) -> tuple[Path, dict[str, Any]]:
        root, _ = self.tf_root(create_variables=True)
        state = set(run(["terraform", "state", "list"], cwd=root, check=False).stdout.splitlines())
        for name in sorted(RUNTIME_ECR_IMAGES):
            address = f'aws_ecr_repository.experiment["{name}"]'
            if address not in state:
                run(
                    ["terraform", "import", address, f"osc-usrse26-{self.run_id}/{name}"],
                    cwd=root,
                )
        plan = self.work / "runtime.tfplan"
        plan_json = self.work / "runtime-plan.json"
        run(["terraform", "plan", "-input=false", "-out", str(plan)], cwd=root)
        plan_json.write_text(run(["terraform", "show", "-json", str(plan)], cwd=root).stdout, encoding="utf-8")
        run(["python", str(ROOT / "platform/aws/check_terraform_plan.py"), str(plan_json)], cwd=ROOT)
        run(["terraform", "apply", "-input=false", "-auto-approve", str(plan)], cwd=root, capture=False)
        return root, self.tf_outputs(root)

    def configure_kubectl(self) -> None:
        os.environ["KUBECONFIG"] = str(self.kubeconfig)
        aws(
            "eks", "update-kubeconfig", "--name", f"osc-usrse26-{self.run_id}-eks",
            "--alias", f"osc-usrse26-{self.run_id}", "--kubeconfig", str(self.kubeconfig),
        )
        context = run(["kubectl", "config", "current-context"]).stdout.strip()
        if context != f"osc-usrse26-{self.run_id}":
            raise RuntimeError(f"Unexpected Kubernetes context: {context}")

    def kubectl(self, *args: str, capture: bool = True, check: bool = True) -> str:
        environment = os.environ.copy()
        environment["KUBECONFIG"] = str(self.kubeconfig)
        return run(["kubectl", *args], env=environment, capture=capture, check=check).stdout

    def deploy_runtime(self, outputs: dict[str, Any]) -> None:
        self.configure_kubectl()
        nodes = sorted(item["metadata"]["name"] for item in json.loads(self.kubectl("get", "nodes", "-o", "json"))["items"])
        if len(nodes) != 3:
            raise RuntimeError("The reviewed runtime requires exactly three EKS nodes")
        for index, node in enumerate(nodes):
            self.kubectl("label", "node", node, f"osc-is/fabric-role=org{index}", "--overwrite")

        fabric = ROOT / "platform/.generated/fabric-network-eks"
        environment = os.environ.copy()
        environment.update({
            "KUBECONFIG": str(self.kubeconfig),
            "TEST_NETWORK_CLUSTER_RUNTIME": "eks",
            "TEST_NETWORK_CLUSTER_NAME": f"osc-usrse26-{self.run_id}-eks",
            "TEST_NETWORK_KUBE_NAMESPACE": "osc-fabric",
            "TEST_NETWORK_DOMAIN": "localho.st",
            "TEST_NETWORK_NGINX_HTTPS_PORT": "18443",
        })
        run(["./network", "cluster", "init"], cwd=fabric, env=environment, capture=False)
        port_log = (self.work / "fabric-port-forward.log").open("w", encoding="utf-8")
        port_forward = subprocess.Popen(
            ["kubectl", "-n", "ingress-nginx", "port-forward", "service/ingress-nginx-controller", "18443:443"],
            env=environment,
            stdout=port_log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            time.sleep(5)
            if port_forward.poll() is not None:
                raise RuntimeError("Fabric ingress port-forward exited early")
            environment.update({
                "RUN_ID": self.run_id,
                "CHAINCODE_IMAGE": self.load_manifest()["images"]["chaincode"]["ecrReference"],
                "CHAINCODE_DIR": "/opt/osc/chaincode-go",
            })
            run(["bash", "platform/scripts/deploy_aws_fabric.sh"], cwd=ROOT, env=environment, capture=False)
            run(
                ["python", "platform/aws/upload_fabric_identities.py", "--network", str(fabric), "--run-id", self.run_id],
                cwd=ROOT,
                env=environment,
            )
        finally:
            port_forward.terminate()
            try:
                port_forward.wait(timeout=10)
            except subprocess.TimeoutExpired:
                port_forward.kill()
            port_log.close()

        rabbit_host = re.sub(r"^amqps://|:5671$", "", outputs["rabbitmq_amqps_endpoint"])
        namespace = run(
            ["kubectl", "create", "namespace", "osc-apps", "--dry-run=client", "-o", "yaml"],
            env=environment,
        ).stdout
        applied = subprocess.run(["kubectl", "apply", "-f", "-"], env=environment, input=namespace, text=True, capture_output=True)
        if applied.returncode:
            raise RuntimeError(applied.stderr)
        self.kubectl(
            "label", "namespace", "osc-apps", "app.kubernetes.io/part-of=osc-is",
            "pod-security.kubernetes.io/enforce=restricted", "pod-security.kubernetes.io/audit=restricted",
            "pod-security.kubernetes.io/warn=restricted", "--overwrite",
        )
        for namespace_name in ("osc-apps", "kube-system"):
            name = "aws-runtime-endpoints" if namespace_name == "osc-apps" else "osc-runtime"
            literal = f"rabbitmq-host={rabbit_host}" if namespace_name == "osc-apps" else f"vpc-id={outputs['vpc_id']}"
            rendered = run(
                ["kubectl", "-n", namespace_name, "create", "configmap", name, f"--from-literal={literal}", "--dry-run=client", "-o", "yaml"],
                env=environment,
            ).stdout
            applied = subprocess.run(["kubectl", "apply", "-f", "-"], env=environment, input=rendered, text=True, capture_output=True)
            if applied.returncode:
                raise RuntimeError(applied.stderr)

        argocd_ns = run(["kubectl", "create", "namespace", "argocd", "--dry-run=client", "-o", "yaml"], env=environment).stdout
        applied = subprocess.run(["kubectl", "apply", "-f", "-"], env=environment, input=argocd_ns, text=True, capture_output=True)
        if applied.returncode:
            raise RuntimeError(applied.stderr)
        self.kubectl(
            "label", "namespace", "argocd", "pod-security.kubernetes.io/enforce=privileged",
            "pod-security.kubernetes.io/audit=restricted", "pod-security.kubernetes.io/warn=restricted", "--overwrite",
        )
        self.kubectl("apply", "--server-side", "--force-conflicts", "-n", "argocd", "-f", str(ROOT / "platform/vendor/argocd-install-v3.5.2.yaml"))
        self.kubectl("wait", "-n", "argocd", "deployment", "--all", "--for=condition=Available", "--timeout=10m")
        self.kubectl("rollout", "status", "-n", "argocd", "statefulset/argocd-application-controller", "--timeout=10m")
        bootstrap = self.work / "gitops-bootstrap"
        manifest = self.load_manifest()
        run([
            "python", "platform/scripts/render_gitops_bootstrap.py", "--bootstrap", "platform/gitops/bootstrap",
            "--destination", str(bootstrap), "--repository-image", manifest["images"]["gitops-repository"]["ecrReference"],
            "--baseline-revision", manifest["gitops"]["baselineRevision"], "--rollout-revision", manifest["gitops"]["rolloutRevision"],
        ], cwd=ROOT)
        self.kubectl("apply", "-f", str(bootstrap / "repository-server.yaml"))
        self.kubectl("rollout", "status", "-n", "argocd", "deployment/osc-gitops-repository", "--timeout=5m")
        self.kubectl("apply", "-f", str(bootstrap / "application.yaml"))
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            app = json.loads(self.kubectl("get", "application", "-n", "argocd", "osc-is-aws", "-o", "json"))
            if app.get("status", {}).get("sync", {}).get("status") == "Synced" and app.get("status", {}).get("health", {}).get("status") == "Healthy":
                break
            time.sleep(10)
        else:
            raise RuntimeError("Argo CD did not reach Synced and Healthy")
        for workload in (
            "statefulset/postgres", "deployment/api-gateway", "deployment/ledger-gateway-nsg",
            "deployment/ledger-gateway-citizen-science", "deployment/submission-worker",
            "deployment/submission-listener", "deployment/history-worker-nsg", "deployment/history-worker-citizen-science",
        ):
            self.kubectl("rollout", "status", "-n", "osc-apps", workload, "--timeout=10m")
        run(["bash", "platform/scripts/seed-local-data.sh"], cwd=ROOT, env=environment, capture=False)
        self.set_api_state("PREPARING", "Automated public canary has not completed")

    def private_control_json(self, path: str, *, method: str = "GET", body: Any = None) -> Any:
        if not path.startswith("/api/v1/demo/internal/"):
            raise RuntimeError("Private control requests are limited to demo internal endpoints")
        self.configure_kubectl()
        script = """
const [method,path,body]=process.argv.slice(1);
const options={method,headers:{'Accept':'application/json','X-Demo-Control-Key':process.env.DEMO_CONTROL_API_KEY}};
if(body){options.headers['Content-Type']='application/json';options.body=body;}
fetch('http://127.0.0.1:3000'+path,options).then(async r=>{const text=await r.text();if(!r.ok)throw new Error(`${r.status} ${text.slice(0,500)}`);process.stdout.write(text||'null');}).catch(e=>{console.error(e.message);process.exit(1)});
""".strip()
        output = self.kubectl(
            "-n", "osc-apps", "exec", "deployment/api-gateway", "--", "node", "-e", script,
            method, path, json.dumps(body, separators=(",", ":")) if body is not None else "",
        )
        return json.loads(output or "null")

    def set_api_state(self, state: str, reason: str) -> None:
        expires = datetime.fromisoformat(self.expires_at.replace("Z", "+00:00"))
        opens = expires - timedelta(hours=int(required("MAX_RUNTIME_HOURS")))
        self.private_control_json(
            "/api/v1/demo/internal/status",
            method="PUT",
            body={
                "state": state,
                "runId": self.run_id,
                "reason": reason,
                "opensAt": opens.isoformat(),
                "closesAt": expires.isoformat(),
            },
        )

    def wait_for_alb(self) -> dict[str, Any]:
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            ingress = json.loads(self.kubectl("get", "ingress", "-n", "osc-apps", "osc-demo-api", "-o", "json"))
            entries = ingress.get("status", {}).get("loadBalancer", {}).get("ingress", [])
            if entries and entries[0].get("hostname"):
                hostname = entries[0]["hostname"]
                lbs = aws_json("elbv2", "describe-load-balancers").get("LoadBalancers", [])
                matches = [lb for lb in lbs if lb.get("DNSName") == hostname and lb.get("Scheme") == "internal"]
                if len(matches) == 1 and matches[0].get("State", {}).get("Code") == "active":
                    return matches[0]
            time.sleep(10)
        raise RuntimeError("The tagged internal ALB did not become active")

    def attach_origin(self, load_balancer: dict[str, Any]) -> None:
        endpoint = {
            "Name": f"osc-usrse26-{self.run_id}-api",
            "Arn": load_balancer["LoadBalancerArn"],
            "HTTPPort": 80,
            "HTTPSPort": 443,
            "OriginProtocolPolicy": "http-only",
        }
        tags = {"Items": [
            {"Key": "Project", "Value": "OSC-IS"},
            {"Key": "Purpose", "Value": "USRSE26-Interactive-Demo"},
            {"Key": "Environment", "Value": "ephemeral"},
            {"Key": "ManagedBy", "Value": "LifecycleRunner"},
            {"Key": "Owner", "Value": "ofgarzon"},
            {"Key": "RunId", "Value": self.run_id},
            {"Key": "ExpiresAt", "Value": self.expires_at},
        ]}
        created = aws_json("cloudfront", "create-vpc-origin", "--vpc-origin-endpoint-config", json.dumps(endpoint), "--tags", json.dumps(tags))
        origin_id = created["VpcOrigin"]["Id"]
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            current = aws_json("cloudfront", "get-vpc-origin", "--id", origin_id)
            if current["VpcOrigin"]["Status"] == "Deployed":
                break
            time.sleep(15)
        else:
            raise RuntimeError("CloudFront VPC origin did not deploy")
        distribution_id = required("CLOUDFRONT_DISTRIBUTION")
        current = aws_json("cloudfront", "get-distribution-config", "--id", distribution_id)
        config = current["DistributionConfig"]
        origins = config.setdefault("Origins", {"Quantity": 0, "Items": []})
        origins.setdefault("Items", []).append({
            "Id": "runtime-api",
            "DomainName": load_balancer["DNSName"],
            "VpcOriginConfig": {"VpcOriginId": origin_id, "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5},
            "ConnectionAttempts": 3,
            "ConnectionTimeout": 10,
        })
        origins["Quantity"] = len(origins["Items"])
        behaviors = config.setdefault("CacheBehaviors", {"Quantity": 0, "Items": []})
        behaviors.setdefault("Items", []).append({
            "PathPattern": "/api/*",
            "TargetOriginId": "runtime-api",
            "TrustedSigners": {"Enabled": False, "Quantity": 0},
            "TrustedKeyGroups": {"Enabled": False, "Quantity": 0},
            "ViewerProtocolPolicy": "https-only",
            "AllowedMethods": {
                "Quantity": 7,
                "Items": ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"],
                "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]},
            },
            "SmoothStreaming": False,
            "Compress": True,
            "LambdaFunctionAssociations": {"Quantity": 0},
            "FunctionAssociations": {"Quantity": 0},
            "CachePolicyId": required("API_CACHE_POLICY_ID"),
            "OriginRequestPolicyId": required("API_ORIGIN_POLICY_ID"),
        })
        behaviors["Quantity"] = len(behaviors["Items"])
        payload = self.work / "distribution.json"
        payload.write_text(json.dumps(config), encoding="utf-8")
        aws(
            "cloudfront", "update-distribution", "--id", distribution_id,
            "--if-match", current["ETag"], "--distribution-config", f"file://{payload}",
        )
        aws("cloudfront", "wait", "distribution-deployed", "--id", distribution_id)
        self.put_json(
            f"runtime-state/{self.run_id}/vpc-origin.json",
            {"id": origin_id, "loadBalancerArn": load_balancer["LoadBalancerArn"], "attachedAt": iso_now()},
        )

    def move_runner_into_vpc(self, outputs: dict[str, Any]) -> None:
        config = {
            "vpcId": outputs["vpc_id"],
            "subnets": outputs["private_subnet_ids"],
            "securityGroupIds": [outputs["lifecycle_runner_security_group_id"]],
        }
        aws("codebuild", "update-project", "--name", required("CODEBUILD_PROJECT"), "--vpc-config", json.dumps(config))

    def start(self) -> None:
        self.load_manifest()
        self.write_status("PREPARING", "The temporary demonstration environment is being prepared and verified.")
        self.update_lifecycle_record("PREPARING")
        self.sync_webapp()
        root, outputs = self.provision()
        self.deploy_runtime(outputs)
        load_balancer = self.wait_for_alb()
        self.attach_origin(load_balancer)
        self.move_runner_into_vpc(outputs)
        self.put_json(
            f"evidence/{self.run_id}/start.json",
            {"schemaVersion": 1, "runId": self.run_id, "completedAt": iso_now(), "cluster": outputs["cluster_name"], "vpcOriginAttached": True},
        )
        del root

    def http_json(
        self,
        opener: urllib.request.OpenerDirector,
        path: str,
        *,
        method: str = "GET",
        body: Any = None,
        headers: dict[str, str] | None = None,
        expected: int = 200,
    ) -> Any:
        request_headers = {"Accept": "application/json", **(headers or {})}
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(required("PUBLIC_URL") + path, data=payload, headers=request_headers, method=method)
        try:
            response = opener.open(request, timeout=30)
            status = response.status
            data = response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            data = error.read()
        if status != expected:
            raise RuntimeError(f"{method} {path} returned {status}, expected {expected}: {data[:500]!r}")
        return json.loads(data or b"null")

    def canary(self) -> None:
        self.load_manifest()
        self.configure_kubectl()
        self.set_api_state("OPEN", "Automated canary in progress")
        origin = required("PUBLIC_URL")
        evidence: dict[str, Any] = {"schemaVersion": 1, "runId": self.run_id, "startedAt": iso_now()}
        try:
            self.http_json(urllib.request.build_opener(), "/api/v1/health")
            jars: list[http.cookiejar.CookieJar] = []
            guests = []
            for organization in ("neuroscience-gateway", "citizen-science"):
                jar = http.cookiejar.CookieJar()
                opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
                session = self.http_json(
                    opener, "/api/v1/demo/session", method="POST", body={"organization": organization},
                    headers={"Origin": origin}, expected=201,
                )
                if not any(cookie.name == "__Host-osc_demo" and cookie.secure for cookie in jar):
                    raise RuntimeError("Canary session cookie is not host-only and secure")
                jars.append(jar)
                guests.append((opener, session))
            opener, guest = guests[0]
            fingerprint = hashlib.sha256(f"{self.run_id}:public-canary".encode()).hexdigest()
            request_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"osc-is:{self.run_id}:artifact"))
            mutation_headers = {"Origin": origin, "X-Demo-CSRF": guest["csrfToken"], "X-Correlation-Id": request_id}
            artifact = self.http_json(
                opener, "/api/v1/demo/artifacts", method="POST",
                body={"requestId": request_id, "fingerprint": fingerprint, "sizeBytes": 256, "extension": "json", "researchContext": "REPRODUCIBLE_ANALYSIS"},
                headers=mutation_headers, expected=201,
            )
            started = time.monotonic()
            while time.monotonic() - started < 300:
                artifact = self.http_json(opener, f"/api/v1/demo/artifacts/{artifact['id']}")
                if artifact.get("submissionState") == "SUCCESS":
                    break
                if artifact.get("submissionState") == "FAILED":
                    raise RuntimeError("Public artifact canary reached FAILED")
                time.sleep(2)
            else:
                raise RuntimeError("Public artifact canary exceeded five minutes")
            artifact_confirmation_ms = round((time.monotonic() - started) * 1000)
            history = self.http_json(opener, f"/api/v1/demo/artifacts/{artifact['id']}/history")
            if history.get("total") != 1:
                raise RuntimeError("Artifact canary did not produce exactly one ledger revision")
            self.http_json(guests[1][0], f"/api/v1/demo/artifacts/{artifact['id']}", expected=403)
            workflow_request = str(uuid.uuid5(uuid.NAMESPACE_URL, f"osc-is:{self.run_id}:workflow"))
            workflow = self.http_json(
                opener, "/api/v1/demo/workflows", method="POST",
                body={"requestId": workflow_request, "artifactIds": [artifact["id"]], "researchContext": "REPRODUCIBLE_ANALYSIS"},
                headers={**mutation_headers, "X-Correlation-Id": workflow_request}, expected=201,
            )
            workflow_started = time.monotonic()
            while time.monotonic() - workflow_started < 300:
                workflow = self.http_json(opener, f"/api/v1/demo/workflows/{workflow['id']}")
                if workflow.get("submissionState") == "SUCCESS":
                    break
                if workflow.get("submissionState") == "FAILED":
                    raise RuntimeError("Public workflow canary reached FAILED")
                time.sleep(2)
            else:
                raise RuntimeError("Public workflow canary exceeded five minutes")
            workflow_history = self.http_json(opener, f"/api/v1/demo/workflows/{workflow['id']}/history")
            if workflow_history.get("total") != 1:
                raise RuntimeError("Workflow canary did not produce exactly one ledger revision")
            evidence.update({
                "completedAt": iso_now(), "artifactId": artifact["id"], "artifactTxId": artifact["blockchainTxId"],
                "artifactConfirmationMs": artifact_confirmation_ms,
                "workflowId": workflow["id"], "workflowTxId": workflow["blockchainTxId"],
                "workflowConfirmationMs": round((time.monotonic() - workflow_started) * 1000),
                "crossOrganizationReadDenied": True, "duplicateLedgerRevisions": 0,
            })
            self.write_status("OPEN", "The interactive provenance demonstration is open.")
            self.update_lifecycle_record("OPEN", canaryCompletedAt=evidence["completedAt"])
            self.put_json(f"evidence/{self.run_id}/canary.json", evidence)
        except Exception:
            self.set_api_state("READ_ONLY", "Public canary failed")
            self.write_status("READ_ONLY", "The interactive service is read-only while an automated safety check is investigated.")
            raise

    def read_only(self) -> None:
        self.load_manifest()
        self.configure_kubectl()
        self.write_status("READ_ONLY", "New contributions are closed; confirmed provenance history remains available during export.")
        self.set_api_state("READ_ONLY", "Scheduled close or safety threshold")
        self.update_lifecycle_record("READ_ONLY")

    def export(self) -> None:
        self.load_manifest()
        exported = self.private_control_json("/api/v1/demo/internal/export")
        forbidden = ("email", "filename", "privateComment", "token", "secret", "sessionId")
        serialized = json.dumps(exported)
        if any(term.lower() in serialized.lower() for term in forbidden):
            raise RuntimeError("Sanitized export contains a forbidden field")
        key = f"evidence/{self.run_id}/sanitized-export.json"
        self.put_json(key, exported)
        self.put_json(
            f"evidence/{self.run_id}/sanitized-export.checksum.json",
            {"algorithm": "sha256", "sha256": hashlib.sha256((serialized + "\n").encode()).hexdigest(), "objectKey": key},
        )

    def detach_origin(self) -> None:
        distribution_id = required("CLOUDFRONT_DISTRIBUTION")
        current = aws_json("cloudfront", "get-distribution-config", "--id", distribution_id)
        config = current["DistributionConfig"]
        origins = config.get("Origins", {"Quantity": 0})
        origins["Items"] = [item for item in origins.get("Items", []) if item.get("Id") != "runtime-api"]
        origins["Quantity"] = len(origins["Items"])
        if not origins["Items"]:
            origins.pop("Items", None)
        behaviors = config.get("CacheBehaviors", {"Quantity": 0})
        behaviors["Items"] = [item for item in behaviors.get("Items", []) if item.get("PathPattern") != "/api/*"]
        behaviors["Quantity"] = len(behaviors["Items"])
        if not behaviors["Items"]:
            behaviors.pop("Items", None)
        payload = self.work / "distribution-detached.json"
        payload.write_text(json.dumps(config), encoding="utf-8")
        aws(
            "cloudfront", "update-distribution", "--id", distribution_id,
            "--if-match", current["ETag"], "--distribution-config", f"file://{payload}",
        )
        aws("cloudfront", "wait", "distribution-deployed", "--id", distribution_id)
        metadata = self.work / "vpc-origin.json"
        result = run([
            "aws", "s3api", "get-object", "--bucket", required("STATE_BUCKET"),
            "--key", f"runtime-state/{self.run_id}/vpc-origin.json", str(metadata),
            "--region", REGION, "--no-cli-pager",
        ], check=False)
        origin_ids: set[str] = set()
        if result.returncode == 0:
            origin_ids.add(json.loads(metadata.read_text(encoding="utf-8"))["id"])
        listed = aws_json("cloudfront", "list-vpc-origins")
        for item in listed.get("VpcOriginList", {}).get("Items", []):
            if item.get("Name") == f"osc-usrse26-{self.run_id}-api":
                origin_ids.add(item["Id"])
        for origin_id in sorted(origin_ids):
            origin = aws_json("cloudfront", "get-vpc-origin", "--id", origin_id, check=False)
            if origin:
                aws("cloudfront", "delete-vpc-origin", "--id", origin_id, "--if-match", origin["ETag"])
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                if aws_json("cloudfront", "get-vpc-origin", "--id", origin_id, check=False) is None:
                    break
                time.sleep(15)
            else:
                raise RuntimeError(f"CloudFront VPC origin {origin_id} did not delete")

    def restore_fallback(self, state: str = "READ_ONLY") -> None:
        bucket = required("STATUS_BUCKET")
        objects = aws_json("s3api", "list-objects-v2", "--bucket", bucket).get("Contents", [])
        for item in objects:
            if item["Key"] != "status.json":
                aws("s3api", "delete-object", "--bucket", bucket, "--key", item["Key"])
        aws(
            "s3api", "put-object", "--bucket", bucket, "--key", "index.html",
            "--body", str(ROOT / "terraform/usrse26-control/templates/index.html"),
            "--content-type", "text/html; charset=utf-8", "--server-side-encryption", "AES256",
        )
        if state == "READ_ONLY":
            self.write_status("READ_ONLY", "The contribution window is closed while sanitized evidence is exported and the runtime is removed.")

    def reset_codebuild_network(self) -> None:
        aws(
            "codebuild", "update-project", "--name", required("CODEBUILD_PROJECT"),
            "--vpc-config", json.dumps({"vpcId": "", "subnets": [], "securityGroupIds": []}),
        )

    def delete_workloads(self) -> None:
        clusters = aws_json("eks", "list-clusters").get("clusters", [])
        if f"osc-usrse26-{self.run_id}-eks" not in clusters:
            return
        self.configure_kubectl()
        self.kubectl("-n", "argocd", "delete", "application", "osc-is-aws", "--ignore-not-found=true", "--wait=true", "--timeout=5m", check=False)
        for namespace in ("osc-apps", "osc-fabric", "argocd", "ingress-nginx", "cert-manager"):
            self.kubectl("delete", "namespace", namespace, "--ignore-not-found=true", "--wait=true", "--timeout=10m")
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            volumes = aws_json(
                "ec2", "describe-volumes", "--filters",
                f"Name=tag:RunId,Values={self.run_id}", "Name=tag:Project,Values=OSC-IS",
                "Name=tag:Purpose,Values=USRSE26-Interactive-Demo", "Name=tag:Environment,Values=ephemeral",
            ).get("Volumes", [])
            if not volumes:
                return
            if all(volume["State"] == "available" for volume in volumes):
                for volume in volumes:
                    aws("ec2", "delete-volume", "--volume-id", volume["VolumeId"])
                return
            time.sleep(15)
        raise RuntimeError("Tagged EBS volumes did not become removable")

    def destroy(self) -> None:
        failures: list[str] = []
        try:
            self.load_manifest()
            for operation in (self.detach_origin, self.restore_fallback, self.delete_workloads):
                try:
                    operation()
                except Exception as error:
                    failures.append(f"{operation.__name__}: {error}")
        finally:
            try:
                self.reset_codebuild_network()
            except Exception as error:
                failures.append(f"reset_codebuild_network: {error}")
        self.put_json(
            f"evidence/{self.run_id}/workload-destroy.json",
            {
                "schemaVersion": 1, "runId": self.run_id, "completedAt": iso_now(),
                "staticFallbackPreserved": not any(item.startswith("restore_fallback:") for item in failures),
                "runnerVpcPlacementRemoved": not any(item.startswith("reset_codebuild_network:") for item in failures),
                "failures": failures,
            },
        )
        if failures:
            raise RuntimeError("; ".join(failures))

    def destroy_runtime(self) -> None:
        state_object = run([
            "aws", "s3api", "head-object", "--bucket", required("STATE_BUCKET"),
            "--key", f"runtime-state/{self.run_id}/runtime.auto.tfvars.json",
            "--region", REGION, "--no-cli-pager",
        ], check=False)
        terraform_destroyed = state_object.returncode == 0
        if terraform_destroyed:
            root, _ = self.tf_root(create_variables=False)
            run(["terraform", "destroy", "-input=false", "-auto-approve"], cwd=root, capture=False)
        self.delete_residual_runtime_repositories()
        self.put_json(
            f"evidence/{self.run_id}/destroy.json",
            {
                "schemaVersion": 1, "runId": self.run_id, "completedAt": iso_now(),
                "staticFallbackPreserved": True, "terraformStateFound": terraform_destroyed,
            },
        )

    def delete_residual_runtime_repositories(self) -> None:
        for name in sorted(RUNTIME_ECR_IMAGES):
            repository = f"osc-usrse26-{self.run_id}/{name}"
            described = aws_json(
                "ecr", "describe-repositories", "--repository-names", repository, check=False,
            )
            if not described:
                continue
            details = described.get("repositories", [])
            if len(details) != 1 or details[0].get("repositoryName") != repository:
                raise RuntimeError(f"Unexpected ECR lookup result for {repository}")
            tags = aws_json(
                "ecr", "list-tags-for-resource", "--resource-arn", details[0]["repositoryArn"],
            ).get("tags", [])
            tag_map = {item["Key"]: item["Value"] for item in tags}
            expected = {
                "Project": "OSC-IS", "Purpose": "USRSE26-Interactive-Demo",
                "Environment": "ephemeral", "RunId": self.run_id,
            }
            if any(tag_map.get(key) != value for key, value in expected.items()):
                raise RuntimeError(f"Refusing to delete partially tagged ECR repository {repository}")
            aws("ecr", "delete-repository", "--repository-name", repository, "--force")

    def failed_start_cleanup(self) -> None:
        failures: list[str] = []
        try:
            for operation in (self.detach_origin, self.restore_fallback, self.delete_workloads):
                try:
                    operation()
                except Exception as error:
                    failures.append(f"{operation.__name__}: {error}")
        finally:
            try:
                self.reset_codebuild_network()
            except Exception as error:
                failures.append(f"reset_codebuild_network: {error}")
        self.put_json(
            f"evidence/{self.run_id}/failed-start-cleanup.json",
            {"schemaVersion": 1, "runId": self.run_id, "completedAt": iso_now(), "failures": failures},
        )
        if failures:
            raise RuntimeError("; ".join(failures))

    def browser_probe(self, path: str) -> dict[str, Any]:
        started = time.monotonic()
        response = urllib.request.urlopen(required("PUBLIC_URL") + path, timeout=30)
        response.read(1024)
        if response.status != 200:
            raise RuntimeError(f"{path} returned HTTP {response.status}")
        return {"status": response.status, "durationMs": round((time.monotonic() - started) * 1000)}

    def kubernetes_readiness(self) -> dict[str, Any]:
        self.configure_kubectl()
        pods = json.loads(self.kubectl("get", "pods", "-A", "-o", "json"))["items"]
        active = [item for item in pods if item.get("status", {}).get("phase") not in {"Succeeded", "Failed"}]

        def ready(item: dict[str, Any]) -> bool:
            expected = len(item.get("spec", {}).get("containers", []))
            statuses = item.get("status", {}).get("containerStatuses", [])
            return (
                item.get("status", {}).get("phase") == "Running"
                and expected > 0
                and len(statuses) == expected
                and all(status.get("ready") is True for status in statuses)
            )

        namespaces: dict[str, dict[str, int]] = {}
        for item in active:
            namespace = item.get("metadata", {}).get("namespace", "unknown")
            value = namespaces.setdefault(namespace, {"total": 0, "ready": 0, "unavailable": 0})
            value["total"] += 1
            value["ready"] += int(ready(item))
            value["unavailable"] += int(not ready(item))
        fabric = namespaces.get("osc-fabric", {"total": 0, "ready": 0, "unavailable": 0})
        application = namespaces.get("osc-apps", {"total": 0, "ready": 0, "unavailable": 0})
        return {
            "total": len(active),
            "ready": sum(int(ready(item)) for item in active),
            "unavailable": sum(int(not ready(item)) for item in active),
            "application": application,
            "fabric": fabric,
        }

    def alb_health(self) -> dict[str, int]:
        ingress = json.loads(self.kubectl("get", "ingress", "-n", "osc-apps", "osc-demo-api", "-o", "json"))
        entries = ingress.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        if len(entries) != 1 or not entries[0].get("hostname"):
            raise RuntimeError("The runtime ingress does not have one ALB hostname")
        hostname = entries[0]["hostname"]
        matches = [
            item for item in aws_json("elbv2", "describe-load-balancers").get("LoadBalancers", [])
            if item.get("DNSName") == hostname and item.get("Scheme") == "internal"
        ]
        if len(matches) != 1:
            raise RuntimeError("The runtime ingress hostname did not resolve to one internal ALB")
        groups = aws_json(
            "elbv2", "describe-target-groups", "--load-balancer-arn", matches[0]["LoadBalancerArn"],
        ).get("TargetGroups", [])
        states: dict[str, int] = {}
        for group in groups:
            descriptions = aws_json(
                "elbv2", "describe-target-health", "--target-group-arn", group["TargetGroupArn"],
            ).get("TargetHealthDescriptions", [])
            for description in descriptions:
                state = description.get("TargetHealth", {}).get("State", "unknown")
                states[state] = states.get(state, 0) + 1
        return {
            "targetGroups": len(groups),
            "healthy": states.get("healthy", 0),
            "unhealthy": sum(value for key, value in states.items() if key != "healthy"),
        }

    def cloudwatch_window(
        self,
        namespace: str,
        metric: str,
        dimensions: list[dict[str, str]],
        *,
        region: str = REGION,
    ) -> dict[str, Any]:
        end = datetime.now(timezone.utc)
        start = end - timedelta(minutes=10)
        response = aws_json_in_region(
            region,
            "cloudwatch", "get-metric-statistics",
            "--namespace", namespace, "--metric-name", metric,
            "--dimensions", json.dumps(dimensions),
            "--start-time", start.isoformat(), "--end-time", end.isoformat(),
            "--period", "60", "--statistics", "Average", "Maximum", "Sum",
        )
        points = sorted(response.get("Datapoints", []), key=lambda item: item.get("Timestamp", ""))
        return {
            "samples": len(points),
            "latestAverage": points[-1].get("Average") if points else None,
            "maximum": max((point.get("Maximum", 0) for point in points), default=None),
            "sum": sum(point.get("Sum", 0) for point in points) if points else None,
        }

    def broker_metrics(self) -> dict[str, Any]:
        dimensions = [{"Name": "Broker", "Value": f"osc-usrse26-{self.run_id}-rabbitmq"}]
        return {
            metric: self.cloudwatch_window("AWS/AmazonMQ", metric, dimensions)
            for metric in (
                "MessageCount", "MessageReadyCount", "MessageUnacknowledgedCount",
                "PublishRate", "ConfirmRate", "AckRate",
            )
        }

    def waf_metrics(self) -> dict[str, Any]:
        dimensions = [
            {"Name": "WebACL", "Value": required("WEB_ACL_NAME")},
            {"Name": "Rule", "Value": "ALL"},
            {"Name": "Region", "Value": "Global"},
        ]
        return {
            metric: self.cloudwatch_window("AWS/WAFV2", metric, dimensions, region="us-east-1")
            for metric in ("AllowedRequests", "BlockedRequests")
        }

    def start_safety_teardown(self, reason: str) -> None:
        self.write_status("READ_ONLY", "An automated safety threshold was reached; teardown has started.")
        aws_json(
            "states", "start-execution", "--state-machine-arn", required("STOP_STATE_MACHINE_ARN"),
            "--input", json.dumps({"runId": self.run_id, "reason": reason}),
        )

    def monitor(self) -> None:
        self.load_manifest()
        evidence: dict[str, Any] = {"schemaVersion": 1, "runId": self.run_id, "observedAt": iso_now()}
        failures: list[str] = []

        def collect(name: str, operation: Any) -> Any:
            try:
                value = operation()
                evidence[name] = value
                return value
            except Exception:
                failures.append(name)
                evidence[name] = None
                return None

        browser = collect("browser", lambda: {
            "root": self.browser_probe("/"),
            "status": self.http_json(urllib.request.build_opener(), "/status.json"),
        })
        health = collect("serviceHealth", lambda: self.http_json(urllib.request.build_opener(), "/api/v1/health"))
        metrics = collect(
            "applicationMetrics",
            lambda: self.private_control_json("/api/v1/demo/internal/metrics"),
        )
        readiness = collect("podReadiness", self.kubernetes_readiness)
        targets = collect("albTargets", self.alb_health)
        collect("rabbitMq", self.broker_metrics)
        collect("waf", self.waf_metrics)
        budget = aws_json("budgets", "describe-budget", "--account-id", ACCOUNT, "--budget-name", required("BUDGET_NAME"))
        actual = float(budget["Budget"]["CalculatedSpend"]["ActualSpend"]["Amount"])
        evidence["actualCostUsd"] = actual

        if not browser or browser.get("status", {}).get("state") != "OPEN":
            failures.append("browserState")
        if not health or health.get("status") != "ok":
            failures.append("serviceHealthStatus")
        if metrics:
            queue = metrics.get("queue", {})
            if queue.get("failed", 0) > 0 or queue.get("oldestPendingAgeSeconds", 0) > 300:
                failures.append("queueSafety")
            latency = metrics.get("confirmationLatencyMs", {})
            if any((latency.get(kind, {}).get("p95") or 0) > 300_000 for kind in ("artifact", "workflow")):
                failures.append("confirmationLatency")
        if readiness:
            if readiness.get("application", {}).get("unavailable", 1) > 0:
                failures.append("applicationReadiness")
            if readiness.get("fabric", {}).get("total", 0) < 7 or readiness.get("fabric", {}).get("unavailable", 1) > 0:
                failures.append("fabricReadiness")
        if targets and (targets.get("healthy", 0) < 1 or targets.get("unhealthy", 0) > 0):
            failures.append("albTargetHealth")
        failures = sorted(set(failures))
        consecutive_failures = self.update_monitor_failure_count(bool(failures))
        evidence["safetyFailures"] = failures
        evidence["consecutiveSafetyFailures"] = consecutive_failures

        if actual >= float(required("COST_INFO_USD")):
            evidence["costInformationSent"] = self.notify_cost_once(
                "costInformationNotifiedAt", "OSC-IS demo cost information",
                f"Run {self.run_id} reached USD {actual:.2f}.",
            )
        if actual >= float(required("COST_WARNING_USD")):
            evidence["costWarningSent"] = self.notify_cost_once(
                "costWarningNotifiedAt", "OSC-IS demo cost warning",
                f"Run {self.run_id} reached USD {actual:.2f}.",
            )
        if actual >= float(required("COST_TEARDOWN_USD")):
            self.start_safety_teardown("cost-threshold")
            evidence["teardownStarted"] = True
        elif consecutive_failures >= 2:
            self.start_safety_teardown("persistent-safety-failure")
            evidence["teardownStarted"] = True
        self.put_json(f"evidence/{self.run_id}/monitor-{int(time.time())}.json", evidence)

    def sweep(self) -> None:
        manifest = self.load_manifest()
        expected_prefix = f"osc-usrse26-{self.run_id}"
        runtime_tags = {
            "Project": "OSC-IS",
            "Purpose": "USRSE26-Interactive-Demo",
            "Environment": "ephemeral",
            "RunId": self.run_id,
            "ExpiresAt": manifest["expiresAt"],
        }

        def inventory() -> dict[str, list[str]]:
            tag_arguments = [
                f"Key={key},Values={value}" for key, value in runtime_tags.items()
            ]
            tagged = aws_json(
                "resourcegroupstaggingapi", "get-resources", "--tag-filters", *tag_arguments,
            ).get("ResourceTagMappingList", [])
            clusters = aws_json("eks", "list-clusters").get("clusters", [])
            brokers = aws_json("mq", "list-brokers").get("BrokerSummaries", [])
            ecr = aws_json("ecr", "describe-repositories").get("repositories", [])
            volumes = aws_json(
                "ec2", "describe-volumes", "--filters",
                f"Name=tag:RunId,Values={self.run_id}",
                "Name=tag:ExpiresAt,Values=" + manifest["expiresAt"],
            ).get("Volumes", [])
            distribution = aws_json(
                "cloudfront", "get-distribution-config", "--id", required("CLOUDFRONT_DISTRIBUTION"),
            )["DistributionConfig"]
            runtime_origins = [
                item.get("Id", "") for item in distribution.get("Origins", {}).get("Items", [])
                if item.get("Id") == "runtime-api"
            ]
            return {
                "taggedResources": sorted(item["ResourceARN"] for item in tagged),
                "clusters": sorted(name for name in clusters if name == f"{expected_prefix}-eks"),
                "brokers": sorted(
                    item["BrokerName"] for item in brokers
                    if item["BrokerName"] == f"{expected_prefix}-rabbitmq"
                ),
                "repositories": sorted(
                    item["repositoryName"] for item in ecr
                    if item["repositoryName"].startswith(expected_prefix + "/")
                    and not item["repositoryName"].endswith("/lifecycle-runner")
                ),
                "volumes": sorted(volume["VolumeId"] for volume in volumes),
                "cloudFrontRuntimeOrigins": runtime_origins,
            }

        deadline = time.monotonic() + 600
        residual = inventory()
        while any(residual.values()) and time.monotonic() < deadline:
            time.sleep(15)
            residual = inventory()
        remaining = sum(len(items) for items in residual.values())
        if remaining:
            self.put_json(
                f"evidence/{self.run_id}/runtime-teardown-proof.json",
                {
                    "schemaVersion": 1, "runId": self.run_id, "verified": False,
                    "status": "RESIDUAL_RUNTIME_RESOURCES", "residual": residual,
                    "remainingTaggedResources": remaining, "requiredTags": runtime_tags,
                    "checkedAt": iso_now(),
                },
            )
            raise RuntimeError(f"Tagged runtime resources remain: {residual}")
        fallback = self.http_json(urllib.request.build_opener(), "/status.json")
        if fallback.get("state") != "READ_ONLY":
            raise RuntimeError("Static fallback was not healthy and READ_ONLY before final closure")
        proof = {
            "schemaVersion": 1, "runId": self.run_id, "verified": True, "checkedAt": iso_now(),
            "expiresAt": manifest["expiresAt"], "residual": residual,
            "requiredTags": runtime_tags, "remainingTaggedResources": 0,
            "status": "DESTROYED_AND_VERIFIED", "cloudFrontRuntimeOriginDetached": True,
            "staticFallbackHealthy": True, "controlPlaneResourcesPreserved": True,
        }
        self.put_json(f"evidence/{self.run_id}/runtime-teardown-proof.json", proof)
        self.write_status("CLOSED", "The temporary demonstration is closed and its runtime resources have been removed.")
        self.update_lifecycle_record("CLOSED", teardownVerifiedAt=proof["checkedAt"])

    @staticmethod
    def self_test() -> None:
        for executable in ("aws", "bash", "git", "jq", "kubectl", "openssl", "python", "terraform"):
            if shutil.which(executable) is None:
                raise RuntimeError(f"Runner image is missing {executable}")
        for path in (
            ROOT / "terraform/usrse26-eks/versions.tf",
            ROOT / "platform/aws/check_terraform_plan.py",
            ROOT / "platform/scripts/deploy_aws_fabric.sh",
            ROOT / "platform/.generated/fabric-network-eks/network",
            Path("/opt/osc/chaincode-go/go.mod"),
        ):
            if not path.exists():
                raise RuntimeError(f"Runner image is missing {path}")
        fabric_bin = ROOT / "platform/.generated/fabric-network-eks/bin"
        version_checks = {
            (str(fabric_bin / "peer"), "version"): "Version: v2.5.16",
            (str(fabric_bin / "fabric-ca-client"), "version"): "Version: v1.5.22",
            ("terraform", "version"): "Terraform v1.16.2",
            ("kubectl", "version", "--client"): "Client Version: v1.35.8",
        }
        for command, expected in version_checks.items():
            output = run(list(command)).stdout
            if expected not in output:
                raise RuntimeError(f"Runner tool version check failed for {command[0]}")
        print("Lifecycle runner image self-test passed.")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in VALID_ACTIONS:
        raise SystemExit(f"usage: osc-demo-lifecycle {'|'.join(sorted(VALID_ACTIONS))}")
    action = sys.argv[1]
    if action == "SELF_TEST":
        Lifecycle.self_test()
        return
    lifecycle = Lifecycle()
    lifecycle.guard()
    dispatch = {
        "START": lifecycle.start,
        "CANARY": lifecycle.canary,
        "MONITOR": lifecycle.monitor,
        "READ_ONLY": lifecycle.read_only,
        "EXPORT": lifecycle.export,
        "DESTROY": lifecycle.destroy,
        "DESTROY_RUNTIME": lifecycle.destroy_runtime,
        "SWEEP": lifecycle.sweep,
        "FAILED_START_CLEANUP": lifecycle.failed_start_cleanup,
    }
    dispatch[action]()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        if len(sys.argv) == 2 and sys.argv[1] == "START":
            print("START failed; attempting same-build tagged cleanup before exiting", file=sys.stderr)
            try:
                cleanup = Lifecycle()
                cleanup.guard()
                cleanup.failed_start_cleanup()
            except Exception as cleanup_error:
                print(f"same-build cleanup also failed: {cleanup_error}", file=sys.stderr)
        print(f"lifecycle action failed: {error}", file=sys.stderr)
        raise SystemExit(1)
