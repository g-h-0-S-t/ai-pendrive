<#
.SYNOPSIS
    AI Pendrive unified launcher engine.
.DESCRIPTION
    Reads config.json, optionally lets the user pick a different local model,
    then starts llamafile with the configured parameters and opens the browser.
.PARAMETER Root
    Project root.
#>
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Sanitize $Root. cmd.exe passes paths with a trailing backslash and quoting
# issues can leave a stray quote inside the string. Strip both here.
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

$Root = Resolve-Root -Path $Root

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host ''
    Write-Host ('   [ERR] Project root does not exist: ' + $Root) -ForegroundColor Red
    exit 1
}

Set-Location -LiteralPath $Root

$CONFIG  = Join-Path $Root 'config.json'
$MODELS  = Join-Path $Root 'models'
$INDEX   = Join-Path $MODELS '.model_index.json'

if (-not (Test-Path -LiteralPath $CONFIG)) {
    throw "config.json not found. Run setup.bat first."
}

# ============================================================================
# UI helpers
# ============================================================================
function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '                    AI PENDRIVE LAUNCHER' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
}
function Write-Section([string]$T) {
    Write-Host ''
    Write-Host ('  --------------------------------------------------------------') -ForegroundColor DarkGray
    Write-Host ('   ' + $T) -ForegroundColor White
    Write-Host ('  --------------------------------------------------------------') -ForegroundColor DarkGray
}
function Write-Ok([string]$M)   { Write-Host ('   [OK]   ' + $M) -ForegroundColor Green }
function Write-Warn([string]$M) { Write-Host ('   [WARN] ' + $M) -ForegroundColor Yellow }
function Write-Err([string]$M)  { Write-Host ('   [ERR]  ' + $M) -ForegroundColor Red }
function Write-Info([string]$M) { Write-Host ('   [INFO] ' + $M) -ForegroundColor Cyan }

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [int]$Default = 0)
    Write-Host ''
    Write-Host ('   ' + $Prompt) -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i -eq $Default) { '>' } else { ' ' }
        Write-Host ('     {0} [{1}] {2}' -f $marker, ($i + 1), $Options[$i])
    }
    while ($true) {
        $ans = Read-Host ('   Choose 1-{0} (default {1})' -f $Options.Count, ($Default + 1))
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        if ($ans -match '^\d+$') {
            $n = [int]$ans
            if ($n -ge 1 -and $n -le $Options.Count) { return ($n - 1) }
        }
        Write-Warn 'Invalid choice.'
    }
}

# ============================================================================
# Load config
# ============================================================================
function Load-Config {
    if (-not (Test-Path -LiteralPath $CONFIG)) { throw 'config.json missing.' }
    $raw = Get-Content -LiteralPath $CONFIG -Raw
    return ($raw | ConvertFrom-Json)
}

