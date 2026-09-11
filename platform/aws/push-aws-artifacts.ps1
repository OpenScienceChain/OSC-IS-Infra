[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$ReleaseBucket,

    [Parameter(Mandatory = $true)]
    [datetimeoffset]$ExpiresAt
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$manifestPath = Join-Path $runRoot 'artifacts\artifacts.json'
$deploymentPath = Join-Path $runRoot 'artifacts\ecr-deployment.json'
$registry = '269624229733.dkr.ecr.us-west-2.amazonaws.com'
$releasePrefix = "releases/$RunId"
$manifestKey = "$releasePrefix/artifacts.json"
$repositoryPolicyPath = Join-Path $runRoot 'artifacts\ecr-lifecycle-policy.json'
$controlExpiresAt = '2026-11-22T15:00:00Z'

if ($ExpiresAt -le [DateTimeOffset]::UtcNow -or $ExpiresAt -gt [DateTimeOffset]::UtcNow.AddHours(72)) {
    throw 'ExpiresAt must be in the future and no more than 72 hours from now.'
}

if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Isolated-build artifact manifest is absent.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.runId -ne $RunId -or
    $manifest.buildCredentialIsolation.status -ne 'ENFORCED_COMMON_AWS_SOURCES_ABSENT' -or
    -not $manifest.buildCredentialIsolation.commonAwsCredentialSourcesAbsent) {
    throw 'Artifact manifest build-isolation provenance check failed.'
}
$credentialEvidencePath = [string]$manifest.buildCredentialIsolation.evidenceFile
if (-not (Test-Path -LiteralPath $credentialEvidencePath)) { throw 'Build credential-isolation evidence is absent.' }
$credentialEvidenceSha = (Get-FileHash -LiteralPath $credentialEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($credentialEvidenceSha -ne $manifest.buildCredentialIsolation.evidenceSha256) {
    throw 'Build credential-isolation evidence checksum mismatch.'
}
if ([DateTimeOffset]::Parse($manifest.expiresAt).ToString('o') -ne $ExpiresAt.ToString('o')) {
    throw 'ExpiresAt does not match the isolated-build artifact manifest.'
}

foreach ($image in $manifest.images.PSObject.Properties) {
    $actualSha = (Get-FileHash -LiteralPath $image.Value.archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $image.Value.archiveSha256) { throw "Archive checksum mismatch for $($image.Name)." }
    docker load --input $image.Value.archive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not load verified archive for $($image.Name)." }
}

Push-Location $infraRoot
try {
    python platform/aws/aws_guard.py
    $versioning = (aws s3api get-bucket-versioning `
        --bucket $ReleaseBucket `
        --query Status `
        --output text `
        --profile default `
        --region us-west-2 `
        --no-cli-pager).Trim()
    if ($LASTEXITCODE -ne 0 -or $versioning -ne 'Enabled') {
        throw 'The release bucket must exist in the authorized account with versioning enabled.'
    }

    $repositoryPolicy = @{
        rules = @(@{
            rulePriority = 1
            description = 'Retain only the five most recent experiment images'
            selection = @{tagStatus = 'any'; countType = 'imageCountMoreThan'; countNumber = 5}
            action = @{type = 'expire'}
        })
    } | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($repositoryPolicyPath, $repositoryPolicy + [Environment]::NewLine)

    aws ecr get-login-password --profile default --region us-west-2 --no-cli-pager | docker login --username AWS --password-stdin $registry | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Short-lived ECR login failed.' }

    $pushed = [ordered]@{}
    $releasedImages = [ordered]@{}
    foreach ($image in $manifest.images.PSObject.Properties) {
        $name = $image.Name
        $repository = "osc-usrse26-$RunId/$name"
        $repositoryExpiresAt = if ($name -eq 'lifecycle-runner') { $controlExpiresAt } else { $ExpiresAt.ToString('o') }
        $existing = aws ecr describe-repositories `
            --repository-names $repository `
            --query 'repositories[0]' `
            --output json `
            --profile default `
            --region us-west-2 `
            --no-cli-pager 2>$null
        if ($LASTEXITCODE -ne 0) {
            python platform/aws/aws_guard.py | Out-Null
            $existing = aws ecr create-repository `
                --repository-name $repository `
                --image-tag-mutability IMMUTABLE `
                --image-scanning-configuration scanOnPush=true `
                --encryption-configuration encryptionType=AES256 `
                --tags `
                    Key=Project,Value=OSC-IS `
                    Key=Purpose,Value=USRSE26-Interactive-Demo `
                    Key=Environment,Value=ephemeral `
                    Key=ManagedBy,Value=Terraform `
                    Key=Owner,Value=ofgarzon `
                    Key=RunId,Value=$RunId `
                    Key=ExpiresAt,Value=$repositoryExpiresAt `
                --query repository `
                --output json `
                --profile default `
                --region us-west-2 `
                --no-cli-pager
            if ($LASTEXITCODE -ne 0) { throw "Could not create exact release repository $repository." }
        }
        $repositoryData = $existing | ConvertFrom-Json
        if ($repositoryData.imageTagMutability -ne 'IMMUTABLE' -or -not $repositoryData.imageScanningConfiguration.scanOnPush -or $repositoryData.encryptionConfiguration.encryptionType -ne 'AES256') {
            throw "Pre-existing repository $repository does not match the immutable release contract."
        }
        $tags = aws ecr list-tags-for-resource `
            --resource-arn $repositoryData.repositoryArn `
            --query 'tags' `
            --output json `
            --profile default `
            --region us-west-2 `
            --no-cli-pager | ConvertFrom-Json
        $tagMap = @{}
        foreach ($tag in @($tags)) { $tagMap[$tag.Key] = $tag.Value }
        $expectedTags = @{Project='OSC-IS'; Purpose='USRSE26-Interactive-Demo'; Environment='ephemeral'; ManagedBy='Terraform'; Owner='ofgarzon'; RunId=$RunId; ExpiresAt=$repositoryExpiresAt}
        foreach ($entry in $expectedTags.GetEnumerator()) {
            if ($tagMap[$entry.Key] -ne $entry.Value) { throw "Repository $repository is missing exact tag $($entry.Key)." }
        }
        aws ecr put-lifecycle-policy `
            --repository-name $repository `
            --lifecycle-policy-text "file://$repositoryPolicyPath" `
            --profile default `
            --region us-west-2 `
            --no-cli-pager | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not apply the bounded lifecycle policy to $repository." }

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
        $releasedImages[$name] = [ordered]@{
            ecrReference = $pushed[$name]
            digest = $image.Value.localDigest
            archiveSha256 = $image.Value.archiveSha256
            sbomSha256 = (Get-FileHash -LiteralPath $image.Value.sbom -Algorithm SHA256).Hash.ToLowerInvariant()
            scanSha256 = (Get-FileHash -LiteralPath $image.Value.scan -Algorithm SHA256).Hash.ToLowerInvariant()
            highCriticalFindings = 0
            runtimeUser = $image.Value.runtimeUser
        }
    }

    $webBundleSha = (Get-FileHash -LiteralPath $manifest.webApp.archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($webBundleSha -ne $manifest.webApp.sha256) { throw 'WebApp bundle checksum mismatch before release upload.' }
    python platform/aws/aws_guard.py | Out-Null
    $webPut = aws s3api put-object `
        --bucket $ReleaseBucket `
        --key $manifest.webApp.objectKey `
        --body $manifest.webApp.archive `
        --content-type application/gzip `
        --server-side-encryption AES256 `
        --checksum-algorithm SHA256 `
        --output json `
        --profile default `
        --region us-west-2 `
        --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($webPut.VersionId)) {
        throw 'Versioned WebApp bundle upload failed.'
    }
    $credentialEvidenceKey = "$releasePrefix/build-credential-isolation.json"
    python platform/aws/aws_guard.py | Out-Null
    $credentialEvidencePut = aws s3api put-object `
        --bucket $ReleaseBucket `
        --key $credentialEvidenceKey `
        --body $credentialEvidencePath `
        --content-type application/json `
        --server-side-encryption AES256 `
        --checksum-algorithm SHA256 `
        --output json `
        --profile default `
        --region us-west-2 `
        --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($credentialEvidencePut.VersionId)) {
        throw 'Versioned build credential-isolation evidence upload failed.'
    }
    $releaseManifest = [ordered]@{
        schemaVersion = $manifest.schemaVersion
        runId = $manifest.runId
        expiresAt = $manifest.expiresAt
        createdAt = $manifest.createdAt
        buildCredentialIsolation = [ordered]@{
            status = $manifest.buildCredentialIsolation.status
            commonAwsCredentialSourcesAbsent = $manifest.buildCredentialIsolation.commonAwsCredentialSourcesAbsent
            evidence = [ordered]@{
                s3Uri = "s3://$ReleaseBucket/$credentialEvidenceKey"
                versionId = $credentialEvidencePut.VersionId
                sha256 = $credentialEvidenceSha
            }
            limitation = $manifest.buildCredentialIsolation.limitation
        }
        webApp = [ordered]@{
            sourceRevision = $manifest.webApp.sourceRevision
            s3Uri = "s3://$ReleaseBucket/$($manifest.webApp.objectKey)"
            versionId = $webPut.VersionId
            sha256 = $manifest.webApp.sha256
            objectKey = $manifest.webApp.objectKey
        }
        images = $releasedImages
        externalImages = $manifest.externalImages
        sourceCommits = $manifest.sourceCommits
        gitops = $manifest.gitops
    }
    $releaseManifestPath = Join-Path $runRoot 'artifacts\artifacts.release.json'
    [IO.File]::WriteAllText($releaseManifestPath, ($releaseManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    $manifestSha = (Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    python platform/aws/aws_guard.py | Out-Null
    $manifestPut = aws s3api put-object `
        --bucket $ReleaseBucket `
        --key $manifestKey `
        --body $releaseManifestPath `
        --content-type application/json `
        --server-side-encryption AES256 `
        --checksum-algorithm SHA256 `
        --output json `
        --profile default `
        --region us-west-2 `
        --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($manifestPut.VersionId)) {
        throw 'Versioned artifact-manifest upload failed.'
    }

    $report = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        pushedAt = [DateTimeOffset]::UtcNow.ToString('o')
        buildsExecutedWithAwsCredentials = $false
        references = $pushed
        webApp = [ordered]@{
            s3Uri = $releaseManifest.webApp.s3Uri
            versionId = $webPut.VersionId
            sha256 = $webBundleSha
            sourceRevision = $manifest.webApp.sourceRevision
        }
        artifactManifest = [ordered]@{
            s3Uri = "s3://$ReleaseBucket/$manifestKey"
            versionId = $manifestPut.VersionId
            sha256 = $manifestSha
        }
    }
    [IO.File]::WriteAllText($deploymentPath, ($report | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host 'All ECR digests and versioned S3 release artifacts match the isolated-build manifest.'
}
finally {
    docker logout $registry | Out-Null
    Pop-Location
}
