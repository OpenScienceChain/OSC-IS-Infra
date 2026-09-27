[CmdletBinding()]
param(
  [string]$RunId = ('local-real-ledger-' + (Get-Date -Format 'yyyyMMddHHmmss')),
  [ValidateRange(1, 24)]
  [int]$Hours = 4
)

$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^[A-Za-z0-9._-]{1,128}$') {
  throw 'RunId must match the Gateway demonstration contract'
}
if (-not $env:LOCAL_CONTROL_KEY -or $env:LOCAL_CONTROL_KEY.Length -lt 24) {
  throw 'Set a disposable LOCAL_CONTROL_KEY of at least 24 characters in this process'
}
$now = (Get-Date).ToUniversalTime()
$payload = @{
  state = 'OPEN'
  runId = $RunId
  reason = 'isolated local real-ledger verification'
  opensAt = $now.AddMinutes(-1).ToString('o')
  closesAt = $now.AddHours($Hours).ToString('o')
} | ConvertTo-Json -Compress

$result = Invoke-RestMethod -Method Put -Uri 'http://localhost:13388/api/v1/demo/internal/status' `
  -Headers @{ 'X-Demo-Control-Key' = $env:LOCAL_CONTROL_KEY } `
  -ContentType 'application/json' -Body $payload -TimeoutSec 10
if ($result.state -ne 'OPEN' -or $result.runId -ne $RunId) {
  throw 'Gateway did not confirm the requested local OPEN state and run ID'
}
Write-Output "Local demo OPEN: $RunId"
Write-Output "Closes at: $($result.closesAt)"
