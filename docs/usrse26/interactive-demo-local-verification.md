# Interactive Demo Local Verification

## Verified on this branch

The following checks completed in the isolated local Kind environment without
writing to AWS:

- both Terraform roots initialized without backends and validated;
- the complete AWS Kustomize bundle rendered successfully;
- the pinned Fabric sample source was checksum/revision verified and patched;
- the generated EKS Fabric topology passed the three-orderer, two-peer-per-
  organization, Raft, and immutable-image validator;
- all Python files compiled and all PowerShell files passed AST parsing;
- the dependency-free interactive-demo contract suite passed;
- the `TIME_BOUNDED` 72-hour planning model produced USD 104.83 against the
  USD 200 pre-deployment ceiling, and the rendered lifecycle boundary/identity
  model contained zero Budget or billing actions;
- the production WebApp route passed a live Cypress browser journey through
  session selection, artifact confirmation/history, workflow confirmation, and
  feedback;
- the 300-session load candidate completed 300 artifact and 120 workflow
  submissions with zero unexpected failures, zero duplicate ledger revisions,
  and every terminal confirmation under five minutes (artifact p95 164,309 ms;
  workflow p95 62,676 ms);
- API Gateway, RabbitMQ, and Fabric peer recovery checks passed with no duplicate
  ledger revisions; and
- Argo CD self-heal, digest rollout, and rollback checks passed (1 s, 13 s, and
  10 s respectively) without storing Git credentials; and
- `fabric-down.sh` removed the exact `osc-usrse26-infra` Kind cluster and local
  registry and verified both were absent.

These checks establish local behavior and configuration validity only. They do
not establish an AWS deployment, production readiness, adoption, or measured
researcher benefit.

## Reproduction sequence

With the product revisions frozen, the local sequence is:

```powershell
wsl bash platform/scripts/validate-clean-checkout.sh
wsl bash platform/scripts/prepare-local.sh
wsl bash platform/scripts/fabric-up.sh
wsl bash platform/scripts/build-local-images.sh
wsl bash platform/scripts/deploy-local-apps.sh
wsl bash platform/scripts/seed-local-data.sh
wsl bash platform/scripts/validate-local-stack.sh
wsl bash platform/scripts/validate-local-recovery.sh
wsl bash platform/scripts/deploy-local-gitops.sh
wsl bash platform/scripts/validate-local-gitops.sh
wsl bash platform/scripts/fabric-down.sh
./platform/aws/prepare-aws-artifacts.ps1 `
  -RunId usrse26demo `
  -AlbControllerImage 'public.ecr.aws/eks/aws-load-balancer-controller@sha256:REVIEWED' `
  -ExpiresAt '2026-10-23T15:00:00Z'
```

The final preparation command must stop if a sibling repository is dirty or if
any image has a HIGH or CRITICAL vulnerability. Record the exact repository
revisions, test transcript, WebApp bundle SHA-256, OCI digests, SBOM/scan
checksums, and any failed assertions in the release evidence package.
