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

# Deploy-time autogen (Common must load first; it defines the shared helpers + load order).
. (Join-Path $src "tools\autogen\Common.ps1")
. (Join-Path $src "tools\autogen\Toc.ps1")
. (Join-Path $src "tools\autogen\NamespaceSlots.ps1")
. (Join-Path $src "tools\autogen\Readme.ps1")

if (-not (Test-Path $AddonsPath)) {
    throw "WoW AddOns folder not found: $AddonsPath  (set WOW_ADDONS_PATH or pass -AddonsPath)"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# /MIR keeps dest an exact mirror of the addon files; exclusions keep repo tooling out
# of the deployed copy. HagAIO.toc is excluded from the mirror because the full manifest
# (header template + generated file list) is written into dest below, after the mirror.
$exclDirs  = @(".git", ".github", ".claude", "tools", "Test", "Dev")
$exclFiles = @("deploy.ps1", "README.md", "CONTRIBUTING.md", "DATABASE_SCHEMA.md", "package.json",
    "package-lock.json", ".gitignore", "LICENSE", "HagAIO.toc", "*.zip", "*.ps1", "*.py")

robocopy $src $dest /MIR /XD $exclDirs /XF $exclFiles /NFL /NDL /NJH /NJS /NP | Out-Null

# robocopy exit codes < 8 are success (0-7 = copied/extra/mismatch, not errors).
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

# --- autogen ---------------------------------------------------------------
# 1. Manifest: write the generated .toc into the deployed folder.
Write-Utf8NoBom -Path (Join-Path $dest "HagAIO.toc") -Text (New-TocText -Root $src)
# 2. Namespace slots: inject the ns.* block into the deployed Namespace.lua (at its marker).
Update-DeployedNamespaceSlots -Root $src -DeployedFile (Join-Path $dest "Core\Namespace.lua")
# 3. README: regenerate the repo doc's managed regions so they track the source.
Update-Readme -Root $src
# 4. Database schema doc: rebuild DATABASE_SCHEMA.md from the live table definitions (needs LuaJIT;
#    the generator loads the real engine + every module headless, so the doc can't drift).
$luajit = (Get-Command luajit -ErrorAction SilentlyContinue).Source
if (-not $luajit) {
    $cand = Join-Path $env:LOCALAPPDATA "Programs\LuaJIT\bin\luajit.exe"
    if (Test-Path $cand) { $luajit = $cand }
}
if ($luajit) {
    Push-Location $src
    try { & $luajit "tools\gen_schema.lua" } finally { Pop-Location }
} else {
    Write-Host "Skipped DATABASE_SCHEMA.md (no luajit/lua found)." -ForegroundColor Yellow
}

Write-Host "Deployed HagAIO -> $dest" -ForegroundColor Green
Write-Host "Autogen: .toc + namespace slots (deployed), README (repo) regenerated." -ForegroundColor DarkGray
Write-Host "In-game: /reload (or relaunch) to load the changes." -ForegroundColor DarkGray
exit 0
