<#
.SYNOPSIS
    Build a sanitized, portable ZIP of the AppDynamics Agent Automation framework
    on Windows, ready to transfer to and unzip on a Linux control node.

.DESCRIPTION
    - Copies the framework to a clean staging folder, EXCLUDING secrets, client
      data, run artifacts, and build cruft (see $Exclude).
    - Normalizes line endings to LF on shell/YAML/config text so the scripts run
      correctly on Linux (Windows zips otherwise carry CRLF).
    - Includes the offline Ansible collection bundle if present
      (packaging/offline-collections/), so the target site needs no internet.
    - Produces appd-agent-automation-<Version>.zip with a single top-level folder.
      The extraction location BECOMES the project root - all paths are relative,
      so nothing needs editing after unzip. Run packaging/bootstrap.sh next.

.EXAMPLE
    # From the repo root, in PowerShell:
    .\packaging\Package-Framework.ps1 -Version 1.0.0

.EXAMPLE
    # Include the Word runbook + decks under docs/ in the package:
    .\packaging\Package-Framework.ps1 -Version 1.0.0 -IncludeDocs
#>
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$OutDir,
    [string]$Version = "1.0.0",
    [switch]$IncludeDocs
)

$ErrorActionPreference = "Stop"

# Resolve roots -------------------------------------------------------------
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }   # repo root = parent of packaging/
if (-not $OutDir)     { $OutDir = Join-Path $SourceRoot "dist" }
$PkgName  = "appd-agent-automation"
$Stage    = Join-Path ([System.IO.Path]::GetTempPath()) ("appdpkg_" + [Guid]::NewGuid().ToString("N"))
$PkgRoot  = Join-Path $Stage $PkgName
$ZipPath  = Join-Path $OutDir ("$PkgName-$Version.zip")

# Paths to EXCLUDE (relative, forward-slash). Secrets + client data + cruft. ---
$Exclude = @(
    ".git", ".gitignore",
    "artifacts",                       # run logs/reports
    "collections",                     # installed collections (offline bundle is kept)
    "node_modules", "dist",
    "client_config/active.yml",        # client-specific (sanitized out)
    "inventory/group_vars/vault.yml",  # secrets
    ".vault_pass"
)
# Any client_config/*.yml that is NOT the example is also excluded (extra safety).

# Text extensions to convert CRLF -> LF --------------------------------------
$TextExt = @(".sh", ".yml", ".yaml", ".j2", ".cfg", ".md", ".txt")

Write-Host "==> Source : $SourceRoot"
Write-Host "==> Staging: $PkgRoot"
New-Item -ItemType Directory -Force -Path $PkgRoot | Out-Null

function Test-Excluded {
    param([string]$Rel)
    $r = $Rel -replace "\\", "/"
    foreach ($e in $Exclude) { if ($r -eq $e -or $r -like "$e/*") { return $true } }
    # exclude any client_config/*.yml except the example template
    if ($r -like "client_config/*.yml" -and $r -ne "client_config/example.client.yml") { return $true }
    # exclude generated binaries unless -IncludeDocs
    if (-not $IncludeDocs -and ($r -like "*.pptx" -or $r -like "*.docx" -or $r -like "*.png" -or $r -like "*.xlsx")) { return $true }
    return $false
}

# Copy tree with exclusions ---------------------------------------------------
$srcItems = Get-ChildItem -Path $SourceRoot -Recurse -File
foreach ($item in $srcItems) {
    $rel = $item.FullName.Substring($SourceRoot.Length).TrimStart("\","/")
    if (Test-Excluded $rel) { continue }
    $dest = Join-Path $PkgRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if ($TextExt -contains $item.Extension.ToLower()) {
        # normalize to LF, write UTF8 (no BOM)
        $content = [System.IO.File]::ReadAllText($item.FullName)
        $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($dest, $content, $utf8NoBom)
    } else {
        Copy-Item -Path $item.FullName -Destination $dest -Force
    }
}

# Optionally place docs (runbook/decks) under docs/ --------------------------
if ($IncludeDocs) {
    $docDest = Join-Path $PkgRoot "docs"
    New-Item -ItemType Directory -Force -Path $docDest | Out-Null
    Get-ChildItem -Path $SourceRoot -File | Where-Object { $_.Extension -in ".docx",".pptx" } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $docDest $_.Name) -Force }
}

# Warn if offline collection bundle is missing -------------------------------
if (-not (Test-Path (Join-Path $PkgRoot "packaging/offline-collections/requirements.yml"))) {
    Write-Warning "No offline collection bundle found. For an air-gapped site, first run"
    Write-Warning "  bash packaging/download_collections.sh   (on an internet-connected host),"
    Write-Warning "  then re-run this packager so collections are bundled."
}

# Write a build manifest -----------------------------------------------------
$manifest = @"
package   : $PkgName
version   : $Version
built_utc : $((Get-Date).ToUniversalTime().ToString("o"))
built_by  : $env:USERNAME@$env:COMPUTERNAME
notes     : Sanitized package - no secrets, no client_config/active.yml, no vault.
            Extract anywhere; that folder is the project root. Run packaging/bootstrap.sh.
"@
Set-Content -Path (Join-Path $PkgRoot "PACKAGE_MANIFEST.txt") -Value $manifest -Encoding utf8

# Zip ------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Write-Host "==> Compressing -> $ZipPath"
Compress-Archive -Path $PkgRoot -DestinationPath $ZipPath -CompressionLevel Optimal

# Checksum -------------------------------------------------------------------
$sha = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
Set-Content -Path ("$ZipPath.sha256") -Value "$sha  $(Split-Path -Leaf $ZipPath)" -Encoding ascii

# Cleanup staging ------------------------------------------------------------
Remove-Item -Recurse -Force $Stage

Write-Host ""
Write-Host "Package : $ZipPath"
Write-Host "SHA256  : $sha"
Write-Host "Transfer the .zip to the Linux control node, unzip, then run:"
Write-Host "    cd $PkgName && bash packaging/bootstrap.sh"
