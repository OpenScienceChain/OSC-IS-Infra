[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$manifestPath = Join-Path $runRoot 'artifacts\artifacts.json'
$deploymentPath = Join-Path $runRoot 'artifacts\ecr-deployment.json'
$registry = '269624229733.dkr.ecr.us-west-2.amazonaws.com'

if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Credential-free artifact manifest is absent.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.runId -ne $RunId -or -not $manifest.credentialFreeBuild) { throw 'Artifact manifest provenance check failed.' }

foreach ($image in $manifest.images.PSObject.Properties) {
    $actualSha = (Get-FileHash -LiteralPath $image.Value.archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $image.Value.archiveSha256) { throw "Archive checksum mismatch for $($image.Name)." }
    docker load --input $image.Value.archive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not load verified archive for $($image.Name)." }
}

Push-Location $infraRoot
try {
    python platform/aws/aws_guard.py
    aws ecr get-login-password --profile default --region us-west-2 --no-cli-pager | docker login --username AWS --password-stdin $registry | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Short-lived ECR login failed.' }

    $pushed = [ordered]@{}
    foreach ($image in $manifest.images.PSObject.Properties) {
        $name = $image.Name
        $repository = "osc-usrse26-$RunId/$name"
        $tagged = "$registry/$repository`:$RunId"
        docker tag $image.Value.localReference $tagged
        if ($LASTEXITCODE -ne 0) { throw "Could not tag $name for ECR." }
        docker push $tagged | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not push $name to ECR." }

        python platform/aws/aws_guard.py | Out-Null
        $actualDigest = (aws ecr describe-images `
            --repository-name $repository `
            --image-ids "imageTag=$RunId" `
            --query 'imageDetails[0].imageDigest' `
            --output text `
            --profile default `
            --region us-west-2 `
            --no-cli-pager).Trim()
        if ($actualDigest -ne $image.Value.localDigest) {
            throw "ECR digest mismatch for ${name}: expected $($image.Value.localDigest), got $actualDigest"
        }
        $pushed[$name] = "$registry/$repository@$actualDigest"
    }

    $report = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        pushedAt = [DateTimeOffset]::UtcNow.ToString('o')
        buildsExecutedWithAwsCredentials = $false
        references = $pushed
    }
    [IO.File]::WriteAllText($deploymentPath, ($report | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host 'All ECR manifest digests match the credential-free local build manifest.'
}
finally {
    docker logout $registry | Out-Null
    Pop-Location
}
