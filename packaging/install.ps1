#Requires -Version 5.1
<#
.SYNOPSIS
  Install dub-publish to a per-user Programs folder and add it to User PATH.

.DESCRIPTION
  Default install root: %LOCALAPPDATA%\Programs\dlang-supplemental\dub-publish
  Copies dub-publish.exe (and LICENSE if present), updates User PATH, refreshes
  the current session Path. Does not migrate DPAPI credentials — run
  `dub-publish login --user … --save-credentials` after install/upgrade.

.PARAMETER Prefix
  Install directory (contains dub-publish.exe).

.PARAMETER SkipPath
  Install files only; do not modify User PATH.
#>
[CmdletBinding()]
param(
    [string] $Prefix = $(Join-Path $env:LOCALAPPDATA "Programs\dlang-supplemental\dub-publish"),
    [switch] $SkipPath
)

$ErrorActionPreference = "Stop"

function Get-SourceExe {
    $here = $PSScriptRoot
    $candidates = @(
        (Join-Path $here "dub-publish.exe"),
        (Join-Path (Split-Path $here -Parent) "dub-publish.exe"),
        (Join-Path (Get-Location) "dub-publish.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path $c).Path }
    }
    throw "dub-publish.exe not found next to this script, repo root, or cwd."
}

$exeSrc = Get-SourceExe
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $Prefix "dub-publish.exe") -Force

$licenseSrc = Join-Path (Split-Path $exeSrc -Parent) "LICENSE"
if (Test-Path -LiteralPath $licenseSrc) {
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $Prefix "LICENSE") -Force
}

$uninstall = Join-Path $Prefix "uninstall.ps1"
@'
#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Prefix = Split-Path -Parent $MyInvocation.MyCommand.Path
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = $userPath -split ";" | Where-Object { $_ -and ($_ -ne $Prefix) }
[Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
Remove-Item -LiteralPath $Prefix -Recurse -Force
Write-Host "Removed $Prefix and User PATH entry."
Write-Host "Open a new shell (or refresh Path) so dub-publish disappears from PATH."
'@ | Set-Content -LiteralPath $uninstall -Encoding UTF8

if (-not $SkipPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $parts = @($userPath -split ";" | Where-Object { $_ })
    if ($parts -notcontains $Prefix) {
        $parts += $Prefix
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
        Write-Host "Added to User PATH: $Prefix"
    } else {
        Write-Host "User PATH already contains: $Prefix"
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")
}

Write-Host "Installed: $(Join-Path $Prefix 'dub-publish.exe')"
try {
    & (Join-Path $Prefix "dub-publish.exe") version
} catch {
    Write-Host "(version check skipped: $_)"
}

Write-Host ""
Write-Host "Credentials are DPAPI-bound to this Windows user profile and are NOT"
Write-Host "installed with the binary. After install/reinstall, re-register:"
Write-Host "  1. Write the registry password (first line) to:"
Write-Host "       $env:LOCALAPPDATA\dlang-supplemental\dub-publish\password.incoming"
Write-Host "  2. dub-publish login --user YOUR_USER --save-credentials"
Write-Host ""
Write-Host "Uninstall: powershell -File `"$uninstall`""
