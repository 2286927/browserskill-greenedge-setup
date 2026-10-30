# detect_edge.ps1 - Detect portable ("green") Edge install, launcher, user data dir,
# BrowserSkill extension, bsk CLI and daemon status. Prints one JSON object to stdout.
# Read-only: this script never installs, starts or changes anything.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File detect_edge.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File detect_edge.ps1 -EdgeDir "D:\Program Files\Microsoft Edge"
param(
    [string]$EdgeDir = ""
)

$ErrorActionPreference = "SilentlyContinue"
$EXT_ID = "emacgiaaaiojkkpkddmmdfhmokgmnikg"   # BrowserSkill extension id (Edge Add-ons)

function Test-ExePath([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $true }
    return $false
}

# ---- 1. Locate msedge.exe ----
$found = $null
if ($EdgeDir -ne "") {
    foreach ($sub in @("App\msedge.exe", "Application\msedge.exe", "msedge.exe")) {
        $p = Join-Path $EdgeDir $sub
        if (Test-ExePath $p) { $found = $p; break }
    }
} else {
    $cands = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
        $r = $d.Root
        # portable layouts first (App subdir is the typical green/repack layout)
        [void]$cands.Add((Join-Path $r "Program Files\Microsoft Edge\App\msedge.exe"))
        [void]$cands.Add((Join-Path $r "Program Files (x86)\Microsoft Edge\App\msedge.exe"))
        [void]$cands.Add((Join-Path $r "Microsoft Edge\App\msedge.exe"))
        # some repacks keep the standard Application subdir under a custom root
        [void]$cands.Add((Join-Path $r "Program Files\Microsoft Edge\Application\msedge.exe"))
    }
    # official install locations (fallback / comparison)
    [void]$cands.Add("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
    [void]$cands.Add("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe")
    foreach ($c in $cands) { if (Test-ExePath $c) { $found = $c; break } }
}

$edgeInfo = $null
if ($found) {
    # edge root: two levels up (e.g. ...\Microsoft Edge\App\msedge.exe -> ...\Microsoft Edge)
    # note: Split-Path -LiteralPath -Parent is ambiguous in Windows PowerShell 5.1,
    # use the .NET API instead (works on all PowerShell versions)
    $appDir   = [System.IO.Path]::GetDirectoryName($found)
    $edgeRoot = [System.IO.Path]::GetDirectoryName($appDir)
    $version  = (Get-Item -LiteralPath $found).VersionInfo.ProductVersion

    # portable markers inside edge root
    $markers = @()
    if (Test-Path -LiteralPath (Join-Path $edgeRoot "App")) { $markers += "App-dir" }
    foreach ($dn in @("Data", "User Data")) {
        if (Test-Path -LiteralPath (Join-Path $edgeRoot $dn)) { $markers += "DataDir:$dn" }
    }
    if (Test-Path -LiteralPath (Join-Path $edgeRoot "chrome++.ini")) { $markers += "chrome++.ini" }
    if (Test-Path -LiteralPath (Join-Path $appDir   "chrome++.ini")) { $markers += "chrome++.ini(App)" }

    # launcher files (bat / lnk) at edge root; names are listed, not hardcoded (may be non-ASCII)
    $bats = @(); $lnks = @()
    Get-ChildItem -LiteralPath $edgeRoot -File | ForEach-Object {
        if ($_.Extension -ieq ".bat") { $bats += $_.Name }
        if ($_.Extension -ieq ".lnk") { $lnks += $_.Name }
    }

    $isPortable = ($markers.Count -gt 0)

    # ---- 2. User data dir + BrowserSkill extension detection ----
    $dataDir = $null
    foreach ($dn in @("Data", "User Data")) {
        $p = Join-Path $edgeRoot $dn
        if (Test-Path -LiteralPath $p -PathType Container) { $dataDir = $p; break }
    }
    $dataIsPortable = ($null -ne $dataDir)
    if (-not $dataDir) { $dataDir = Join-Path $env:LOCALAPPDATA "Microsoft\Edge" }

    $extInstalled = $false
    $extLocations = @()
    if (Test-Path -LiteralPath $dataDir) {
        $extRoots = @(Join-Path $dataDir "Extensions")
        Get-ChildItem -LiteralPath $dataDir -Directory | ForEach-Object {
            $extRoots += (Join-Path $_.FullName "Extensions")
        }
        foreach ($extRoot in $extRoots) {
            $p = Join-Path $extRoot $EXT_ID
            if (Test-Path -LiteralPath $p) { $extInstalled = $true; $extLocations += $p }
        }
    }

    $edgeInfo = [ordered]@{
        found = $true
        exe = $found
        version = $version
        root = $edgeRoot
        is_portable = $isPortable
        markers = $markers
        launchers = [ordered]@{ direct_exe = $found; bat_files = $bats; lnk_files = $lnks }
        data_dir = $dataDir
        data_dir_is_portable = $dataIsPortable
        browserskill_extension_installed = $extInstalled
        extension_locations = $extLocations
    }
} else {
    $edgeInfo = [ordered]@{ found = $false }
}

# ---- 3. bsk CLI ----
$bskPath = Join-Path $HOME ".local\bin\bsk.exe"
$bskExists = Test-ExePath $bskPath
$bskVersion = $null
if ($bskExists) {
    $bskVersion = ((& $bskPath --version 2>$null) | Out-String).Trim()
}

# ---- 4. daemon status (read-only probe; BSK_AUTO_START=0 prevents implicit startup) ----
$env:BSK_AUTO_START = "0"
$daemonRunning = $false
$daemonInfo = $null
$connectedBrowsers = @()
if ($bskExists) {
    $raw = (& $bskPath status --json 2>$null | Out-String).Trim()
    if ($raw -and $raw.StartsWith("{")) {
        try {
            $st = $raw | ConvertFrom-Json
            if ($st -and $st.pid) {
                $daemonRunning = $true
                $daemonInfo = [ordered]@{ pid = $st.pid; ws_port = $st.ws_port; daemon_version = $st.daemon_version }
                $connectedBrowsers = @($st.browsers | ForEach-Object {
                    [ordered]@{ name = $_.browser_name; version = $_.browser_version; extension = $_.extension_version; sessions = $_.session_count }
                })
            }
        } catch {}
    }
}

# ---- 5. Emit single JSON result ----
$result = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    edge = $edgeInfo
    bsk_cli = [ordered]@{ path = $bskPath; exists = $bskExists; version = $bskVersion }
    daemon = [ordered]@{ running = $daemonRunning; info = $daemonInfo; browsers = $connectedBrowsers }
}
$result | ConvertTo-Json -Depth 6
