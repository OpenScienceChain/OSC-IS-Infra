[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{8,20}$')]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$generatedRoot = (Resolve-Path (Join-Path $repoRoot 'platform\.generated')).Path
$targets = @(
    (Join-Path $generatedRoot "aws\$RunId"),
    (Join-Path $generatedRoot 'fabric-network-eks\build')
)
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$allowedSids = @(
    $currentSid,
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
)
$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$expectedSids = @($allowedSids | ForEach-Object { $_.Value })

foreach ($target in $targets) {
    $root = (Resolve-Path -LiteralPath $target).Path
    if (-not $root.StartsWith($generatedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to change ACLs outside $generatedRoot"
    }
    $entries = @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse point in runtime directory: $($entry.FullName)"
        }
    }
    foreach ($entry in $entries) {
        $grant = if ($entry.PSIsContainer) { '(OI)(CI)F' } else { 'F' }
        & icacls.exe $entry.FullName /grant:r "${account}:$grant" "*S-1-5-18:$grant" "*S-1-5-32-544:$grant" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ACL grant failed: $($entry.FullName)" }
        & icacls.exe $entry.FullName /inheritance:r | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ACL inheritance removal failed: $($entry.FullName)" }
    }
    foreach ($entry in $entries) {
        $rules = @((Get-Acl -LiteralPath $entry.FullName).Access)
        if ($rules.Count -ne 3) { throw "Unexpected number of ACL rules: $($entry.FullName)" }
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($sid -notin $expectedSids -or $rule.IsInherited -or
                $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Unexpected ACL rule: $($entry.FullName)"
            }
        }
    }
    Write-Host "Protected $($entries.Count) runtime paths under $root"
}
