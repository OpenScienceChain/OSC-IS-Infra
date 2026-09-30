param(
  [ValidateRange(1, 60)][int]$Samples = 24,
  [ValidateRange(1, 30)][int]$DelaySeconds = 3,
  [string]$OutputPath = (Join-Path $PSScriptRoot '..\.generated\aws\usrse260930\evidence\metrics\resource-samples-raw.json')
)

$ErrorActionPreference = 'Stop'
$context = 'osc-usrse26-usrse260930'
if ((& kubectl config current-context).Trim() -ne $context) { throw 'Refusing a different Kubernetes context.' }
$account = ((& aws sts get-caller-identity --output json) | ConvertFrom-Json).Account
if ($account -ne '269624229733') { throw 'Refusing a different AWS account.' }
$nodeNames = @((& kubectl --context $context get nodes -o json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name })
if ($nodeNames.Count -ne 3) { throw 'Expected the reviewed three-node baseline.' }

$rows = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $Samples; $index++) {
  $sampledAt = (Get-Date).ToUniversalTime().ToString('o')
  foreach ($nodeName in $nodeNames) {
    $summary = & kubectl --context $context get --raw "/api/v1/nodes/$nodeName/proxy/stats/summary" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not read kubelet summary for $nodeName" }
    foreach ($pod in @($summary.pods | Where-Object { $_.podRef.namespace -in @('osc-apps', 'osc-fabric') })) {
      $cpuValues = @($pod.containers | Where-Object { $null -ne $_.cpu.usageNanoCores } | ForEach-Object { [double]$_.cpu.usageNanoCores })
      $memoryValues = @($pod.containers | Where-Object { $null -ne $_.memory.workingSetBytes } | ForEach-Object { [double]$_.memory.workingSetBytes })
      $rows.Add([ordered]@{
        sampledAt = $sampledAt
        node = $nodeName
        namespace = $pod.podRef.namespace
        pod = $pod.podRef.name
        cpuMilliCores = if ($cpuValues.Count) { [math]::Round(($cpuValues | Measure-Object -Sum).Sum / 1e6, 3) } else { $null }
        workingSetMiB = if ($memoryValues.Count) { [math]::Round(($memoryValues | Measure-Object -Sum).Sum / 1048576, 3) } else { $null }
      })
    }
  }
  if ($index -lt $Samples - 1) { Start-Sleep -Seconds $DelaySeconds }
}

$outputParent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
@{
  schemaVersion = 1
  context = $context
  method = 'Read-only Kubernetes node proxy kubelet stats/summary; CPU usageNanoCores and memory workingSetBytes for osc-apps and osc-fabric pods.'
  requestedSamples = $Samples
  rows = $rows
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Captured $Samples resource samples to $OutputPath"
