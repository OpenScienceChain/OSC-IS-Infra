# Guarded AWS evidence run

These dependency-free scripts operate only in AWS account `269624229733`,
profile `default`, region `us-west-2`. They keep raw inventories, state, plans,
and outputs under ignored `platform/.generated/aws/<run-id>/` storage.

The required order is:

```powershell
./platform/aws/prepare-run.ps1 -RunId 20260902a -AdminCidr 203.0.113.10/32
./platform/aws/apply-run.ps1 -RunId 20260902a
# Deploy and validate only prebuilt, scanned artifacts.
./platform/aws/destroy-run.ps1 -RunId 20260902a
```

`prepare-run.ps1` captures the baseline, applies the cost ceiling, creates a
saved Terraform plan, and rejects destructive, public, mutable, untagged, or
out-of-scope resources. `apply-run.ps1` only applies that reviewed plan before
its eight-hour expiry. `destroy-run.ps1` destroys the Terraform state and fails
unless the final inventory has exact baseline parity.

Do not deploy applications until their images have been built, tested, scanned,
and recorded by digest. Do not build or install dependencies after apply.
