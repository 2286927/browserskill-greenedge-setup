# mirror-lib.ps1 - OPTIONAL GitHub mirror acceleration for browserskill-greenedge-setup
# Dot-source this file: . "$PSScriptRoot\mirror-lib.ps1"
#
# SECURITY NOTE (v1.1.1):
# The default install path uses GitHub directly (origin only). Mirrors are an
# OPT-IN fallback for networks where github.com is unreachable, and must be
# enabled explicitly with -UseMirror.
#
# The following proxy hosts were removed from the list because third-party threat
# intelligence flagged them (cdn.gh-proxy.org m=8, ghfast.top m=8, hk.gh-proxy.org m=5
# at 2026-11-01). Do not re-add a host without checking its reputation first.
#
# Integrity anchor: artifact SHA256 values are pinned in install_bsk.ps1
# ($KnownSha256) and never trusted from the mirror channel alone.

$script:ReleaseMirrors = @(
    "https://gh-proxy.org/https://github.com",
    "https://ghproxy.net/https://github.com",
    "https://wget.la/https://github.com"
)

$script:RawMirrors = @(
    "https://gh-proxy.org/https://raw.githubusercontent.com",
    "https://wget.la/https://raw.githubusercontent.com"
)

function Get-MirrorTarget {
    param([string]$Mirror, [string]$Url)
    try {
        $u = [System.Uri]$Url
        return ($Mirror.TrimEnd('/') + $u.PathAndQuery)
    } catch {
        return $null
    }
}

function Get-MirrorList {
    param([string]$Kind = "release")
    switch ($Kind) {
        "raw" { return $script:RawMirrors }
        default { return $script:ReleaseMirrors }
    }
}

# Probe reachability of each mirror for a small file; returns list of {name, ok, ms, status}
function Test-Mirrors {
    param(
        [string]$Url = "https://raw.githubusercontent.com/Tencent/BrowserSkill/main/README.md",
        [string]$Kind = "raw",
        [int]$TimeoutSec = 8
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $out = @()
    $targets = @()
    foreach ($m in (Get-MirrorList -Kind $Kind)) { $targets += @{ name = $m; uri = (Get-MirrorTarget -Mirror $m -Url $Url) } }
    $targets += @{ name = "origin"; uri = $Url }
    foreach ($t in $targets) {
        if (-not $t.uri) { continue }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri $t.uri -TimeoutSec $TimeoutSec -UseBasicParsing -Method Head -ErrorAction Stop
            $sw.Stop()
            $out += [pscustomobject]@{ mirror = $t.name; ok = $true; ms = $sw.ElapsedMilliseconds; status = $resp.StatusCode }
        } catch {
            $sw.Stop()
            $out += [pscustomobject]@{ mirror = $t.name; ok = $false; ms = $sw.ElapsedMilliseconds; status = $_.Exception.Message }
        }
    }
    return $out
}
