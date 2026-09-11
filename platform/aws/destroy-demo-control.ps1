[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{8,20}$')][string]$RunId)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-control'
$runRoot = Join-Path $repoRoot "platform\.generated\control\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$tfvarsPath = Join-Path $runRoot 'control.tfvars'
$runtimeProof = Join-Path $runRoot 'runtime-teardown-proof.json'
$finalProof = Join-Path $runRoot 'control-plane-teardown-proof.json'
$deploymentPath = Join-Path $repoRoot "platform\.generated\aws\$RunId\artifacts\ecr-deployment.json"

foreach ($path in @($statePath, $tfvarsPath, $deploymentPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing control teardown input: $path" }
}

function Get-TaggedResources([string]$Region) {
    $result = aws resourcegroupstaggingapi get-resources `
        --tag-filters `
            'Key=Project,Values=OSC-IS' `
            'Key=Purpose,Values=USRSE26-Interactive-Demo' `
            "Key=RunId,Values=$RunId" `
        --output json `
        --profile default `
        --region $Region `
        --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not inventory tagged resources in $Region." }
    return @($result.ResourceTagMappingList | ForEach-Object { $_.ResourceARN } | Sort-Object)
}

function Remove-ReleaseArtifacts([string]$Bucket) {
    $prefix = "releases/$RunId/"
    do {
        $listing = aws s3api list-object-versions `
            --bucket $Bucket `
            --prefix $prefix `
            --output json `
            --profile default `
            --region us-west-2 `
            --no-cli-pager | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Could not inventory exact versioned release objects.' }
        $objects = @(
            @($listing.Versions) | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } }
            @($listing.DeleteMarkers) | ForEach-Object { @{ Key = $_.Key; VersionId = $_.VersionId } }
        )
        if ($objects.Count -gt 0) {
            $batch = @{ Objects = @($objects | Select-Object -First 1000); Quiet = $true } | ConvertTo-Json -Depth 5 -Compress
            $batchPath = Join-Path $runRoot 'release-delete-batch.json'
            [IO.File]::WriteAllText($batchPath, $batch + [Environment]::NewLine)
            python platform/aws/aws_guard.py | Out-Null
            aws s3api delete-objects `
                --bucket $Bucket `
                --delete "file://$batchPath" `
                --profile default `
                --region us-west-2 `
                --no-cli-pager | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not remove exact versioned release objects.' }
        }
    } while ($objects.Count -gt 0)
}

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py | Out-Null
    Push-Location $terraformRoot
    try {
        $controlBucket = (terraform output "-state=$statePath" -raw control_bucket).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($controlBucket)) {
            throw 'Could not resolve the exact control evidence bucket from reviewed Terraform state.'
        }
    }
    finally { Pop-Location }
    aws s3api get-object `
        --bucket $controlBucket `
        --key "evidence/$RunId/runtime-teardown-proof.json" `
        $runtimeProof `
        --profile default `
        --region us-west-2 `
        --no-cli-pager | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not download the runtime teardown proof from the control bucket.' }
    $proof = Get-Content -LiteralPath $runtimeProof -Raw | ConvertFrom-Json
    $residualCount = @($proof.residual.PSObject.Properties | ForEach-Object { @($_.Value).Count } | Measure-Object -Sum).Sum
    if (
        $proof.runId -ne $RunId -or
        -not $proof.verified -or
        $proof.remainingTaggedResources -ne 0 -or
        $residualCount -ne 0 -or
        -not $proof.cloudFrontRuntimeOriginDetached -or
        -not $proof.staticFallbackHealthy -or
        $proof.status -ne 'DESTROYED_AND_VERIFIED'
    ) {
        throw 'Runtime teardown proof is not complete; refusing to remove the surviving edge/control plane.'
    }
    $inventoryBefore = @(
        Get-TaggedResources 'us-west-2'
        Get-TaggedResources 'us-east-1'
    ) | Sort-Object -Unique
    Push-Location $terraformRoot
    try {
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py') | Out-Null
        terraform destroy -input=false -auto-approve "-state=$statePath" "-var-file=$tfvarsPath"
        if ($LASTEXITCODE -ne 0) { throw 'Control-plane destroy failed.' }
    }
    finally { Pop-Location }

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
    if ($deployment.runId -ne $RunId -or $deployment.artifactManifest.s3Uri -notmatch '^s3://([^/]+)/releases/([^/]+)/artifacts[.]json$') {
        throw 'Release evidence does not identify the exact run-scoped artifact prefix.'
    }
    if ($Matches[2] -ne $RunId) { throw 'Release evidence RunId and S3 prefix disagree.' }
    Remove-ReleaseArtifacts $Matches[1]

    $inventoryAfter = @(
        Get-TaggedResources 'us-west-2'
        Get-TaggedResources 'us-east-1'
    ) | Sort-Object -Unique
    $final = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        expectedAccount = '269624229733'
        expectedRegion = 'us-west-2'
        status = if ($inventoryAfter.Count -eq 0) { 'CONTROL_DESTROYED_AND_VERIFIED' } else { 'RESIDUAL_TAGGED_RESOURCES' }
        inventoryBeforeDestroy = @($inventoryBefore)
        inventoryAfterDestroy = @($inventoryAfter)
        remainingTaggedResources = $inventoryAfter.Count
        runtimeProofSha256 = (Get-FileHash -LiteralPath $runtimeProof -Algorithm SHA256).Hash.ToLowerInvariant()
        releaseArtifactsRemoved = $true
        checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($finalProof, ($final | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    if ($inventoryAfter.Count -ne 0) {
        throw "Tagged resources remain after control teardown; evidence is at $finalProof"
    }
}
finally { Pop-Location }
