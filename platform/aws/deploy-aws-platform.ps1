[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$infraRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runRoot = Join-Path $infraRoot "platform\.generated\aws\$RunId"
$statePath = Join-Path $runRoot 'terraform.tfstate'
$artifactManifestPath = Join-Path $runRoot 'artifacts\artifacts.json'
$deploymentPath = Join-Path $runRoot 'artifacts\ecr-deployment.json'
$gitSource = Join-Path $runRoot 'gitops-source'
$bootstrapOutput = Join-Path $runRoot 'gitops-bootstrap'
$network = Join-Path $infraRoot 'platform\.generated\fabric-network-eks'
$context = "osc-usrse26-$RunId"
$cluster = "osc-usrse26-$RunId-eks"
$gitBash = 'C:\Program Files\Git\bin\bash.exe'

foreach ($required in @($statePath, $artifactManifestPath, $deploymentPath, $gitBash, (Join-Path $network 'network'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing deployment input: $required" }
}

$artifacts = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json
$deployed = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
if ($artifacts.runId -ne $RunId -or $deployed.runId -ne $RunId) { throw 'AWS artifact run ID mismatch.' }

Push-Location $infraRoot
$portForward = $null
try {
    python platform/aws/aws_guard.py
    aws eks update-kubeconfig --name $cluster --alias $context --profile default --region us-west-2 --no-cli-pager | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the guarded EKS context.' }
    if ((kubectl config current-context).Trim() -ne $context) { throw 'Unexpected kubectl context after EKS configuration.' }
    kubectl get nodes | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'EKS nodes are unavailable.' }

    kubectl apply -f (Join-Path $gitSource 'manifests\storage-class.yaml') | Out-Null
    kubectl create namespace osc-fabric --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    kubectl label namespace osc-fabric `
        pod-security.kubernetes.io/enforce=baseline `
        pod-security.kubernetes.io/audit=restricted `
        pod-security.kubernetes.io/warn=restricted `
        --overwrite | Out-Null

    $env:TEST_NETWORK_CLUSTER_RUNTIME = 'eks'
    $env:TEST_NETWORK_CLUSTER_NAME = $cluster
    $env:TEST_NETWORK_KUBE_NAMESPACE = 'osc-fabric'
    $env:TEST_NETWORK_DOMAIN = 'localho.st'
    $env:TEST_NETWORK_NGINX_HTTPS_PORT = '18443'
    Push-Location $network
    try {
        & $gitBash ./network cluster init
        if ($LASTEXITCODE -ne 0) { throw 'Fabric cluster prerequisites failed.' }
    }
    finally {
        Pop-Location
    }

    $pfOut = Join-Path $runRoot 'fabric-port-forward.out.log'
    $pfErr = Join-Path $runRoot 'fabric-port-forward.err.log'
    $portForward = Start-Process `
        -FilePath (Get-Command kubectl).Source `
        -ArgumentList @('-n', 'ingress-nginx', 'port-forward', 'service/ingress-nginx-controller', '18443:443') `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $pfOut `
        -RedirectStandardError $pfErr
    Start-Sleep -Seconds 5
    if ($portForward.HasExited) { throw "Fabric ingress port-forward exited early; inspect $pfErr" }

    $env:RUN_ID = $RunId
    $env:CHAINCODE_IMAGE = $deployed.references.chaincode
    & $gitBash (Join-Path $infraRoot 'platform/scripts/deploy_aws_fabric.sh')
    if ($LASTEXITCODE -ne 0) { throw 'Fabric deployment failed.' }

    python platform/aws/aws_guard.py | Out-Null
    python platform/aws/upload_fabric_identities.py --network $network --run-id $RunId
    if ($LASTEXITCODE -ne 0) { throw 'Fabric identity upload failed.' }

    $rabbitEndpoint = terraform -chdir=terraform/usrse26-eks output -raw -state=$statePath rabbitmq_amqps_endpoint
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the private broker endpoint.' }
    $rabbitUri = [Uri]$rabbitEndpoint.Trim()
    if ($rabbitUri.Scheme -ne 'amqps' -or $rabbitUri.Port -ne 5671) { throw 'Terraform returned an unexpected broker endpoint.' }

    kubectl create namespace osc-apps --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    kubectl label namespace osc-apps `
        app.kubernetes.io/part-of=osc-is `
        pod-security.kubernetes.io/enforce=restricted `
        pod-security.kubernetes.io/audit=restricted `
        pod-security.kubernetes.io/warn=restricted `
        --overwrite | Out-Null
    kubectl -n osc-apps create configmap aws-runtime-endpoints `
        --from-literal="rabbitmq-host=$($rabbitUri.Host)" `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    kubectl label namespace argocd `
        pod-security.kubernetes.io/enforce=privileged `
        pod-security.kubernetes.io/audit=restricted `
        pod-security.kubernetes.io/warn=restricted `
        --overwrite | Out-Null
    kubectl apply --server-side --force-conflicts -n argocd -f platform/vendor/argocd-install-v3.5.2.yaml | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Argo CD installation failed.' }
    kubectl wait -n argocd deployment --all --for=condition=Available --timeout=10m | Out-Null
    kubectl rollout status -n argocd statefulset/argocd-application-controller --timeout=10m | Out-Null

    python platform/scripts/render_gitops_bootstrap.py `
        --bootstrap platform/gitops/bootstrap `
        --destination $bootstrapOutput `
        --repository-image $deployed.references.'gitops-repository' `
        --baseline-revision $artifacts.gitops.baselineRevision `
        --rollout-revision $artifacts.gitops.rolloutRevision
    if ($LASTEXITCODE -ne 0) { throw 'Argo CD bootstrap rendering failed.' }
    kubectl apply -f (Join-Path $bootstrapOutput 'repository-server.yaml') | Out-Null
    kubectl rollout status -n argocd deployment/osc-gitops-repository --timeout=5m | Out-Null
    kubectl apply -f (Join-Path $bootstrapOutput 'application.yaml') | Out-Null

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
    do {
        Start-Sleep -Seconds 10
        $sync = (kubectl -n argocd get application osc-is-aws -o jsonpath='{.status.sync.status}').Trim()
        $health = (kubectl -n argocd get application osc-is-aws -o jsonpath='{.status.health.status}').Trim()
        Write-Host "Argo CD: sync=$sync health=$health"
    } while (($sync -ne 'Synced' -or $health -ne 'Healthy') -and [DateTimeOffset]::UtcNow -lt $deadline)
    if ($sync -ne 'Synced' -or $health -ne 'Healthy') { throw 'Argo CD did not reach Synced and Healthy.' }

    kubectl -n osc-apps rollout status statefulset/postgres --timeout=10m | Out-Null
    foreach ($deployment in @('api-gateway', 'ledger-gateway-nsg', 'ledger-gateway-citizen-science', 'submission-worker', 'submission-listener')) {
        kubectl -n osc-apps rollout status "deployment/$deployment" --timeout=10m | Out-Null
    }
    kubectl get nodes -o wide
    kubectl get pods -A -o wide
    Write-Host 'EKS, Fabric, Amazon MQ, Argo CD, and OSC-IS workloads are ready.'
}
finally {
    if ($portForward -and -not $portForward.HasExited) {
        Stop-Process -Id $portForward.Id -Force
        $portForward.WaitForExit()
    }
    Pop-Location
}
