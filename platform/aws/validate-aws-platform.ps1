[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$artifactManifestPath = Join-Path $runRoot 'artifacts\artifacts.json'
$deploymentPath = Join-Path $runRoot 'artifacts\ecr-deployment.json'
$evidenceRoot = Join-Path $runRoot 'evidence'
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$context = "osc-usrse26-$RunId"

foreach ($required in @($artifactManifestPath, $deploymentPath, $gitBash)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing validation input: $required" }
}
New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
$artifacts = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json
$deployed = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
$posixRunRoot = (& $gitBash -lc "cygpath -u '$runRoot'").Trim()

Push-Location $infraRoot
try {
    python platform/aws/aws_guard.py
    if ((kubectl config current-context).Trim() -ne $context) { throw "Refusing to validate outside $context." }
    kubectl get nodes | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'EKS nodes are unavailable.' }

    $env:API_IMAGE = $artifacts.images.'api-gateway'.localReference
    & $gitBash (Join-Path $infraRoot 'platform/scripts/seed-local-data.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Deterministic EKS test-data seeding failed.' }

    $env:EXPECTED_CONTEXT = $context
    $env:EVIDENCE_DIR = "$posixRunRoot/evidence/aws-stack"
    & $gitBash (Join-Path $infraRoot 'platform/scripts/validate-local-stack.sh')
    if ($LASTEXITCODE -ne 0) { throw 'AWS provenance and authorization validation failed.' }

    $env:RECOVERY_MODE = 'aws'
    $env:APPLICATION = 'osc-is-aws'
    $env:AWS_NETWORK_POLICIES = "$posixRunRoot/gitops-source/manifests/network-policies.yaml"
    $env:EVIDENCE_DIR = "$posixRunRoot/evidence/aws-recovery"
    & $gitBash (Join-Path $infraRoot 'platform/scripts/validate-local-recovery.sh')
    if ($LASTEXITCODE -ne 0) { throw 'AWS recovery validation failed.' }

    $env:RUN_ID = $RunId
    $env:BASELINE_REVISION = $artifacts.gitops.baselineRevision
    $env:ROLLOUT_REVISION = $artifacts.gitops.rolloutRevision
    $env:REPOSITORY_IMAGE = $deployed.references.'gitops-repository'
    $env:EVIDENCE_DIR = "$posixRunRoot/evidence/aws-gitops"
    & $gitBash (Join-Path $infraRoot 'platform/scripts/validate-local-gitops.sh')
    if ($LASTEXITCODE -ne 0) { throw 'AWS GitOps validation failed.' }

    $env:EVIDENCE_DIR = "$posixRunRoot/evidence/aws-post-rollback"
    & $gitBash (Join-Path $infraRoot 'platform/scripts/validate-local-stack.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Post-rollback application validation failed.' }

    $loadBalancerServices = kubectl get services -A -o json | ConvertFrom-Json
    $loadBalancerServices = @($loadBalancerServices.items | Where-Object { $_.spec.type -eq 'LoadBalancer' })
    if ($loadBalancerServices.Count -ne 0) { throw 'The experiment unexpectedly created a Kubernetes LoadBalancer service.' }

    $podInventory = kubectl get pods -A -o json | ConvertFrom-Json
    $mutableImages = @(
        $podInventory.items |
            Where-Object { $_.metadata.namespace -ne 'kube-system' } |
            ForEach-Object { $_.spec.containers.image } |
            Where-Object { $_ -notmatch '@sha256:' }
    )
    if ($mutableImages.Count -ne 0) {
        throw "Mutable workload images detected: $($mutableImages -join ', ')"
    }

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
