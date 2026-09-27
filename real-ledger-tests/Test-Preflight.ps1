[CmdletBinding()]
param(
  [string]$OscIsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$GeneratedNetwork = (Join-Path $PSScriptRoot '.generated\test-network'),
  [switch]$RequireReady
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
$root = [System.IO.Path]::GetFullPath($OscIsRoot)
$network = Join-Path $root 'OSC-Network\test-network'
$chaincode = Join-Path $root '.codex-interactive-demo-worktrees\OSC-Chaincode\chaincode-go\chaincode\provenance.go'
$bridge = Join-Path $root '.codex-interactive-demo-worktrees\OSC-Artifact-Submission\fabric-bridge\src\server.ts'
$contract = Join-Path $root '.codex-tmp\gateway-guest-reads\docs\demo-guest-portal-contract.md'

foreach ($path in @($network, $chaincode, $bridge, $contract)) {
  if (-not (Test-Path -LiteralPath $path)) { $failures.Add("Missing source: $path") }
}
foreach ($name in @('git', 'docker', 'go', 'bash')) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    $failures.Add("Required command unavailable: $name")
  }
}

$repos = @{
  Network = Join-Path $root 'OSC-Network'
  Chaincode = Join-Path $root '.codex-interactive-demo-worktrees\OSC-Chaincode'
  Submission = Join-Path $root '.codex-interactive-demo-worktrees\OSC-Artifact-Submission'
  Gateway = Join-Path $root '.codex-tmp\gateway-guest-reads'
}
foreach ($entry in $repos.GetEnumerator()) {
  if (Test-Path -LiteralPath $entry.Value) {
    $revision = & git -C $entry.Value rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $failures.Add("Cannot read $($entry.Key) revision") }
    else { Write-Output "$($entry.Key): $revision" }
  }
}

if ((Test-Path -LiteralPath $chaincode) -and
    -not ((Get-Content -LiteralPath $chaincode -Raw) -match 'CitizenScienceMSP')) {
  $failures.Add('Current chaincode does not identify CitizenScienceMSP')
}
if ((Test-Path -LiteralPath $bridge) -and
    -not ((Get-Content -LiteralPath $bridge -Raw) -match 'NSGMSP')) {
  $failures.Add('Current ledger gateway does not identify NSGMSP')
}

$generatedConfig = Join-Path $GeneratedNetwork 'configtx\configtx.yaml'
$generatedCompose = Join-Path $GeneratedNetwork 'compose\compose-test-net.yaml'
if (-not (Test-Path -LiteralPath $generatedConfig) -or
    -not (Test-Path -LiteralPath $generatedCompose)) {
  $failures.Add('No generated two-organization Fabric network is staged')
} else {
  $configText = Get-Content -LiteralPath $generatedConfig -Raw
  $composeText = Get-Content -LiteralPath $generatedCompose -Raw
  foreach ($msp in @('NSGMSP', 'CitizenScienceMSP')) {
    if ($configText -notmatch [regex]::Escape($msp) -or
        $composeText -notmatch [regex]::Escape($msp)) {
      $failures.Add("Generated channel/peer configuration lacks $msp")
    }
  }
  if ($configText -match 'Org[12]MSP' -or $composeText -match 'Org[12]MSP') {
    $failures.Add('Generated network still contains sample Org1MSP/Org2MSP IDs')
  }
  if ($composeText -match 'hyperledger/fabric-(peer|orderer):latest') {
    $failures.Add('Generated network still uses mutable Fabric images')
  }
}

if ($RequireReady -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  $generatedParent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($GeneratedNetwork))
  foreach ($relative in @('bin\peer', 'bin\cryptogen', 'bin\configtxgen', 'config\core.yaml')) {
    if (-not (Test-Path -LiteralPath (Join-Path $generatedParent $relative))) {
      $failures.Add("Missing version-pinned Fabric tool/config: $relative")
    }
  }
  & docker info --format '{{.ServerVersion}}' *> $null
  if ($LASTEXITCODE -ne 0) { $failures.Add('Docker daemon is unavailable') }
  $fabricNames = @('orderer.example.com', 'peer0.org1.example.com', 'peer0.org2.example.com')
  foreach ($name in $fabricNames) {
    $existing = & docker ps -a --format '{{.Names}}' --filter "name=^/${name}$" 2>$null
    if ($existing -contains $name) {
      $failures.Add("Fixed-name Fabric container already exists: $name")
    }
  }
  foreach ($project in @('osc-ui-tests', 'osc-is-system-test', 'osc-usrse26-ux',
      'osc-is-real-ledger-e2e', 'osc-is-fabric-e2e')) {
    $running = @(& docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$project" 2>$null)
    if ($running.Count -gt 0) {
      $failures.Add("Another demo stack is running ($project): $($running -join ', ')")
    }
  }
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    foreach ($port in @(18088, 13388, 7050, 7051, 7053, 9051)) {
      if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {
        $failures.Add("Required localhost port is occupied: $port")
      }
    }
  }
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGiB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Output "Free host memory: $freeGiB GiB"
    if ($freeGiB -lt 16) { $failures.Add('Less than 16 GiB of host RAM is free') }
  }
}

if ($failures.Count -gt 0) {
  foreach ($failure in $failures) { Write-Error $failure -ErrorAction Continue }
  exit 1
}
Write-Output 'Preflight passed. This does not certify a running Fabric network.'
