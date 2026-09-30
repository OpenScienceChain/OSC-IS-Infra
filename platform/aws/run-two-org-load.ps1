param(
  [ValidateSet('normal', 'fault', 'timing')][string]$Mode = 'normal',
  [string]$RunId = 'usrse260930'
)

$ErrorActionPreference = 'Stop'
if ($RunId -ne 'usrse260930') { throw 'This bounded runner is pinned to the reviewed AWS evidence run.' }
$context = (& kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $context -ne "osc-usrse26-$RunId") { throw "Refusing Kubernetes context $context" }
$account = ((& aws sts get-caller-identity --output json) | ConvertFrom-Json).Account
if ($LASTEXITCODE -ne 0 -or $account -ne '269624229733') { throw "Refusing AWS account $account" }
$app = (& kubectl -n argocd get application osc-is-aws -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $app.status.sync.status -ne 'Synced' -or $app.status.health.status -ne 'Healthy') {
  throw 'Argo application must begin Synced and Healthy.'
}
$gateway = (& kubectl -n osc-apps get deployment ledger-gateway-nsg -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $gateway.spec.replicas -lt 1) { throw 'Ledger gateway is not ready for a bounded fault.' }
$gatewayReplicas = [int]$gateway.spec.replicas
$originalSelfHeal = [bool]$app.spec.syncPolicy.automated.selfHeal
$image = (& kubectl -n osc-apps get deployment api-gateway -o json | ConvertFrom-Json).spec.template.spec.containers[0].image
if ($LASTEXITCODE -ne 0 -or $image -notmatch '^269624229733\.dkr\.ecr\.us-west-2\.amazonaws\.com/osc-usrse26-usrse260930/api-gateway@sha256:[a-f0-9]{64}$') {
  throw 'Refusing unreviewed load-runner image.'
}

$scriptPath = Join-Path $PSScriptRoot 'measure-two-org-load.js'
$evidenceDir = Join-Path $PSScriptRoot '..\.generated\aws\usrse260930\evidence\metrics\load'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
$name = "osc-evidence-$Mode-$stamp"
$configName = "$name-script"
$writeCap = switch ($Mode) { 'normal' { 332 } 'fault' { 92 } 'timing' { 157 } }
$selfHealChanged = $false
$jobCreated = $false
$configCreated = $false
$faultEvents = [ordered]@{ mode = $Mode; job = $name; gatewayReplicasBefore = $gatewayReplicas }

function Invoke-Kubectl([string[]]$Arguments) {
  $output = & kubectl @Arguments
  if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($Arguments -join ' ')" }
  return $output
}

