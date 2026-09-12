[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^[A-Za-z]:\\') { throw "Unsupported WSL path: $fullPath" }
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $remainder = $fullPath.Substring(2).Replace('\', '/')
    return "/mnt/$drive$remainder"
}

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$artifactManifestPath = Join-Path $runRoot 'artifacts\artifacts.json'
$deploymentPath = Join-Path $runRoot 'artifacts\ecr-deployment.json'
$hotfixManifestPath = Join-Path $runRoot 'artifacts\hotfix\hotfix.json'
$evidenceRoot = Join-Path $runRoot 'evidence'
$context = "osc-usrse26-$RunId"
$wsl = (Get-Command wsl.exe).Source
$wslDistribution = 'Ubuntu-24.04'
$windowsKubeConfig = Join-Path $env:USERPROFILE '.kube\config'
$wslAwsWrapper = Join-Path $runRoot 'wsl-bin\aws'

foreach ($required in @($artifactManifestPath, $deploymentPath, $wsl, $wslAwsWrapper, $windowsKubeConfig)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing validation input: $required" }
}
New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
$artifacts = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json
$deployed = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
$baselineRevision = [string]$artifacts.gitops.baselineRevision
$rolloutRevision = [string]$artifacts.gitops.rolloutRevision
$repositoryImage = [string]$deployed.references.'gitops-repository'
if (Test-Path -LiteralPath $hotfixManifestPath) {
    $hotfix = Get-Content -LiteralPath $hotfixManifestPath -Raw | ConvertFrom-Json
    if ($hotfix.runId -ne $RunId) { throw 'The hotfix manifest belongs to a different run.' }
    foreach ($reference in @($hotfix.images.'ledger-gateway'.reference, $hotfix.images.'gitops-repository'.reference)) {
        if ($reference -notmatch '@sha256:[0-9a-f]{64}$') { throw "Mutable hotfix image reference: $reference" }
    }
    $baselineRevision = [string]$hotfix.gitops.baselineRevision
    $rolloutRevision = [string]$hotfix.gitops.rolloutRevision
    $repositoryImage = [string]$hotfix.images.'gitops-repository'.reference
}
$posixRunRoot = ConvertTo-WslPath $runRoot
$wslKubeConfig = ConvertTo-WslPath $windowsKubeConfig
$wslToolsPath = ConvertTo-WslPath (Split-Path -Parent $wslAwsWrapper)
$wslPath = "${wslToolsPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

Push-Location $infraRoot
try {
    python platform/aws/aws_guard.py
    if ((kubectl config current-context).Trim() -ne $context) { throw "Refusing to validate outside $context." }
    kubectl get nodes | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'EKS nodes are unavailable.' }

    & $wsl -d $wslDistribution --cd $infraRoot -- env `
        "KUBECONFIG=$wslKubeConfig" "PATH=$wslPath" `
        "OSC_RUNTIME_SECRET_DIR=/tmp/osc-is-$RunId-runtime-secrets" `
        "API_IMAGE=$($artifacts.images.'api-gateway'.localReference)" `
        bash platform/scripts/seed-local-data.sh
    if ($LASTEXITCODE -ne 0) { throw 'Deterministic EKS test-data seeding failed.' }

    & $wsl -d $wslDistribution --cd $infraRoot -- env `
        "KUBECONFIG=$wslKubeConfig" "PATH=$wslPath" `
        "EXPECTED_CONTEXT=$context" `
        "EVIDENCE_DIR=$posixRunRoot/evidence/aws-stack" `
        bash platform/scripts/validate-local-stack.sh
    if ($LASTEXITCODE -ne 0) { throw 'AWS provenance and authorization validation failed.' }

    & $wsl -d $wslDistribution --cd $infraRoot -- env `
        "KUBECONFIG=$wslKubeConfig" "PATH=$wslPath" `
        'RECOVERY_MODE=aws' 'APPLICATION=osc-is-aws' "EXPECTED_CONTEXT=$context" `
        "AWS_NETWORK_POLICIES=$posixRunRoot/gitops-source/manifests/network-policies.yaml" `
        "EVIDENCE_DIR=$posixRunRoot/evidence/aws-recovery" `
        bash platform/scripts/validate-local-recovery.sh
    if ($LASTEXITCODE -ne 0) { throw 'AWS recovery validation failed.' }

    & $wsl -d $wslDistribution --cd $infraRoot -- env `
        "KUBECONFIG=$wslKubeConfig" "PATH=$wslPath" `
        "EXPECTED_CONTEXT=$context" 'APPLICATION=osc-is-aws' `
        "RUN_ID=$RunId" `
        "BASELINE_REVISION=$baselineRevision" `
        "ROLLOUT_REVISION=$rolloutRevision" `
        "REPOSITORY_IMAGE=$repositoryImage" `
        "EVIDENCE_DIR=$posixRunRoot/evidence/aws-gitops" `
        bash platform/scripts/validate-local-gitops.sh
    if ($LASTEXITCODE -ne 0) { throw 'AWS GitOps validation failed.' }

    & $wsl -d $wslDistribution --cd $infraRoot -- env `
        "KUBECONFIG=$wslKubeConfig" "PATH=$wslPath" `
        "EXPECTED_CONTEXT=$context" `
        "EVIDENCE_DIR=$posixRunRoot/evidence/aws-post-rollback" `
        bash platform/scripts/validate-local-stack.sh
    if ($LASTEXITCODE -ne 0) { throw 'Post-rollback application validation failed.' }

    $loadBalancerServices = kubectl get services -A -o json | ConvertFrom-Json
    $loadBalancerServices = @($loadBalancerServices.items | Where-Object { $_.spec.type -eq 'LoadBalancer' })
    if ($loadBalancerServices.Count -ne 0) { throw 'The experiment unexpectedly created a Kubernetes LoadBalancer service.' }

    $podInventory = kubectl get pods -A -o json | ConvertFrom-Json
    $controlledNamespaces = @('argocd', 'cert-manager', 'ingress-nginx', 'osc-apps', 'osc-fabric')
    $managedAddonNamespaces = @('aws-secrets-manager', 'kube-system')
    $unexpectedNamespaces = @(
        $podInventory.items.metadata.namespace |
            Where-Object { $_ -notin $controlledNamespaces -and $_ -notin $managedAddonNamespaces } |
            Sort-Object -Unique
    )
    if ($unexpectedNamespaces.Count -ne 0) {
        throw "Pods detected in unclassified namespaces: $($unexpectedNamespaces -join ', ')"
    }
    $mutableImages = @(
        $podInventory.items |
            Where-Object { $_.metadata.namespace -in $controlledNamespaces } |
            ForEach-Object { $_.spec.containers.image } |
            Where-Object { $_ -notmatch '@sha256:' }
    )
    if ($mutableImages.Count -ne 0) {
        throw "Mutable workload images detected: $($mutableImages -join ', ')"
    }
    $managedAddonImages = @(
        $podInventory.items |
            Where-Object { $_.metadata.namespace -in $managedAddonNamespaces } |
            ForEach-Object {
                $pod = $_
                foreach ($container in $pod.status.containerStatuses) {
                    [ordered]@{
                        namespace = $pod.metadata.namespace
                        pod = $pod.metadata.name
                        container = $container.name
                        declaredImage = $container.image
                        resolvedImageId = $container.imageID
                        resolvedByDigest = $container.imageID -match '@sha256:[0-9a-f]{64}$'
                    }
                }
            }
    )
    $unresolvedManagedImages = @($managedAddonImages | Where-Object { -not $_.resolvedByDigest })
    if ($unresolvedManagedImages.Count -ne 0) { throw 'An AWS-managed add-on image did not resolve to a digest.' }
    [IO.File]::WriteAllText(
        (Join-Path $evidenceRoot 'managed-addon-images.json'),
        ($managedAddonImages | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    )

    python platform/aws/aws_guard.py | Out-Null
    $brokerId = (aws mq list-brokers `
        --query "BrokerSummaries[?BrokerName=='osc-usrse26-$RunId-rabbitmq'].BrokerId | [0]" `
        --output text --profile default --region us-west-2 --no-cli-pager).Trim()
    if (-not $brokerId -or $brokerId -eq 'None') { throw 'Amazon MQ broker was not found.' }
    aws mq describe-broker `
        --broker-id $brokerId `
        --query '{BrokerName:BrokerName,BrokerState:BrokerState,DeploymentMode:DeploymentMode,EngineType:EngineType,EngineVersion:EngineVersion,HostInstanceType:HostInstanceType,PubliclyAccessible:PubliclyAccessible,EncryptionOptions:EncryptionOptions,Logs:Logs}' `
        --output json --profile default --region us-west-2 --no-cli-pager `
        | Out-File -LiteralPath (Join-Path $evidenceRoot 'amazon-mq.json') -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw 'Amazon MQ evidence query failed.' }

    kubectl get nodes -o json | Out-File -LiteralPath (Join-Path $evidenceRoot 'kubernetes-nodes.json') -Encoding utf8NoBOM
    kubectl get pods -A -o json | Out-File -LiteralPath (Join-Path $evidenceRoot 'kubernetes-pods.json') -Encoding utf8NoBOM
    kubectl -n argocd get application osc-is-aws -o json | Out-File -LiteralPath (Join-Path $evidenceRoot 'argocd-application.json') -Encoding utf8NoBOM
    kubectl -n osc-fabric get deployment,pod,pvc -o json | Out-File -LiteralPath (Join-Path $evidenceRoot 'fabric-workloads.json') -Encoding utf8NoBOM

    $summary = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        validatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        provenanceAndAuthorization = $true
        directFabricCrossOrganizationDenial = $true
        dependencyRecovery = $true
        workerRestartRecovery = $true
        peerFailover = $true
        gitOpsDriftRolloutRollback = $true
        postRollbackHappyPath = $true
        immutableImages = $true
        loadBalancerServices = 0
        credentialsRetained = $false
    }
    [IO.File]::WriteAllText((Join-Path $evidenceRoot 'validation-summary.json'), ($summary | ConvertTo-Json) + [Environment]::NewLine)
    Write-Host 'AWS provenance, authorization, resilience, GitOps, and rollback evidence passed.'
}
finally {
    Pop-Location
}
