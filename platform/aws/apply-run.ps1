[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $repoRoot "platform\.generated\aws\$RunId"
$terraformRoot = Join-Path $runRoot 'terraform-local'
$statePath = Join-Path $runRoot 'terraform.tfstate'
$planPath = Join-Path $runRoot 'reviewed.tfplan'
$planJsonPath = Join-Path $runRoot 'reviewed-plan.json'
$metadataPath = Join-Path $runRoot 'run-metadata.json'

foreach ($required in @($planPath, $planJsonPath, $metadataPath, $statePath, (Join-Path $terraformRoot 'versions.tf'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing reviewed run artifact: $required" }
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.runId -ne $RunId -or $metadata.backendOwner -ne 'local' -or
    $metadata.account -ne '269624229733' -or $metadata.region -ne 'us-west-2') {
    throw 'Run metadata violates the authorized AWS boundary.'
}
if (-not (Get-Content -LiteralPath (Join-Path $terraformRoot 'versions.tf') -Raw).Contains('backend "local" {}')) {
    throw 'Reviewed Terraform copy is not configured for local state.'
}
if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($metadata.expiresAt)) {
    throw 'The reviewed plan has expired. Prepare a new run instead of applying it.'
}

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py
    python platform/aws/check_terraform_plan.py $planJsonPath
    Push-Location $terraformRoot
    try {
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py')
        terraform apply -input=false -auto-approve $planPath
        if ($LASTEXITCODE -ne 0) { throw 'Terraform apply failed.' }
        terraform output -json | Out-File -LiteralPath (Join-Path $runRoot 'terraform-outputs.json') -Encoding utf8NoBOM
    }
    finally {
        Pop-Location
    }
    $metadata.status = 'APPLIED'
    $metadata | Add-Member -NotePropertyName appliedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json) + [Environment]::NewLine)
    Write-Host "Run $RunId applied. Teardown deadline: $($metadata.expiresAt)"
}
finally {
    Pop-Location
}
