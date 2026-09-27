[CmdletBinding()]
param(
  [string]$OscIsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$GeneratedNetwork = (Join-Path $PSScriptRoot '.generated\test-network'),
  [string]$WebAppDir = (Join-Path $PSScriptRoot '..\..\..\.codex-tmp\OSC-WebApp-real-ledger-e2e-20260926'),
  [string]$WSLDistro = 'Ubuntu-24.04',
  [string]$LinuxGoExecutable = '/usr/local/go/bin/go',
  [hashtable]$ExpectedRevisions = @{},
  [switch]$VerifySources,
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
  WebApp = [IO.Path]::GetFullPath($WebAppDir)
  E2ERunner = Join-Path $root '.codex-tmp\OSC-WebApp-live-e2e-prep-20260923'
}
if ($RequireReady -or $VerifySources) {
  foreach ($name in $repos.Keys) {
    if ([string]$ExpectedRevisions[$name] -notmatch '^[a-f0-9]{40}$') {
      $failures.Add("Missing exact 40-character expected revision for $name")
    }
  }
}
foreach ($entry in $repos.GetEnumerator()) {
  if (Test-Path -LiteralPath $entry.Value) {
    $revision = & git -C $entry.Value rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $failures.Add("Cannot read $($entry.Key) revision") }
    else {
      Write-Output "$($entry.Key): $revision"
      if (($RequireReady -or $VerifySources) -and
          $revision -ne [string]$ExpectedRevisions[$entry.Key]) {
        $failures.Add("$($entry.Key) revision differs from pinned source")
      }
    }
    if ($RequireReady -or $VerifySources) {
      $changes = @(& git -C $entry.Value status --porcelain=v1 --untracked-files=all 2>$null)
      if ($LASTEXITCODE -ne 0) { $failures.Add("Cannot inspect $($entry.Key) worktree") }
      elseif ($changes.Count -gt 0) {
        $failures.Add("$($entry.Key) worktree is not clean: $($changes[0])")
      }
    }
  } elseif ($RequireReady -or $VerifySources) {
    $failures.Add("Missing $($entry.Key) checkout: $($entry.Value)")
  }
}

$e2eSpec = Join-Path $repos.E2ERunner 'cypress\e2e\demo\local-real-ledger.cy.ts'
if ($VerifySources -and -not (Test-Path -LiteralPath $e2eSpec)) {
  $failures.Add('Pinned E2E runner lacks the real-ledger Cypress spec')
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
  $goMod = Join-Path $root '.codex-interactive-demo-worktrees\OSC-Chaincode\chaincode-go\go.mod'
  $requiredGo = [regex]::Match((Get-Content -LiteralPath $goMod -Raw), '(?m)^go\s+(\d+\.\d+\.\d+)').Groups[1].Value
  if (-not $requiredGo) { $failures.Add('Cannot read exact Go version from chaincode go.mod') }
  elseif (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    $failures.Add('WSL is required for the generated Linux Fabric network')
  } else {
    $goVersion = [string](& wsl -d $WSLDistro -- env GOTOOLCHAIN=local $LinuxGoExecutable version 2>$null)
    if ($LASTEXITCODE -ne 0 -or $goVersion -notmatch [regex]::Escape("go$requiredGo")) {
      $failures.Add("Linux Go toolchain must be exactly $requiredGo without auto-download (found: $goVersion)")
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
