[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-eks'
$runRoot = Join-Path $repoRoot "platform\.generated\aws\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$tfvarsPath = Join-Path $runRoot 'run.tfvars'
$baselinePath = Join-Path $runRoot 'baseline-inventory.json'
$finalPath = Join-Path $runRoot 'final-inventory.json'
$parityPath = Join-Path $runRoot 'inventory-parity.json'
$metadataPath = Join-Path $runRoot 'run-metadata.json'

foreach ($required in @($statePath, $tfvarsPath, $baselinePath, $metadataPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing teardown artifact: $required" }
}

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py
    & (Join-Path $repoRoot 'platform/aws/cleanup-aws-workloads.ps1') -RunId $RunId
    if ($LASTEXITCODE -ne 0) { throw 'Kubernetes workload cleanup failed.' }
    Push-Location $terraformRoot
    try {
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py')
        terraform destroy -input=false -auto-approve -state=$statePath -var-file=$tfvarsPath
        if ($LASTEXITCODE -ne 0) { throw 'Terraform destroy failed; do not leave this session.' }
    }
    finally {
        Pop-Location
    }

    python platform/aws/aws_guard.py
    python platform/aws/inventory.py --output $finalPath
    python platform/aws/compare_inventories.py $baselinePath $finalPath --run-id $RunId --output $parityPath

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.status = 'DESTROYED_AND_VERIFIED'
    $metadata | Add-Member -NotePropertyName destroyedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json) + [Environment]::NewLine)
    Write-Host "Run $RunId destroyed; final inventory matches the baseline."
}
finally {
    Pop-Location
}
