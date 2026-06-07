# tools/autogen/Toc.ps1 — builds the full HagAIO.toc: the tracked header (the part of
# HagAIO.toc above the FILES marker, edited by hand) + the auto-filled, load-ordered Lua
# file list. deploy.ps1 writes the result into the deployed AddOn folder. Requires
# Common.ps1 (Get-OrderedLuaFiles, the pinned lists). The repo HagAIO.toc holds only the
# header; the file list lives nowhere in source.

function New-TocText {
    param([string]$Root)

    $template = Join-Path $Root 'HagAIO.toc'
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

    $ordered = Get-OrderedLuaFiles -Root $Root
    $head    = @($script:PinnedHead)
    $init    = $script:PinnedInit
    $free    = @($ordered | Where-Object { $head -notcontains $_ -and $_ -ne $init -and $_ -notlike 'Modules\*' })
    $modules = @($ordered | Where-Object { $_ -like 'Modules\*' })

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $header) { $out.Add($l) }
    $out.Add('# --- foundation: fixed load order (base classes before subclasses; UI\Widgets')
    $out.Add('#     before the windows/modules that alias it) ---')
    foreach ($l in $head) { $out.Add($l) }
    $out.Add('')
    $out.Add('# --- libs / services / UI: order-independent, sorted by folder then name ---')
    foreach ($l in $free) { $out.Add($l) }
    $out.Add('')
    $out.Add('# --- core initializer: boots services in dependency order, before modules ---')
    $out.Add($init)
    $out.Add('')
    $out.Add('# --- modules: sorted by folder then name (parent modules before submodules) ---')
    foreach ($l in $modules) { $out.Add($l) }

    return (($out -join "`r`n") + "`r`n")
}
