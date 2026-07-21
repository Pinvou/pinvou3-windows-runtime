param(
  [Parameter(Mandatory = $true)]
  [string]$SourceDirectory,
  [Parameter(Mandatory = $true)]
  [string]$OutputPath,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$sourceRoot = (Resolve-Path $SourceDirectory).Path
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
  throw "Component source directory not found: $sourceRoot"
}
if ((Test-Path -LiteralPath $outputFullPath) -and -not $Force) {
  throw "Component archive already exists; pass -Force to replace it: $outputFullPath"
}

$files = @(
  Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force |
    Sort-Object {
      $_.FullName.Substring($sourceRoot.TrimEnd('\').Length + 1).Replace('\', '/')
    }
)
if ($files.Count -eq 0) {
  throw "Component source directory is empty: $sourceRoot"
}

$parent = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temporary = "$outputFullPath.tmp-$([System.Guid]::NewGuid().ToString('N'))"
try {
  $fileStream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew)
  try {
    $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
      foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.TrimEnd('\').Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $input = [System.IO.File]::OpenRead($file.FullName)
        $output = $entry.Open()
        try {
          $input.CopyTo($output)
        } finally {
          $output.Dispose()
          $input.Dispose()
        }
      }
    } finally {
      $archive.Dispose()
    }
  } finally {
    $fileStream.Dispose()
  }
  Move-Item -LiteralPath $temporary -Destination $outputFullPath -Force
} finally {
  Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$bytes = (Get-Item -LiteralPath $outputFullPath).Length
Write-Host ("Packed component: {0} files, {1:N2} MiB" -f $files.Count, ($bytes / 1MB))
Write-Host ("SHA-256: {0}" -f $hash)
Write-Host ("Output: {0}" -f $outputFullPath)
