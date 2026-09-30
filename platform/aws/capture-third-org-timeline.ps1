[CmdletBinding()]
param(
  [ValidateRange(1, 720)][int]$Samples = 360,
  [ValidateRange(2, 60)][int]$DelaySeconds = 10,
  [string]$OutputPath = (Join-Path $PSScriptRoot '..\.generated\aws\usrse260930\evidence\metrics\third-org-timeline.jsonl'),
  [string]$StopFile = (Join-Path $PSScriptRoot '..\.generated\aws\usrse260930\evidence\metrics\third-org-timeline.stop')
)

$ErrorActionPreference = 'Stop'
if ((& kubectl config current-context).Trim() -ne 'osc-usrse26-usrse260930') { throw 'Unexpected Kubernetes context.' }
if (((& aws sts get-caller-identity --output json) | ConvertFrom-Json).Account -ne '269624229733') { throw 'Unexpected AWS account.' }
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
if (Test-Path -LiteralPath $OutputPath) { throw 'Refusing to append to an existing onboarding timeline.' }

for ($index = 0; $index -lt $Samples; $index++) {
  if (Test-Path -LiteralPath $StopFile) { break }
  $capturedAt = (Get-Date).ToUniversalTime().ToString('o')
  $fabric = (& kubectl -n osc-fabric get pods -o json | ConvertFrom-Json).items
  $apps = (& kubectl -n osc-apps get pods -o json | ConvertFrom-Json).items
  $application = & kubectl -n argocd get application osc-is-aws -o json | ConvertFrom-Json
  $nodes = (& kubectl get nodes -o json | ConvertFrom-Json).items
  if ($LASTEXITCODE -ne 0) { throw 'A Kubernetes snapshot failed.' }
  $thirdFabric = @($fabric | Where-Object { $_.metadata.name -match '^org3' })
  $thirdApps = @($apps | Where-Object { $_.metadata.name -match 'magnetic-arch' })
  $ready = { param($pod) $pod.status.phase -eq 'Running' -and @($pod.status.containerStatuses).Count -gt 0 -and @($pod.status.containerStatuses | Where-Object { $_.ready }).Count -eq @($pod.status.containerStatuses).Count }
  [ordered]@{
    capturedAt = $capturedAt
    thirdFabricPods = $thirdFabric.Count
    thirdFabricReady = @($thirdFabric | Where-Object { & $ready $_ }).Count
    thirdAppPods = $thirdApps.Count
    thirdAppReady = @($thirdApps | Where-Object { & $ready $_ }).Count
    fabricPods = @($fabric).Count
    appPods = @($apps).Count
    readyNodes = @($nodes | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 }).Count
    argoSync = $application.status.sync.status
    argoHealth = $application.status.health.status
    argoRevision = $application.status.sync.revision
  } | ConvertTo-Json -Compress | Add-Content -LiteralPath $OutputPath -Encoding utf8
  Start-Sleep -Seconds $DelaySeconds
}
Write-Host "Onboarding snapshot capture stopped after $index iterations."
