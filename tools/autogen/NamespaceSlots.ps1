# tools/autogen/NamespaceSlots.ps1 — generates the `ns.<Name> = nil` slot block that
# documents the shape of the namespace, and injects it into the DEPLOYED Core/Namespace.lua
# at the `-- @AUTOGEN:slots` marker. The repo source keeps only the marker, so the derived
# block never clutters the readable source. Descriptions come from each slot's source-file
# header (single source); Core framework slots map to their file, services/libs are
# discovered from their registration (same rule the old nscheck.mjs used). Requires
# Common.ps1 (Get-FileDescription, Write-Utf8NoBom).

# Core framework slots -> source file (stable framework internals; not auto-discoverable
# because they're published by direct assignment, not by *Manager:Register).
$script:CoreSlots = [ordered]@{
    'Class'            = 'Core\Class.lua'
    'Object'           = 'Core\Class.lua'
    'Type'             = 'Core\Type.lua'
    'Enum'             = 'Core\Enum.lua'
    'Theme'            = 'Core\Theme.lua'
    'Registry'         = 'Core\Registry.lua'
    'Loggable'         = 'Core\Loggable.lua'
    'Lib'              = 'Core\Lib.lua'
    'LibManager'       = 'Core\LibManager.lua'
    'Service'          = 'Core\Service.lua'
    'ServiceManager'   = 'Core\ServiceManager.lua'
    'Submodule'        = 'Core\Submodule.lua'
    'SubmoduleManager' = 'Core\SubmoduleManager.lua'
    'Component'        = 'Core\Component.lua'
    'Module'           = 'Core\Module.lua'
    'ModuleManager'    = 'Core\ModuleManager.lua'
    'DependencyGraph'  = 'Core\DependencyGraph.lua'
    'Logger'           = 'Core\Logger.lua'
    'UI'               = 'UI\Widgets.lua'
    'Initializer'      = 'Core\Init.lua'
}

# Non-UI services (ServiceManager:Register without ui=true) + libs (LibManager:Register),
# each published at ns.<Name>. Returns objects { Name, Path }.
function Get-PublishedServiceLibs {
    param([string]$Root)
    $found = @()
    foreach ($d in @('Core', 'Lib', 'Services', 'UI', 'Modules')) {
        $dir = Join-Path $Root $d
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in Get-ChildItem -Path $dir -Recurse -Filter *.lua -File) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
            $code = (([System.IO.File]::ReadAllLines($f.FullName)) | ForEach-Object { $_ -replace '--.*$', '' }) -join "`n"
            foreach ($m in [regex]::Matches($code, 'ServiceManager:Register\(\s*\w+:New\(\s*["''](\w+)["'']\s*(,\s*\{([\s\S]*?)\})?')) {
                if ($m.Groups[3].Value -notmatch '\bui\s*=\s*true\b') {
                    $found += [pscustomobject]@{ Name = $m.Groups[1].Value; Path = $rel }
                }
            }
            foreach ($m in [regex]::Matches($code, 'LibManager:Register\(\s*\w+:New\(\s*["''](\w+)["'']')) {
                $found += [pscustomobject]@{ Name = $m.Groups[1].Value; Path = $rel }
            }
            # Value-class libs (e.g. Format, Vector2D) publish by direct assignment rather
            # than LibManager:Register -- catch those too, but only in Lib/ (so module
            # aliases like ns.Tasks aren't pulled into the framework slot list).
            if ($rel -like 'Lib\*') {
                foreach ($m in [regex]::Matches($code, '(?m)^ns\.(\w+)\s*=[^=]')) {
                    $found += [pscustomobject]@{ Name = $m.Groups[1].Value; Path = $rel }
                }
            }
        }
    }
    return $found
}

function New-NamespaceSlotsBlock {
    param([string]$Root)
    $rows = New-Object System.Collections.Generic.List[string]
    $add = {
        param($name, $path)
        $lhs = "ns.$name = nil"
        $desc = Get-FileDescription -Root $Root -RelPath $path
        $src = $path -replace '\\', '/'
        $pad = if ($lhs.Length -lt 23) { ' ' * (23 - $lhs.Length) } else { ' ' }
        $comment = if ($desc) { "$desc  ($src)" } else { "($src)" }
        $rows.Add("$lhs$pad-- $comment")
    }
    foreach ($k in $script:CoreSlots.Keys) { & $add $k $script:CoreSlots[$k] }
    foreach ($e in (Get-PublishedServiceLibs -Root $Root | Sort-Object Name -Unique)) {
        if (-not $script:CoreSlots.Contains($e.Name)) { & $add $e.Name $e.Path }
    }
    return ($rows -join "`n")
}

# Inject the generated block right after the `-- @AUTOGEN:slots` marker in the deployed
# Namespace.lua. No marker => safe no-op (e.g. running the addon from a raw source symlink).
function Update-DeployedNamespaceSlots {
    param([string]$Root, [string]$DeployedFile)
    if (-not (Test-Path $DeployedFile)) { return }
    $text = [System.IO.File]::ReadAllText($DeployedFile)
    $marker = '-- @AUTOGEN:slots'
    $idx = $text.IndexOf($marker)
    if ($idx -lt 0) { return }
    $lineEnd = $text.IndexOf("`n", $idx)
    if ($lineEnd -lt 0) { $lineEnd = $text.Length } else { $lineEnd += 1 }
    $block = New-NamespaceSlotsBlock -Root $Root
    $new = $text.Substring(0, $lineEnd) + $block + "`n" + $text.Substring($lineEnd)
    Write-Utf8NoBom -Path $DeployedFile -Text $new
}
