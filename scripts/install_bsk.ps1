# install_bsk.ps1 - Install bsk CLI with a pinned integrity anchor.
#
# SECURITY MODEL (v1.1.4):
#  1. DEFAULT SOURCE ORDER: try GitHub official (origin) first; if unreachable,
#     fall back to mirrors. Official source always has priority.
#  2. ALWAYS INSTALL THE LATEST RELEASE unless -Version is given explicitly.
#     $KnownSha256 entries are integrity anchors, NOT version gates: a release that
#     is not frozen here still installs normally (see rule 3b). Never downgrade a
#     user to an old build just because this file has not been updated.
#  3. Integrity - where the expected SHA256 may come from:
#       a) pinned in this file ($KnownSha256) -> must match; any channel that
#          disagrees is treated as tampering and aborts the install
#       b) at least TWO independent channels (different mirror operators, or the
#          official channel plus one mirror) report the SAME value -> accept it
#       c) the official direct channel alone -> accept it
#       d) a single proxy channel is the only source -> refuse to install
#     Consequence: one compromised proxy cannot forge a checksum (it has no partner
#     to agree with), while a genuinely new release still installs on day one.
#  4. The final download source, where the checksum came from, and the verification
#     result are printed explicitly.
#  5. Only 'bsk --version' is executed after install; nothing else.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk.ps1 -UseMirror
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk.ps1 -CheckOnly
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk.ps1 -Version 0.4.0
#
# Env:
#   BSK_INSTALL_DIR  target dir (default: $HOME\.local\bin)
#   BSK_VERSION      pin version (same as -Version)
param(
    [string]$Version = "",
    [string]$InstallDir = "",
    [int]$TimeoutSec = 30,
    [switch]$UseMirror,
    [switch]$DirectOnly,
    [switch]$CheckOnly,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "mirror-lib.ps1")

$Repo = "Tencent/BrowserSkill"
$GitHub = "https://github.com/$Repo"

# ---- Pinned SHA256 of official artifacts (integrity anchor, independent of download channel) ----
# Values are taken from the official release manifest once, reviewed, and frozen here.
$KnownSha256 = @{
    "0.4.1" = "f4a62af2dde31508188ea0c80feee11dbb62d9e7b7bf388f3f3a9856cfffb37d"
    "0.4.0" = "6feeb22e608e63e3049b2611cf48fce73daac2420945c35174c16e784cdb2677"
}

if (-not $InstallDir) { $InstallDir = if ($env:BSK_INSTALL_DIR) { $env:BSK_INSTALL_DIR } else { Join-Path $HOME ".local\bin" } }
if (-not $Version -and $env:BSK_VERSION) { $Version = $env:BSK_VERSION }

function Write-Log($msg) { if (-not $Quiet) { Write-Host "==> $msg" -ForegroundColor Cyan } }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

# ---- source selection ----
# default      : official GitHub direct first, then opt-in mirrors as fallback
# -DirectOnly  : official GitHub direct only (strictest)
# -UseMirror   : mirrors first (fastest on networks where github.com is blocked), origin last
function Get-Sources {
    param([string]$Kind)
    $list = @()
    if ($DirectOnly) {
        $list += @{ name = "origin"; mode = "direct" }
        return $list
    }
    if ($UseMirror) {
        foreach ($m in (Get-MirrorList -Kind $Kind)) { $list += @{ name = $m; mode = "mirror" } }
        $list += @{ name = "origin"; mode = "direct" }
        return $list
    }
    $list += @{ name = "origin"; mode = "direct" }
    foreach ($m in (Get-MirrorList -Kind $Kind)) { $list += @{ name = $m; mode = "mirror" } }
    return $list
}

function Get-SourceUri {
    param($Source, [string]$Url)
    if ($Source.mode -eq "direct") { return $Url }
    return (Get-MirrorTarget -Mirror $Source.name -Url $Url)
}

