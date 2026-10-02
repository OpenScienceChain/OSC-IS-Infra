function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^[A-Za-z]:\\') { throw "Unsupported WSL path: $fullPath" }
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $remainder = $fullPath.Substring(2).Replace('\', '/')
    return "/mnt/$drive$remainder"
}
