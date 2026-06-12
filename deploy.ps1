<#
.SYNOPSIS
    Deploy (mirror) the HagAIO addon source into the live WoW retail AddOns folder,
    running the deploy-time autogen steps on the way in.

.DESCRIPTION
    Copies the addon runtime files from this repo into
    <WoW>\_retail_\Interface\AddOns\HagAIO so changes take effect on the next
    /reload or client launch, then runs the autogen scripts (tools/autogen/*.ps1):
      * Toc            — writes a freshly generated HagAIO.toc into the deployed folder
                         (the repo keeps only the .toc header; the file list is derived).
      * NamespaceSlots — injects the ns.* slot block into the deployed Core/Namespace.lua
                         at its `-- @AUTOGEN:slots` marker (kept out of the repo source).
      * DevChars       — injects this machine's dev-character whitelist (git-ignored
                         Dev/devchars.txt) at the `-- @AUTOGEN:devchars` marker; the repo
                         and release zips ship ns.DEV_WHITELIST empty.
      * Readme         — regenerates README.md's file tree + version table IN THE REPO
                         (the README is a committed GitHub doc, not a deployed file).
    Dev/repo artifacts (.git, README, this script, etc.) are excluded from the mirror.
    Run after any code change.

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

# Deploy-time autogen (Common must load first; it defines the shared helpers + the load
# order from tools/load-order.json). tools/autogen.ps1 owns the repo-doc generation
# (README regions + DATABASE_SCHEMA.md) and is also runnable standalone — dot-sourcing it
# here only defines Update-RepoDocs.
. (Join-Path $src "tools\autogen\Common.ps1")
. (Join-Path $src "tools\autogen\Toc.ps1")
. (Join-Path $src "tools\autogen\NamespaceSlots.ps1")
. (Join-Path $src "tools\autogen\DevChars.ps1")
. (Join-Path $src "tools\autogen.ps1")

if (-not (Test-Path $AddonsPath)) {
    throw "WoW AddOns folder not found: $AddonsPath  (set WOW_ADDONS_PATH or pass -AddonsPath)"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# /MIR keeps dest an exact mirror of the addon files; the exclusion lists (shared with
# tools/package.ps1 via Common.ps1) keep repo tooling out of the deployed copy. HagAIO.toc
# is excluded from the mirror because the full manifest (header template + generated file
# list) is written into dest below, after the mirror.
robocopy $src $dest /MIR /XD $script:DeployExcludeDirs /XF $script:DeployExcludeFiles /NFL /NDL /NJH /NJS /NP | Out-Null

# robocopy exit codes < 8 are success (0-7 = copied/extra/mismatch, not errors).
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

# --- autogen ---------------------------------------------------------------
# 1. Manifest: write the generated .toc into the deployed folder.
Write-Utf8NoBom -Path (Join-Path $dest "HagAIO.toc") -Text (New-TocText -Root $src)
# 2. Namespace slots: inject the ns.* block into the deployed Namespace.lua (at its marker).
Update-DeployedNamespaceSlots -Root $src -DeployedFile (Join-Path $dest "Core\Namespace.lua")
# 2b. Dev whitelist: inject this machine's dev characters (git-ignored Dev/devchars.txt)
#     into the deployed Namespace.lua -- the repo and release zips ship it empty.
Update-DeployedDevChars -Root $src -DeployedFile (Join-Path $dest "Core\Namespace.lua")
# 3. Repo docs: README regions + DATABASE_SCHEMA.md, shared with the standalone
#    tools/autogen.ps1 (CI checks their freshness). A missing LuaJIT only warns here.
Update-RepoDocs -Root $src -SchemaOptional

Write-Host "Deployed HagAIO -> $dest" -ForegroundColor Green
Write-Host "Autogen: .toc + namespace slots (deployed), README (repo) regenerated." -ForegroundColor DarkGray
Write-Host "In-game: /reload (or relaunch) to load the changes." -ForegroundColor DarkGray
exit 0
