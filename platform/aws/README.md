# Guarded AWS interactive-demo run

These dependency-free scripts operate only in AWS account `269624229733`,
profile `default`, region `us-west-2`. They keep raw inventories, state, plans,
and outputs under ignored `platform/.generated/aws/<run-id>/` storage.

The required order is:

```powershell
./platform/aws/prepare-run.ps1 -RunId usrse26demo -AdminCidr 203.0.113.10/32 -Hours 72 -AlbControllerImage 'IMAGE@sha256:REVIEWED'
./platform/aws/apply-run.ps1 -RunId usrse26demo
# Deploy and validate only prebuilt, scanned artifacts.
./platform/aws/destroy-run.ps1 -RunId usrse26demo
```

`prepare-run.ps1` captures the baseline, applies the $200 ceiling, creates a
saved Terraform plan, and rejects destructive, public, mutable, untagged, or
out-of-scope resources. `apply-run.ps1` only applies that reviewed plan before
its configured expiry. `destroy-run.ps1` destroys runtime and fails unless the
final inventory has exact baseline parity.

The persistent status edge and automated lifecycle use the separate guarded
`prepare-demo-control.ps1`, `apply-demo-control.ps1`, and
`destroy-demo-control.ps1` flow documented in
`docs/usrse26/interactive-demo-runbook.md`.

Do not deploy applications until their images have been built, tested, scanned,
and recorded by digest. Do not build or install dependencies after apply.
