[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$expectedContext = "osc-usrse26-$RunId"
$actualContext = (kubectl config current-context).Trim()
if ($actualContext -ne $expectedContext) { throw "Refusing context $actualContext" }
$application = kubectl -n argocd get application osc-is-aws -o json | ConvertFrom-Json
if ($application.status.sync.status -ne 'Synced' -or
    $application.status.health.status -ne 'Healthy' -or
    -not $application.spec.syncPolicy.automated.selfHeal) {
    throw 'Argo application is not healthy with self-heal enabled.'
}
$revision = [string]$application.status.sync.revision
$deployment = kubectl -n osc-apps get deployment api-gateway -o json | ConvertFrom-Json
if ($deployment.spec.replicas -ne 2 -or $deployment.status.readyReplicas -ne 2) {
    throw 'API Gateway is not at the two-replica baseline.'
}
$started = [DateTimeOffset]::UtcNow
$healedAt = $null
try {
    kubectl -n osc-apps scale deployment/api-gateway --replicas=1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not inject the bounded replica drift.' }
    $deadline = $started.AddMinutes(4)
    do {
        Start-Sleep -Seconds 3
        $replicas = (kubectl -n osc-apps get deployment api-gateway -o jsonpath='{.spec.replicas}').Trim()
        $sync = (kubectl -n argocd get application osc-is-aws -o jsonpath='{.status.sync.status}').Trim()
        $health = (kubectl -n argocd get application osc-is-aws -o jsonpath='{.status.health.status}').Trim()
        $observedRevision = (kubectl -n argocd get application osc-is-aws -o jsonpath='{.status.sync.revision}').Trim()
        if ($replicas -eq '2' -and $sync -eq 'Synced' -and $health -eq 'Healthy' -and $observedRevision -eq $revision) {
            $healedAt = [DateTimeOffset]::UtcNow
            break
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $healedAt) { throw 'Argo did not heal the replica drift within four minutes.' }
    kubectl -n osc-apps rollout status deployment/api-gateway --timeout=3m | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'API replicas did not become ready after healing.' }
    $report = [ordered]@{
        runId = $RunId
        startedAt = $started.ToString('o')
        healedAt = $healedAt.ToString('o')
        secondsToSyncedHealthy = [int][Math]::Ceiling(($healedAt - $started).TotalSeconds)
        gitopsRevision = $revision
        injectedReplicas = 1
        restoredReplicas = 2
        selfHealVerified = $true
        credentialsRetained = $false
    }
    $root = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path "platform\.generated\aws\$RunId\evidence\aws-gitops"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'drift-summary.json')
    $report | ConvertTo-Json
}
finally {
    $current = (kubectl -n osc-apps get deployment api-gateway -o jsonpath='{.spec.replicas}').Trim()
    if ($current -ne '2') {
        kubectl -n osc-apps scale deployment/api-gateway --replicas=2 | Out-Null
    }
    kubectl -n osc-apps rollout status deployment/api-gateway --timeout=3m | Out-Null
}