# Download a file from the allowed sources and verify its SHA256.
function Fetch-Verified {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Kind,
        [string]$ExpectedSha,
        [int]$TimeoutSec,
        [switch]$Quiet
    )
    $result = @{ ok = $false; source = $null; mode = $null; bytes = 0; sha256 = $null; expected = $ExpectedSha; errors = @() }
    foreach ($s in (Get-Sources -Kind $Kind)) {
        $uri = Get-SourceUri -Source $s -Url $Url
        if (-not $uri) { continue }
        if (-not $Quiet) { Write-Host ("    source: {0} ({1})" -f $s.name, $s.mode) -ForegroundColor DarkGray }
        try {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            $reqArgs = New-BskRequestArgs -Base @{
                Uri = $uri; OutFile = $OutFile; TimeoutSec = $TimeoutSec; UseBasicParsing = $true; ErrorAction = "Stop"
            }
            Invoke-WebRequest @reqArgs

            if (-not (Test-Path -LiteralPath $OutFile)) { throw "no output file" }
            $len = (Get-Item -LiteralPath $OutFile).Length
            if ($len -le 0) { throw "empty file" }

            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash
            if ($ExpectedSha -and ($hash -ine $ExpectedSha)) {
                throw ("sha256 mismatch: expected {0}, got {1}" -f $ExpectedSha, $hash)
            }

            $result.ok = $true
            $result.source = $s.name
            $result.mode = $s.mode
            $result.bytes = $len
            $result.sha256 = $hash
            return $result
        } catch {
            $result.errors += ("{0}: {1}" -f $s.name, $_.Exception.Message)
            if (-not $Quiet) { Write-Host ("      fail: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
        }
    }
    return $result
}

# ---------- CheckOnly ----------
if ($CheckOnly) {
    $modeText = if ($DirectOnly) { "official GitHub direct only (-DirectOnly)" }
                elseif ($UseMirror) { "mirrors first, origin last (-UseMirror)" }
                else { "official GitHub direct first, mirrors as fallback (default)" }
    Write-Log ("mode: {0}" -f $modeText)
    if (-not $DirectOnly) {
        Write-Log "probing mirrors (HEAD request)"
        $rows = Test-Mirrors -Url "https://raw.githubusercontent.com/$Repo/main/README.md" -Kind "raw" -TimeoutSec $TimeoutSec
        $rows | Sort-Object -Property @{Expression={-$_.ok}},@{Expression={$_.ms}} | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
    Write-Log ("frozen checksums (extra anchors, NOT version gates): {0}" -f (($KnownSha256.Keys | Sort-Object) -join ", "))
    Write-Log "behaviour: always installs the latest release; unfrozen releases are accepted when >=2 independent channels agree"
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bsk-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # ---------- 1. resolve version + collect the checksum each channel reports ----------
    # Always target the LATEST release unless the caller pins a version explicitly.
    # Pins in $KnownSha256 are an extra anchor, never a version gate.
    if ($Version) {
        $Version = $Version -replace '^v', ''
        Write-Log "pinned version: $Version"
        $manifestUrl = "$GitHub/releases/download/cli-v$Version/version.json"
    } else {
        $manifestUrl = "$GitHub/releases/latest/download/version.json"
        Write-Log "resolving latest version from every allowed channel"
    }

    function Read-ManifestFromSource {
        param($Source, [string]$Url, [int]$TimeoutSec)
        $uri = Get-SourceUri -Source $Source -Url $Url
        if (-not $uri) { return $null }
        $f = Join-Path $tmp ("manifest-" + [Guid]::NewGuid().ToString("N") + ".json")
        try {
            $reqArgs = New-BskRequestArgs -Base @{
                Uri = $uri; OutFile = $f; TimeoutSec = $TimeoutSec; UseBasicParsing = $true; ErrorAction = "Stop"
            }
            Invoke-WebRequest @reqArgs
            $obj = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $sha = $null
            if ($obj.assets -and $obj.assets."windows-x64") { $sha = $obj.assets."windows-x64".sha256 }
            return [pscustomobject]@{
                channel = $Source.name; mode = $Source.mode; ok = $true; version = $obj.version; sha = $sha; error = $null
            }
        } catch {
            return [pscustomobject]@{
                channel = $Source.name; mode = $Source.mode; ok = $false; version = $null; sha = $null; error = $_.Exception.Message
            }
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    $probes = @()
    foreach ($s in (Get-Sources -Kind "release")) {
        if (-not $Quiet) { Write-Host ("    probe: {0} ({1})" -f $s.name, $s.mode) -ForegroundColor DarkGray }
        $pr = Read-ManifestFromSource -Source $s -Url $manifestUrl -TimeoutSec $TimeoutSec
        if ($pr) { $probes += $pr }
    }
    $okProbes = @($probes | Where-Object { $_.ok })
    if (-not $okProbes) { throw "version manifest unavailable from every allowed channel" }

    if (-not $Version) {
        $official = $okProbes | Where-Object { $_.mode -eq "direct" } | Select-Object -First 1
        if ($official -and $official.version) {
            $Version = $official.version
        } else {
            $Version = ($okProbes | Group-Object -Property { $_.version } | Sort-Object -Property Count -Descending | Select-Object -First 1).Name
        }
        if (-not $Version) { throw "could not determine bsk version" }
        $newest = @($okProbes | ForEach-Object { $_.version } | Sort-Object -Unique)
        if ($newest.Count -gt 1) {
            Write-Warn ("channels report different versions ({0}); installing {1} (official answer wins, otherwise the most common)" -f ($newest -join ", "), $Version)
        }
    }
    Write-Log "version: $Version"

    # ---------- 2. decide the expected SHA256 ----------
    # v1.1.4 rule: never block a newer release just because it is not frozen in this file.
    #   a) pinned in package                -> must match, and any channel disagreeing is a red flag
    #   b) >=2 independent channels agree   -> accept that value (one proxy cannot forge agreement)
    #   c) the official direct channel says -> accept
    #   d) anything else (single proxy only)-> refuse
    $pinnedSha = $KnownSha256[$Version]
    $reports = @($okProbes | Where-Object { $_.version -eq $Version -and $_.sha })
    $groups = @($reports | Group-Object -Property { $_.sha })

    if ($pinnedSha) {
        $expectedSha = $pinnedSha
        $shaSource = "pinned in package"
        Write-Log "checksum: pinned in this package"
        $disagree = @($reports | Where-Object { $_.sha -ine $pinnedSha })
        if ($disagree.Count -gt 0) {
            throw ("pinned checksum for {0} is {1}, but {2} report a different value. Possible tampering - refusing to install." -f `
                $Version, $pinnedSha, (($disagree | ForEach-Object { $_.channel + "=" + $_.sha }) -join "; "))
        }
    } else {
        if ($groups.Count -eq 0) {
            throw "no SHA256 available for bsk $Version (not pinned, absent from every manifest). Refusing to install."
        }
        if ($groups.Count -gt 1) {
            throw ("channels disagree on the SHA256 for bsk {0}: {1}. Refusing to install." -f $Version,
                (($groups | ForEach-Object { "$($_.Name) <= " + (($_.Group | ForEach-Object { $_.channel }) -join "/") }) -join " | "))
        }
        $winner = $groups[0]
        $chans = @($winner.Group | ForEach-Object { $_.channel } | Select-Object -Unique)
        $hasOfficial = @($winner.Group | Where-Object { $_.mode -eq "direct" }).Count -gt 0
        if ($hasOfficial -or $chans.Count -ge 2) {
            $expectedSha = $winner.Name
            $shaSource = if ($hasOfficial) { "official manifest (direct)" } else { "agreed by $($chans.Count) channels: $($chans -join ', ')" }
            if (-not $hasOfficial) {
                Write-Warn ("$Version is not frozen in this package; using the SHA256 that $($chans.Count) independent channels agree on")
            }
        } else {
            throw ("no trustworthy SHA256 for bsk {0}: only one proxy channel ({1}) reported a value. Use -DirectOnly, or let a second channel confirm it." -f $Version, ($chans -join ","))
        }
    }

    # ---------- 3. download archive ----------
    $archiveName = "bsk-v$Version-x86_64-pc-windows-msvc.zip"
    $downloadUrl = "$GitHub/releases/download/cli-v$Version/$archiveName"
    $archivePath = Join-Path $tmp $archiveName

    Write-Log "downloading $archiveName"
    $r2 = Fetch-Verified -Url $downloadUrl -OutFile $archivePath -Kind release -ExpectedSha $expectedSha -TimeoutSec $TimeoutSec -Quiet:$Quiet
    if (-not $r2.ok) {
        Write-Warn "download failed on every allowed source"
        if ($DirectOnly) {
            Write-Warn "you used -DirectOnly; drop it to allow mirror fallback when github.com is unreachable"
        }
        throw "archive download failed"
    }

    # ---------- 4. explicit verification report ----------
    Write-Host ""
    Write-Host "---- integrity report ----" -ForegroundColor Cyan
    Write-Host ("  source        : {0} ({1})" -f $r2.source, $r2.mode)
    Write-Host ("  checksum from : {0}" -f $shaSource)
    Write-Host ("  expected sha256: {0}" -f $expectedSha)
    Write-Host ("  actual   sha256: {0}" -f $r2.sha256)
    Write-Host ("  verified      : {0}" -f $(if ($r2.sha256 -ieq $expectedSha) { "OK" } else { "MISMATCH" }))
    Write-Host ("  bytes         : {0:N0}" -f $r2.bytes)
    Write-Host "--------------------------" -ForegroundColor Cyan
    Write-Host ""

    if ($r2.sha256 -ine $expectedSha) { throw "sha256 verification failed; aborting before extraction" }

    # ---------- 5. extract ----------
    Write-Log "extracting"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractDir = Join-Path $tmp "extract"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractDir)
    $newExe = Join-Path $extractDir "bsk.exe"
    if (-not (Test-Path -LiteralPath $newExe)) { throw "bsk.exe not found in archive" }

    # ---------- 6. stop existing daemon (best effort) ----------
    $targetExe = Join-Path $InstallDir "bsk.exe"
    if (Test-Path -LiteralPath $targetExe) {
        Write-Log "stopping existing daemon (best effort)"
        try {
            & $targetExe daemon stop 2>$null | Out-Null
            Start-Sleep -Milliseconds 800
        } catch { Write-Warn "daemon stop failed (may be harmless)" }
    }

    # ---------- 7. replace binary ----------
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $staged = "$targetExe.install-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.File]::Copy($newExe, $staged, $true)

    $replaced = $false
    for ($i = 1; $i -le 5; $i++) {
        try {
            if ([System.IO.File]::Exists($targetExe)) {
                [System.IO.File]::Replace($staged, $targetExe, [NullString]::Value)
            } else {
                [System.IO.File]::Move($staged, $targetExe)
            }
            $replaced = $true
            break
        } catch {
            Write-Warn ("replace attempt {0} failed: {1}" -f $i, $_.Exception.Message)
            Start-Sleep -Milliseconds 700
        }
    }
    if (-not $replaced) { throw "could not replace $targetExe (file locked?)" }
    Write-Log "installed to $targetExe"

    # ---------- 8. PATH (user env + bashrc) ----------
    try {
        $cur = @([Environment]::GetEnvironmentVariable("PATH", "User") -split ";" | Where-Object { $_ })
        $newPath = (@($InstallDir) + @($cur | Where-Object { $_ -ine $InstallDir })) -join ";"
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Log "user PATH updated"
    } catch { Write-Warn "user PATH update failed" }

    try {
        $bashrc = Join-Path $HOME ".bashrc"
        $unix = $InstallDir -replace '\\', '/'
        if ($unix -match '^([A-Za-z]):(.*)$') { $unix = '/' + $matches[1].ToLower() + $matches[2] }
        $line = "export PATH='$unix':`"`$PATH`"  # bsk CLI"
        $has = (Test-Path -LiteralPath $bashrc) -and ([System.IO.File]::ReadAllText($bashrc).Contains($line))
        if (-not $has) {
            [System.IO.File]::AppendAllText($bashrc, "`n$line`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Log "~/.bashrc updated"
        }
    } catch { Write-Warn "bashrc update failed" }

    # ---------- 9. verify install (only --version, nothing else) ----------
    $ver = (& $targetExe --version 2>$null | Out-String).Trim()
    Write-Log "verify: $ver"
    if ($LASTEXITCODE -ne 0 -or -not $ver) { throw "installed bsk failed verification" }

    Write-Host ""
    Write-Host ("DONE  version={0}  source={1}({2})  sha256=OK  install_dir={3}" -f $Version, $r2.source, $r2.mode, $InstallDir) -ForegroundColor Green
    Write-Host "note: PATH changes apply to NEW shells; call the binary by absolute path in the current session."
    Write-Host "note: the installer only ran 'bsk --version'. Review the skill before granting broader use."
}
catch {
    $msg = $_.Exception.Message
    Write-Host ""
    Write-Host ("FAILED: {0}" -f $msg) -ForegroundColor Red
    if ($msg -match 'checksum|SHA256|disagree|tampering') {
        Write-Host "hint: this is an integrity guard, not a network problem. It clears itself when a second" -ForegroundColor Yellow
        Write-Host "      independent channel confirms the same checksum, or when you use -DirectOnly." -ForegroundColor Yellow
        Write-Host "      Manual update path: references/manual-cli-update.md" -ForegroundColor Yellow
    } elseif ($DirectOnly) {
        Write-Host "hint: -DirectOnly restricts downloads to github.com. Drop it to allow mirror fallback." -ForegroundColor Yellow
    } else {
        Write-Host "hint: official source and mirrors both failed. Check network, or see references/deployment-guide.md." -ForegroundColor Yellow
    }
    exit 1
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
