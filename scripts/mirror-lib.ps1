# mirror-lib.ps1 - GitHub mirror acceleration library for browserskill-greenedge-setup
# Dot-source this file: . "$PSScriptRoot\mirror-lib.ps1"
# Then call: $r = Download-WithMirror -Url <full original url> -OutFile <path> -Kind release|raw
#
# Mirror list derived from XIU2/UserScript GithubEnhanced-High-Speed-Download.user.js
# (public, community-maintained). Order = try order. All are "prefix proxies":
# target = <mirror prefix> + <original url PathAndQuery>

$script:ReleaseMirrors = @(
    "https://cdn.gh-proxy.org/https://github.com",
    "https://gh-proxy.org/https://github.com",
    "https://hk.gh-proxy.org/https://github.com",
    "https://ghproxy.net/https://github.com",
    "https://wget.la/https://github.com",
    "https://ghfast.top/https://github.com"
)

$script:RawMirrors = @(
    "https://cdn.gh-proxy.org/https://raw.githubusercontent.com",
    "https://hk.gh-proxy.org/https://raw.githubusercontent.com",
    "https://wget.la/https://raw.githubusercontent.com",
    "https://ghfast.top/https://raw.githubusercontent.com"
)

$script:CloneMirrors = @(
    "https://hk.gh-proxy.org/https://github.com",
    "https://ghfast.top/https://github.com",
    "https://githubfast.com",
    "https://gitclone.com/github.com"
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
        "raw"   { return $script:RawMirrors }
        "clone" { return $script:CloneMirrors }
        default { return $script:ReleaseMirrors }
    }
}

# Downloads a file trying each mirror in order, then the original URL as last resort.
# Returns a hashtable: @{ ok = $true/$false; source = <mirror or 'origin'>; bytes; sha256; errors = @() }
function Download-WithMirror {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Kind = "release",
        [string]$ExpectedSha256 = "",
        [int]$TimeoutSec = 20,
        [switch]$NoOriginFallback,
        [switch]$Quiet
    )

    $ErrorActionPreference = "Continue"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $result = @{ ok = $false; source = $null; bytes = 0; sha256 = $null; errors = @() }
    $mirrors = Get-MirrorList -Kind $Kind

    $candidates = @()
    foreach ($m in $mirrors) {
        $t = Get-MirrorTarget -Mirror $m -Url $Url
        if ($t) { $candidates += @{ name = $m; uri = $t } }
    }
    if (-not $NoOriginFallback) { $candidates += @{ name = "origin"; uri = $Url } }

    foreach ($c in $candidates) {
        if (-not $Quiet) { Write-Host ("  -> try {0}" -f $c.name) -ForegroundColor DarkGray }
        try {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            Invoke-WebRequest -Uri $c.uri -OutFile $OutFile -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop

            if (-not (Test-Path -LiteralPath $OutFile)) { throw "no output file" }
            $len = (Get-Item -LiteralPath $OutFile).Length
            if ($len -le 0) { throw "empty file" }

            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash
            if ($ExpectedSha256 -and ($hash -ine $ExpectedSha256)) {
                throw ("sha256 mismatch (expect {0})" -f $ExpectedSha256)
            }

            $result.ok = $true
            $result.source = $c.name
            $result.bytes = $len
            $result.sha256 = $hash
            if (-not $Quiet) { Write-Host ("     ok via {0} ({1} bytes)" -f $c.name, $len) -ForegroundColor Green }
            return $result
        } catch {
            $msg = ("{0}: {1}" -f $c.name, $_.Exception.Message)
            $result.errors += $msg
            if (-not $Quiet) { Write-Host ("     fail: {0}" -f $msg) -ForegroundColor DarkYellow }
        }
    }

    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    return $result
}

# Probe reachability of each mirror for a small file; returns list of {name, ok, ms}
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
