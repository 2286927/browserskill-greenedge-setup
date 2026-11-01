# detect_edge.ps1 - Detect portable ("green") Edge install, launcher, user data dir,
# BrowserSkill extension, bsk CLI and daemon status. Prints one JSON object to stdout.
# Read-only: this script never installs, starts or changes anything.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File detect_edge.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File detect_edge.ps1 -EdgeDir "D:\Program Files\Microsoft Edge"
#   powershell -NoProfile -ExecutionPolicy Bypass -File detect_edge.ps1 -SkipScan   # skip the bounded folder scan (fastest)
param(
    [string]$EdgeDir = "",
    [switch]$SkipScan
)

$ErrorActionPreference = "SilentlyContinue"
$EXT_ID = "emacgiaaaiojkkpkddmmdfhmokgmnikg"   # BrowserSkill extension id (Edge Add-ons)

function Test-ExePath([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $true }
    return $false
}

# ---- 1. Locate msedge.exe (4 strategies, cheapest first) ----
function Find-ExeUnder([string]$root) {
    if (-not $root) { return $null }
    foreach ($sub in @("App\msedge.exe", "Application\msedge.exe", "msedge.exe")) {
        $p = Join-Path $root $sub
        if (Test-ExePath $p) { return $p }
    }
    return $null
}

$driveRoots = @(Get-PSDrive -PSProvider FileSystem |
    Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
    ForEach-Object { $_.Root })

$found = $null
$foundVia = $null

# 1a. explicit directory supplied by the caller
if ($EdgeDir -ne "") {
    $p = Find-ExeUnder $EdgeDir
    if ($p) { $found = $p; $foundVia = "explicit -EdgeDir" }
}

# 1b. well-known locations on every fixed drive (covers portable / repack layouts)
if (-not $found) {
    $relCands = @(
        "Program Files\Microsoft Edge\App\msedge.exe",
        "Program Files (x86)\Microsoft Edge\App\msedge.exe",
        "Program Files\Microsoft Edge\Application\msedge.exe",
        "Program Files (x86)\Microsoft Edge\Application\msedge.exe",
        "Microsoft Edge\App\msedge.exe",
        "Apps\Microsoft Edge\App\msedge.exe",
        "Software\Microsoft Edge\App\msedge.exe",
        "Tools\Microsoft Edge\App\msedge.exe",
        "Portable\Microsoft Edge\App\msedge.exe"
    )
    foreach ($r in $driveRoots) {
        foreach ($rel in $relCands) {
            $c = Join-Path $r $rel
            if (Test-ExePath $c) { $found = $c; $foundVia = "well-known path"; break }
        }
        if ($found) { break }
    }
    if (-not $found) {
        foreach ($c in @(
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        )) {
            if (Test-ExePath $c) { $found = $c; $foundVia = "well-known path (official layout)"; break }
        }
    }
}

# 1c. registry App Paths (official installers and some repacks register the exe here)
if (-not $found) {
    foreach ($k in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    )) {
        $v = $null
        try { $v = (Get-ItemProperty -Path $k -ErrorAction Stop).'(default)' } catch { $v = $null }
        if ($v) {
            $v = $v.Trim('"')
            if (Test-ExePath $v) { $found = $v; $foundVia = "registry App Paths"; break }
        }
    }
}

# 1d. bounded scan for renamed / non-standard portable folders (depth 3, never full-disk)
if (-not $found -and -not $SkipScan) {
    $skipNames = '^(Windows|WindowsApps|Windows\.old|\$Recycle\.Bin|System Volume Information|Recovery|PerfLogs|node_modules|AppData)$'
    $containerNames = '^(Program Files( \(x86\))?|Programs|Apps|Software|Tools|Green|Portable|Applications|应用|软件|工具|绿色|便携)$'
    foreach ($r in $driveRoots) {
        $lvl1 = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch $skipNames })
        foreach ($a in $lvl1) {
            # a\ 直接就是 Edge 目录
            if ($a.Name -match 'Edge|msedge|浏览器') {
                $p = Find-ExeUnder $a.FullName
                if ($p) { $found = $p; $foundVia = "scan depth 1"; break }
            }
            # a\ 是容器目录（Program Files / Apps / Software ...）
            if ($a.Name -match $containerNames) {
                foreach ($b in @(Get-ChildItem -LiteralPath $a.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if ($b.Name -match 'Edge|msedge') {
                        $p = Find-ExeUnder $b.FullName
                        if ($p) { $found = $p; $foundVia = "scan depth 2"; break }
                    }
                    # 厂商子目录下的 Microsoft Edge（如 Program Files\Vendor\Microsoft Edge）
                    $nested = Join-Path $b.FullName "Microsoft Edge"
                    if (Test-Path -LiteralPath $nested -PathType Container) {
                        $p = Find-ExeUnder $nested
                        if ($p) { $found = $p; $foundVia = "scan depth 3"; break }
                    }
                }
            }
            if ($found) { break }
        }
        if ($found) { break }
    }
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
        found_via = $foundVia
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
    $edgeInfo = [ordered]@{
        found = $false
        searched = [ordered]@{
            explicit_dir = $(if ($EdgeDir) { $EdgeDir } else { $null })
            well_known_paths = $true
            registry_app_paths = $true
            bounded_scan = (-not $SkipScan)
            drives = $driveRoots
        }
        hint = "Edge not found. Ask the user for the folder that contains msedge.exe and rerun with -EdgeDir '<folder>'."
    }
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
