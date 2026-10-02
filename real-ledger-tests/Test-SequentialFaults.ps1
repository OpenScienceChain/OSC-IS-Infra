[CmdletBinding()]
param(
  [switch]$ConfirmLocalFaults,
  [switch]$IncludeFabricPeer,
  [string]$EnvFile = (Join-Path $PSScriptRoot '.generated\local-staged.env'),
  [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '.generated\fault-evidence')
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmLocalFaults) {
  throw 'Local fault injection requires -ConfirmLocalFaults after the real-ledger stack passes happy-path tests'
}

$composeFile = Join-Path $PSScriptRoot 'compose.yaml'
$project = 'osc-is-real-ledger-e2e'
$envPath = [System.IO.Path]::GetFullPath($EnvFile)
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
  throw "Missing ignored local Compose environment: $envPath"
}
$composeArgs = @('compose', '--env-file', $envPath, '-p', $project, '-f', $composeFile)
$evidence = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$generated = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.generated'))
if (-not $evidence.StartsWith($generated + [System.IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
  throw 'EvidenceDirectory must be inside this harness generated directory'
}

function Assert-Running([string]$service) {
  $ids = @(& docker @composeArgs ps -q $service)
  if ($LASTEXITCODE -ne 0 -or $ids.Count -ne 1) {
    throw "Expected exactly one $service container in $project"
  }
  $state = & docker inspect --format '{{.State.Running}}' $ids[0]
  if ($LASTEXITCODE -ne 0 -or $state -ne 'true') {
    throw "$service is not running"
  }
}

function Assert-HealthyPortal {
  $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:18088/healthz' -TimeoutSec 10
  if ($response.StatusCode -ne 200) { throw 'WebApp health did not recover' }
  $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:13388/api/v1/health' -TimeoutSec 10
  if ($response.StatusCode -ne 200) { throw 'Gateway health did not recover' }
}

foreach ($service in @('rabbitmq', 'gateway', 'history-nsg', 'postgres')) {
  Assert-Running $service
}
Assert-HealthyPortal
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

foreach ($service in @('rabbitmq', 'gateway', 'history-nsg', 'postgres')) {
  $started = Get-Date
  $restored = $false
  try {
    & docker @composeArgs stop --timeout 5 $service | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not stop $service" }
    $id = @(& docker @composeArgs ps -a -q $service)
    if ($id.Count -ne 1) { throw "Cannot identify stopped $service container" }
    $state = & docker inspect --format '{{.State.Running}}' $id[0]
    if ($state -ne 'false') { throw "$service did not stop" }
    Start-Sleep -Seconds 3
  } finally {
    & docker @composeArgs start $service | Out-Null
    if ($LASTEXITCODE -eq 0) {
      & docker @composeArgs up --detach --wait --no-build | Out-Null
      if ($LASTEXITCODE -eq 0) { $restored = $true }
    }
  }
  if (-not $restored) { throw "$service failed to restore; stopping fault sequence" }
  Assert-Running $service
  Assert-HealthyPortal
  $results.Add([pscustomobject]@{
    service = $service
    startedAt = $started.ToUniversalTime().ToString('o')
    restoredAt = (Get-Date).ToUniversalTime().ToString('o')
    containerRestored = $true
    portalHealthRestored = $true
    applicationSemanticsVerified = $false
  })
}

if ($IncludeFabricPeer) {
  $peer = 'peer0.org1.example.com'
  $label = & docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' $peer
  if ($LASTEXITCODE -ne 0 -or $label -ne 'osc-is-fabric-e2e') {
    throw 'Refusing to interrupt peer without exact osc-is-fabric-e2e ownership label'
  }
  $started = Get-Date
  try {
    & docker stop --time 5 $peer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop exact Fabric peer' }
    Start-Sleep -Seconds 3
  } finally {
    & docker start $peer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore exact Fabric peer' }
  }
  Assert-HealthyPortal
  $results.Add([pscustomobject]@{
    service = $peer
    startedAt = $started.ToUniversalTime().ToString('o')
    restoredAt = (Get-Date).ToUniversalTime().ToString('o')
    containerRestored = $true
    portalHealthRestored = $true
    applicationSemanticsVerified = $false
  })
}

$output = Join-Path $evidence 'fault-restoration.json'
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $output -Encoding utf8
Write-Output "Container and health restoration recorded: $output"
Write-Output 'These checks do not prove queue integrity or exactly-once Fabric behavior; rerun the API/Cypress provenance assertions.'