function Save-Config($cfg) {
    $json = $cfg | ConvertTo-Json -Depth 5
    $dir = Split-Path -Parent $CONFIG
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($CONFIG, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok 'config.json updated.'
}

# ============================================================================
# Model index
# ============================================================================
function Refresh-ModelIndex {
    if (-not (Test-Path -LiteralPath $MODELS)) {
        New-Item -ItemType Directory -Path $MODELS -Force | Out-Null
    }

    $index = @()
    Get-ChildItem -LiteralPath $MODELS -Recurse -Filter '*.gguf' -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
        $index += [pscustomobject]@{
            name       = $_.Name
            path       = $rel
            sizeBytes  = $_.Length
            tierFolder = $_.Directory.Name
            modifiedAt = $_.LastWriteTime.ToString('s')
        }
    }

    $json = if ($index.Count -gt 0) { $index | ConvertTo-Json -Depth 4 } else { '[]' }

    try {
        $indexDir = Split-Path -Parent $INDEX
        if ($indexDir -and -not (Test-Path -LiteralPath $indexDir)) {
            New-Item -ItemType Directory -Path $indexDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($INDEX, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warn ('Could not write model index: ' + $_.Exception.Message)
    }

    return $index
}

function Get-Models {
    if (Test-Path -LiteralPath $INDEX) {
        try {
            $raw = Get-Content -LiteralPath $INDEX -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                # ConvertFrom-Json returns $null for '[]' on some PS versions
                if ($null -eq $parsed) { return @() }
                # A single-entry index comes back as one object, not an array;
                # force it into an array so callers can use .Count / index safely.
                if ($parsed -isnot [System.Array]) { return @($parsed) }
                return $parsed
            }
        } catch {}
    }
    return Refresh-ModelIndex
}

# ============================================================================
# Launch
# ============================================================================
function Start-Llama {
    param($cfg)

    $llamaRel = if ($cfg.llamafilePath) { $cfg.llamafilePath } else { 'server\llamafile-0.10.5.exe' }
    $llama = Join-Path $Root $llamaRel
    if (-not (Test-Path -LiteralPath $llama)) {
        Write-Err ('Llamafile not found at: ' + $llama)
        Write-Warn 'Run setup.bat to install it.'
        Read-Host '   Press Enter' | Out-Null
        return 1
    }

    $modelPath = if ([System.IO.Path]::IsPathRooted($cfg.modelPath)) {
        $cfg.modelPath
    } else {
        Join-Path $Root $cfg.modelPath
    }
    if (-not (Test-Path -LiteralPath $modelPath)) {
        Write-Err ('Model not found at: ' + $modelPath)
        Write-Warn 'Run setup.bat to download a model, or use the model picker.'
        Read-Host '   Press Enter' | Out-Null
        return 1
    }

    $args = @(
        '--server'
        '-m', $modelPath
        '--host', $cfg.host
        '--port', "$($cfg.port)"
        '--jinja'
        '-c', "$($cfg.context)"
        '-n', "$($cfg.predict)"
        '-np', "$($cfg.parallel)"
        '-ngl', "$($cfg.gpuLayers)"
        '-t', "$($cfg.threads)"
        '--flash-attn', $cfg.flashAttn
        '--cache-type-k', $cfg.cacheK
        '--cache-type-v', $cfg.cacheV
        '--batch-size', "$($cfg.batch)"
        '--ubatch-size', "$($cfg.ubatch)"
    )
    if ($cfg.enableMetrics) { $args += '--metrics' }
    if ($cfg.useNoMmap)    { $args += '--no-mmap' }
    if ($cfg.enableTools)  { $args += @('--tools', $cfg.tools) }

    $baseUrl   = ('http://{0}:{1}' -f $cfg.host, $cfg.port)
    $healthUrl = $baseUrl + '/health'

    Write-Banner
    Write-Host '   Launching AI Pendrive' -ForegroundColor Green
    Write-Host ''
    Write-Host ('   Profile       : {0}' -f $cfg.tier)
    Write-Host ('   Model         : {0}' -f (Split-Path $modelPath -Leaf))
    Write-Host ('   Llamafile     : {0}' -f $llama)
    Write-Host ('   Server URL    : {0}' -f $baseUrl)
    Write-Host ('   Context       : {0} tokens' -f $cfg.context)
    Write-Host ('   Max gen       : {0} tokens' -f $cfg.predict)
    Write-Host ('   Parallel      : {0}' -f $cfg.parallel)
    Write-Host ('   GPU layers    : {0}' -f $cfg.gpuLayers)
    Write-Host ('   CPU threads   : {0}' -f $cfg.threads)
    Write-Host ('   Batch/uBatch  : {0} / {1}' -f $cfg.batch, $cfg.ubatch)
    Write-Host ('   KV cache K/V  : {0} / {1}' -f $cfg.cacheK, $cfg.cacheV)
    Write-Host ('   No-mmap       : {0}' -f $cfg.useNoMmap)
    Write-Host ('   Flash Attn    : {0}' -f $cfg.flashAttn)
    Write-Host ('   Metrics       : {0}' -f $cfg.enableMetrics)
    Write-Host ('   Agent tools   : {0} ({1})' -f $cfg.enableTools, $cfg.tools)
    Write-Host ''
    Write-Host '   Loading model. The browser opens automatically when ready.' -ForegroundColor DarkGray
    Write-Host '   Press Ctrl+C in this window to stop the server.' -ForegroundColor DarkGray
    Write-Host ''

    $browserTimeout = if ($cfg.browserTimeoutMin) { $cfg.browserTimeoutMin } else { 30 }
    $watcher = @"
`$url='$healthUrl'
`$open='$baseUrl/'
`$deadline=(Get-Date).AddMinutes($browserTimeout)
while((Get-Date) -lt `$deadline){
    try {
        `$r=Invoke-WebRequest -Uri `$url -UseBasicParsing -TimeoutSec 2
        if(`$r.StatusCode -ge 200 -and `$r.StatusCode -lt 500){ Start-Process `$open; exit 0 }
    } catch {}
    Start-Sleep -Milliseconds 750
}
"@
    Start-Process -FilePath 'powershell' -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
        '-Command', $watcher
    ) -WindowStyle Hidden | Out-Null

    Write-Host '   --------------------------------------------------------------' -ForegroundColor DarkGray
    & $llama @args
    $serverExit = $LASTEXITCODE

    Write-Host ''
    Write-Host ('   Server exited with code {0}.' -f $serverExit) -ForegroundColor DarkGray
    return $serverExit
}

# ============================================================================
# Menus
# ============================================================================
function Show-ConfigSummary {
    param($cfg)
    Write-Host ('   Tier         : {0}' -f $cfg.tier)
    Write-Host ('   Model        : {0}' -f $cfg.modelPath)
    Write-Host ('   Host:Port    : {0}:{1}' -f $cfg.host, $cfg.port)
    Write-Host ('   Context      : {0}' -f $cfg.context)
    Write-Host ('   Max gen      : {0}' -f $cfg.predict)
    Write-Host ('   Parallel     : {0}' -f $cfg.parallel)
    Write-Host ('   Threads      : {0}' -f $cfg.threads)
    Write-Host ('   GPU layers   : {0}' -f $cfg.gpuLayers)
    Write-Host ('   Batch/uBatch : {0} / {1}' -f $cfg.batch, $cfg.ubatch)
    Write-Host ('   KV cache     : {0} / {1}' -f $cfg.cacheK, $cfg.cacheV)
    Write-Host ('   Tools        : {0} ({1})' -f $cfg.enableTools, $cfg.tools)
    Write-Host ('   Metrics      : {0}' -f $cfg.enableMetrics)
}

function Menu-Models {
    param($cfg)
    $models = Get-Models
    if (-not $models -or @($models).Count -eq 0) {
        Write-Warn 'No .gguf models found in models\.'
        Write-Info 'Use the "Add model" option to download one.'
        Read-Host '   Press Enter' | Out-Null
        return $cfg
    }

    $models = @($models)
    $options = @()
    $defaultIdx = 0
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $sizeGb = [Math]::Round($m.sizeBytes / 1GB, 2)
        $isCurrent = ($cfg.modelPath -eq $m.path)
        if ($isCurrent) { $defaultIdx = $i }
        $tag = if ($isCurrent) { ' [CURRENT]' } else { '' }
        $options += ('[{0}] {1} ({2} GB){3}' -f $m.tierFolder, $m.name, $sizeGb, $tag)
    }
    $options += 'Back'

    $choice = Read-Choice -Prompt 'Select a model:' -Options $options -Default $defaultIdx
    if ($choice -eq $options.Count - 1) { return $cfg }

    $cfg.modelPath = $models[$choice].path
    Save-Config $cfg
    Write-Ok ('Selected model: ' + $models[$choice].name)
    return $cfg
}

function Menu-AddModel {
    param($cfg)
    Write-Section 'Add a new model'
    Write-Host '   Paste a Hugging Face resolve URL, an hf:// URI, or "user/repo/file.gguf".' -ForegroundColor DarkGray
    Write-Host '   Examples:' -ForegroundColor DarkGray
    Write-Host '     https://huggingface.co/<user>/<repo>/resolve/main/<file>.gguf' -ForegroundColor DarkGray
    Write-Host '     hf://<user>/<repo>/<file>.gguf' -ForegroundColor DarkGray
    Write-Host ''
    $url = Read-Host '   URL (Enter to cancel)'
    if ([string]::IsNullOrWhiteSpace($url)) { return $cfg }

    $tier = Read-Host '   Save into tier folder (4GB / 6GB / 8GB / no_gpu / custom) [custom]'
    if ([string]::IsNullOrWhiteSpace($tier)) { $tier = 'custom' }

    $token = ''
    $tokenFile = Join-Path $Root '.hf_token'
    if (Test-Path -LiteralPath $tokenFile) {
        $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
    if (-not $token) {
        Write-Host ''
        Write-Info 'No saved HF token found. Press Enter to skip if the repo is public.'
        $sec = Read-Host '   HF token (Enter to skip)' -AsSecureString
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        )
        if ($token -and (Read-Host '   Save token to .hf_token? [Y/n]') -notmatch '^(n|no)$') {
            [System.IO.File]::WriteAllText($tokenFile, $token, (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    $downloadPs = Join-Path $Root 'download_model.ps1'
    try {
        & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $downloadPs `
            -Url $url -Tier $tier -Token $token -ShowProgress
        Refresh-ModelIndex | Out-Null
        Write-Ok 'Model added.'
    } catch {
        Write-Err ('Download failed: ' + $_.Exception.Message)
    }
    Read-Host '   Press Enter' | Out-Null
    return $cfg
}

function Menu-EditSettings {
    param($cfg)
    Write-Section 'Edit launch settings'
    Write-Host ('   Current: CTX={0} PREDICT={1} THREADS={2} GPU_LAYERS={3} BATCH={4} UBATCH={5} PORT={6} PARALLEL={7}' -f `
        $cfg.context, $cfg.predict, $cfg.threads, $cfg.gpuLayers, $cfg.batch, $cfg.ubatch, $cfg.port, $cfg.parallel)
    Write-Host ''

    $val = Read-Host ('   Context [' + $cfg.context + ']')
    if ($val -match '^\d+$') { $cfg.context = [int]$val }

    $val = Read-Host ('   Max generation [' + $cfg.predict + ']')
    if ($val -match '^\d+$') { $cfg.predict = [int]$val }
    if ($cfg.predict -gt $cfg.context) { $cfg.predict = $cfg.context }

    $val = Read-Host ('   CPU threads [' + $cfg.threads + ']')
    if ($val -match '^\d+$') { $cfg.threads = [int]$val }

    $val = Read-Host ('   GPU layers [' + $cfg.gpuLayers + ']')
    if ($val -match '^\d+$') { $cfg.gpuLayers = [int]$val }

    $val = Read-Host ('   Batch [' + $cfg.batch + ']')
    if ($val -match '^\d+$') { $cfg.batch = [int]$val }

    $val = Read-Host ('   uBatch [' + $cfg.ubatch + ']')
    if ($val -match '^\d+$') { $cfg.ubatch = [int]$val }

    $val = Read-Host ('   HTTP port [' + $cfg.port + ']')
    if ($val -match '^\d+$') { $cfg.port = [int]$val }

    $val = Read-Host ('   Parallel slots [' + $cfg.parallel + ']')
    if ($val -match '^\d+$') { $cfg.parallel = [int]$val }

    $val = Read-Host ('   Agent tools on/off [' + $cfg.enableTools + ']')
    if ($val -match '^(on|true|1|y|yes)$') { $cfg.enableTools = $true }
    if ($val -match '^(off|false|0|n|no)$') { $cfg.enableTools = $false }

    if ($cfg.enableTools) {
        $val = Read-Host ('   Tools list [' + $cfg.tools + ']')
        if (-not [string]::IsNullOrWhiteSpace($val)) { $cfg.tools = $val.Trim() }
    }

    $val = Read-Host ('   Use --no-mmap on/off [' + $cfg.useNoMmap + ']')
    if ($val -match '^(on|true|1|y|yes)$') { $cfg.useNoMmap = $true }
    if ($val -match '^(off|false|0|n|no)$') { $cfg.useNoMmap = $false }

    $val = Read-Host ('   Flash Attention on/off/auto [' + $cfg.flashAttn + ']')
    if ($val -match '^(on|off|auto)$') { $cfg.flashAttn = $val }

    Save-Config $cfg
    return $cfg
}

function Menu-Reconfigure {
    Write-Section 'Re-run full setup'
    Write-Host '   This launches setup.bat again. Your current config will be overwritten.' -ForegroundColor DarkGray
    $confirm = Read-Host '   Continue? [y/N]'
    if ($confirm -match '^(y|yes)$') {
        $setup = Join-Path $Root 'setup.bat'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + $setup + '"') -Wait
        return (Load-Config)
    }
    return $null
}

# ============================================================================
# MAIN
# ============================================================================
try {
    $cfg = Load-Config

    while ($true) {
        Write-Banner
        Write-Section 'Current configuration'
        Show-ConfigSummary $cfg

        $choice = Read-Choice -Prompt 'What do you want to do?' -Options @(
            'Start the server now',
            'Change model',
            'Add a new model from Hugging Face',
            'Edit launch settings',
            'Re-run full setup wizard',
            'Exit'
        ) -Default 0

        switch ($choice) {
            0 {
                $rc = Start-Llama $cfg
                Read-Host '   Press Enter to return to menu' | Out-Null
            }
            1 { $cfg = Menu-Models $cfg }
            2 { $cfg = Menu-AddModel $cfg }
            3 { $cfg = Menu-EditSettings $cfg }
            4 {
                $newCfg = Menu-Reconfigure
                if ($newCfg) { $cfg = $newCfg }
            }
            5 { exit 0 }
        }
    }
}
catch {
    Write-Host ''
    Write-Err ('Launcher error: ' + $_.Exception.Message)
    Write-Host ('   At: ' + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    Read-Host '   Press Enter to close' | Out-Null
    exit 1
}