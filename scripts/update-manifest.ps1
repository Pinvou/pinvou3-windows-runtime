param(
  [string]$PayloadRoot = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($PayloadRoot)) {
  $PayloadRoot = Join-Path $repoRoot "payload"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $repoRoot "windows-runtime.manifest.json"
}
if (-not (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
  throw "Windows runtime payload directory not found: $PayloadRoot"
}

function Get-RelativePath {
  param([string]$Root, [string]$Path)
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside payload root: $Path"
  }
  return $full.Substring($prefix.Length).Replace('\', '/')
}

function Get-ComponentName {
  param([string]$RelativePath)
  $first = ($RelativePath -split '/')[0]
  if ($RelativePath -match '^node-') { return "node" }
  if ($RelativePath -match '^python-') { return "python" }
  if ($RelativePath -match '^pandoc-') { return "pandoc" }
  if ($RelativePath -match '^onnxruntime-') { return "onnxruntime" }
  if ($RelativePath -match '^(asr|poppler|tesseract)-runtime\.zip$') { return $Matches[1] }
  return $first
}

function Get-ZipEntrySha256 {
  param([System.IO.Compression.ZipArchiveEntry]$Entry)
  $stream = $Entry.Open()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($stream)
    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Get-ManagedArchiveContents {
  param([string]$ArchivePath, [string]$ManifestPath, [string]$Component)
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $entries = @(
      $zip.Entries |
        Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
        Sort-Object FullName |
        ForEach-Object {
          $entryPath = $_.FullName.Replace('\', '/')
          if ($entryPath.StartsWith('/') -or $entryPath -match '(^|/)\.\.(/|$)') {
            throw "Unsafe entry path in managed component archive ${ManifestPath}: $entryPath"
          }
          [pscustomobject][ordered]@{
            path = $entryPath
            bytes = [long]$_.Length
            sha256 = Get-ZipEntrySha256 -Entry $_
          }
        }
    )
  } finally {
    $zip.Dispose()
  }
  return [pscustomobject][ordered]@{
    archive = $ManifestPath
    component = $Component
    files = $entries.Count
    entries = $entries
  }
}

$files = @(
  Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse -Force |
    ForEach-Object {
      $relative = Get-RelativePath -Root $PayloadRoot -Path $_.FullName
      [pscustomobject][ordered]@{
        path = "payload/$relative"
        component = Get-ComponentName -RelativePath $relative
        bytes = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    } |
    Sort-Object path
)

$components = @(
  $files |
    Group-Object -Property component |
    Sort-Object Name |
    ForEach-Object {
      [ordered]@{
        name = $_.Name
        files = $_.Count
        bytes = [long](($_.Group | ForEach-Object { [long]$_.bytes } | Measure-Object -Sum).Sum)
      }
    }
)

$managedArchives = @(
  $files |
    Where-Object { $_.path -match '^payload/(asr|poppler|tesseract)-runtime\.zip$' } |
    Sort-Object path |
    ForEach-Object {
      $archivePath = Join-Path $repoRoot $_.path.Replace('/', '\')
      Get-ManagedArchiveContents -ArchivePath $archivePath -ManifestPath $_.path -Component $_.component
    }
)

$manifest = [ordered]@{
  schemaVersion = 1
  target = "windows-x86_64"
  sourceLayout = "payload"
  components = $components
  files = $files
  managedArchives = $managedArchives
}

$encoding = New-Object System.Text.UTF8Encoding($false)
$json = ($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").Replace("`r", "`n")
[System.IO.File]::WriteAllText(
  $OutputPath,
  ($json + "`n"),
  $encoding
)

$managedEntryCount = [long](($managedArchives | ForEach-Object { $_.files } | Measure-Object -Sum).Sum)
Write-Host ("Generated Windows runtime manifest: {0} repository files, {1} components, {2} managed archive entries" -f $files.Count, $components.Count, $managedEntryCount)
