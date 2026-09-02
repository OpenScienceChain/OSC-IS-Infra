[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}/32$')]
    [string]$AdminCidr,

    [ValidateRange(1, 8)]
    [int]$Hours = 8
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-eks'
$runRoot = Join-Path $repoRoot "platform\.generated\aws\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$planPath = Join-Path $runRoot 'reviewed.tfplan'
$planJsonPath = Join-Path $runRoot 'reviewed-plan.json'
$tfvarsPath = Join-Path $runRoot 'run.tfvars'
$baselinePath = Join-Path $runRoot 'baseline-inventory.json'
$costPath = Join-Path $runRoot 'cost-estimate.json'
$metadataPath = Join-Path $runRoot 'run-metadata.json'

if ($AdminCidr -eq '0.0.0.0/32' -or $AdminCidr -eq '0.0.0.0/0') {
    throw 'AdminCidr must identify one trusted public IPv4 address.'
}

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$startedAt = [DateTimeOffset]::UtcNow
$expiresAt = $startedAt.AddHours($Hours)

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py
    python platform/aws/inventory.py --output $baselinePath
    python platform/aws/estimate_cost.py --hours $Hours --output $costPath

    $tfvars = @(
        "run_id = `"$RunId`""
        "expires_at = `"$($expiresAt.ToString('o'))`""
        "admin_cidr = `"$AdminCidr`""
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($tfvarsPath, $tfvars + [Environment]::NewLine)

    $metadata = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        startedAt = $startedAt.ToString('o')
        expiresAt = $expiresAt.ToString('o')
        maximumHours = $Hours
        account = '269624229733'
        profile = 'default'
        region = 'us-west-2'
        status = 'PLANNED'
    }
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json) + [Environment]::NewLine)

    Push-Location $terraformRoot
    try {
        terraform init -backend=false -input=false
        terraform validate
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py')
        $planArgs = @(
            'plan'
            '-input=false'
            '-lock=true'
            "-state=$statePath"
            "-var-file=$tfvarsPath"
            "-out=$planPath"
        )
        & terraform @planArgs
        if ($LASTEXITCODE -ne 0) { throw 'Terraform plan failed.' }
        $planJson = & terraform show -json $planPath
        if ($LASTEXITCODE -ne 0) { throw 'Terraform plan serialization failed.' }
        [IO.File]::WriteAllText($planJsonPath, ($planJson -join [Environment]::NewLine))
    }
    finally {
        Pop-Location
    }

    python platform/aws/check_terraform_plan.py $planJsonPath
    Write-Host "AWS evidence plan is ready for review: $planPath"
    Write-Host "It expires at $($expiresAt.ToString('o')); do not apply it after that time."
}
finally {
    Pop-Location
}
