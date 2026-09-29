[CmdletBinding()]
param(
  [string]$OscIsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$GeneratedNetwork = (Join-Path $PSScriptRoot '.generated\test-network'),
  [string]$WebAppDir = (Join-Path $PSScriptRoot '..\..\..\.codex-showcase-worktrees\OSC-WebApp'),
  [string]$ReuseSecretsFrom,
  [string]$Output = (Join-Path $PSScriptRoot '.generated\local.env')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($OscIsRoot)
$network = [IO.Path]::GetFullPath($GeneratedNetwork)
$outputPath = [IO.Path]::GetFullPath($Output)
$generatedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.generated'))
if (-not $outputPath.StartsWith($generatedRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Local secrets file must remain inside the ignored .generated directory'
}
if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite $outputPath" }
$mountRoot = Join-Path $generatedRoot (([IO.Path]::GetFileNameWithoutExtension($outputPath)) + '-fabric')
if (Test-Path -LiteralPath $mountRoot) { throw "Refusing to overwrite $mountRoot" }

$versions = @{}
foreach ($line in (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\platform\versions.env'))) {
  if ($line -match '^([A-Z_]+)=(.+)$') { $versions[$Matches[1]] = $Matches[2] }
}
foreach ($name in @('POSTGRES_IMAGE', 'RABBITMQ_IMAGE')) {
  if ([string]$versions[$name] -notmatch '@sha256:[a-f0-9]{64}$') {
    throw "Missing pinned image for $name"
  }
}

function Get-OneIdentityFile([string]$organization, [string]$folder) {
  $directory = Join-Path $network "organizations\peerOrganizations\$organization\users\User1@$organization\msp\$folder"
  $files = @(Get-ChildItem -LiteralPath $directory -File)
  if ($files.Count -ne 1) { throw "Expected one generated identity file in $directory" }
  return $files[0].FullName
}

function Get-MountPath([string]$path) {
  $absolute = [IO.Path]::GetFullPath($path)
  if (-not (Test-Path -LiteralPath $absolute)) { throw "Missing local source: $absolute" }
  return $absolute.Replace('\', '/')
}

function Copy-FabricMount([string]$source, [string]$name) {
  $absolute = [IO.Path]::GetFullPath($source)
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Missing Fabric identity: $absolute" }
  $destination = Join-Path $mountRoot $name
  [IO.File]::Copy($absolute, $destination, $false)
  return Get-MountPath $destination
}

function New-Secret { return [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant() }
$reusedSecrets = @{}
if ($ReuseSecretsFrom) {
  foreach ($line in (Get-Content -LiteralPath $ReuseSecretsFrom)) {
    if ($line -match '^([A-Z_]+)=(.+)$') { $reusedSecrets[$Matches[1]] = $Matches[2] }
  }
}
function Get-Secret([string]$name) {
  if (-not $ReuseSecretsFrom) { return New-Secret }
  if ([string]$reusedSecrets[$name] -notmatch '^[a-f0-9]{64}$') {
    throw "Missing reusable disposable secret: $name"
  }
  return $reusedSecrets[$name]
}

New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
$values = [ordered]@{
  WEBAPP_DIR = Get-MountPath $WebAppDir
  GATEWAY_DIR = Get-MountPath (Join-Path $root '.codex-showcase-worktrees\OSC-APIGateway')
  SUBMISSION_DIR = Get-MountPath (Join-Path $root '.codex-showcase-worktrees\OSC-Artifact-Submission')
  POSTGRES_IMAGE = $versions.POSTGRES_IMAGE
  RABBITMQ_IMAGE = $versions.RABBITMQ_IMAGE
  NSG_CERT_FILE = Copy-FabricMount (Get-OneIdentityFile 'org1.example.com' 'signcerts') 'nsg-cert.pem'
  NSG_KEY_FILE = Copy-FabricMount (Get-OneIdentityFile 'org1.example.com' 'keystore') 'nsg-key.pem'
  NSG_TLS_CA_FILE = Copy-FabricMount (Join-Path $network 'organizations\peerOrganizations\org1.example.com\tlsca\tlsca.org1.example.com-cert.pem') 'nsg-ca.pem'
  CS_CERT_FILE = Copy-FabricMount (Get-OneIdentityFile 'org2.example.com' 'signcerts') 'cs-cert.pem'
  CS_KEY_FILE = Copy-FabricMount (Get-OneIdentityFile 'org2.example.com' 'keystore') 'cs-key.pem'
  CS_TLS_CA_FILE = Copy-FabricMount (Join-Path $network 'organizations\peerOrganizations\org2.example.com\tlsca\tlsca.org2.example.com-cert.pem') 'cs-ca.pem'
  MAGNETIC_CERT_FILE = Copy-FabricMount (Get-OneIdentityFile 'org3.example.com' 'signcerts') 'magnetic-cert.pem'
  MAGNETIC_KEY_FILE = Copy-FabricMount (Get-OneIdentityFile 'org3.example.com' 'keystore') 'magnetic-key.pem'
  MAGNETIC_TLS_CA_FILE = Copy-FabricMount (Join-Path $network 'organizations\peerOrganizations\org3.example.com\tlsca\tlsca.org3.example.com-cert.pem') 'magnetic-ca.pem'
  LEDGER_TOKEN = Get-Secret 'LEDGER_TOKEN'
  LOCAL_ADMIN_PASSWORD = Get-Secret 'LOCAL_ADMIN_PASSWORD'
  LOCAL_MAGNETIC_CURATOR_PASSWORD = Get-Secret 'LOCAL_MAGNETIC_CURATOR_PASSWORD'
  LOCAL_ANALYTICS_SECRET = Get-Secret 'LOCAL_ANALYTICS_SECRET'
  LOCAL_CONTROL_KEY = Get-Secret 'LOCAL_CONTROL_KEY'
  LOCAL_DB_PASSWORD = Get-Secret 'LOCAL_DB_PASSWORD'
  LOCAL_DEMO_JWT_SECRET = Get-Secret 'LOCAL_DEMO_JWT_SECRET'
  LOCAL_JWT_SECRET = Get-Secret 'LOCAL_JWT_SECRET'
  LOCAL_LISTENER_KEY = Get-Secret 'LOCAL_LISTENER_KEY'
  LOCAL_RABBIT_PASSWORD = Get-Secret 'LOCAL_RABBIT_PASSWORD'
}

New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputPath)) -Force | Out-Null
$lines = foreach ($entry in $values.GetEnumerator()) { "$($entry.Key)=$($entry.Value)" }
[IO.File]::WriteAllLines($outputPath, $lines, [Text.UTF8Encoding]::new($false))
Write-Output "Wrote disposable local Compose environment: $outputPath"
