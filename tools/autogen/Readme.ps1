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

# ---- AUTOGEN:commands -- the /hag slash-command table, scanned from the registration sites ------
# The command surface is declared in the source: the built-in router verbs in
# Services/SlashCommand.lua, plus each module/service's `commands = { ... }` block -- a LEAF
# command, or a GROUP carrying a `subcommands` table (see SlashCommand:RegisterGroup). We scan the
# same load-ordered files the file tree uses, expand a group to one row per sub-command, and mark a
# developer-only command (a `dev = true` sub, or any command in a ns.WhenDevCharKnown file). The
# three stable built-ins (/hag, help, modules) are fixed rows, like the file tree's fixed rows.

# Blank Lua comments (keep string literals) so a doc-comment `-- commands = { ... }` example in a
# Core base class is never parsed as a real registration.
function Remove-LuaComments {
    param([string]$Src)
    $Src = [regex]::Replace($Src, '--\[\[[\s\S]*?\]\]', { param($m) ($m.Value -replace '[^\r\n]', ' ') })
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($Src -split "`n")) {
        $inStr = $false; $q = ''; $cut = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $c = $line[$i]
            if ($inStr) { if ($c -eq $q) { $inStr = $false } }
            elseif ($c -eq '"' -or $c -eq "'") { $inStr = $true; $q = $c }
            elseif ($c -eq '-' -and $i + 1 -lt $line.Length -and $line[$i + 1] -eq '-') { $cut = $i; break }
        }
        if ($cut -ge 0) { $line = $line.Substring(0, $cut) }
        [void]$sb.AppendLine($line)
    }
    return $sb.ToString()
}

# Inner text between the brace at $Open and its match, plus the index of the closing brace.
function Get-LuaBraceSpan {
    param([string]$Text, [int]$Open)
    $depth = 0
    for ($i = $Open; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return @{ Inner = $Text.Substring($Open + 1, $i - $Open - 1); End = $i } } }
    }
    return @{ Inner = $Text.Substring($Open + 1); End = $Text.Length - 1 }
}

# Ordered `key = { body }` table entries at the TOP level of $Inner (brace-matched, so a nested
# table -- e.g. a `subcommands` block -- is stepped over, not descended into).
function Get-LuaTableEntries {
    param([string]$Inner)
    $out = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'(\w+)\s*=\s*\{'
    $pos = 0
    while ($true) {
        $m = $rx.Match($Inner, $pos)
        if (-not $m.Success) { break }
        $span = Get-LuaBraceSpan -Text $Inner -Open ($m.Index + $m.Length - 1)
        $out.Add([pscustomobject]@{ Key = $m.Groups[1].Value; Body = $span.Inner })
        $pos = $span.End + 1
    }
    return $out
}

function Get-LuaStringField {
    param([string]$Body, [string]$Field)
    $m = [regex]::Match($Body, $Field + '\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-SlashCommandBlock {
    param([string]$Root)
    $bt = $script:Bt
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($rel in (Get-OrderedLuaFiles -Root $Root)) {
        $src = Remove-LuaComments ([System.IO.File]::ReadAllText((Join-Path $Root $rel)))
        $devFile = [bool]($src -match 'WhenDevCharKnown')
        $rx = [regex]'\bcommands\s*=\s*\{'
        $pos = 0
        while ($true) {
            $m = $rx.Match($src, $pos)
            if (-not $m.Success) { break }
            $blk = Get-LuaBraceSpan -Text $src -Open ($m.Index + $m.Length - 1)
            foreach ($cmd in (Get-LuaTableEntries -Inner $blk.Inner)) {
                $sm = [regex]::Match($cmd.Body, 'subcommands\s*=\s*\{')
                if ($sm.Success) {
                    $sub = Get-LuaBraceSpan -Text $cmd.Body -Open ($sm.Index + $sm.Length - 1)
                    foreach ($s in (Get-LuaTableEntries -Inner $sub.Inner)) {
                        $dev = $devFile -or [bool]($s.Body -match 'dev\s*=\s*true')
                        $rows.Add([pscustomobject]@{ Cmd = "/hag $($cmd.Key) $($s.Key)"; Effect = (Get-LuaStringField $s.Body 'help'); Dev = $dev; DevFile = $devFile })
                    }
                } else {
                    $rows.Add([pscustomobject]@{ Cmd = "/hag $($cmd.Key)"; Effect = (Get-LuaStringField $cmd.Body 'help'); Dev = $devFile; DevFile = $devFile })
                }
            }
            $pos = $blk.End + 1
        }
    }
    # The three built-in router verbs are fixed rows (stable; not declared in a commands={} block).
    $core = @(
        [pscustomobject]@{ Cmd = '/hag';         Effect = 'open the settings window';             Dev = $false; DevFile = $false },
        [pscustomobject]@{ Cmd = '/hag help';    Effect = 'list commands';                        Dev = $false; DevFile = $false },
        [pscustomobject]@{ Cmd = '/hag modules'; Effect = 'list feature modules and their state'; Dev = $false; DevFile = $false }
    )
    # Built-ins, then scanned commands in load order, with wholly developer-only commands last.
    $ordered = @($core) + @($rows | Where-Object { -not $_.DevFile }) + @($rows | Where-Object { $_.DevFile })

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('| Command | Effect |')
    $out.Add('|---|---|')
    foreach ($r in $ordered) {
        $eff = if ($r.Effect) { [string]$r.Effect } else { '' }
        $eff = [regex]::Replace($eff, '<[^>]+>', { param($mm) "$bt$($mm.Value)$bt" })   # render `<name>` args as code
        if ($eff.Length -gt 0) { $eff = $eff.Substring(0, 1).ToUpper() + $eff.Substring(1) }
        if ($r.Dev) { $eff += ' (developer characters)' }
        $out.Add("| $bt$($r.Cmd)$bt | $eff |")
    }
    return ($out -join "`n")
}

function Update-Readme {
    param([string]$Root)
    $path = Join-Path $Root 'README.md'
    $text = [System.IO.File]::ReadAllText($path)
    $text = Set-MarkedRegion -Text $text -BeginPrefix '<!-- AUTOGEN:filetree' -EndMarker '<!-- /AUTOGEN:filetree -->' -Inner (Get-FileTreeBlock -Root $Root)
    $text = Set-MarkedRegion -Text $text -BeginPrefix '<!-- AUTOGEN:version'  -EndMarker '<!-- /AUTOGEN:version -->'  -Inner (Get-VersionBlock  -Root $Root)
    $text = Set-MarkedRegion -Text $text -BeginPrefix '<!-- AUTOGEN:commands' -EndMarker '<!-- /AUTOGEN:commands -->' -Inner (Get-SlashCommandBlock -Root $Root)
    $text = $text -replace "`r`n", "`n"   # keep LF throughout (matches the prior generator)
    Write-Utf8NoBom -Path $path -Text $text
}
