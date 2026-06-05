<#
.SYNOPSIS
    Deploy (mirror) the HagAIO addon source into the live WoW retail AddOns folder.

.DESCRIPTION
    Copies the addon runtime files from this repo into
    <WoW>\_retail_\Interface\AddOns\HagAIO so changes take effect on the next
    /reload or client launch. Dev/repo artifacts (.git, README, this script,
    etc.) are excluded. Run after any code change.

.PARAMETER AddonsPath
    Override the WoW retail AddOns directory. Defaults to the standard install,
    or the WOW_ADDONS_PATH environment variable if set.
#>
[CmdletBinding()]
param(
    [string]$AddonsPath = $(if ($env:WOW_ADDONS_PATH) { $env:WOW_ADDONS_PATH }
        else { "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns" })
)

$ErrorActionPreference = "Stop"
$src  = $PSScriptRoot
$dest = Join-Path $AddonsPath "HagAIO"

if (-not (Test-Path $AddonsPath)) {
    throw "WoW AddOns folder not found: $AddonsPath  (set WOW_ADDONS_PATH or pass -AddonsPath)"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# /MIR keeps dest an exact mirror of the addon files; exclusions keep repo
# tooling out of the deployed copy.
$exclDirs  = @(".git", ".github", ".claude")
$exclFiles = @("deploy.ps1", "README.md", ".gitignore", "LICENSE", "*.zip", "*.ps1")

robocopy $src $dest /MIR /XD $exclDirs /XF $exclFiles /NFL /NDL /NJH /NJS /NP | Out-Null

# robocopy exit codes < 8 are success (0-7 = copied/extra/mismatch, not errors).
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

Write-Host "Deployed HagAIO -> $dest" -ForegroundColor Green
Write-Host "In-game: /reload (or relaunch) to load the changes." -ForegroundColor DarkGray
exit 0
