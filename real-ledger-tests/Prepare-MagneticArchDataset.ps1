[CmdletBinding()]
param(
  [string]$Output = (Join-Path $PSScriptRoot '.generated\magnetic-arch-manifest.json'),
  [string]$CacheDir = (Join-Path $PSScriptRoot '.generated\dataset')
)

$ErrorActionPreference = 'Stop'
$generatedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.generated'))
$outputPath = [IO.Path]::GetFullPath($Output)
$cachePath = [IO.Path]::GetFullPath($CacheDir)
foreach ($path in @($outputPath, $cachePath)) {
  if (-not $path.StartsWith($generatedRoot + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Dataset preparation must stay inside the ignored .generated directory'
  }
}
if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite $outputPath" }

Add-Type -AssemblyName System.IO.Compression
$files = @(
  @{ Name = 'S0-RPA.zip'; Size = 153604; Md5 = '79ee342cda0638b5f2383d436b17d133'; Code = 'S0'; Count = 21; Title = 'S0 - single ECR source without applied magnetic field' },
  @{ Name = 'S1-RPA.zip'; Size = 176516; Md5 = 'f1f0409fadd232027d2901d5a4745a53'; Code = 'S1'; Count = 21; Title = 'S1 - single ECR source with applied magnetic field' },
  @{ Name = 'D0-RPA.zip'; Size = 80723; Md5 = '034ab94546311ff875921899ddb5fc91'; Code = 'D0'; Count = 11; Title = 'D0 - ECR source cluster without applied magnetic field' },
  @{ Name = 'DA-RPA.zip'; Size = 99362; Md5 = '9a33a8459bda798d1542001247f707b8'; Code = 'DA'; Count = 13; Title = 'DA - ECR source cluster with opposed magnetic polarity' },
  @{ Name = 'DB-RPA.zip'; Size = 102068; Md5 = '5bdcc6559ab536433d879be06179de91'; Code = 'DB'; Count = 13; Title = 'DB - ECR source cluster with same magnetic polarity' },
  @{ Name = 'DA_FC.txt'; Size = 870; Md5 = 'e199d107e13f769ee56b48d775ebb9da'; Code = 'DA' }
)

function Assert-SourceFile([hashtable]$item, [string]$path) {
  $actualSize = (Get-Item -LiteralPath $path).Length
  $actualMd5 = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash.ToLowerInvariant()
  if ($actualSize -ne $item.Size -or $actualMd5 -ne $item.Md5) {
    throw "Zenodo source checksum or size changed: $($item.Name)"
  }
}

function Get-EntryHash([IO.Stream]$stream) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() }
  finally { $sha.Dispose() }
}

New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
$downloaded = [System.Collections.Generic.List[string]]::new()
try {
  foreach ($item in $files) {
    $path = Join-Path $cachePath $item.Name
    if (-not (Test-Path -LiteralPath $path)) {
      $url = "https://zenodo.org/api/records/13987138/files/$($item.Name)/content"
      & curl.exe -L --fail --silent --show-error --output $path $url
      if ($LASTEXITCODE -ne 0) { throw "Could not download $($item.Name)" }
      $downloaded.Add($path)
    }
    Assert-SourceFile $item $path
  }

  $artifacts = @()
  foreach ($archive in ($files | Where-Object { $_.Name.EndsWith('.zip') })) {
    $path = Join-Path $cachePath $archive.Name
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
      $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
      if ($entries.Count -ne $archive.Count -or $entries.Count -gt 50) {
        throw "Unexpected measurement count in $($archive.Name)"
      }
      $measurements = @()
      foreach ($entry in $entries) {
        $name = $entry.FullName
        if ($name -notmatch "^$($archive.Code)_[A-Za-z0-9_-]+\.csv$" -or
            $entry.Length -lt 1 -or $entry.Length -gt 100000) {
          throw "Unexpected ZIP entry in $($archive.Name): $name"
        }
        $stream = $entry.Open()
        try { $hash = Get-EntryHash $stream }
        finally { $stream.Dispose() }
        $angle = if ($name -match '_(-?\d+)_?deg') { [int]$Matches[1] }
          elseif ($name -match '_(-?\d+)deg') { [int]$Matches[1] }
          else { throw "Angle label missing from $name" }
        $measurements += [ordered]@{
          filename = $name
          hash = $hash
          algorithm = 'sha256'
          sizeBytes = [int]$entry.Length
          angleDegrees = $angle
          probe = 'RPA'
        }
      }
      if ($archive.Code -eq 'DA') {
        $fc = $files | Where-Object { $_.Name -eq 'DA_FC.txt' }
        $fcPath = Join-Path $cachePath $fc.Name
        $stream = [IO.File]::OpenRead($fcPath)
        try { $fcHash = Get-EntryHash $stream }
        finally { $stream.Dispose() }
        $measurements += [ordered]@{
          filename = $fc.Name
          hash = $fcHash
          algorithm = 'sha256'
          sizeBytes = [int]$fc.Size
          angleDegrees = $null
          probe = 'FC'
        }
      }
      $measurements = @($measurements | Sort-Object filename)
      $totalBytes = [long](($measurements | ForEach-Object { $_['sizeBytes'] } | Measure-Object -Sum).Sum)
      if ($totalBytes -gt 10MB) { throw "Configuration exceeds artifact limit: $($archive.Code)" }
      $fingerprintLines = @($measurements | ForEach-Object { "$($_.filename)`t$($_.hash)" })
      $fingerprintBytes = [Text.Encoding]::UTF8.GetBytes(($fingerprintLines -join "`n"))
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $footprint = [Convert]::ToHexString($sha.ComputeHash($fingerprintBytes)).ToLowerInvariant() }
      finally { $sha.Dispose() }
      $artifacts += [ordered]@{
        code = $archive.Code
        title = $archive.Title
        footprint = $footprint
        sizeBytes = $totalBytes
        measurements = $measurements
      }
    } finally { $zip.Dispose() }
  }

  $allMeasurements = [int](($artifacts | ForEach-Object { $_.measurements.Count } | Measure-Object -Sum).Sum)
  if ($artifacts.Count -ne 5 -or $allMeasurements -ne 80) {
    throw "Expected 5 configurations and 80 source files, found $($artifacts.Count) and $allMeasurements"
  }
  $outputData = [ordered]@{
    sourceUrl = 'https://zenodo.org/records/13987138'
    sourceDoi = '10.5281/zenodo.13987138'
    sourceArchiveChecksums = @($files | ForEach-Object { [ordered]@{ filename = $_.Name; md5 = $_.Md5; sizeBytes = $_.Size } })
    footprintAlgorithm = 'sha256 of filename, tab, sha256 hash for each file, sorted by filename and joined by newline'
    fileCount = $allMeasurements
    artifacts = $artifacts
  }
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputPath)) -Force | Out-Null
  [IO.File]::WriteAllText($outputPath,
    ($outputData | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
  Write-Output "Verified $allMeasurements source files across $($artifacts.Count) configurations."
  Write-Output "Hash-only manifest: $outputPath"
} finally {
  foreach ($path in $downloaded) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
  }
}
