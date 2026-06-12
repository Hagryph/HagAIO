<#
.SYNOPSIS
    Build a distributable HagAIO release zip — the exact artifact deploy.ps1 mirrors
    into the live AddOns folder, staged and zipped for upload (GitHub release /
    CurseForge / Wago).

.DESCRIPTION
    NOT run by deploy.ps1 — invoke manually when cutting a release:
        ./tools/package.ps1                  ->  dist/HagAIO-v<version>.zip
        ./tools/package.ps1 -OutDir build    ->  build/HagAIO-v<version>.zip
    Stages the addon into a temp dir using the SAME exclusion lists deploy.ps1 uses
    (shared via tools/autogen/Common.ps1), runs the same generation steps (full .toc,
    namespace slot block), then zips with HagAIO/ as the archive root so it extracts
    straight into Interface\AddOns. The version comes from HagAIO.toc's ## Version line,
    so a tagged commit's zip is reconstructible from the repo alone — no WoW install
    needed. The dev-character whitelist injection (tools/autogen/DevChars.ps1) is
    deliberately NOT run: a release ships ns.DEV_WHITELIST empty.

.PARAMETER OutDir
    Where to put the zip. Defaults to <repo>/dist (git-ignored).
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

. (Join-Path $PSScriptRoot "autogen\Common.ps1")
. (Join-Path $PSScriptRoot "autogen\Toc.ps1")
. (Join-Path $PSScriptRoot "autogen\NamespaceSlots.ps1")

if (-not $OutDir) { $OutDir = Join-Path $root "dist" }

# Version from the tracked .toc header — the one place the addon's version lives.
$toc = [System.IO.File]::ReadAllText((Join-Path $root "HagAIO.toc"))
$version = [regex]::Match($toc, '(?m)^##\s*Version:\s*(.+)$').Groups[1].Value.Trim()
if (-not $version) { throw "package: HagAIO.toc is missing its '## Version:' line" }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("HagAIO-package-" + [guid]::NewGuid().ToString("n"))
$stageAddon = Join-Path $stage "HagAIO"
New-Item -ItemType Directory -Force -Path $stageAddon | Out-Null

try {
    # Mirror the shippable files into the staging dir (same exclusions as deploy.ps1).
    robocopy $root $stageAddon /MIR /XD $script:DeployExcludeDirs /XF $script:DeployExcludeFiles /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "package: robocopy failed with exit code $LASTEXITCODE" }

    # The same generation steps deploy.ps1 runs into the live folder.
    Write-Utf8NoBom -Path (Join-Path $stageAddon "HagAIO.toc") -Text (New-TocText -Root $root)
    Update-DeployedNamespaceSlots -Root $root -DeployedFile (Join-Path $stageAddon "Core\Namespace.lua")

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $zip = Join-Path $OutDir ("HagAIO-v" + $version + ".zip")
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # Entry-by-entry with explicit FORWARD-slash names: under PS 5.1 both Compress-Archive
    # and ZipFile::CreateFromDirectory write backslash separators, which the zip spec
    # forbids and non-Windows extractors mishandle. Entries are rooted at HagAIO/ (the
    # stage's one child), so the zip extracts straight into Interface\AddOns.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $base = (Resolve-Path $stage).Path.TrimEnd('\') + '\'
        foreach ($file in (Get-ChildItem $stage -Recurse -File)) {
            $entryName = $file.FullName.Substring($base.Length) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName) | Out-Null
        }
    } finally {
        $archive.Dispose()
        $fs.Dispose()
    }

    Write-Host "Packaged HagAIO v$version -> $zip" -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
