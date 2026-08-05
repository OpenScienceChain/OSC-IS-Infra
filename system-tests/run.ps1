$ErrorActionPreference = "Stop"
$Compose = @("docker", "compose", "-f", "$PSScriptRoot/docker-compose.yml")

function Invoke-Compose {
  & $Compose[0] $Compose[1..($Compose.Length - 1)] @args
  if ($LASTEXITCODE -ne 0) { throw "docker compose failed: $args" }
}

try {
  Invoke-Compose down --volumes --remove-orphans
  Invoke-Compose up --detach --build rabbitmq mock-ledger-api adapter submission-worker

  Write-Host "[1/4] Healthy v2 multi-organization submission"
  Invoke-Compose --profile probe run --rm probe publish --count 1
  Invoke-Compose --profile probe run --rm probe wait --count 1 --state SUCCESS

  Write-Host "[2/4] Durable queue while the worker is unavailable"
  Invoke-Compose stop submission-worker
  Invoke-Compose --profile probe run --rm probe publish --count 2
  Invoke-Compose --profile probe run --rm probe depth --queue artifact.submit.queue --expected 2
  Invoke-Compose start submission-worker
  Invoke-Compose --profile probe run --rm probe wait --count 2 --state SUCCESS

  Write-Host "[3/4] Explicit failure event while the adapter is unavailable"
  Invoke-Compose stop adapter
  Invoke-Compose --profile probe run --rm probe publish --count 1
  Invoke-Compose --profile probe run --rm probe wait --count 1 --state FAILED

  Write-Host "[4/4] Recovery after the adapter returns"
  Invoke-Compose start adapter
  Invoke-Compose --profile probe run --rm probe publish --count 1
  Invoke-Compose --profile probe run --rm probe wait --count 1 --state SUCCESS
  Write-Host "OSC-IS Docker system tests passed."
}
finally {
  Invoke-Compose down --volumes --remove-orphans
}
