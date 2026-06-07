# tools/autogen/Common.ps1 — shared helpers for the deploy-time autogen scripts
# (Toc.ps1, NamespaceSlots.ps1, Readme.ps1). deploy.ps1 dot-sources this FIRST, then the
# others. The load-order rules live here so the .toc and the README file tree share one
# source of truth (no more duplicated pinned lists across PowerShell and Node).

$script:ScanDirs = @('Core', 'Lib', 'Services', 'UI', 'Modules')

# Foundation files with a fixed load order: a base class must be defined before any file
# that extends it at load time; UI\Widgets is pinned here too because the UI windows +
# several modules alias ns.UI.Widgets at file scope.
$script:PinnedHead = @(
    'Core\Namespace.lua', 'Core\Class.lua', 'Core\Type.lua', 'Core\Enum.lua',
    'Core\Mixin.lua', 'Core\Interface.lua', 'Core\Delegate.lua',
    'Core\Contributions.lua', 'Core\Persisted.lua',
    'Core\Theme.lua', 'Core\DependencyGraph.lua',
    'Core\Logger.lua', 'Core\Registry.lua', 'Core\Loggable.lua', 'Core\Component.lua',
    'Core\Service.lua', 'Core\ServiceManager.lua', 'Core\Module.lua', 'Core\ModuleManager.lua',
    'Core\Submodule.lua', 'Core\SubmoduleManager.lua', 'Core\Lib.lua', 'Core\LibManager.lua',
    'UI\Widgets.lua'
)
# The Core initializer boots services in dependency order; loads after all service/UI
# files, before the modules.
$script:PinnedInit = 'Core\Init.lua'

# Every .lua under the code dirs, in load-safe order: pinned foundation, then the
# order-independent tier (folder-then-name), then Init, then modules (folder-then-name so
# a parent module precedes its submodules). Returns repo-relative backslash paths.
function Get-OrderedLuaFiles {
    param([string]$Root)
    $all = foreach ($d in $script:ScanDirs) {
        $dir = Join-Path $Root $d
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -Filter *.lua -File |
                ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\') }
        }
    }
    $all = @($all | Sort-Object -Unique)

    $pinnedSet = @{}
    foreach ($p in $script:PinnedHead) { $pinnedSet[$p.ToLower()] = $true }
    $pinnedSet[$script:PinnedInit.ToLower()] = $true

    $rest = @($all | Where-Object { -not $pinnedSet.ContainsKey($_.ToLower()) })
    $sort = @{ Expression = { Split-Path $_ -Parent } }, @{ Expression = { Split-Path $_ -Leaf } }
    $modules = @($rest | Where-Object { $_ -like 'Modules\*' } | Sort-Object $sort)
    $free    = @($rest | Where-Object { $_ -notlike 'Modules\*' } | Sort-Object $sort)

    return @($script:PinnedHead) + $free + @($script:PinnedInit) + $modules
}

# The file's one-line description: first comment line after its `-- <path>.lua` banner,
# trimmed to the first sentence (the convention the old gen_readme.mjs used).
function Get-FileDescription {
    param([string]$Root, [string]$RelPath)
    $full = Join-Path $Root $RelPath
    if (-not (Test-Path $full)) { return '' }
    $lines = [System.IO.File]::ReadAllLines($full)
    $start = 0
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k].Trim() -match '^--\s+\S.*\.lua$') { $start = $k; break }
    }
    for ($k = $start + 1; $k -lt $lines.Count; $k++) {
        $t = $lines[$k].Trim()
        if ($t.StartsWith('--')) {
            $d = ($t -replace '^--\s?', '').Trim()
            if (-not $d) { continue }
            $dot = $d.IndexOf('. ')
            if ($dot -ge 0) { $d = $d.Substring(0, $dot) }
            return ($d -replace '\.$', '')
        }
        if ($t) { break }
    }
    return ''
}

# Replace the text between a begin-marker line and an end-marker (both kept) with $Inner.
function Set-MarkedRegion {
    param([string]$Text, [string]$BeginPrefix, [string]$EndMarker, [string]$Inner)
    $b = $Text.IndexOf($BeginPrefix)
    $e = $Text.IndexOf($EndMarker)
    if ($b -lt 0 -or $e -lt 0 -or $e -lt $b) {
        throw "Set-MarkedRegion: markers not found ($BeginPrefix .. $EndMarker)"
    }
    $beginLineEnd = $Text.IndexOf("`n", $b) + 1
    return $Text.Substring(0, $beginLineEnd) + $Inner + "`n" + $Text.Substring($e)
}

# UTF-8 without a BOM — WoW's .toc parser and GitHub markdown both want a clean stream.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
