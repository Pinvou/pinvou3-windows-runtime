$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifestPath = Join-Path $repoRoot "windows-runtime.manifest.json"
$temporaryManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("pinvou3-windows-runtime-manifest-" + [System.Guid]::NewGuid().ToString("N") + ".json")

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

try {
  & (Join-Path $PSScriptRoot "update-manifest.ps1") -OutputPath $temporaryManifest

  $expected = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
  $actual = [System.IO.File]::ReadAllText($temporaryManifest, [System.Text.Encoding]::UTF8)
  Assert-True -Condition ($actual -ceq $expected) -Message "Committed Windows runtime manifest is stale or non-deterministic."

  $manifest = $actual | ConvertFrom-Json
  Assert-True -Condition ([int]$manifest.schemaVersion -eq 2) -Message "Windows runtime manifest schema must be 2."

  $asrArchives = @($manifest.managedArchives | Where-Object { [string]$_.component -eq "asr" })
  Assert-True -Condition ($asrArchives.Count -eq 1) -Message "Expected exactly one managed ASR archive."
  $asrModels = @($asrArchives[0].entries | Where-Object { [string]$_.path -match '(?i)\.gguf$' })
  Assert-True -Condition ($asrModels.Count -eq 1) -Message "ASR runtime must contain exactly one bundled GGUF file."
  Assert-True -Condition ([string]$asrModels[0].path -ceq "models/fsmn-vad.gguf") -Message "ASR runtime may bundle only models/fsmn-vad.gguf."

  $stagedPaths = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($manifest.stagedFiles)) {
    $path = [string]$entry.path
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($path)) -Message "Staged file path must not be empty."
    Assert-True -Condition (-not $path.StartsWith('/')) -Message "Staged file path must be relative: $path"
    Assert-True -Condition ($path -notmatch '^[A-Za-z]:') -Message "Staged file path must not contain a drive prefix: $path"
    Assert-True -Condition ($path -notmatch '(^|/)\.\.(/|$)') -Message "Staged file path must not escape its root: $path"
    Assert-True -Condition (-not $stagedPaths.ContainsKey($path)) -Message "Duplicate Windows-insensitive staged path: $path"
    $stagedPaths.Add($path, $true)
  }

  foreach ($entry in @($manifest.files)) {
    Assert-True -Condition ($stagedPaths.ContainsKey([string]$entry.path)) -Message "Source payload is missing from stagedFiles: $($entry.path)"
  }
  foreach ($archive in @($manifest.managedArchives)) {
    foreach ($entry in @($archive.entries)) {
      $path = "expanded/$($archive.component)/$($entry.path)"
      Assert-True -Condition ($stagedPaths.ContainsKey($path)) -Message "Managed archive entry is missing from stagedFiles: $path"
    }
  }

  Write-Host ("Windows runtime manifest contract: ok ({0} staged files)" -f $stagedPaths.Count)
} finally {
  Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
}
