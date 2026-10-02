[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cluster = "osc-usrse26-$RunId-eks"
$context = "osc-usrse26-$RunId"
$namespaces = @('osc-apps', 'osc-fabric', 'argocd', 'ingress-nginx', 'cert-manager')

Push-Location $repoRoot
try {
    python platform/aws/aws_guard.py | Out-Null
    $clusters = aws eks list-clusters `
        --profile default `
        --region us-west-2 `
        --output json `
        --no-cli-pager | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect EKS clusters before workload cleanup.' }

    if ($cluster -in @($clusters.clusters)) {
        aws eks update-kubeconfig `
            --name $cluster `
            --alias $context `
            --profile default `
            --region us-west-2 `
            --no-cli-pager | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the guarded teardown context.' }

        $applicationCrd = kubectl --context $context get crd applications.argoproj.io `
            --ignore-not-found=true `
            -o name
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Argo CD application definition.' }
        if (-not [string]::IsNullOrWhiteSpace([string]$applicationCrd)) {
            kubectl --context $context -n argocd delete application osc-is-aws `
                --ignore-not-found=true `
                --wait=true `
                --timeout=5m | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not remove the Argo CD application cleanly.' }
        }

        foreach ($namespace in $namespaces) {
            kubectl --context $context delete namespace $namespace `
                --ignore-not-found=true `
                --wait=true `
                --timeout=10m | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Namespace $namespace did not terminate; refusing to destroy the cluster first."
            }
        }
    }

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
    do {
        python platform/aws/aws_guard.py | Out-Null
        $volumeData = aws ec2 describe-volumes `
            --filters `
                "Name=tag:RunId,Values=$RunId" `
                'Name=tag:Project,Values=OSC-IS' `
                'Name=tag:Purpose,Values=USRSE26-Evidence' `
                'Name=tag:Environment,Values=ephemeral' `
                'Name=tag:ManagedBy,Values=EKS-EBS-CSI' `
            --profile default `
            --region us-west-2 `
            --output json `
            --no-cli-pager | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect task-created EBS volumes.' }
        $volumes = @($volumeData.Volumes)
        if ($volumes.Count -gt 0) { Start-Sleep -Seconds 15 }
    } while ($volumes.Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $deadline)

    foreach ($volume in $volumes) {
        if ($volume.State -ne 'available') {
            throw "Task-created EBS volume $($volume.VolumeId) is still $($volume.State)."
        }
        python platform/aws/aws_guard.py | Out-Null
        aws ec2 delete-volume `
            --volume-id $volume.VolumeId `
            --profile default `
            --region us-west-2 `
            --no-cli-pager
        if ($LASTEXITCODE -ne 0) { throw "Could not delete task-created EBS volume $($volume.VolumeId)." }
        aws ec2 wait volume-deleted `
            --volume-ids $volume.VolumeId `
            --profile default `
            --region us-west-2 `
            --no-cli-pager
        if ($LASTEXITCODE -ne 0) { throw "EBS volume $($volume.VolumeId) did not finish deleting." }
    }

    Write-Host 'Kubernetes workloads and task-created persistent volumes are removed.'
}
finally {
    Pop-Location
}
