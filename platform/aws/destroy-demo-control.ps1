[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{8,20}$')][string]$RunId)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-control'
$runRoot = Join-Path $repoRoot "platform\.generated\control\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$tfvarsPath = Join-Path $runRoot 'control.tfvars'
$runtimeProof = Join-Path $runRoot 'runtime-teardown-proof.json'

foreach ($path in @($statePath, $tfvarsPath, $runtimeProof)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing control teardown input: $path" }
}
$proof = Get-Content -LiteralPath $runtimeProof -Raw | ConvertFrom-Json
if ($proof.runId -ne $RunId -or $proof.remainingTaggedResources -ne 0 -or $proof.status -ne 'DESTROYED_AND_VERIFIED') {
    throw 'Runtime teardown proof is not complete; refusing to remove the surviving edge/control plane.'
}

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py | Out-Null
    Push-Location $terraformRoot
    try {
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py') | Out-Null
        terraform destroy -input=false -auto-approve "-state=$statePath" "-var-file=$tfvarsPath"
        if ($LASTEXITCODE -ne 0) { throw 'Control-plane destroy failed.' }
    }
    finally { Pop-Location }
}
finally { Pop-Location }
