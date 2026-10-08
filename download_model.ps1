<#
.SYNOPSIS
    Downloads a GGUF model from Hugging Face into the correct models/ subfolder.
.DESCRIPTION
    Supports:
      - direct resolve URLs (https://huggingface.co/<repo>/resolve/main/<file>)
      - hf:// URIs
      - bare repo + filename
    Optional HF token for gated repos. Token is stored in .hf_token (gitignored)
    only if -SaveToken is passed.

    curl.exe is the DEFAULT downloader. It ships with Windows 10 1803+ and
    Windows 11, and its progress bar renders correctly in cmd.exe consoles.
    System.Net.WebClient is used only when curl.exe is unavailable.

    Progress output:
      - curl: native --progress-bar (stderr, visible in cmd.exe)
      - WebClient: plain-text line, refreshed once per second
.PARAMETER Url
    The model URL or hf:// URI, or "repo" when -Repo and -File are given.
.PARAMETER Repo
    Hugging Face repo id, e.g. "HauhauCS/Qwen3.5-2B-...".
.PARAMETER File
    File name inside the repo, e.g. "Qwen3.5-2B-...-Q8_0.gguf".
.PARAMETER DestDir
    Destination directory (relative or absolute). Defaults to models\<tier>.
.PARAMETER Tier
    Tier folder name: 4GB, 6GB, 8GB, no_gpu, or custom.
.PARAMETER Token
    Hugging Face access token (optional).
.PARAMETER SaveToken
    Persist the token to .hf_token for future runs.
.PARAMETER ShowProgress
    Print live progress. Default on.
.PARAMETER PreferWebClient
    Force the WebClient path even if curl.exe is available.
.PARAMETER StalledSeconds
    Watchdog: if the .partial file does not grow for this many seconds during
    a WebClient download, abort and switch to curl. Default: 60.
#>
param(
    [string]$Url,
    [string]$Repo,
    [string]$File,
    [string]$DestDir,
    [string]$Tier,
    [string]$Token,
    [switch]$SaveToken,
    [bool]$ShowProgress = $true,
    [switch]$PreferWebClient,
    [int]$StalledSeconds = 60
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Sanitize root.
# ---------------------------------------------------------------------------
function Resolve-Root {
    param([string]$Path)
    if (-not $Path) {
        $Path = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not $Path) {
        $Path = (Get-Location).Path
    }
    $Path = $Path.Trim().Trim('"').Trim("'")
    while ($Path.EndsWith('\') -or $Path.EndsWith('/')) {
        $Path = $Path.Substring(0, $Path.Length - 1)
    }
    return $Path
}

$Root = Resolve-Root -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location -LiteralPath $Root

# --- Resolve destination directory ------------------------------------------
if (-not $DestDir) {
    if ($Tier) {
        $DestDir = Join-Path $Root ('models\' + $Tier)
    } else {
        $DestDir = Join-Path $Root 'models\custom'
    }
}
if (-not [System.IO.Path]::IsPathRooted($DestDir)) {
    $DestDir = Join-Path $Root $DestDir
}
if (-not (Test-Path -LiteralPath $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

# --- Normalize URL -----------------------------------------------------------
$resolvedUrl = $null
$resolvedFile = $null

if ($Repo -and $File) {
    $resolvedUrl  = "https://huggingface.co/$Repo/resolve/main/$File"
    $resolvedFile = $File
}
elseif ($Url) {
    if ($Url -match '^hf://(.+?)/(.+?)/(.+)$') {
        $r = $Matches[1] + '/' + $Matches[2]
        $f = $Matches[3]
        $resolvedUrl  = "https://huggingface.co/$r/resolve/main/$f"
        $resolvedFile = $f
    }
    elseif ($Url -match '^https?://') {
        $resolvedUrl  = $Url
        $resolvedFile = [System.IO.Path]::GetFileName(($Url -split '\?')[0])
    }
    else {
        throw "Unrecognized URL or repo spec: $Url"
    }
}
else {
    throw 'You must provide -Url, or -Repo and -File.'
}

if (-not $resolvedFile) {
    throw "Could not determine destination file name from: $resolvedUrl"
}

$destPath = Join-Path $DestDir $resolvedFile
$partial  = $destPath + '.partial'

# --- Token handling ----------------------------------------------------------
if (-not $Token) {
    $tokenFile = Join-Path $Root '.hf_token'
    if (Test-Path -LiteralPath $tokenFile) {
        $Token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
}
if ($SaveToken -and $Token) {
    Set-Content -LiteralPath (Join-Path $Root '.hf_token') -Value $Token -NoNewline -Encoding ASCII
}

# --- Header ------------------------------------------------------------------
Write-Host ''
Write-Host '  --------------------------------------------------------------'
Write-Host ('   Downloading: {0}' -f $resolvedFile)
Write-Host ('   From       : {0}' -f $resolvedUrl)
Write-Host ('   To         : {0}' -f $destPath)
Write-Host '  --------------------------------------------------------------'

if (Test-Path -LiteralPath $destPath) {
    $existing = (Get-Item -LiteralPath $destPath).Length
    if ($existing -gt 0) {
        Write-Host ('   File already exists ({0:N1} MB). Skipping download.' -f ($existing / 1MB))
        Write-Host ''
        return [pscustomobject]@{
            Path    = $destPath
            Bytes   = $existing
            Skipped = $true
            ViaCurl = $false
        }
    }
}

$headers = @{}
if ($Token) {
    $headers['Authorization'] = "Bearer $Token"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-CurlPath {
    $candidates = @(
        'curl.exe',
        (Join-Path $env:SystemRoot 'System32\curl.exe')
    )
    foreach ($c in $candidates) {
        try {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
        } catch {}
    }
    return $null
}

function Get-RemoteSize {
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutMs = 20000)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'HEAD'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $true
        foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
        $resp = $req.GetResponse()
        $len = [int64]$resp.ContentLength
        $resp.Close()
        return $len
    } catch {
        return 0
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Write-DlProgress {
    param(
        [double]$Current,
        [double]$Total,
        [double]$ElapsedSec,
        [switch]$First,
        [switch]$Final
    )
    $speed = if ($ElapsedSec -gt 0.1) { $Current / $ElapsedSec } else { 0 }
    $line = ''
    if ($Total -gt 0) {
        $pct = [Math]::Min(100, ($Current / $Total) * 100)
        $remaining = if ($speed -gt 0) { ($Total - $Current) / $speed } else { 0 }
        $line = ('   [{0,6:N1}%] {1} / {2}   {3:N2} MB/s   ETA {4:N0}s' -f `
            $pct, (Format-Bytes $Current), (Format-Bytes $Total), ($speed / 1MB), $remaining)
    } else {
        $line = ('   {0}   {1:N2} MB/s' -f (Format-Bytes $Current), ($speed / 1MB))
    }

    if ($Final) {
        Write-Host $line -ForegroundColor Green
    } elseif ($First) {
        Write-Host $line
    } else {
        $pad = 100
        Write-Host ("`r" + $line.PadRight($pad)) -NoNewline
    }
}

# ---------------------------------------------------------------------------
# curl downloader (DEFAULT)
# ---------------------------------------------------------------------------
function Invoke-CurlDownload {
    param(
        [string]$Uri,
        [string]$OutFile,
        [hashtable]$Headers,
        [bool]$ShowProgress
    )

    $curl = Get-CurlPath
    if (-not $curl) {
        throw 'curl.exe not found on this system.'
    }

    $args = @(
        '-L',
        '--fail',
        '--retry', '3',
        '--retry-delay', '2',
        '--connect-timeout', '30'
    )
    foreach ($k in $Headers.Keys) {
        $args += @('-H', ("{0}: {1}" -f $k, $Headers[$k]))
    }
    if ($ShowProgress) {
        $args += @('--progress-bar')
    } else {
        $args += @('--silent', '--show-error')
    }
    $args += @('-o', $OutFile, $Uri)

    & $curl @args
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("curl.exe exited with code {0}" -f $code)
    }
}

# ---------------------------------------------------------------------------
# WebClient downloader (FALLBACK when curl is missing)
# ---------------------------------------------------------------------------
function Invoke-WebClientDownload {
    param(
        [string]$Uri,
        [string]$OutFile,
        [hashtable]$Headers,
        [int64]$TotalBytes,
        [bool]$ShowProgress,
        [int]$StalledSeconds
    )

    $wc = New-Object System.Net.WebClient
    foreach ($k in $Headers.Keys) { $wc.Headers.Add($k, $Headers[$k]) }

    $script:wcDone  = $false
    $script:wcError = $null

    $task = [System.Threading.Tasks.Task]::Run([Action]{
        try {
            $wc.DownloadFile($Uri, $OutFile)
        } catch {
            $script:wcError = $_.Exception
        } finally {
            $script:wcDone = $true
        }
    })

    $start      = Get-Date
    $lastSize   = -1
    $lastChange = Get-Date
    $stalled    = $false
    $firstLine  = $true

    while (-not $script:wcDone) {
        Start-Sleep -Milliseconds 1000

        $cur = 0
        if (Test-Path -LiteralPath $OutFile) {
            try { $cur = (Get-Item -LiteralPath $OutFile).Length } catch { $cur = 0 }
        }
        if ($cur -ne $lastSize) {
            $lastSize = $cur
            $lastChange = Get-Date
        }

        if ($ShowProgress) {
            $elapsed = ((Get-Date) - $start).TotalSeconds
            Write-DlProgress -Current $cur -Total $TotalBytes -ElapsedSec $elapsed -First:$firstLine
            $firstLine = $false
        }

        if (((Get-Date) - $lastChange).TotalSeconds -ge $StalledSeconds) {
            $stalled = $true
            break
        }
    }

    if ($stalled) {
        if ($ShowProgress) { Write-Host '' }
        Write-Host ('   [WARN] No progress for {0}s; aborting WebClient.' -f $StalledSeconds) -ForegroundColor Yellow
        try { $wc.CancelAsync() } catch {}
        try { $wc.Dispose() } catch {}
        try { $task.Wait(3000) | Out-Null } catch {}
        throw 'WebClient stalled (no bytes for the watchdog window).'
    }

    try { $task.Wait() } catch {}

    if ($script:wcError) {
        throw $script:wcError
    }

    if ($ShowProgress) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        $finalSize = 0
        try { $finalSize = (Get-Item -LiteralPath $OutFile).Length } catch {}
        Write-DlProgress -Current $finalSize -Total $TotalBytes -ElapsedSec $elapsed -Final
    }
}

# ---------------------------------------------------------------------------
# Probe the remote size (best effort)
# ---------------------------------------------------------------------------
$totalBytes = Get-RemoteSize -Uri $resolvedUrl -Headers $headers -TimeoutMs 20000
if ($totalBytes -gt 0) {
    Write-Host ('   Size: {0}' -f (Format-Bytes $totalBytes))
} else {
    Write-Host '   Size: unknown (server did not return Content-Length)'
}
Write-Host ''

Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$usedCurl = $false

# ---------------------------------------------------------------------------
# Choose downloader: curl unless unavailable or forced otherwise.
# ---------------------------------------------------------------------------
$curlPath = Get-CurlPath
$useCurl  = ($null -ne $curlPath) -and (-not $PreferWebClient)

if ($useCurl) {
    Write-Host ('   Using curl.exe (default).' ) -ForegroundColor DarkGray
    try {
        Invoke-CurlDownload -Uri $resolvedUrl -OutFile $partial -Headers $headers -ShowProgress $ShowProgress
        $usedCurl = $true
    } catch {
        Write-Host ''
        Write-Host ('   [WARN] curl failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host '   [INFO] Falling back to WebClient...' -ForegroundColor Cyan
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

        Invoke-WebClientDownload -Uri $resolvedUrl -OutFile $partial -Headers $headers `
            -TotalBytes $totalBytes -ShowProgress $ShowProgress -StalledSeconds $StalledSeconds
        $usedCurl = $false
    }
} else {
    if (-not $curlPath) {
        Write-Host '   [WARN] curl.exe not found on this system; using WebClient.' -ForegroundColor Yellow
    } else {
        Write-Host '   Using WebClient (requested).' -ForegroundColor DarkGray
    }
    Invoke-WebClientDownload -Uri $resolvedUrl -OutFile $partial -Headers $headers `
        -TotalBytes $totalBytes -ShowProgress $ShowProgress -StalledSeconds $StalledSeconds
    $usedCurl = $false
}

# ---------------------------------------------------------------------------
# Final sanity checks
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $partial)) {
    throw 'Download finished but the .partial file is missing.'
}
$partialSize = (Get-Item -LiteralPath $partial).Length
if ($partialSize -eq 0) {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    throw 'Download finished but the file is empty.'
}
if ($totalBytes -gt 0 -and $partialSize -lt $totalBytes) {
    Write-Host ('   [WARN] Final size {0} is smaller than expected {1}.' -f `
        (Format-Bytes $partialSize), (Format-Bytes $totalBytes)) -ForegroundColor Yellow
}

Move-Item -LiteralPath $partial -Destination $destPath -Force
$sw.Stop()

$rate = ($partialSize / 1MB) / [Math]::Max(0.1, $sw.Elapsed.TotalSeconds)
Write-Host ''
Write-Host ('   Downloaded {0} in {1:N1}s ({2:N2} MB/s).' -f `
    (Format-Bytes $partialSize), $sw.Elapsed.TotalSeconds, $rate) -ForegroundColor Green
Write-Host ''

return [pscustomobject]@{
    Path    = $destPath
    Bytes   = $partialSize
    Skipped = $false
    ViaCurl = $usedCurl
}