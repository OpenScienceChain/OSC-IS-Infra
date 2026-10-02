[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{8,20}$')][string]$RunId)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-control'
$runRoot = Join-Path $repoRoot "platform\.generated\control\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$planPath = Join-Path $runRoot 'reviewed.tfplan'
$planJsonPath = Join-Path $runRoot 'reviewed-plan.json'

foreach ($path in @($planPath, $planJsonPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing reviewed control-plane artifact: $path" }
}

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py | Out-Null
    python platform/aws/check_control_plan.py $planJsonPath --run-id $RunId
    if ($LASTEXITCODE -ne 0) { throw 'Control-plane policy recheck failed.' }
    Push-Location $terraformRoot
    try {
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py') | Out-Null
        terraform apply -input=false -auto-approve "-state=$statePath" $planPath
        if ($LASTEXITCODE -ne 0) { throw 'Control-plane apply failed.' }
        terraform output "-state=$statePath" -json | Out-File -LiteralPath (Join-Path $runRoot 'terraform-outputs.json') -Encoding utf8NoBOM
    }
    finally { Pop-Location }
}
finally { Pop-Location }
