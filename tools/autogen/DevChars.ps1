# tools/autogen/DevChars.ps1 — injects the developer-character whitelist into the
# DEPLOYED Core/Namespace.lua at its `-- @AUTOGEN:devchars` marker, from the git-ignored
# Dev/devchars.txt (one "Name-Realm" per line; blank lines and #-comments ignored).
# The repo source ships the whitelist empty, so no personal data is committed or
# packaged — dev characters exist only in the deployer's own live copy. deploy.ps1 calls
# this; tools/package.ps1 deliberately does NOT (a release zip has an empty whitelist).
# Requires Common.ps1 (Write-Utf8NoBom).

function Update-DeployedDevChars {
    param([string]$Root, [string]$DeployedFile)
    if (-not (Test-Path $DeployedFile)) { return }
    $listFile = Join-Path $Root 'Dev\devchars.txt'
    if (-not (Test-Path $listFile)) { return }   # no local dev config -> whitelist stays empty
    $chars = @([System.IO.File]::ReadAllLines($listFile) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($chars.Count -eq 0) { return }

    $text = [System.IO.File]::ReadAllText($DeployedFile)
    $marker = '-- @AUTOGEN:devchars'
    $idx = $text.IndexOf($marker)
    if ($idx -lt 0) { return }                   # no marker -> safe no-op
    $lineEnd = $text.IndexOf("`n", $idx)
    if ($lineEnd -lt 0) { $lineEnd = $text.Length } else { $lineEnd += 1 }
    $block = ($chars | ForEach-Object { 'DEV_WHITELIST["' + $_ + '"] = true' }) -join "`n"
    $new = $text.Substring(0, $lineEnd) + $block + "`n" + $text.Substring($lineEnd)
    Write-Utf8NoBom -Path $DeployedFile -Text $new
    Write-Host ("Dev whitelist: injected {0} character(s) into the deployed Namespace.lua." -f $chars.Count) -ForegroundColor DarkGray
}
