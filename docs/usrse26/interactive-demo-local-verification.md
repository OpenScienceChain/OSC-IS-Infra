# Interactive Demo Local Verification

## Verified on this branch

The following checks completed without writing to AWS or any remote Git
repository:

- both Terraform roots initialized without backends and validated;
- the complete AWS Kustomize bundle rendered successfully;
- the pinned Fabric sample source was checksum/revision verified and patched;
- the generated EKS Fabric topology passed the three-orderer, two-peer-per-
  organization, Raft, and immutable-image validator;
- all Python files compiled and all PowerShell files passed AST parsing; and
- the dependency-free interactive-demo contract suite passed.

These checks establish configuration and contract validity only. They do not
establish an AWS deployment, load result, failover result, or production claim.

## Deliberately not claimed

A complete Kind browser-to-ledger E2E run was not executed because the release
owner's API Gateway demo-session/API contracts are still uncommitted in its
separate working copy, and the reviewed WebApp demo bundle is not yet available
as a versioned release artifact. Building those dirty sibling repositories
would make the evidence irreproducible and could disturb work owned by another
task.

Once product revisions are frozen, run:

```powershell
wsl bash platform/scripts/validate-clean-checkout.sh
wsl bash platform/scripts/prepare-local.sh
wsl bash platform/scripts/fabric-up.sh
wsl bash platform/scripts/deploy-local-apps.sh
wsl bash platform/scripts/seed-local-data.sh
wsl bash platform/scripts/validate-local-stack.sh
wsl bash platform/scripts/validate-local-recovery.sh
wsl bash platform/scripts/deploy-local-gitops.sh
wsl bash platform/scripts/validate-local-gitops.sh
wsl bash platform/scripts/fabric-down.sh
./platform/aws/prepare-aws-artifacts.ps1 `
  -RunId usrse26demo `
  -AlbControllerImage 'public.ecr.aws/eks/aws-load-balancer-controller@sha256:REVIEWED'
```

Then record the exact repository revisions, test transcript, WebApp bundle
SHA-256, OCI digests, and any failed assertions in the release evidence package.
