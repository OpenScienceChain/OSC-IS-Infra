[CmdletBinding()]
param(
  [string]$ProjectName = 'osc-is-magnetic-showcase'
)

$ErrorActionPreference = 'Stop'
if ($ProjectName -notmatch '^osc-is-[a-z0-9-]+$') {
  throw 'Expected a local OSC Compose project name.'
}
if ((docker context show).Trim() -notin @('default', 'desktop-linux')) {
  throw 'This script only runs against a local Docker context.'
}
$dockerEndpoint = (docker context inspect --format '{{.Endpoints.docker.Host}}').Trim()
if ($dockerEndpoint -notmatch '^(npipe:|unix:)' -or
    ($env:DOCKER_HOST -and $env:DOCKER_HOST -notmatch '^(npipe:|unix:)')) {
  throw 'A local Docker socket is required.'
}

$envFile = Join-Path $PSScriptRoot '.generated/local.env'
$composeFile = Join-Path $PSScriptRoot 'compose.yaml'
if (-not (Test-Path -LiteralPath $envFile)) {
  throw 'Generate .generated/local.env before initializing organizations.'
}

$postgresId = (docker compose -p $ProjectName --env-file $envFile -f $composeFile ps -q postgres).Trim()
if ($LASTEXITCODE -ne 0 -or -not $postgresId) {
  throw "The $ProjectName PostgreSQL service is not running."
}
$containerName = (docker inspect --format '{{.Name}}' $postgresId).Trim()
if ($LASTEXITCODE -ne 0 -or $containerName -ne "/$ProjectName-postgres-1") {
  throw 'The PostgreSQL container does not belong to the expected local Compose project.'
}

$sql = @'
BEGIN;
INSERT INTO organization_entity (id, name, description, slug, "mspId", status)
VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Neuroscience Gateway',
   'Local research demonstration organization', 'neuroscience-gateway', 'NSGMSP', 'active'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Citizen Science',
   'Local citizen science demonstration organization', 'citizen-science', 'CitizenScienceMSP', 'active')
ON CONFLICT (id) DO NOTHING;
DO $$
BEGIN
  IF (
    SELECT count(*) FROM organization_entity
    WHERE (id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
           AND slug = 'neuroscience-gateway' AND "mspId" = 'NSGMSP'
           AND status = 'active' AND "archivedAt" IS NULL)
       OR (id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
           AND slug = 'citizen-science' AND "mspId" = 'CitizenScienceMSP'
           AND status = 'active' AND "archivedAt" IS NULL)
  ) <> 2 THEN
    RAISE EXCEPTION 'Local demonstration organizations conflict with the expected Fabric identities';
  END IF;
END $$;
COMMIT;
'@

docker exec $postgresId psql -v ON_ERROR_STOP=1 -U osc_local -d osc_local -c $sql
if ($LASTEXITCODE -ne 0) {
  throw 'Local organization initialization failed.'
}
Write-Output 'Neuroscience Gateway and Citizen Science are ready for local account registration.'
