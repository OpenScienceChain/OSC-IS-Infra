param(
  [switch]$KeepRunning,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$composeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
$webAppPath = Resolve-Path (Join-Path $PSScriptRoot '..\..\OSC-WebApp')

function Wait-Http {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$Attempts = 60
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
        return
      }
    } catch {
      if ($attempt -eq $Attempts) { throw }
    }
    Start-Sleep -Seconds 2
  }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
docker info *> $null
$dockerInfoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($dockerInfoExitCode -ne 0) {
  throw 'Docker Desktop is not ready.'
}

try {
  if (-not $SkipBuild) {
    docker compose -f $composeFile build
    if ($LASTEXITCODE -ne 0) { throw 'Container build failed.' }
  }

  docker compose -f $composeFile up -d
  if ($LASTEXITCODE -ne 0) { throw 'Container startup failed.' }

  Wait-Http 'http://127.0.0.1:8080/healthz'
  Wait-Http 'http://127.0.0.1:3300/api/v1/health'
  Wait-Http 'http://127.0.0.1:3310/health'

  Push-Location $webAppPath
  try {
    npx cypress run --browser chrome --config baseUrl=http://127.0.0.1:8080 --spec cypress/e2e/local-stack/local-stack.cy.ts
    if ($LASTEXITCODE -ne 0) { throw 'Local stack browser tests failed.' }
  } finally {
    Pop-Location
  }

  docker compose -f $composeFile stop rabbitmq
  if ($LASTEXITCODE -ne 0) { throw 'Could not stop RabbitMQ for the interruption check.' }
  Wait-Http 'http://127.0.0.1:3300/api/v1/health'
  docker compose -f $composeFile start rabbitmq
  if ($LASTEXITCODE -ne 0) { throw 'Could not restart RabbitMQ.' }

  docker compose -f $composeFile stop api-gateway
  if ($LASTEXITCODE -ne 0) { throw 'Could not stop the API Gateway for the interruption check.' }
  Wait-Http 'http://127.0.0.1:8080/healthz'
  Wait-Http 'http://127.0.0.1:3310/health'
  docker compose -f $composeFile start api-gateway
  if ($LASTEXITCODE -ne 0) { throw 'Could not restart the API Gateway.' }
  Wait-Http 'http://127.0.0.1:3300/api/v1/health'

  Write-Host 'Local OSC deployment and interruption checks passed.'
  Write-Host 'WebApp: http://127.0.0.1:8080'
  Write-Host 'API Gateway: http://127.0.0.1:3300/api/v1/health'
  Write-Host 'RabbitMQ management: http://127.0.0.1:15672'
} finally {
  if (-not $KeepRunning) {
    docker compose -f $composeFile down -v
  }
}
