[CmdletBinding()]
param(
  [ValidatePattern('^[a-z0-9]{8,20}$')][string]$RunId = 'usrse260930'
)

$ErrorActionPreference = 'Stop'
if ($RunId -ne 'usrse260930') { throw 'Only the reviewed AWS evidence run is supported.' }
if ((& kubectl config current-context).Trim() -ne 'osc-usrse26-usrse260930') { throw 'Unexpected Kubernetes context.' }
if (((& aws sts get-caller-identity --output json) | ConvertFrom-Json).Account -ne '269624229733') { throw 'Unexpected AWS account.' }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$network = Join-Path $root 'platform\.generated\fabric-network-eks'
$runRoot = Join-Path $root "platform\.generated\aws\$RunId"
$org3Kube = Join-Path $network 'kube\org3'
$org3Config = Join-Path $network 'config\org3'
$privateDir = Join-Path $runRoot 'org3-private'
foreach ($directory in @($org3Kube, $org3Config, $privateDir)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$credentialPath = Join-Path $privateDir 'ca-credentials.json'
if (Test-Path -LiteralPath $credentialPath) {
  $credentials = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
} else {
  $credentials = [ordered]@{
    root = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    admin = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    peer = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  }
  $credentials | ConvertTo-Json | Set-Content -LiteralPath $credentialPath -Encoding utf8
}

function Convert-OrgTemplate([string]$source, [string]$destination) {
  $body = Get-Content -LiteralPath $source -Raw
  if ($body -notmatch 'org2|CitizenScienceMSP') { throw "Source is not an org2 template: $source" }
  $body = $body.Replace('ORG2_NS', 'ORG3_NS').Replace('CitizenScienceMSP', 'MagneticArchMSP').Replace('org2', 'org3')
  if ($body -match 'org2|CitizenScienceMSP|ORG2_NS') { throw "Incomplete org3 conversion: $source" }
  [IO.File]::WriteAllText($destination, $body, [Text.UTF8Encoding]::new($false))
}

foreach ($name in @('org2-ca.yaml', 'org2-peer1.yaml', 'org2-tls-cert-issuer.yaml', 'org2-cc-template.yaml')) {
  Convert-OrgTemplate (Join-Path $network "kube\org2\$name") (Join-Path $org3Kube ($name -replace 'org2', 'org3'))
}
Convert-OrgTemplate (Join-Path $network 'kube\pvc-fabric-org2.yaml') (Join-Path $network 'kube\pvc-fabric-org3.yaml')
Convert-OrgTemplate (Join-Path $network 'config\org2\core.yaml') (Join-Path $org3Config 'core.yaml')

$peerPath = Join-Path $org3Kube 'org3-peer1.yaml'
$peer = Get-Content -LiteralPath $peerPath -Raw
$peer = $peer.Replace('osc-is/fabric-role: org3', 'osc-is/fabric-role: org2')
$peer = $peer.Replace('CORE_PEER_GOSSIP_BOOTSTRAP: org3-peer2:7051', 'CORE_PEER_GOSSIP_BOOTSTRAP: org3-peer1:7051')
if ($peer -match 'org3-peer2' -or $peer -notmatch 'osc-is/fabric-role: org2') { throw 'Peer template needs manual review.' }
[IO.File]::WriteAllText($peerPath, $peer, [Text.UTF8Encoding]::new($false))

$caTemplatePath = Join-Path $org3Kube 'org3-ca.yaml'
$caTemplate = Get-Content -LiteralPath $caTemplatePath -Raw
$caTemplate = $caTemplate.Replace('osc-is/fabric-role: org3', 'osc-is/fabric-role: org2')
$caTemplate = [regex]::Replace($caTemplate, 'configMap:\s+name: org3-config', "secret:`n            secretName: org3-ca-config")
if ($caTemplate -notmatch 'secretName: org3-ca-config' -or $caTemplate -match 'configMap:') { throw 'CA template needs manual review.' }
[IO.File]::WriteAllText($caTemplatePath, $caTemplate, [Text.UTF8Encoding]::new($false))

$caConfig = Get-Content -LiteralPath (Join-Path $network 'config\org2\fabric-ca-server-config.yaml') -Raw
$caConfig = $caConfig.Replace('org2', 'org3').Replace('pass: rcaadminpw', "pass: $($credentials.root)")
if ($caConfig -match 'org2|rcaadminpw' -or $caConfig -notmatch 'name: org3-ca') { throw 'CA configuration needs manual review.' }
[IO.File]::WriteAllText((Join-Path $privateDir 'fabric-ca-server-config.yaml'), $caConfig, [Text.UTF8Encoding]::new($false))

foreach ($file in @($credentialPath, (Join-Path $privateDir 'fabric-ca-server-config.yaml'))) {
  & icacls.exe $file /inheritance:r | Out-Null
  & icacls.exe $file /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Cannot protect generated credential file: $file" }
}

Write-Host "Prepared pinned org3 templates and private CA input under the guarded run. No cluster resources changed."
