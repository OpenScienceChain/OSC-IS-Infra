[CmdletBinding()]
param(
  [string]$OscIsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$Destination = (Join-Path $PSScriptRoot '.generated\test-network'),
  [string]$ToolsRoot
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($OscIsRoot)
$repository = Join-Path $root 'OSC-Network'
$source = Join-Path $repository 'test-network'
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$destinationParent = [System.IO.Path]::GetDirectoryName($destinationPath)
$versionsFile = Join-Path $PSScriptRoot '..\platform\versions.env'
if (-not (Test-Path -LiteralPath (Join-Path $source 'network.sh'))) {
  throw "Missing tracked OSC-Network/test-network at $source"
}
if (Test-Path -LiteralPath $destinationPath) {
  throw "Refusing to overwrite existing generated network: $destinationPath"
}
$versions = @{}
foreach ($line in (Get-Content -LiteralPath $versionsFile)) {
  if ($line -match '^([A-Z_]+)=(.+)$') { $versions[$Matches[1]] = $Matches[2] }
}
foreach ($required in @('FABRIC_PEER_IMAGE', 'FABRIC_ORDERER_IMAGE', 'FABRIC_CA_IMAGE')) {
  if (-not $versions[$required] -or $versions[$required] -notmatch '@sha256:[a-f0-9]{64}$') {
    throw "Missing reviewed digest: $required"
  }
}
if ($ToolsRoot) {
  $toolsPath = [System.IO.Path]::GetFullPath($ToolsRoot)
  foreach ($name in @('bin', 'config')) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolsPath $name))) {
      throw "Missing Fabric $name in $toolsPath"
    }
    if (Test-Path -LiteralPath (Join-Path $destinationParent $name)) {
      throw "Refusing to overwrite existing generated $name"
    }
  }
}

$revision = & git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify OSC-Network revision' }
$tracked = @(& git -C $repository ls-files -- 'test-network')
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
  throw 'Cannot enumerate tracked test-network files'
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
$replacements = @{
  'Org1MSP' = 'NSGMSP'
  'Org2MSP' = 'CitizenScienceMSP'
  'hyperledger/fabric-peer:latest' = $versions.FABRIC_PEER_IMAGE
  'hyperledger/fabric-orderer:latest' = $versions.FABRIC_ORDERER_IMAGE
  'hyperledger/fabric-ca:latest' = $versions.FABRIC_CA_IMAGE
}
$textExtensions = @('.sh', '.yaml', '.yml', '.json', '.config', '.md', '.txt')
$copied = 0
foreach ($trackedPath in $tracked) {
  if (-not $trackedPath.StartsWith('test-network/')) { throw "Unexpected path: $trackedPath" }
  $relative = $trackedPath.Substring('test-network/'.Length)
  $target = [System.IO.Path]::GetFullPath((Join-Path $destinationPath $relative))
  if (-not $target.StartsWith($destinationPath + [System.IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw "Tracked path escapes generated network: $trackedPath"
  }
  $parent = [System.IO.Path]::GetDirectoryName($target)
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repository $trackedPath) -Destination $target
  if ([System.IO.Path]::GetExtension($target) -in $textExtensions) {
    $contents = [System.IO.File]::ReadAllText($target)
    foreach ($old in $replacements.Keys) { $contents = $contents.Replace($old, $replacements[$old]) }
    $contents = $contents.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($target, $contents, [System.Text.UTF8Encoding]::new($false))
  }
  $copied++
}

if ($ToolsRoot) {
  Copy-Item -LiteralPath (Join-Path $toolsPath 'bin') -Destination $destinationParent -Recurse
  Copy-Item -LiteralPath (Join-Path $toolsPath 'config') -Destination $destinationParent -Recurse
}

Write-Output "Staged $copied tracked test-network files from OSC-Network $revision"
Write-Output "Generated network: $destinationPath"
Write-Output 'This is still a sample network; preflight and live MSP/certificate checks are required before product tests.'
