# install_bsk_mirror.ps1 - Install bsk CLI via GitHub mirrors (for unstable GitHub access)
#
# Why this exists: the official install.ps1 hardcodes https://github.com for its
# own downloads, so it cannot be accelerated by a prefix proxy. This script
# re-implements the same steps but fetches through mirrors first, then falls back
# to the original GitHub URL, with SHA256 verification at every hop.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk_mirror.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk_mirror.ps1 -CheckOnly
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_bsk_mirror.ps1 -Version 0.4.0
#
# Env:
#   BSK_INSTALL_DIR  target dir (default: $HOME\.local\bin)
#   BSK_VERSION      pin version (same as -Version)
param(
    [string]$Version = "",
    [string]$InstallDir = "",
    [int]$TimeoutSec = 25,
    [switch]$CheckOnly,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "mirror-lib.ps1")

$Repo = "Tencent/BrowserSkill"
$GitHub = "https://github.com/$Repo"
if (-not $InstallDir) { $InstallDir = if ($env:BSK_INSTALL_DIR) { $env:BSK_INSTALL_DIR } else { Join-Path $HOME ".local\bin" } }
if (-not $Version -and $env:BSK_VERSION) { $Version = $env:BSK_VERSION }

function Write-Log($msg) { if (-not $Quiet) { Write-Host "==> $msg" -ForegroundColor Cyan } }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

# ---------- CheckOnly: probe mirrors ----------
if ($CheckOnly) {
    Write-Log "probing mirrors (raw kind, HEAD request)"
    $rows = Test-Mirrors -Url "https://raw.githubusercontent.com/$Repo/main/README.md" -Kind "raw" -TimeoutSec $TimeoutSec
    $rows | Sort-Object -Property @{Expression={-$_.ok}},@{Expression={$_.ms}} | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $okCount = @($rows | Where-Object { $_.ok }).Count
    Write-Log ("reachable: {0}/{1}" -f $okCount, $rows.Count)
    if ($okCount -eq 0) { Write-Warn "no mirror reachable; network may be fully blocked" }
    exit 0
}

# ---------- 1. resolve version ----------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bsk-mirror-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    if ($Version) {
        $Version = $Version -replace '^v', ''
        Write-Log "pinned version: $Version"
        $manifestUrl = "$GitHub/releases/download/cli-v$Version/version.json"
        $manifest = $null
        try {
            $r = Download-WithMirror -Url $manifestUrl -OutFile (Join-Path $tmp "version.json") -Kind release -TimeoutSec $TimeoutSec -Quiet:$Quiet
            if ($r.ok) { $manifest = Get-Content -LiteralPath (Join-Path $tmp "version.json") -Raw | ConvertFrom-Json }
        } catch { $manifest = $null }
    } else {
        $manifestUrl = "$GitHub/releases/latest/download/version.json"
        Write-Log "fetching version.json via mirrors"
        $r = Download-WithMirror -Url $manifestUrl -OutFile (Join-Path $tmp "version.json") -Kind release -TimeoutSec $TimeoutSec -Quiet:$Quiet
        if (-not $r.ok) {
            Write-Warn "could not fetch version.json from any mirror or origin"
            throw "version.json download failed (all mirrors + origin)"
        }
        $manifest = Get-Content -LiteralPath (Join-Path $tmp "version.json") -Raw | ConvertFrom-Json
        $Version = $manifest.version
        if (-not $Version) { throw "could not parse version from version.json" }
        Write-Log "latest version: $Version"
    }

    # ---------- 2. download archive ----------
    $platformKey = "windows-x64"
    $asset = $null
    if ($manifest -and $manifest.assets) { $asset = $manifest.assets.$platformKey }
    $expectedSha = if ($asset) { $asset.sha256 } else { "" }
    if (-not $expectedSha) { Write-Warn "no checksum published; verification skipped" }

    $archiveName = "bsk-v$Version-x86_64-pc-windows-msvc.zip"
    $downloadUrl = "$GitHub/releases/download/cli-v$Version/$archiveName"
    $archivePath = Join-Path $tmp $archiveName

    Write-Log "downloading $archiveName via mirrors"
    $r2 = Download-WithMirror -Url $downloadUrl -OutFile $archivePath -Kind release -ExpectedSha256 $expectedSha -TimeoutSec $TimeoutSec -Quiet:$Quiet
    if (-not $r2.ok) {
        Write-Warn "archive download failed on every source"
        throw "archive download failed (all mirrors + origin)"
    }
    Write-Log ("archive ok via {0} ({1:N0} bytes)" -f $r2.source, $r2.bytes)

    # ---------- 3. extract ----------
    Write-Log "extracting"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractDir = Join-Path $tmp "extract"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractDir)
    $newExe = Join-Path $extractDir "bsk.exe"
    if (-not (Test-Path -LiteralPath $newExe)) { throw "bsk.exe not found in archive" }

    # ---------- 4. stop existing daemon (best effort) ----------
    $targetExe = Join-Path $InstallDir "bsk.exe"
    if (Test-Path -LiteralPath $targetExe) {
        Write-Log "stopping existing daemon (best effort)"
        try {
            & $targetExe daemon stop 2>$null | Out-Null
            Start-Sleep -Milliseconds 800
        } catch { Write-Warn "daemon stop failed (may be harmless)" }
    }

    # ---------- 5. replace binary ----------
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

    # ---------- 6. PATH (user env + bashrc) ----------
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

    # ---------- 7. verify ----------
    $ver = (& $targetExe --version 2>$null | Out-String).Trim()
    Write-Log "verify: $ver"
    if ($LASTEXITCODE -ne 0 -or -not $ver) { throw "installed bsk failed verification" }

    Write-Host ""
    Write-Host ("DONE  version={0}  source={1}  install_dir={2}" -f $Version, $r2.source, $InstallDir) -ForegroundColor Green
    Write-Host "note: PATH changes apply to NEW shells; always call the binary by absolute path in the current session."
}
catch {
    Write-Host ""
    Write-Host ("FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "fallback: try the official installer (direct GitHub, needs stable access):" -ForegroundColor Yellow
    Write-Host '  irm https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1 -OutFile "$env:TEMP\bsk_install.ps1"' -ForegroundColor Yellow
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\bsk_install.ps1"' -ForegroundColor Yellow
    exit 1
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