try {
  if ($Mode -eq 'fault' -and $originalSelfHeal) {
    Invoke-Kubectl @('-n', 'argocd', 'patch', 'application', 'osc-is-aws', '--type=merge', '-p',
      '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}') | Out-Null
    $selfHealChanged = $true
  }

  $config = @{
    apiVersion = 'v1'; kind = 'ConfigMap'
    metadata = @{ name = $configName; namespace = 'osc-apps'; labels = @{ 'app.kubernetes.io/part-of' = 'osc-evidence-load' } }
    data = @{ 'load.js' = (Get-Content -LiteralPath $scriptPath -Raw) }
  }
  $config | ConvertTo-Json -Depth 20 -Compress | & kubectl create -f - | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary script ConfigMap.' }
  $configCreated = $true

  $job = @{
    apiVersion = 'batch/v1'; kind = 'Job'
    metadata = @{ name = $name; namespace = 'osc-apps'; labels = @{ 'app.kubernetes.io/part-of' = 'osc-evidence-load' } }
    spec = @{
      backoffLimit = 0; activeDeadlineSeconds = 900; ttlSecondsAfterFinished = 3600
      template = @{
        metadata = @{ labels = @{ 'app.kubernetes.io/name' = 'submission-listener'; 'app.kubernetes.io/part-of' = 'osc-evidence-load' } }
        spec = @{
          restartPolicy = 'Never'; serviceAccountName = 'default'; automountServiceAccountToken = $false
          securityContext = @{ runAsUser = 1001; runAsGroup = 1001; runAsNonRoot = $true; seccompProfile = @{ type = 'RuntimeDefault' } }
          containers = @(@{
            name = 'load'; image = $image; imagePullPolicy = 'IfNotPresent'
            command = @('node', '/scripts/load.js')
            env = @(
              @{ name = 'LOAD_MODE'; value = $Mode },
              @{ name = 'LOAD_RUN_ID'; value = "$RunId-$Mode-$stamp" },
              @{ name = 'LOAD_BASE_URL'; value = 'http://api-gateway.osc-apps.svc.cluster.local:3000/api/v1' },
              @{ name = 'LOAD_MAX_WRITES'; value = "$writeCap" },
              @{ name = 'E2E_PASSWORD'; valueFrom = @{ secretKeyRef = @{ name = 'e2e-user-credentials'; key = 'password' } } }
            )
            resources = @{ requests = @{ cpu = '100m'; memory = '128Mi' }; limits = @{ cpu = '1'; memory = '512Mi' } }
            securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
            volumeMounts = @(@{ name = 'script'; mountPath = '/scripts'; readOnly = $true })
          })
          volumes = @(@{ name = 'script'; configMap = @{ name = $configName; defaultMode = 292 } })
        }
      }
    }
  }
  $job | ConvertTo-Json -Depth 30 -Compress | & kubectl create -f - | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not create the bounded load Job.' }
  $jobCreated = $true
  Write-Host "Started $Mode load Job $name"

  if ($Mode -eq 'fault') {
    $deadline = (Get-Date).AddSeconds(120)
    $started = $false
    while ((Get-Date) -lt $deadline) {
      $log = & kubectl -n osc-apps logs "job/$name" --tail=5 2>$null
      if ($log -match 'RUN_START ') { $started = $true; break }
      Start-Sleep -Seconds 1
    }
    if (-not $started) { throw 'Load pod did not announce RUN_START in 120 seconds.' }
    Start-Sleep -Seconds 6
    $faultEvents.downRequestedAt = (Get-Date).ToUniversalTime().ToString('o')
    Invoke-Kubectl @('-n', 'osc-apps', 'scale', 'deployment/ledger-gateway-nsg', '--replicas=0') | Out-Null
    $faultEvents.downAppliedAt = (Get-Date).ToUniversalTime().ToString('o')
    Start-Sleep -Seconds 10
    $faultEvents.restoreRequestedAt = (Get-Date).ToUniversalTime().ToString('o')
    Invoke-Kubectl @('-n', 'osc-apps', 'scale', 'deployment/ledger-gateway-nsg', "--replicas=$gatewayReplicas") | Out-Null
    Invoke-Kubectl @('-n', 'osc-apps', 'rollout', 'status', 'deployment/ledger-gateway-nsg', '--timeout=180s') | Out-Null
    $faultEvents.gatewayReadyAt = (Get-Date).ToUniversalTime().ToString('o')
  }

  $deadline = (Get-Date).AddSeconds(900)
  $jobSucceeded = $false
  $jobFinished = $false
  while ((Get-Date) -lt $deadline) {
    $jobStatus = (& kubectl -n osc-apps get job $name -o json | ConvertFrom-Json).status
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect load Job status.' }
    if ($jobStatus.succeeded -ge 1) { $jobSucceeded = $true; $jobFinished = $true; break }
    if ($jobStatus.failed -ge 1) { $jobFinished = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $jobFinished) { throw 'Load Job exceeded its bounded deadline.' }
  $lines = & kubectl -n osc-apps logs "job/$name"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot retrieve load Job logs.' }
  $resultLine = $lines | Where-Object { $_ -like 'RESULT_JSON *' } | Select-Object -Last 1
  if (-not $resultLine) { throw "Load Job did not produce a report: $($lines | Select-Object -Last 4)" }
  $report = $resultLine.Substring('RESULT_JSON '.Length) | ConvertFrom-Json
  $report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $evidenceDir "$Mode-raw.json") -Encoding utf8
  if ($Mode -eq 'fault') {
    $faultEvents | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidenceDir 'fault-events.json') -Encoding utf8
  }
  Write-Host ($report.summary | ConvertTo-Json -Compress)
  if (-not $jobSucceeded) { throw 'Load Job completed with failure; raw report was preserved.' }
} finally {
  if ($Mode -eq 'fault') {
    & kubectl -n osc-apps scale deployment/ledger-gateway-nsg "--replicas=$gatewayReplicas" | Out-Null
    & kubectl -n osc-apps rollout status deployment/ledger-gateway-nsg --timeout=180s | Out-Null
    if ($selfHealChanged) {
      & kubectl -n argocd patch application osc-is-aws --type=merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}' | Out-Null
    }
  }
  if ($jobCreated) { & kubectl -n osc-apps delete job $name --ignore-not-found --wait=false | Out-Null }
  if ($configCreated) { & kubectl -n osc-apps delete configmap $configName --ignore-not-found | Out-Null }
}
