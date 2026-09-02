[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$worktreeRoot = (Resolve-Path (Join-Path $infraRoot '..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$artifactRoot = Join-Path $runRoot 'artifacts'
$sbomRoot = Join-Path $artifactRoot 'sbom'
$scanRoot = Join-Path $artifactRoot 'scans'
$archiveRoot = Join-Path $artifactRoot 'archives'
$gitRoot = Join-Path $runRoot 'gitops-source'
$gitImageRoot = Join-Path $runRoot 'gitops-image'
$manifestPath = Join-Path $artifactRoot 'artifacts.json'
$registryName = 'osc-usrse26-aws-artifacts'
$registry = 'localhost:5018'
$trivyCache = "osc-usrse26-trivy-$RunId"
$account = '269624229733'
$region = 'us-west-2'
$ecrRoot = "$account.dkr.ecr.$region.amazonaws.com/osc-usrse26-$RunId"
$trivyLine = Get-Content -LiteralPath (Join-Path $infraRoot 'platform/versions.env') | Where-Object { $_.StartsWith('TRIVY_IMAGE=') }
if ($trivyLine.Count -ne 1) { throw 'The immutable Trivy image is not defined exactly once.' }
$trivyImage = $trivyLine.Substring('TRIVY_IMAGE='.Length)
if ($trivyImage -notmatch '@sha256:[0-9a-f]{64}$') { throw 'Trivy must be pinned by digest.' }

$contexts = [ordered]@{
    'api-gateway' = @{ Path = Join-Path $worktreeRoot 'OSC-APIGateway'; Dockerfile = 'Dockerfile' }
    'ledger-gateway' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\fabric-bridge'; Dockerfile = 'Dockerfile' }
    'submission-worker' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\submission_worker'; Dockerfile = 'Dockerfile' }
    'submission-listener' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\submission_listener'; Dockerfile = 'Dockerfile' }
    'chaincode' = @{ Path = Join-Path $worktreeRoot 'OSC-Chaincode\chaincode-go'; Dockerfile = 'Dockerfile' }
}

foreach ($generatedPath in @($artifactRoot, $gitRoot, $gitImageRoot)) {
    if (Test-Path -LiteralPath $generatedPath) {
        $resolved = (Resolve-Path -LiteralPath $generatedPath).Path
        if (-not $resolved.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove generated path outside the run directory: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

foreach ($path in @($artifactRoot, $sbomRoot, $scanRoot, $archiveRoot)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

python (Join-Path $infraRoot 'platform/scripts/patch_fabric_network.py') `
    --source-root (Join-Path $infraRoot 'platform/.generated/fabric-samples') `
    --destination (Join-Path $infraRoot 'platform/.generated/fabric-network-eks') `
    --fabric-bin (Join-Path $infraRoot '.osc-tools/fabric-2.5.16-1.5.22/bin') `
    --vendor (Join-Path $infraRoot 'platform/vendor') `
    --versions (Join-Path $infraRoot 'platform/versions.env') `
    --runtime eks
if ($LASTEXITCODE -ne 0) { throw 'EKS Fabric network preparation failed.' }

function Invoke-Checked {
    param([Parameter(Mandatory = $true)][scriptblock]$Command, [Parameter(Mandatory = $true)][string]$Failure)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw $Failure }
}

function Get-ImageEvidence {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Reference)

    $repoDigests = docker image inspect $Reference --format '{{json .RepoDigests}}' | ConvertFrom-Json
    $matchingDigests = @($repoDigests | Where-Object { $_ -like "localhost:5018/$Name@sha256:*" })
    if ($matchingDigests.Count -ne 1) {
        throw "Could not resolve immutable local registry digest for $Name."
    }
    $repoDigest = [string]$matchingDigests[0]
    if ($repoDigest -notmatch '^localhost:5018/.+@sha256:[0-9a-f]{64}$') {
        throw "The local registry returned a malformed digest for $Name."
    }
    $digest = $repoDigest.Split('@')[1]
    $metadata = docker image inspect $Reference | ConvertFrom-Json
    $user = [string]$metadata[0].Config.User
    if ([string]::IsNullOrWhiteSpace($user) -or $user -in @('0', 'root', '0:0')) {
        throw "$Name does not declare a non-root runtime user."
    }

    $sbomPath = Join-Path $sbomRoot "$Name.cdx.json"
    $scanPath = Join-Path $scanRoot "$Name-high-critical.json"
    Invoke-Checked { docker scout sbom --format cyclonedx --output $sbomPath "local://$Reference" } "SBOM generation failed for $Name."
    & docker run --rm --platform linux/amd64 `
        --volume /var/run/docker.sock:/var/run/docker.sock `
        --volume "${trivyCache}:/root/.cache/" `
        $trivyImage image `
        --scanners vuln `
        --severity HIGH,CRITICAL `
        --exit-code 1 `
        --format json `
        --no-progress `
        $Reference | Out-File -LiteralPath $scanPath -Encoding utf8NoBOM
    if ($LASTEXITCODE -eq 1) { throw "High or critical container vulnerability detected in $Name; inspect $scanPath." }
    if ($LASTEXITCODE -ne 0) { throw "Trivy container scan failed for $Name." }

    $archivePath = Join-Path $archiveRoot "$Name.tar"
    Invoke-Checked { docker save --output $archivePath $Reference } "Image archive creation failed for $Name."
    $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

    return [ordered]@{
        localReference = $Reference
        localDigest = $digest
        ecrReference = "$ecrRoot/$Name@$digest"
        imageId = $metadata[0].Id
        architecture = $metadata[0].Architecture
        os = $metadata[0].Os
        runtimeUser = $user
        archive = $archivePath
        archiveSha256 = $archiveSha
        sbom = $sbomPath
        scan = $scanPath
    }
}

if (docker ps -a --format '{{.Names}}' | Select-String -SimpleMatch $registryName -Quiet) {
    docker rm --force $registryName | Out-Null
}

try {
    Invoke-Checked {
        docker run --detach --name $registryName --publish 127.0.0.1:5018:5000 registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
    } 'Could not start the isolated artifact registry.'

    $images = [ordered]@{}
    foreach ($name in $contexts.Keys) {
        $context = $contexts[$name]
        $reference = "$registry/$name`:$RunId"
        Invoke-Checked {
            docker build --pull=false --provenance=false --platform linux/amd64 --file (Join-Path $context.Path $context.Dockerfile) --tag $reference $context.Path
        } "Container build failed for $name."
        Invoke-Checked { docker push $reference } "Local registry push failed for $name."
        $images[$name] = Get-ImageEvidence -Name $name -Reference $reference
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        credentialFreeBuild = $true
        images = $images
        sourceCommits = [ordered]@{
            infra = (git -C $infraRoot rev-parse HEAD).Trim()
            apiGateway = (git -C (Join-Path $worktreeRoot 'OSC-APIGateway') rev-parse HEAD).Trim()
            artifactSubmission = (git -C (Join-Path $worktreeRoot 'OSC-Artifact-Submission') rev-parse HEAD).Trim()
            chaincode = (git -C (Join-Path $worktreeRoot 'OSC-Chaincode') rev-parse HEAD).Trim()
        }
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    python (Join-Path $infraRoot 'platform/scripts/render_aws_gitops.py') `
        --templates (Join-Path $infraRoot 'platform/gitops/aws') `
        --artifacts $manifestPath `
        --destination (Join-Path $gitRoot 'manifests') `
        --run-id $RunId
    if ($LASTEXITCODE -ne 0) { throw 'AWS GitOps rendering failed.' }
    kubectl kustomize (Join-Path $gitRoot 'manifests') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Rendered AWS manifests failed client-side Kustomize validation.' }

    git -C $gitRoot init --initial-branch=main | Out-Null
    git -C $gitRoot config user.name 'OSC US-RSE evidence'
    git -C $gitRoot config user.email 'usrse26-evidence@localhost'
    git -C $gitRoot add manifests
    git -C $gitRoot commit -m 'gitops: record known-good AWS deployment' | Out-Null
    $baselineRevision = (git -C $gitRoot rev-parse HEAD).Trim()

    $apiManifest = Join-Path $gitRoot 'manifests\api-gateway.yaml'
    $apiText = Get-Content -LiteralPath $apiManifest -Raw
    $needle = "  template:`n    metadata:`n      labels:"
    $replacement = "  template:`n    metadata:`n      annotations:`n        usrse26.osc.example/rollout-id: `"$RunId`"`n      labels:"
    if (($apiText.Split($needle).Count - 1) -ne 1) { throw 'Could not stage the controlled API rollout.' }
    [IO.File]::WriteAllText($apiManifest, $apiText.Replace($needle, $replacement))
    git -C $gitRoot add manifests/api-gateway.yaml
    git -C $gitRoot commit -m 'gitops: stage controlled API rollout' | Out-Null
    $rolloutRevision = (git -C $gitRoot rev-parse HEAD).Trim()

    New-Item -ItemType Directory -Force -Path (Join-Path $gitImageRoot 'site') | Out-Null
    $bareRepository = Join-Path $gitImageRoot 'site\osc-is-infra.git'
    Invoke-Checked { git clone --bare $gitRoot $bareRepository | Out-Null } 'Could not create the GitOps bare repository.'
    Invoke-Checked { git -C $bareRepository update-server-info } 'Could not prepare the GitOps repository for HTTP cloning.'
    $infoRefs = Join-Path $bareRepository 'info\refs'
    if (-not (Test-Path -LiteralPath $infoRefs) -or (Get-Item -LiteralPath $infoRefs).Length -eq 0) {
        throw 'The GitOps repository does not contain HTTP clone metadata.'
    }

    $gitImageReference = "$registry/gitops-repository`:$RunId"
    Invoke-Checked {
        docker build --pull=false --provenance=false --platform linux/amd64 --file (Join-Path $infraRoot 'platform/gitops/bootstrap/repository.Dockerfile') --tag $gitImageReference $gitImageRoot
    } 'GitOps repository image build failed.'
    Invoke-Checked { docker push $gitImageReference } 'GitOps repository local push failed.'
    $images['gitops-repository'] = Get-ImageEvidence -Name 'gitops-repository' -Reference $gitImageReference

    $manifest.images = $images
    $manifest.gitops = [ordered]@{
        baselineRevision = $baselineRevision
        rolloutRevision = $rolloutRevision
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host "Prepared six scanned, non-root, digest-addressed artifacts at $artifactRoot"
}
finally {
    if (docker ps -a --format '{{.Names}}' | Select-String -SimpleMatch $registryName -Quiet) {
        docker rm --force $registryName | Out-Null
    }
    if (docker volume ls --format '{{.Name}}' | Select-String -SimpleMatch $trivyCache -Quiet) {
        docker volume rm --force $trivyCache | Out-Null
    }
}
