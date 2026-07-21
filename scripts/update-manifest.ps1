param(
  [string]$PayloadRoot = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

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

$manifest = [ordered]@{
  schemaVersion = 1
  target = "windows-x86_64"
  sourceLayout = "payload"
  components = $components
  files = $files
}

$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
  $OutputPath,
  (($manifest | ConvertTo-Json -Depth 8) + "`n"),
  $encoding
)

Write-Host ("Generated Windows runtime manifest: {0} files, {1} components" -f $files.Count, $components.Count)
