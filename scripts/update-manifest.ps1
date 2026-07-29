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
  if ($RelativePath -match '^(7zip|asr|poppler|tesseract)-runtime\.zip$') { return $Matches[1] }
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

function Get-SafeZipEntryPath {
  param([string]$EntryPath, [string]$ManifestPath)

  $normalized = $EntryPath.Replace('\', '/')
  if (
    [string]::IsNullOrWhiteSpace($normalized) -or
    $normalized.StartsWith('/') -or
    $normalized -match '^[A-Za-z]:' -or
    $normalized -match '(^|/)\.\.(/|$)'
  ) {
    throw "Unsafe entry path in archive ${ManifestPath}: $normalized"
  }
  return $normalized
}

function Get-ArchiveFileEntries {
  param([string]$ArchivePath, [string]$ManifestPath)

  $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $seen = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entries = @(
      $zip.Entries |
        Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
        Sort-Object FullName |
        ForEach-Object {
          $entryPath = Get-SafeZipEntryPath -EntryPath $_.FullName -ManifestPath $ManifestPath
          if ($seen.ContainsKey($entryPath)) {
            throw "Duplicate Windows-insensitive entry path in archive ${ManifestPath}: $entryPath"
          }
          $seen.Add($entryPath, $true)
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
  return $entries
}

function Get-ManagedArchiveContents {
  param([string]$ArchivePath, [string]$ManifestPath, [string]$Component)

  $entries = @(Get-ArchiveFileEntries -ArchivePath $ArchivePath -ManifestPath $ManifestPath)
  return [pscustomobject][ordered]@{
    archive = $ManifestPath
    component = $Component
    files = $entries.Count
    entries = $entries
  }
}

function Get-FlattenedArchiveStagedEntries {
  param(
    [string]$ArchivePath,
    [string]$ManifestPath,
    [string]$Component,
    [string]$RequiredFile,
    [switch]$OnnxOnly
  )

  $entries = @(Get-ArchiveFileEntries -ArchivePath $ArchivePath -ManifestPath $ManifestPath)
  $requiredMatches = @(
    $entries | Where-Object { (($_.path -split '/')[-1]) -ieq $RequiredFile }
  )
  if ($requiredMatches.Count -ne 1) {
    throw "Expected exactly one ${RequiredFile} in archive ${ManifestPath}, found $($requiredMatches.Count)."
  }

  $requiredPath = [string]$requiredMatches[0].path
  $separator = $requiredPath.LastIndexOf('/')
  $prefix = if ($separator -ge 0) { $requiredPath.Substring(0, $separator + 1) } else { "" }
  $selected = @(
    $entries | Where-Object {
      ([string]$_.path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
  )
  if ($OnnxOnly) {
    $selected = @(
      $selected | Where-Object {
        $name = ([string]$_.path -split '/')[-1]
        $name -ieq $RequiredFile -or $name -ieq "onnxruntime_providers_shared.dll"
      }
    )
  }

  return @(
    $selected | ForEach-Object {
      $relativePath = ([string]$_.path).Substring($prefix.Length)
      [pscustomobject][ordered]@{
        path = "expanded/$Component/$relativePath"
        bytes = [long]$_.bytes
        sha256 = [string]$_.sha256
      }
    }
  )
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
    Where-Object { $_.path -match '^payload/(7zip|asr|poppler|tesseract)-runtime\.zip$' } |
    Sort-Object path |
    ForEach-Object {
      $archivePath = Join-Path $repoRoot $_.path.Replace('/', '\')
      Get-ManagedArchiveContents -ArchivePath $archivePath -ManifestPath $_.path -Component $_.component
    }
)

$asrArchive = @($managedArchives | Where-Object { $_.component -eq "asr" })
if ($asrArchive.Count -ne 1) {
  throw "Windows runtime manifest must contain exactly one managed ASR archive."
}
$asrModels = @($asrArchive[0].entries | Where-Object { [string]$_.path -match '(?i)\.gguf$' })
if ($asrModels.Count -ne 1 -or [string]$asrModels[0].path -ne "models/fsmn-vad.gguf") {
  throw "ASR runtime must bundle only models/fsmn-vad.gguf; recognition models are downloaded on demand."
}

$flattenedArchiveSpecs = @(
  [pscustomobject]@{ pattern = '^payload/node-.+-win-x64\.zip$'; component = 'node'; requiredFile = 'node.exe'; onnxOnly = $false },
  [pscustomobject]@{ pattern = '^payload/python-.+-embed-amd64\.zip$'; component = 'python'; requiredFile = 'pythonw.exe'; onnxOnly = $false },
  [pscustomobject]@{ pattern = '^payload/pandoc-.+-windows-x86_64\.zip$'; component = 'pandoc'; requiredFile = 'pandoc.exe'; onnxOnly = $false },
  [pscustomobject]@{ pattern = '^payload/onnxruntime-win-x64-.+-runtime\.zip$'; component = 'onnxruntime'; requiredFile = 'onnxruntime.dll'; onnxOnly = $true }
)

$stagedFiles = @(
  $files | ForEach-Object {
    [pscustomobject][ordered]@{
      path = [string]$_.path
      bytes = [long]$_.bytes
      sha256 = [string]$_.sha256
    }
  }
  $managedArchives | ForEach-Object {
    $component = [string]$_.component
    $_.entries | ForEach-Object {
      [pscustomobject][ordered]@{
        path = "expanded/$component/$($_.path)"
        bytes = [long]$_.bytes
        sha256 = [string]$_.sha256
      }
    }
  }
  $flattenedArchiveSpecs | ForEach-Object {
    $spec = $_
    $archiveMatches = @($files | Where-Object { [string]$_.path -match [string]$spec.pattern })
    if ($archiveMatches.Count -ne 1) {
      throw "Expected exactly one $($spec.component) archive, found $($archiveMatches.Count)."
    }
    $archiveManifestPath = [string]$archiveMatches[0].path
    $archivePath = Join-Path $repoRoot $archiveManifestPath.Replace('/', '\')
    Get-FlattenedArchiveStagedEntries `
      -ArchivePath $archivePath `
      -ManifestPath $archiveManifestPath `
      -Component ([string]$spec.component) `
      -RequiredFile ([string]$spec.requiredFile) `
      -OnnxOnly:([bool]$spec.onnxOnly)
  }
)

$stagedPathIndex = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $stagedFiles) {
  $stagedPath = [string]$entry.path
  if ($stagedPathIndex.ContainsKey($stagedPath)) {
    throw "Duplicate Windows-insensitive staged file path: $stagedPath"
  }
  $stagedPathIndex.Add($stagedPath, $true)
}
$stagedFiles = @($stagedFiles | Sort-Object path)

$manifest = [ordered]@{
  schemaVersion = 2
  target = "windows-x86_64"
  sourceLayout = "payload"
  components = $components
  files = $files
  managedArchives = $managedArchives
  stagedFiles = $stagedFiles
}

$encoding = New-Object System.Text.UTF8Encoding($false)
$json = ($manifest | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").Replace("`r", "`n")
[System.IO.File]::WriteAllText(
  $OutputPath,
  ($json + "`n"),
  $encoding
)

$managedEntryCount = [long](($managedArchives | ForEach-Object { $_.files } | Measure-Object -Sum).Sum)
Write-Host ("Generated Windows runtime manifest: {0} repository files, {1} components, {2} managed archive entries, {3} staged files" -f $files.Count, $components.Count, $managedEntryCount, $stagedFiles.Count)
