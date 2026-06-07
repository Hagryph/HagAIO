<#
.SYNOPSIS
    Deploy (mirror) the HagAIO addon source into the live WoW retail AddOns folder,
    generating the load manifest (.toc) on the way in.

.DESCRIPTION
    Copies the addon runtime files from this repo into
    <WoW>\_retail_\Interface\AddOns\HagAIO so changes take effect on the next
    /reload or client launch, then writes a freshly generated HagAIO.toc straight
    into the deployed folder. The .toc is NOT tracked in the repo -- it is derived
    from the files on disk every deploy, so a new .lua never needs a manual manifest
    edit. Dev/repo artifacts (.git, README, this script, etc.) are excluded. Run
    after any code change.

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

# Build the .toc text. The header (## directives + comments) is maintained by hand in
# the tracked HagAIO.toc; this only fills the Lua FILE LIST. WoW loads only files named
# in the manifest, so it scans every code dir and lists them in a load-safe order:
#   1. a hardcoded foundation block whose order is fixed (a base class must be defined
#      before any file that extends it at load time; UI\Widgets is pinned here too
#      because the UI windows + several modules alias ns.UI.Widgets at file scope),
#   2. the libs/services/UI tier, which is order-independent -> sorted folder-then-name,
#   3. Core\Init.lua (boots services in dependency order; after the service/UI files,
#      before the modules),
#   4. the modules, sorted folder-then-name so a parent module (Modules\Class.lua)
#      always precedes its submodules (Modules\Class\Monk.lua).
# NOTE: tools/gen_readme.mjs mirrors this ordering to build the README file tree --
# keep the pinned lists below in sync with the ones there.
function Build-TocLines {
    param([string]$Root)

    # Header is the tracked HagAIO.toc up to the FILES marker -- everything the addon
    # author edits by hand (Interface version, saved vars, icon, ...).
    $template = Join-Path $Root "HagAIO.toc"
    if (-not (Test-Path $template)) {
        throw "Missing HagAIO.toc (the tracked header template) at $template"
    }
    $marker = '# >>> FILES'
    $header = New-Object System.Collections.Generic.List[string]
    # Read as UTF-8 (.NET default) -- the header carries non-ASCII (em dash, arrow) and
    # PS 5.1's Get-Content would mis-decode this no-BOM UTF-8 file as ANSI.
    foreach ($line in [System.IO.File]::ReadAllLines($template)) {
        if ($line.TrimStart().StartsWith($marker)) { break }
        $header.Add($line)
    }

    $pinnedHead = @(
        'Core\Namespace.lua', 'Core\Class.lua', 'Core\Theme.lua', 'Core\DependencyGraph.lua',
        'Core\Logger.lua', 'Core\Registry.lua', 'Core\Loggable.lua', 'Core\Component.lua',
        'Core\Service.lua', 'Core\ServiceManager.lua', 'Core\Module.lua', 'Core\ModuleManager.lua',
        'Core\Submodule.lua', 'Core\SubmoduleManager.lua', 'Core\Lib.lua', 'Core\LibManager.lua',
        'UI\Widgets.lua'
    )
    $pinnedInit = 'Core\Init.lua'
    $scanDirs   = @('Core', 'Lib', 'Services', 'UI', 'Modules')

    # Every .lua on disk, as repo-relative backslash paths (the form WoW expects).
    $all = foreach ($d in $scanDirs) {
        $dir = Join-Path $Root $d
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -Filter *.lua -File |
                ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') }
        }
    }
    $all = @($all | Sort-Object -Unique)

    $pinnedSet = @{}
    foreach ($p in $pinnedHead) { $pinnedSet[$p.ToLower()] = $true }
    $pinnedSet[$pinnedInit.ToLower()] = $true

    $rest    = @($all | Where-Object { -not $pinnedSet.ContainsKey($_.ToLower()) })
    # Folder-then-name: shorter parent dir sorts before its child dir (prefix-first),
    # so all Modules\*.lua precede every Modules\<Sub>\*.lua.
    $sort    = @{ Expression = { Split-Path $_ -Parent } }, @{ Expression = { Split-Path $_ -Leaf } }
    $modules = @($rest | Where-Object { $_ -like 'Modules\*' } | Sort-Object $sort)
    $free    = @($rest | Where-Object { $_ -notlike 'Modules\*' } | Sort-Object $sort)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $header) { $out.Add($l) }
    $out.Add('# --- foundation: fixed load order (base classes before subclasses; UI\Widgets')
    $out.Add('#     before the windows/modules that alias it) ---')
    foreach ($l in $pinnedHead) { $out.Add($l) }
    $out.Add('')
    $out.Add('# --- libs / services / UI: order-independent, sorted by folder then name ---')
    foreach ($l in $free) { $out.Add($l) }
    $out.Add('')
    $out.Add('# --- core initializer: boots services in dependency order, before modules ---')
    $out.Add($pinnedInit)
    $out.Add('')
    $out.Add('# --- modules: sorted by folder then name (parent modules before submodules) ---')
    foreach ($l in $modules) { $out.Add($l) }
    return $out.ToArray()
}

if (-not (Test-Path $AddonsPath)) {
    throw "WoW AddOns folder not found: $AddonsPath  (set WOW_ADDONS_PATH or pass -AddonsPath)"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

# /MIR keeps dest an exact mirror of the addon files; exclusions keep repo tooling out
# of the deployed copy. HagAIO.toc is excluded from the mirror because the full manifest
# (header template + generated file list) is written into dest below, after the mirror.
$exclDirs  = @(".git", ".github", ".claude", "tools", "Test", "Dev")
$exclFiles = @("deploy.ps1", "README.md", "CONTRIBUTING.md", "package.json", "package-lock.json",
    ".gitignore", "LICENSE", "HagAIO.toc", "*.zip", "*.ps1", "*.py")

robocopy $src $dest /MIR /XD $exclDirs /XF $exclFiles /NFL /NDL /NJH /NJS /NP | Out-Null

# robocopy exit codes < 8 are success (0-7 = copied/extra/mismatch, not errors).
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

# Generate the manifest from disk and write it straight into the deployed folder
# (UTF-8 without a BOM -- WoW's .toc parser wants a clean leading '##').
$tocLines = Build-TocLines -Root $src
$tocText  = ($tocLines -join "`r`n") + "`r`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dest "HagAIO.toc"), $tocText, $utf8NoBom)

Write-Host "Deployed HagAIO -> $dest" -ForegroundColor Green
Write-Host "Generated HagAIO.toc ($($tocLines.Count) lines) in the deployed folder." -ForegroundColor DarkGray
Write-Host "In-game: /reload (or relaunch) to load the changes." -ForegroundColor DarkGray
exit 0
