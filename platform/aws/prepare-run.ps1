[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}/32$')]
    [string]$AdminCidr,

    [ValidateRange(1, 72)]
    [int]$Hours = 72,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\s]+@sha256:[0-9a-f]{64}$')]
    [string]$AlbControllerImage,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RuntimeRoleArnsPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$terraformRoot = Join-Path $repoRoot 'terraform\usrse26-eks'
$runRoot = Join-Path $repoRoot "platform\.generated\aws\$RunId"
$planPath = Join-Path $runRoot 'reviewed.tfplan'
$planJsonPath = Join-Path $runRoot 'reviewed-plan.json'
$tfvarsPath = Join-Path $runRoot 'run.tfvars'
$baselinePath = Join-Path $runRoot 'baseline-inventory.json'
$costPath = Join-Path $runRoot 'cost-estimate.json'
$metadataPath = Join-Path $runRoot 'run-metadata.json'

if ($AdminCidr -eq '0.0.0.0/32' -or $AdminCidr -eq '0.0.0.0/0') {
    throw 'AdminCidr must identify one trusted public IPv4 address.'
}

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$startedAt = [DateTimeOffset]::UtcNow
$expiresAt = $startedAt.AddHours($Hours)
$runtimeRoleArnsJson = Get-Content -LiteralPath $RuntimeRoleArnsPath -Raw
$runtimeRoleArns = $runtimeRoleArnsJson | ConvertFrom-Json
$requiredRuntimeRoles = @(
    'eks_cluster', 'eks_nodes', 'alb_controller', 'api_gateway', 'postgres',
    'submission_worker', 'submission_listener', 'ledger_gateway_nsg',
    'ledger_gateway_citizen_science', 'ebs_csi'
)
foreach ($roleKey in $requiredRuntimeRoles) {
    $roleArn = [string]$runtimeRoleArns.$roleKey
    $expectedSuffix = $roleKey.Replace('_', '-')
    if ($roleArn -notmatch "^arn:aws:iam::269624229733:role/osc-usrse26-$RunId-$expectedSuffix$") {
        throw "RuntimeRoleArnsPath contains an invalid or cross-run role for $roleKey."
    }
}
$runtimeRoleArnsJson = $runtimeRoleArns | ConvertTo-Json -Compress

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py
    python platform/aws/inventory.py --output $baselinePath
    python platform/aws/estimate_cost.py --hours $Hours --output $costPath

    $tfvars = @(
        "run_id = `"$RunId`""
        "expires_at = `"$($expiresAt.ToString('o'))`""
        "admin_cidr = `"$AdminCidr`""
        "runner_public_cidr = `"$AdminCidr`""
        "maximum_runtime_hours = $Hours"
        "alb_controller_image = `"$AlbControllerImage`""
        "runtime_role_arns = $runtimeRoleArnsJson"
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($tfvarsPath, $tfvars + [Environment]::NewLine)

    $metadata = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        startedAt = $startedAt.ToString('o')
        expiresAt = $expiresAt.ToString('o')
        maximumHours = $Hours
        account = '269624229733'
        profile = 'default'
        region = 'us-west-2'
        status = 'PLANNED'
    }
    [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json) + [Environment]::NewLine)

    Push-Location $terraformRoot
    try {
        terraform init -input=false -reconfigure `
            "-backend-config=bucket=osc-usrse26-$RunId-control-269624229733" `
            "-backend-config=key=runtime-state/$RunId/terraform.tfstate" `
            '-backend-config=region=us-west-2' `
            "-backend-config=dynamodb_table=osc-usrse26-$RunId-terraform-locks" `
            '-backend-config=encrypt=true'
        if ($LASTEXITCODE -ne 0) { throw 'Terraform backend initialization failed.' }
        terraform validate
        if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed.' }
        python (Join-Path $repoRoot 'platform/aws/aws_guard.py')
        $runtimeRepositories = @(
            'api-gateway',
            'chaincode',
            'gitops-repository',
            'history-worker',
            'ledger-gateway',
            'submission-listener',
            'submission-worker',
            'webapp'
        )
        $stateEntries = @(terraform state list 2>$null)
        foreach ($name in $runtimeRepositories) {
            $address = 'aws_ecr_repository.experiment["{0}"]' -f $name
            if ($stateEntries -notcontains $address) {
                terraform import -input=false "-var-file=$tfvarsPath" `
                    $address "osc-usrse26-$RunId/$name"
                if ($LASTEXITCODE -ne 0) { throw "Could not import the exact runtime repository for $name." }
            }
        }
        $planArgs = @(
            'plan'
            '-input=false'
            '-lock=true'
            "-var-file=$tfvarsPath"
            "-out=$planPath"
        )
        & terraform @planArgs
        if ($LASTEXITCODE -ne 0) { throw 'Terraform plan failed.' }
        $planJson = & terraform show -json $planPath
        if ($LASTEXITCODE -ne 0) { throw 'Terraform plan serialization failed.' }
        [IO.File]::WriteAllText($planJsonPath, ($planJson -join [Environment]::NewLine))
    }
    finally {
        Pop-Location
    }

    python platform/aws/check_terraform_plan.py $planJsonPath
    if ($LASTEXITCODE -ne 0) { throw 'Terraform plan policy check failed.' }
    Write-Host "AWS evidence plan is ready for review: $planPath"
    Write-Host "It expires at $($expiresAt.ToString('o')); do not apply it after that time."
}
finally {
    Pop-Location
}
