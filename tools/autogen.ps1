<#
.SYNOPSIS
    Regenerate the repo's COMMITTED generated docs — README.md's managed regions and
    DATABASE_SCHEMA.md (+ the diagram) — without needing a WoW install.

.DESCRIPTION
    The deployed-artifact generation (.toc, namespace slots) stays in deploy.ps1; this
    script owns only the REPO docs, so they can be refreshed (and CI-checked for
    freshness) on any machine:
      * README.md      — the AUTOGEN:filetree + AUTOGEN:version regions (tools/autogen/Readme.ps1)
      * DATABASE_SCHEMA.md + diagram/DB — from the live table definitions (tools/gen_schema.lua,
                         loads the real engine headless; needs a Lua interpreter)
    Run standalone after a schema/file-layout change, or let deploy.ps1 call it (deploy
    dot-sources this file and runs Update-RepoDocs with -SchemaOptional, so a missing
    LuaJIT degrades to a warning there but is an ERROR here).

.PARAMETER SkipSchema
    Regenerate only the README regions (no Lua interpreter needed).

.PARAMETER SchemaOptional
    Warn-and-skip the schema doc when no Lua interpreter is found instead of throwing.

.PARAMETER LuaExe
    Override the Lua interpreter (default: luajit / lua on PATH, then the known
    Windows LuaJIT install).
#>
[CmdletBinding()]
param(
    [switch]$SkipSchema,
    [switch]$SchemaOptional,
    [string]$LuaExe
)

$ErrorActionPreference = "Stop"
$script:RepoRoot = Split-Path $PSScriptRoot -Parent

. (Join-Path $PSScriptRoot "autogen\Common.ps1")
. (Join-Path $PSScriptRoot "autogen\Readme.ps1")

# First luajit/lua that actually runs (mirrors tools/check.mjs's findLua).
function Get-LuaExe {
    $candidates = @("luajit", "lua")
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Programs\LuaJIT\bin\luajit.exe") }
    foreach ($c in $candidates) {
        try { & $c "-v" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return $c } } catch {}
    }
    return $null
}

# Regenerate the committed repo docs. Shared with deploy.ps1 (which dot-sources this file).
function Update-RepoDocs {
    param([string]$Root, [switch]$SkipSchema, [switch]$SchemaOptional, [string]$LuaExe)
    Update-Readme -Root $Root
    Write-Host "autogen: README.md regions regenerated." -ForegroundColor DarkGray
    if ($SkipSchema) { return }
    $lua = if ($LuaExe) { $LuaExe } else { Get-LuaExe }
    if (-not $lua) {
        if ($SchemaOptional) {
            Write-Host "Skipped DATABASE_SCHEMA.md (no luajit/lua found)." -ForegroundColor Yellow
            return
        }
        throw "autogen: no luajit/lua interpreter found (install LuaJIT, or pass -LuaExe / -SkipSchema)"
    }
    Push-Location $Root
    try {
        & $lua (Join-Path "tools" "gen_schema.lua")
        if ($LASTEXITCODE -ne 0) { throw "autogen: gen_schema.lua failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

# Run only when invoked as a script; dot-sourcing (deploy.ps1) just gets the functions.
if ($MyInvocation.InvocationName -ne '.') {
    Update-RepoDocs -Root $script:RepoRoot -SkipSchema:$SkipSchema -SchemaOptional:$SchemaOptional -LuaExe $LuaExe
}
