# tools/autogen/Readme.ps1 — regenerates README.md's two managed regions IN THE REPO (the
# README is a committed GitHub doc, not a deployed file). deploy.ps1 calls Update-Readme so
# the doc stays in step with the source on every deploy.
#   AUTOGEN:filetree — the source tree (load-ordered files + each file's header description)
#   AUTOGEN:version  — the "Target version" table, from HagAIO.toc (single source for the
#                      target patch: ## Interface + the # expansion: / # next-patch: tags)
# Requires Common.ps1 (Get-OrderedLuaFiles, Get-FileDescription, Set-MarkedRegion, Write-Utf8NoBom).

$script:Bt = ([char]96).ToString()   # backtick, awkward to embed literally in PS strings

function Get-FileTreeBlock {
    param([string]$Root)
    $col = 27
    $row = {
        param($name, $desc, $indent = 0)
        $left = (' ' * $indent) + $name
        $gap = if ($left.Length -lt $col) { ' ' * ($col - $left.Length) } else { ' ' }
        "$left$gap$desc"
    }
    $files = Get-OrderedLuaFiles -Root $Root
    $dash = [char]0x2014   # em dash, built by code-point so the script stays pure ASCII
                           # (PS 5.1 reads a no-BOM .ps1 as ANSI and would mangle a literal)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((& $row 'HagAIO.toc' "Load manifest $dash header tracked; file list filled on deploy"))

    # Group by top-level dir, in first-seen (load) order.
    $order = New-Object System.Collections.Generic.List[string]
    $byGroup = @{}
    foreach ($rel in $files) {
        $g = ($rel -split '\\')[0]
        $name = ($rel -split '\\', 2)[1]
        if (-not $byGroup.ContainsKey($g)) { $byGroup[$g] = New-Object System.Collections.Generic.List[object]; $order.Add($g) }
        $byGroup[$g].Add([pscustomobject]@{ Name = $name; Rel = $rel })
    }
    foreach ($g in $order) {
        $out.Add("$g/")
        foreach ($e in $byGroup[$g]) {
            $desc = Get-FileDescription -Root $Root -RelPath $e.Rel
            if (-not $desc) { $desc = '(no description)' }
            $out.Add((& $row $e.Name $desc 2))
        }
    }
    $out.Add((& $row 'Dev/' 'Scratch space (excluded from deploy)'))
    $out.Add((& $row 'deploy.ps1' 'Mirror the addon into the live WoW AddOns folder + generate the .toc'))

    $fence = $script:Bt * 3
    return $fence + "`n" + ($out -join "`n") + "`n" + $fence
}

# `## Interface: 120005` -> "12.0.5" (AABBCC = major.minor.patch).
function Get-PatchString {
    param([int]$Interface)
    return "{0}.{1}.{2}" -f [math]::Floor($Interface / 10000), ([math]::Floor($Interface / 100) % 100), ($Interface % 100)
}

function Get-VersionBlock {
    param([string]$Root)
    $toc = [System.IO.File]::ReadAllText((Join-Path $Root 'HagAIO.toc'))
    $iface = [regex]::Match($toc, '(?m)^##\s*Interface:\s*(\d+)').Groups[1].Value
    if (-not $iface) { throw 'Readme: HagAIO.toc is missing its `## Interface:` line' }
    $expansion = [regex]::Match($toc, '(?m)^#\s*expansion:\s*(.+)$').Groups[1].Value.Trim()
    $next = [regex]::Match($toc, '(?m)^#\s*next-patch:\s*(.+)$').Groups[1].Value.Trim()
    $patch = Get-PatchString -Interface ([int]$iface)
    $bt = $script:Bt
    return @(
        '| | |',
        '|---|---|',
        "| Expansion | $expansion |",
        "| $bt.toc$bt Interface | $bt$iface$bt (patch $patch) |",
        "| Next patch | $next |"
    ) -join "`n"
}

function Update-Readme {
    param([string]$Root)
    $path = Join-Path $Root 'README.md'
    $text = [System.IO.File]::ReadAllText($path)
    $text = Set-MarkedRegion -Text $text -BeginPrefix '<!-- AUTOGEN:filetree' -EndMarker '<!-- /AUTOGEN:filetree -->' -Inner (Get-FileTreeBlock -Root $Root)
    $text = Set-MarkedRegion -Text $text -BeginPrefix '<!-- AUTOGEN:version'  -EndMarker '<!-- /AUTOGEN:version -->'  -Inner (Get-VersionBlock  -Root $Root)
    $text = $text -replace "`r`n", "`n"   # keep LF throughout (matches the prior generator)
    Write-Utf8NoBom -Path $path -Text $text
}
