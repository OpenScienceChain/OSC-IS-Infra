[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^(?:auto[a-z0-9]{4,16}|manual[a-z0-9]{2,14})$')][string]$RunId,
    [Parameter(Mandatory = $true)][ValidatePattern('^Z[A-Z0-9]+$')][string]$HostedZoneId,
    [Parameter(Mandatory = $true)][ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}/32$')][string]$AdminCidr,
    [Parameter(Mandatory = $true)][ValidatePattern('^[^\s]+@sha256:[0-9a-f]{64}$')][string]$LifecycleRunnerImage,
    [Parameter(Mandatory = $true)][ValidatePattern('^s3://[a-z0-9.-]+/.+/.+\.json$')][string]$ArtifactManifestS3Uri,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArtifactManifestSha256,
    [AllowNull()][string]$NotificationEmail = $null
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-control'
$runRoot = Join-Path $repoRoot "platform\.generated\control\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$planPath = Join-Path $runRoot 'reviewed.tfplan'
$planJsonPath = Join-Path $runRoot 'reviewed-plan.json'
$tfvarsPath = Join-Path $runRoot 'control.tfvars'
$artifactManifestPath = Join-Path $repoRoot "platform\.generated\aws\$RunId\artifacts\artifacts.json"

if ($AdminCidr -in @('0.0.0.0/0', '0.0.0.0/32')) { throw 'AdminCidr must identify one trusted IPv4 address.' }
if ($LifecycleRunnerImage -notmatch "^269624229733[.]dkr[.]ecr[.]us-west-2[.]amazonaws[.]com/osc-usrse26-$RunId/lifecycle-runner@sha256:[0-9a-f]{64}$") {
    throw 'LifecycleRunnerImage must be the immutable image in this exact run-scoped ECR repository.'
}
if (-not (Test-Path -LiteralPath $artifactManifestPath -PathType Leaf)) { throw 'The exact-run artifact manifest is absent.' }
$artifactManifest = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json
if ($artifactManifest.runId -ne $RunId) { throw 'Artifact manifest run ID mismatch.' }
$manualExpiresAt = ([DateTimeOffset]$artifactManifest.expiresAt).ToUniversalTime()
if ($RunId.StartsWith('manual') -and
    ($manualExpiresAt -le [DateTimeOffset]::UtcNow.AddHours(3) -or $manualExpiresAt -gt [DateTimeOffset]::UtcNow.AddHours(72))) {
    throw 'Manual control expiry must be more than three hours and no more than 72 hours away.'
}
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py | Out-Null
    $costEstimatePath = Join-Path $runRoot 'cost-estimate.json'
    python platform/aws/estimate_cost.py --hours 72 --output $costEstimatePath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Pre-deployment planning-estimate gate failed.' }
    $costEstimate = Get-Content -LiteralPath $costEstimatePath -Raw | ConvertFrom-Json
    if ($costEstimate.costControlMode -ne 'TIME_BOUNDED' -or
        -not $costEstimate.approvedForPlanning -or
        [decimal]$costEstimate.plannedEstimateWith25PercentContingency -gt 200) {
        throw 'Planning estimate is missing, inconsistent, or above USD 200.'
    }
    $planningEstimateUsd = [decimal]$costEstimate.plannedEstimateWith25PercentContingency
    $tfvarsArguments = @(
        'platform/aws/write_control_tfvars.py',
        '--output', $tfvarsPath,
        '--run-id', $RunId,
        '--hosted-zone-id', $HostedZoneId,
        '--admin-cidr', $AdminCidr,
        '--lifecycle-runner-image', $LifecycleRunnerImage,
        '--artifact-manifest-s3-uri', $ArtifactManifestS3Uri,
        '--artifact-manifest-sha256', $ArtifactManifestSha256,
        '--planning-estimate-usd', $planningEstimateUsd.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    if (-not [string]::IsNullOrWhiteSpace($NotificationEmail)) {
        $tfvarsArguments += @('--notification-email', $NotificationEmail.Trim())
    }
    if ($RunId.StartsWith('manual')) {
        $tfvarsArguments += @('--manual-expires-at', $manualExpiresAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    }
    python @tfvarsArguments
    if ($LASTEXITCODE -ne 0) { throw 'Control-plane variable generation failed.' }

    Push-Location $terraformRoot
    try {
        terraform init -backend=false -input=false
        if ($LASTEXITCODE -ne 0) { throw 'Terraform initialization failed.' }
        terraform validate
        if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
        $lifecycleRepository = "osc-usrse26-$RunId/lifecycle-runner"
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py') | Out-Null
        aws ecr describe-repositories `
            --repository-names $lifecycleRepository `
            --profile default `
            --region us-west-2 `
            --no-cli-pager | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The reviewed lifecycle-runner ECR repository must exist before control-plane planning.' }
        $stateEntries = @(terraform state list "-state=$statePath" 2>$null)
        if ($stateEntries -notcontains 'aws_ecr_repository.lifecycle_runner') {
            terraform import -input=false "-state=$statePath" "-var-file=$tfvarsPath" `
                aws_ecr_repository.lifecycle_runner $lifecycleRepository
            if ($LASTEXITCODE -ne 0) { throw 'Could not import the exact lifecycle-runner repository into control state.' }
        }
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py') | Out-Null
        terraform plan -input=false -lock=true "-state=$statePath" "-var-file=$tfvarsPath" "-out=$planPath"
        if ($LASTEXITCODE -ne 0) { throw 'Terraform control-plane plan failed.' }
        terraform show -json $planPath | Out-File -LiteralPath $planJsonPath -Encoding utf8NoBOM
        if ($LASTEXITCODE -ne 0) { throw 'Terraform plan serialization failed.' }
    }
    finally { Pop-Location }

    $guardArguments = @('platform/aws/check_control_plan.py', $planJsonPath, '--run-id', $RunId)
    if ($RunId.StartsWith('manual')) {
        $guardArguments += @('--manual-expires-at', $manualExpiresAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    }
    python @guardArguments
    if ($LASTEXITCODE -ne 0) { throw 'Control-plane policy check failed.' }
    Write-Host "Reviewed control-plane plan: $planPath"
}
finally { Pop-Location }
