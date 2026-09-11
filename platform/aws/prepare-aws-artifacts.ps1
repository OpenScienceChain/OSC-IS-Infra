[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\s]+@sha256:[0-9a-f]{64}$')]
    [string]$AlbControllerImage,

    [Parameter(Mandatory = $true)]
    [datetimeoffset]$ExpiresAt
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$worktreeRoot = (Resolve-Path (Join-Path $infraRoot '..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$artifactRoot = Join-Path $runRoot 'artifacts'
$sbomRoot = Join-Path $artifactRoot 'sbom'
$scanRoot = Join-Path $artifactRoot 'scans'
$archiveRoot = Join-Path $artifactRoot 'archives'
$webBundleRoot = Join-Path $artifactRoot 'webapp-root'
$webBundleArchive = Join-Path $archiveRoot 'webapp-static.tar.gz'
$gitRoot = Join-Path $runRoot 'gitops-source'
$gitImageRoot = Join-Path $runRoot 'gitops-image'
$manifestPath = Join-Path $artifactRoot 'artifacts.json'
$lifecycleContext = Join-Path $infraRoot 'platform\.generated\lifecycle-context'
$registryName = 'osc-usrse26-aws-artifacts'
$registry = 'localhost:5018'
$trivyCache = "osc-usrse26-trivy-$RunId"
$webContainer = $null
$account = '269624229733'
$region = 'us-west-2'
$ecrRoot = "$account.dkr.ecr.$region.amazonaws.com/osc-usrse26-$RunId"
if ($ExpiresAt -le [DateTimeOffset]::UtcNow -or $ExpiresAt -gt [DateTimeOffset]::UtcNow.AddHours(72)) {
    throw 'ExpiresAt must be in the future and no more than 72 hours from now.'
}
$trivyLine = Get-Content -LiteralPath (Join-Path $infraRoot 'platform/versions.env') | Where-Object { $_.StartsWith('TRIVY_IMAGE=') }
if ($trivyLine.Count -ne 1) { throw 'The immutable Trivy image is not defined exactly once.' }
$trivyImage = $trivyLine.Substring('TRIVY_IMAGE='.Length)
if ($trivyImage -notmatch '@sha256:[0-9a-f]{64}$') { throw 'Trivy must be pinned by digest.' }

$contexts = [ordered]@{
    'api-gateway' = @{ Path = Join-Path $worktreeRoot 'OSC-APIGateway'; Dockerfile = 'Dockerfile' }
    'ledger-gateway' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\fabric-bridge'; Dockerfile = 'Dockerfile' }
    'submission-worker' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\submission_worker'; Dockerfile = 'Dockerfile' }
    'submission-listener' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\submission_listener'; Dockerfile = 'Dockerfile' }
    'history-worker' = @{ Path = Join-Path $worktreeRoot 'OSC-Artifact-Submission\get_history_worker'; Dockerfile = 'Dockerfile' }
    'chaincode' = @{ Path = Join-Path $worktreeRoot 'OSC-Chaincode\chaincode-go'; Dockerfile = 'Dockerfile' }
    'webapp' = @{ Path = Join-Path $worktreeRoot 'OSC-WebApp'; Dockerfile = 'Dockerfile' }
    'lifecycle-runner' = @{ Path = $infraRoot; Dockerfile = 'platform\lifecycle\Dockerfile' }
}

$sourceRepositories = @(
    (Join-Path $worktreeRoot 'OSC-APIGateway'),
    (Join-Path $worktreeRoot 'OSC-Artifact-Submission'),
    (Join-Path $worktreeRoot 'OSC-Chaincode'),
    (Join-Path $worktreeRoot 'OSC-WebApp'),
    $infraRoot
) | Sort-Object -Unique
foreach ($repository in $sourceRepositories) {
    $changes = @(git -C $repository status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect source repository $repository." }
    if ($changes.Count -ne 0) {
        throw "Credential-free artifact builds require a clean committed source tree: $repository"
    }
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
python (Join-Path $infraRoot 'platform/scripts/validate_fabric_topology.py') `
    --network (Join-Path $infraRoot 'platform/.generated/fabric-network-eks') `
    --deploy-script (Join-Path $infraRoot 'platform/scripts/deploy_aws_fabric.sh')
if ($LASTEXITCODE -ne 0) { throw 'Fabric topology contract failed.' }

if (Test-Path -LiteralPath $lifecycleContext) {
    $resolvedLifecycleContext = (Resolve-Path -LiteralPath $lifecycleContext).Path
    $expectedLifecycleContext = [IO.Path]::GetFullPath((Join-Path $infraRoot 'platform\.generated\lifecycle-context'))
    if ($resolvedLifecycleContext -ne $expectedLifecycleContext) {
        throw "Refusing to remove unexpected lifecycle build context: $resolvedLifecycleContext"
    }
    Remove-Item -LiteralPath $resolvedLifecycleContext -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $lifecycleContext | Out-Null
$lifecycleChaincode = Join-Path $lifecycleContext 'chaincode-go'
New-Item -ItemType Directory -Force -Path $lifecycleChaincode | Out-Null
Copy-Item -LiteralPath (Join-Path $worktreeRoot 'OSC-Chaincode\chaincode-go\go.mod') `
    -Destination (Join-Path $lifecycleChaincode 'go.mod')

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

    $webRevision = (git -C (Join-Path $worktreeRoot 'OSC-WebApp') rev-parse HEAD).Trim()
    if ($webRevision -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the WebApp source revision.' }
    New-Item -ItemType Directory -Force -Path $webBundleRoot | Out-Null
    $webContainer = (docker create $images['webapp'].localReference).Trim()
    if ($LASTEXITCODE -ne 0 -or $webContainer -notmatch '^[0-9a-f]{64}$') {
        throw 'Could not create the WebApp extraction container.'
    }
    Invoke-Checked {
        docker cp "${webContainer}:/usr/share/nginx/html/." $webBundleRoot
    } 'Could not extract the reviewed WebApp build.'
    docker rm $webContainer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the WebApp extraction container.' }
    $webContainer = $null
    python (Join-Path $infraRoot 'platform/aws/package_webapp_bundle.py') `
        --source $webBundleRoot `
        --output $webBundleArchive `
        --source-revision $webRevision
    if ($LASTEXITCODE -ne 0) { throw 'Could not package the deterministic WebApp bundle.' }
    $webBundleSha = (Get-FileHash -LiteralPath $webBundleArchive -Algorithm SHA256).Hash.ToLowerInvariant()

    $manifest = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        expiresAt = $ExpiresAt.ToString('o')
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        credentialFreeBuild = $true
        webApp = [ordered]@{
            sourceRevision = $webRevision
            archive = $webBundleArchive
            sha256 = $webBundleSha
            objectKey = "releases/$RunId/webapp-static.tar.gz"
        }
        images = $images
        externalImages = [ordered]@{
            'aws-load-balancer-controller' = $AlbControllerImage
        }
        sourceCommits = [ordered]@{
            infra = (git -C $infraRoot rev-parse HEAD).Trim()
            webApp = $webRevision
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
    Write-Host "Prepared nine scanned, non-root OCI artifacts and one deterministic WebApp bundle at $artifactRoot"
}
finally {
    if ($webContainer -and (docker ps -a --format '{{.ID}}' | Select-String -SimpleMatch $webContainer -Quiet)) {
        docker rm --force $webContainer | Out-Null
    }
    if (docker ps -a --format '{{.Names}}' | Select-String -SimpleMatch $registryName -Quiet) {
        docker rm --force $registryName | Out-Null
    }
    if (docker volume ls --format '{{.Name}}' | Select-String -SimpleMatch $trivyCache -Quiet) {
        docker volume rm --force $trivyCache | Out-Null
    }
    if (Test-Path -LiteralPath $lifecycleContext) {
        $resolvedLifecycleContext = (Resolve-Path -LiteralPath $lifecycleContext).Path
        $expectedLifecycleContext = [IO.Path]::GetFullPath((Join-Path $infraRoot 'platform\.generated\lifecycle-context'))
        if ($resolvedLifecycleContext -eq $expectedLifecycleContext) {
            Remove-Item -LiteralPath $resolvedLifecycleContext -Recurse -Force
        }
    }
}
