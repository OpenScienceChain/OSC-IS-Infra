# AWS evidence run `usrse260930`

Captured 2026-09-30 UTC. Release owner: OSC-IS coordination chat.

## Verified baseline

- Account `269624229733`, region `us-west-2`; EKS cluster `osc-usrse26-usrse260930-eks` active with one ready node in each of `us-west-2a`, `2b`, and `2c`.
- Fabric has three orderers plus two peer organizations: `NSGMSP` and `CitizenScienceMSP`. Both organizations have two ready peers and two ready chaincode services. This is **not** a three-peer-organization AWS deployment.
- Argo CD application `osc-is-aws` was `Synced/Healthy` at GitOps commit `a6ece95a2a3aa5ba81357d21c0e3d79faf51384b`. The screenshot was taken in headless Chrome through a localhost-only port-forward. Argo manages application workloads; Fabric bootstrap was performed separately.
- Maintained Postman public readiness: 2 requests, 2 assertions, 0 failures. Authenticated multi-org smoke: 6 requests, 0 failed assertions, 0 failures. The negative cross-org update returned HTTP 403.
- Full-stack validation confirmed one NSG artifact with two Fabric revisions, one NSG workflow with a Fabric transaction, ledger history, active-organization claims, and application- and Fabric-level cross-organization denials. See `aws-stack-summary.json` for the IDs and results.
- Controlled dependency-failure validation passed: ledger gateway recovered in 50 seconds, RabbitMQ/outbox in 225 seconds, and an alternate peer accepted a transaction during an NSG peer failure in 8 seconds. Every artifact had one Fabric revision and no duplicate ledger write was observed. These are single-run recovery observations, not benchmark distributions. Argo returned to `Synced/Healthy`, all original replicas became ready, and a fresh six-request Postman smoke passed after recovery.
- A separate, bounded GitOps drift test reduced the API deployment from two replicas to one. Argo restored the declared two replicas and returned to `Synced/Healthy` in 14 seconds without a Git revision change. The forwarded API health check passed afterward. This is one observation, not a reconciliation SLA.
- Public catalog eventually exposed both Postman-created public artifacts. The catalog intentionally omits organization metadata; authentication and cross-org tests establish tenancy separately.

## Security and trade-offs

- The EKS API has private access enabled. Its public control endpoint is restricted to the operator's observed IP `173.255.173.19/32`. The application ALB is internal; the Argo UI is not publicly exposed. The release S3 bucket blocks public ACLs and policies.
- The pinned Fabric test-network manifests retain sample internal CA/CouchDB credentials, and `osc-fabric` has no namespace NetworkPolicy. Those services are ClusterIP/localhost-forward only in this run, but this deployment must not be presented as production-hardened or opened to untrusted networks without replacing credentials and reviewing Fabric traffic policy.
- OCI runtime references are pinned to SHA-256 digests. The nine prepared local images passed a Trivy High/Critical scan with zero findings at build time. This is a bounded scan, not a claim that dependencies are vulnerability-free. The unused lifecycle-runner image was not promoted to ECR.
- The ALB controller was not granted broader security-group permissions. A Terraform-managed TCP/3000 rule connects the exact origin security group to the cluster security group. A generated GitOps hotfix pins the ingress to that security-group ID and disables automatic backend-rule management. That generated GitOps revision is preserved in the run workspace and ECR, but the original pre-Terraform renderer does not yet reproduce this post-apply substitution automatically.
- The run was explicitly authorized to remain up overnight. No automatic teardown exists; `ExpiresAt` is metadata, not a shutdown timer. The preflight model was approximately USD 0.9425/hour, USD 22.62 for 24 hours, with a USD 48.28 run-plus-allowance/contingency estimate. Actual billing may differ. The Terraform expiry metadata is 2026-10-01 03:08 UTC; the artifact manifest has an earlier 2026-10-01 01:50 UTC value. Neither stops resources.
- No real third-organization onboarding time is reported. The current EKS bootstrap/channel and GitOps deployment only support the two peer organizations above. A database-only third org or Argo-only pod would misstate blockchain provenance. The incremental Fabric config update, identity, third peer/chaincode, routing, and local rehearsal remain required before a measured AWS addition.

## Morning access

From the guarded Infra worktree with the EKS context `osc-usrse26-usrse260930`, use localhost-only forwards:

```powershell
kubectl -n argocd port-forward service/argocd-server 18980:443 --address 127.0.0.1
kubectl -n osc-apps port-forward service/api-gateway 18989:3000 --address 127.0.0.1
```

Argo is at `https://127.0.0.1:18980/` (self-signed certificate); the AWS API health endpoint is `http://127.0.0.1:18989/api/v1/health`. Initial Argo admin credentials remain in the Kubernetes `argocd-initial-admin-secret`; do not copy them into reports. The existing local Docker site at `http://localhost:18088/` is a different deployment.

The maintained Postman collection is `OSC-APIGateway/collections/OSC-IS Core Smoke.postman_collection.json`. Set `baseUrl` to `http://127.0.0.1:18989/api/v1`. The guarded `platform/aws/run-postman-smoke.js` runner reads seeded test credentials from Kubernetes without putting them in command-line arguments or saved reports. Do not publish a full Newman environment or response-body report.

## Shutdown, later

At the operator's direction, run `platform/aws/destroy-run.ps1 -RunId usrse260930` from the Infra worktree. Its Terraform state and baseline inventory are in the ignored `platform/.generated/aws/usrse260930/` directory; do not remove that directory before teardown. The release S3 bucket `osc-usrse26-usrse260930-release-269624229733` and IAM boundary `osc-usrse26-usrse260930-runtime-boundary` were provisioned outside Terraform and require an exact-name cleanup and final inventory check after the main destroy. Do not assume the current destroy script handles those two resources.

## Evidence files

- `argocd-two-orgs.png`: Chrome capture of the Argo application tree and health/sync state.
- `argocd-two-orgs.json`: UTC capture metadata.
- `postman-multi-org-summary.json`: sanitized per-request status and assertion results.
- `aws-stack-summary.json`: sanitized end-to-end provenance and authorization results.
- `aws-recovery-summary.json`: sanitized gateway, broker, and peer failure/recovery measurements.
- `postman-post-recovery-summary.json`: authenticated smoke run after full restoration.
- `aws-gitops-drift-summary.json`: single-run Argo replica self-heal timing and revision.

The ignored run workspace retains the reviewed Terraform plan, image manifests, scan/SBOM records, generated GitOps repository, and Kubernetes port-forward logs. These may contain operational details and should not be published wholesale.
