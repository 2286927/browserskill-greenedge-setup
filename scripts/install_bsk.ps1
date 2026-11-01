# install_bsk.ps1 - Install bsk CLI with a pinned integrity anchor.
#
# SECURITY MODEL (v1.1.2, revised after a supply-chain review):
#  1. DEFAULT SOURCE ORDER: try GitHub official (origin) first; if unreachable,
#     fall back to mirrors. Official source always has priority.
#  2. -DirectOnly disables mirrors entirely (strictest); -UseMirror puts mirrors
#     first for networks where github.com is blocked. Hosts previously flagged by
#     threat intelligence were removed from mirror-lib.ps1.
#  3. Integrity: artifact SHA256 values are PINNED in this file ($KnownSha256).
#     Mirrors cannot substitute content: a modified artifact fails the checksum.
#     If a version has no pinned value AND the manifest has none -> hard fail.
#  4. The final download source and the verification result are printed explicitly.
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
            Invoke-WebRequest -Uri $uri -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop

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
    Write-Log ("pinned versions with built-in sha256: {0}" -f (($KnownSha256.Keys | Sort-Object) -join ", "))
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bsk-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # ---------- 1. resolve version ----------
    if ($Version) {
        $Version = $Version -replace '^v', ''
        Write-Log "pinned version: $Version"
        $manifestUrl = "$GitHub/releases/download/cli-v$Version/version.json"
    } else {
        $manifestUrl = "$GitHub/releases/latest/download/version.json"
        Write-Log "fetching version manifest"
    }

    $manifest = $null
    $r = Fetch-Verified -Url $manifestUrl -OutFile (Join-Path $tmp "version.json") -Kind release -ExpectedSha "" -TimeoutSec $TimeoutSec -Quiet:$Quiet
    if ($r.ok) {
        try { $manifest = Get-Content -LiteralPath (Join-Path $tmp "version.json") -Raw | ConvertFrom-Json } catch { $manifest = $null }
    } elseif (-not $Version) {
        Write-Warn "manifest unavailable; cannot resolve latest version"
        throw "version manifest download failed"
    }

    if (-not $Version -and $manifest -and $manifest.version) { $Version = $manifest.version }
    if (-not $Version) { throw "could not determine bsk version" }
    Write-Log "version: $Version"

    # ---------- 2. choose expected SHA256 (pinned value wins) ----------
    $asset = $null
    if ($manifest -and $manifest.assets) { $asset = $manifest.assets."windows-x64" }
    $manifestSha = if ($asset) { $asset.sha256 } else { "" }
    $pinnedSha = $KnownSha256[$Version]

    if ($pinnedSha) {
        $expectedSha = $pinnedSha
        Write-Log "checksum: pinned in package (independent of download channel)"
    } elseif ($manifestSha) {
        $expectedSha = $manifestSha
        Write-Warn "no pinned checksum for $Version; falling back to the official manifest value"
    } else {
        # Hard fail: never install an artifact we cannot verify.
        throw "no SHA256 available for bsk $Version (not pinned in package, absent from manifest). Refusing to install."
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
    Write-Host ""
    Write-Host ("FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($DirectOnly) {
        Write-Host "hint: -DirectOnly restricts downloads to github.com. Drop it to allow mirror fallback." -ForegroundColor Yellow
    } else {
        Write-Host "hint: official source and mirrors both failed. Check network, or see references/deployment-guide.md." -ForegroundColor Yellow
    }
    exit 1
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
