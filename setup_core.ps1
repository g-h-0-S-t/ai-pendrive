<#
.SYNOPSIS
    Interactive setup engine for AI Pendrive.
.DESCRIPTION
    Presents AUTO and SEMI-AUTO modes. Detects hardware via detect_system.ps1,
    downloads llamafile via download_model.ps1 when needed, downloads the
    selected model, and writes config.json for launcher.bat and status.bat.

    AUTO mode is a one-click flow:
        [1/4] detect hardware
        [2/4] ensure runtime
        [3/4] download model (curl by default)
        [4/4] write config.json
    Then a "you're all set" banner.

    SEMI-AUTO is the step-by-step guided flow with all the same steps but
    full user control.
.PARAMETER Root
    Project root (folder containing this script).
#>
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Sanitize $Root.
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

$DETECT   = Join-Path $Root 'detect_system.ps1'
$DOWNLOAD = Join-Path $Root 'download_model.ps1'
$CONFIG   = Join-Path $Root 'config.json'

if (-not (Test-Path -LiteralPath $DETECT))   { throw "detect_system.ps1 not found in $Root" }
if (-not (Test-Path -LiteralPath $DOWNLOAD)) { throw "download_model.ps1 not found in $Root" }

# ============================================================================
# UI helpers
# ============================================================================
function Write-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '                       AI PENDRIVE SETUP' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '   Portable local LLM server | by Cyberbatman' -ForegroundColor DarkCyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-AutoHeader {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '              AI PENDRIVE SETUP  -  AUTOMATIC MODE' -ForegroundColor Cyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host '   Sit back. Everything is handled for you.' -ForegroundColor DarkCyan
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param(
        [int]$Number,
        [int]$Total,
        [string]$Text
    )
    Write-Host ''
    Write-Host ('   [{0}/{1}] {2}' -f $Number, $Total, $Text) -ForegroundColor White
    Write-Host '   --------------------------------------------------------------' -ForegroundColor DarkGray
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('  --------------------------------------------------------------') -ForegroundColor DarkGray
    Write-Host ('   ' + $Title) -ForegroundColor White
    Write-Host ('  --------------------------------------------------------------') -ForegroundColor DarkGray
}

function Write-Ok([string]$Msg)   { Write-Host ('   [OK]   ' + $Msg) -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host ('   [WARN] ' + $Msg) -ForegroundColor Yellow }
function Write-Err([string]$Msg)  { Write-Host ('   [ERR]  ' + $Msg) -ForegroundColor Red }
function Write-Info([string]$Msg) { Write-Host ('   [INFO] ' + $Msg) -ForegroundColor Cyan }

function Write-SuccessBanner {
    param(
        [string]$ModelName,
        [string]$TierLabel,
        [string]$ServerUrl
    )
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Green
    Write-Host '                    YOU ARE ALL SET!' -ForegroundColor Green
    Write-Host '  ==============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host ('   Profile  : {0}' -f $TierLabel) -ForegroundColor White
    Write-Host ('   Model    : {0}' -f $ModelName) -ForegroundColor White
    Write-Host ('   Server   : {0}' -f $ServerUrl) -ForegroundColor White
    Write-Host ''
    Write-Host '   Everything is configured. To start the AI:' -ForegroundColor White
    Write-Host ''
    Write-Host '       Double-click  launcher.bat' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   Optional: double-click status.bat in another window for a' -ForegroundColor DarkGray
    Write-Host '   live dashboard of CPU, RAM, GPU, and token throughput.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   To change models or settings later, run launcher.bat and' -ForegroundColor DarkGray
    Write-Host '   use its menu, or re-run setup.bat at any time.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Green
    Write-Host ''
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [int]$Default = 0
    )
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
        Write-Warn 'Invalid choice, try again.'
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $ans = Read-Host ('   ' + $Prompt + ' ' + $suffix)
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        if ($ans -match '^(y|yes)$') { return $true }
        if ($ans -match '^(n|no)$')  { return $false }
    }
}

function Read-Int {
    param([string]$Prompt, [int]$Default)
    while ($true) {
        $ans = Read-Host ('   ' + $Prompt + ' (default ' + $Default + ')')
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        if ($ans -match '^\d+$') { return [int]$ans }
        Write-Warn 'Enter a whole number.'
    }
}

function Read-Text {
    param([string]$Prompt, [string]$Default = '')
    $suffix = if ($Default) { ' (default ' + $Default + ')' } else { '' }
    $ans = Read-Host ('   ' + $Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans.Trim()
}

# ============================================================================
# Load detection
# ============================================================================
function Invoke-Detection {
    param([switch]$Quiet)
    if (-not $Quiet) { Write-Section 'Detecting hardware' }
    try {
        $json = & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $DETECT -AsJson
        $det = $json | ConvertFrom-Json
    } catch {
        throw "Hardware detection failed: $($_.Exception.Message)"
    }

    if (-not $Quiet) {
        Write-Ok ('CPU: {0} ({1} cores / {2} threads)' -f $det.Cpu.Name, $det.Cpu.Cores, $det.Cpu.Threads)
        Write-Ok ('System RAM: {0} GB total, {1} GB free' -f $det.Ram.TotalGb, $det.Ram.FreeGb)
        Write-Ok ('GPU: {0} {1} ({2} MB VRAM, backend: {3})' -f $det.Gpu.Vendor, $det.Gpu.Name, $det.Gpu.VramMb, $det.Gpu.Backend)
        Write-Info ('Recommended tier: {0} - {1}' -f $det.Recommendation.Tier, $det.Recommendation.Reason)
    }
    return $det
}

# ============================================================================
# Tier key normalization
# ============================================================================
function Normalize-TierKey {
    param([string]$Tier)
    if ([string]::IsNullOrWhiteSpace($Tier)) { return 'no_gpu' }
    $t = $Tier.Trim().ToLowerInvariant()
    switch ($t) {
        '4'        { return '4GB' }
        '4gb'      { return '4GB' }
        '4 gb'     { return '4GB' }
        '6'        { return '6GB' }
        '6gb'      { return '6GB' }
        '6 gb'     { return '6GB' }
        '8'        { return '8GB' }
        '8gb'      { return '8GB' }
        '8 gb'     { return '8GB' }
        'no_gpu'   { return 'no_gpu' }
        'nogpu'    { return 'no_gpu' }
        'cpu'      { return 'no_gpu' }
        'cpu only' { return 'no_gpu' }
        default    { return $Tier }
    }
}

function Get-TierLabel {
    param([string]$TierKey)
    switch ($TierKey) {
        '4GB'    { return '4 GB GPU' }
        '6GB'    { return '6 GB GPU' }
        '8GB'    { return '8 GB+ GPU' }
        'no_gpu' { return 'CPU only' }
        default  { return $TierKey }
    }
}

# ============================================================================
# Path normalization helper
# ============================================================================
function Get-RelativePath {
    param(
        [string]$FullPath,
        [string]$BasePath
    )
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return '' }
    $full = $FullPath
    $base = $BasePath
    if ($full.Length -gt $base.Length -and $full.Substring(0, $base.Length).Equals($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($base.Length)
        $rel = $rel.TrimStart('\', '/')
        return $rel
    }
    return $FullPath
}

# ============================================================================
# Llamafile runtime
# ============================================================================
function Ensure-Llamafile {
    param([switch]$Auto)

    $serverDir = Join-Path $Root 'server'
    if (-not (Test-Path -LiteralPath $serverDir)) {
        New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    }
    $exe = Join-Path $serverDir 'llamafile-0.10.5.exe'

    if (Test-Path -LiteralPath $exe) {
        Write-Ok ('Llamafile runtime present: {0}' -f $exe)
        return [string]$exe
    }

    Write-Warn 'Llamafile runtime not found.'
    Write-Info 'It is a ~250 MB binary from GitHub releases (mozilla-ai/llamafile 0.10.5).'

    if ($Auto) {
        Write-Info 'Downloading automatically...'
    } else {
        $choice = Read-Choice -Prompt 'How do you want to install the runtime?' -Options @(
            'Download now (recommended)',
            'Open the download page in my browser, I will do it manually',
            'Skip (I already have it elsewhere, I will copy it now)'
        ) -Default 0

        if ($choice -eq 1) {
            Start-Process 'https://github.com/mozilla-ai/llamafile/releases/tag/0.10.5'
            Write-Host ''
            Write-Warn 'Browser opened. Download "llamafile-0.10.5" and save it as:'
            Write-Host ('        ' + $exe) -ForegroundColor Yellow
            Write-Host ''
            Read-Host '   Press Enter once the file is in place' | Out-Null
            if (Test-Path -LiteralPath $exe) {
                Write-Ok 'Llamafile detected.'
                return [string]$exe
            }
            Write-Err 'Still not found. You can re-run setup later.'
            return $null
        }
        if ($choice -eq 2) {
            Write-Host ''
            Write-Warn 'Place the runtime at: ' + $exe
            Read-Host '   Press Enter once the file is in place' | Out-Null
            if (Test-Path -LiteralPath $exe) {
                Write-Ok 'Llamafile detected.'
                return [string]$exe
            }
            Write-Err 'Still not found. You can re-run setup later.'
            return $null
        }
    }

    $url = 'https://github.com/mozilla-ai/llamafile/releases/download/0.10.5/llamafile-0.10.5'

    Write-Info 'Downloading llamafile 0.10.5 from GitHub...'
    Write-Host ''

    try {
        $null = & $DOWNLOAD -Url $url -DestDir $serverDir -ShowProgress:$true
    } catch {
        Write-Err ('Runtime download failed: ' + $_.Exception.Message)
        Write-Warn 'You can download it manually from:'
        Write-Host '        https://github.com/mozilla-ai/llamafile/releases/tag/0.10.5' -ForegroundColor Yellow
        Write-Host ('        Save it as: ' + $exe) -ForegroundColor Yellow
        return $null
    }

    $downloaded = Join-Path $serverDir 'llamafile-0.10.5'
    if ((Test-Path -LiteralPath $downloaded) -and -not (Test-Path -LiteralPath $exe)) {
        Move-Item -LiteralPath $downloaded -Destination $exe -Force
    }

    if (Test-Path -LiteralPath $exe) {
        $size = (Get-Item -LiteralPath $exe).Length / 1MB
        Write-Ok ('Runtime downloaded ({0:N1} MB).' -f $size)
        return [string]$exe
    }
    return $null
}

# ============================================================================
# Model catalog
# ============================================================================
$ModelCatalog = @(
    [pscustomobject]@{
        Key      = '4GB'
        Label    = '4 GB GPU - Qwen3.5 2B (Q8_0) - highest quality 2B'
        Repo     = 'HauhauCS/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive'
        File     = 'Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf'
        SizeMb   = 2600
    }
    [pscustomobject]@{
        Key      = '6GB'
        Label    = '6 GB GPU - Qwen3.5 4B (Q4_K_M)'
        Repo     = 'HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive'
        File     = 'Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
        SizeMb   = 2800
    }
    [pscustomobject]@{
        Key      = '8GB'
        Label    = '8 GB+ GPU - Qwen3.5 9B (Q4_K_M) - best quality'
        Repo     = 'HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive'
        File     = 'Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
        SizeMb   = 5800
    }
    [pscustomobject]@{
        Key      = 'no_gpu'
        Label    = 'CPU only - Qwen3.5 2B (Q4_K_M) - smallest, fastest on CPU'
        Repo     = 'HauhauCS/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive'
        File     = 'Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
        SizeMb   = 1900
    }
)

function Get-ModelByKey([string]$Key) {
    $normalized = Normalize-TierKey $Key
    foreach ($m in $ModelCatalog) {
        if ($m.Key -eq $normalized) { return $m }
    }
    return $null
}

function Ensure-Model {
    param(
        [string]$Key,
        [string]$Token,
        [switch]$Auto
    )

    $model = Get-ModelByKey $Key
    if (-not $model) {
        Write-Err ("Unknown model key: " + $Key + " (normalized: " + (Normalize-TierKey $Key) + ")")
        return $null
    }

    $destDir = Join-Path $Root ('models\' + $model.Key)
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $destFile = Join-Path $destDir $model.File

    if (Test-Path -LiteralPath $destFile) {
        $size = (Get-Item -LiteralPath $destFile).Length / 1MB
        Write-Ok ('Model already present: {0} ({1:N1} MB)' -f $destFile, $size)
        return [string]$destFile
    }

    Write-Info ('Model to download: ' + $model.File)
    Write-Info ('Approximate size: {0} MB' -f $model.SizeMb)

    if (-not $Auto) {
        if (-not (Read-YesNo ('Download this model now?') $true)) {
            Write-Warn 'Skipped. The launcher will not work until the model is in place.'
            return $null
        }
    }

    Write-Host ''
    Write-Host '   Starting download...' -ForegroundColor Cyan
    Write-Host '   (The download can take several minutes depending on your connection.)' -ForegroundColor DarkGray
    Write-Host ''

    try {
        $null = & $DOWNLOAD -Repo $model.Repo -File $model.File `
            -DestDir $destDir -Token $Token -ShowProgress:$true
    } catch {
        Write-Err ('Model download failed: ' + $_.Exception.Message)
        return $null
    }

    if (Test-Path -LiteralPath $destFile) {
        $size = (Get-Item -LiteralPath $destFile).Length / 1MB
        Write-Ok ('Model downloaded ({0:N1} MB).' -f $size)
        return [string]$destFile
    }
    Write-Err 'Model file not found after download.'
    return $null
}

# ============================================================================
# Token capture
# ============================================================================
function Get-HfToken {
    param([switch]$Auto)

    $tokenFile = Join-Path $Root '.hf_token'
    if (Test-Path -LiteralPath $tokenFile) {
        $existing = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
        if ($existing) {
            Write-Ok 'Existing Hugging Face token found (.hf_token).'
            if ($Auto) { return [string]$existing }
            if (Read-YesNo 'Use the saved token?' $true) { return [string]$existing }
        }
    }

    if ($Auto) { return '' }

    Write-Host ''
    Write-Host '   A Hugging Face access token is optional.' -ForegroundColor DarkGray
    Write-Host '   Only needed for gated/private model repos.' -ForegroundColor DarkGray
    Write-Host '   Create one at: https://huggingface.co/settings/tokens' -ForegroundColor DarkGray
    Write-Host ''
    if (-not (Read-YesNo 'Do you have a Hugging Face token to enter?' $false)) {
        return ''
    }
    $token = Read-Host '   Paste your HF token (input hidden, Enter to skip)' -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    if ([string]::IsNullOrWhiteSpace($plain)) { return '' }

    if (Read-YesNo 'Save this token to .hf_token for future runs?' $true) {
        [System.IO.File]::WriteAllText($tokenFile, $plain, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok 'Token saved to .hf_token.'
    }
    return [string]$plain
}

# ============================================================================
# Config writing
# ============================================================================
function Write-Config {
    param(
        [string]$Tier,
        [string]$ModelPath,
        [int]$Ctx,
        [int]$Predict,
        [int]$Threads,
        [int]$GpuLayers,
        [int]$Batch,
        [int]$UBatch,
        [string]$CacheK,
        [string]$CacheV,
        [string]$HostName,
        [int]$Port,
        [int]$Parallel,
        [bool]$EnableMetrics,
        [bool]$EnableTools,
        [string]$Tools,
        [bool]$UseNoMmap,
        [string]$FlashAttn,
        [int]$BrowserTimeout
    )

    $cfg = [ordered]@{
        generatedAt       = (Get-Date).ToString('s')
        tier              = $Tier
        modelPath         = $ModelPath
        host              = $HostName
        port              = $Port
        context           = $Ctx
        predict           = $Predict
        parallel          = $Parallel
        threads           = $Threads
        gpuLayers         = $GpuLayers
        batch             = $Batch
        ubatch            = $UBatch
        cacheK            = $CacheK
        cacheV            = $CacheV
        useNoMmap         = $UseNoMmap
        flashAttn         = $FlashAttn
        enableMetrics     = $EnableMetrics
        enableTools       = $EnableTools
        tools             = $Tools
        browserTimeoutMin = $BrowserTimeout
        llamafilePath     = 'server\llamafile-0.10.5.exe'
    }

    $json = $cfg | ConvertTo-Json -Depth 5
    $dir = Split-Path -Parent $CONFIG
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($CONFIG, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Wrote configuration to: ' + $CONFIG)
}

# ============================================================================
# Model index (for launcher model picker)
# ============================================================================
function Update-ModelIndex {
    $modelsDir = Join-Path $Root 'models'
    if (-not (Test-Path -LiteralPath $modelsDir)) {
        New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
    }

    $index = @()
    Get-ChildItem -LiteralPath $modelsDir -Recurse -Filter '*.gguf' -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = Get-RelativePath -FullPath $_.FullName -BasePath $Root
        $index += [pscustomobject]@{
            name       = $_.Name
            path       = $rel
            sizeBytes  = $_.Length
            tierFolder = $_.Directory.Name
            modifiedAt = $_.LastWriteTime.ToString('s')
        }
    }

    $indexPath = Join-Path $modelsDir '.model_index.json'
    $json = if ($index.Count -gt 0) { $index | ConvertTo-Json -Depth 4 } else { '[]' }
    [System.IO.File]::WriteAllText($indexPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Model index updated ({0} model(s)).' -f $index.Count)
}

# ============================================================================
# AUTO MODE (one-click)
# ============================================================================
function Invoke-AutoMode {
    Write-AutoHeader

    Write-Step -Number 1 -Total 4 -Text 'Detecting your hardware'
    $detection = Invoke-Detection -Quiet
    $rec       = $detection.Recommendation
    $tierKey   = Normalize-TierKey $rec.Tier
    $tierLabel = Get-TierLabel $tierKey

    Write-Ok ('CPU  : {0}' -f $detection.Cpu.Name)
    Write-Ok ('RAM  : {0} GB' -f $detection.Ram.TotalGb)
    Write-Ok ('GPU  : {0} {1} ({2} MB VRAM)' -f $detection.Gpu.Vendor, $detection.Gpu.Name, $detection.Gpu.VramMb)
    Write-Info ('Chosen profile: {0}' -f $tierLabel)
    Write-Info ('Reason: {0}' -f $rec.Reason)

    $token = Get-HfToken -Auto

    Write-Step -Number 2 -Total 4 -Text 'Ensuring llamafile runtime'
    $exe = Ensure-Llamafile -Auto
    if (-not $exe) {
        Write-Err 'Could not install the runtime. Cannot continue.'
        return 1
    }

    Write-Step -Number 3 -Total 4 -Text 'Downloading the model for your hardware'
    $modelPath = Ensure-Model -Key $tierKey -Token $token -Auto

    if ($modelPath -is [array]) {
        $modelPath = $modelPath[-1]
    }
    if (-not $modelPath -or -not ($modelPath -is [string])) {
        Write-Err 'Could not download the model. Cannot continue.'
        return 1
    }

    Write-Step -Number 4 -Total 4 -Text 'Writing configuration'
    $modelRel = Get-RelativePath -FullPath $modelPath -BasePath $Root

    Write-Config `
        -Tier $tierKey `
        -ModelPath $modelRel `
        -Ctx $rec.Ctx `
        -Predict $rec.Predict `
        -Threads $rec.Threads `
        -GpuLayers $rec.GpuLayers `
        -Batch $rec.Batch `
        -UBatch $rec.UBatch `
        -CacheK $rec.CacheK `
        -CacheV $rec.CacheV `
        -HostName '127.0.0.1' `
        -Port 8080 `
        -Parallel 1 `
        -EnableMetrics $true `
        -EnableTools $true `
        -Tools 'all' `
        -UseNoMmap $true `
        -FlashAttn 'on' `
        -BrowserTimeout 30

    Update-ModelIndex

    Write-SuccessBanner `
        -ModelName (Split-Path $modelPath -Leaf) `
        -TierLabel $tierLabel `
        -ServerUrl 'http://127.0.0.1:8080/'

    return 0
}

# ============================================================================
# SEMI-AUTO MODE (guided manual)
# ============================================================================
function Invoke-SemiAutoMode {
    param($Detection)

    Write-Banner
    Write-Host '   MODE: SEMI-AUTO (guided manual)' -ForegroundColor Yellow
    Write-Host '   You will be guided step by step. Press Enter to accept defaults.' -ForegroundColor DarkGray
    Write-Host ''

    $rec = $Detection.Recommendation
    $recommendedKey = Normalize-TierKey $rec.Tier

    Write-Section 'Step 1/7 - Hugging Face access token (optional)'
    $token = Get-HfToken

    Write-Section 'Step 2/7 - Model selection'
    $defaultIndex = 0
    for ($i = 0; $i -lt $ModelCatalog.Count; $i++) {
        if ($ModelCatalog[$i].Key -eq $recommendedKey) { $defaultIndex = $i }
    }
    $labels = @()
    for ($i = 0; $i -lt $ModelCatalog.Count; $i++) {
        $m = $ModelCatalog[$i]
        $tag = if ($m.Key -eq $recommendedKey) { ' [RECOMMENDED]' } else { '' }
        $labels += ('{0}{1}' -f $m.Label, $tag)
    }
    $labels += 'Custom (I will paste a Hugging Face link)'

    $choice = Read-Choice -Prompt 'Choose a model:' -Options $labels -Default $defaultIndex

    if ($choice -eq $ModelCatalog.Count) {
        Write-Host ''
        Write-Info 'Paste a Hugging Face resolve URL, an hf:// URI, or "repo/file".'
        Write-Info 'Examples:'
        Write-Host '     https://huggingface.co/<user>/<repo>/resolve/main/<file>.gguf' -ForegroundColor DarkGray
        Write-Host '     hf://<user>/<repo>/<file>.gguf' -ForegroundColor DarkGray
        $url = Read-Text 'URL or hf:// URI'
        $customTier = Read-Text 'Save into which tier folder?' 'custom'
        try {
            $null = & $DOWNLOAD -Url $url -Tier $customTier -Token $token -ShowProgress:$true
            $modelRel = 'models\' + $customTier + '\' + [System.IO.Path]::GetFileName(($url -split '\?')[0])
            $tierForCfg = $customTier
        } catch {
            Write-Err ('Custom download failed: ' + $_.Exception.Message)
            return 1
        }
    } else {
        $model = $ModelCatalog[$choice]
        $tierForCfg = $model.Key
        $modelPath = Ensure-Model -Key $model.Key -Token $token
        if ($modelPath -is [array]) { $modelPath = $modelPath[-1] }
        if (-not $modelPath -or -not ($modelPath -is [string])) {
            Write-Err 'Model download failed or was skipped.'
            return 1
        }
        $modelRel = Get-RelativePath -FullPath $modelPath -BasePath $Root
    }

    Write-Section 'Step 3/7 - Llamafile runtime'
    $exe = Ensure-Llamafile
    if (-not $exe) {
        Write-Warn 'Runtime not installed. The launcher will not work until it is in server\.'
    }

    Write-Section 'Step 4/7 - Hardware profile'
    $tierOptions = @('4 GB GPU', '6 GB GPU', '8 GB GPU or more', 'CPU only (no GPU)')
    $recIdx = 3
    switch ($recommendedKey) {
        '4GB'    { $recIdx = 0 }
        '6GB'    { $recIdx = 1 }
        '8GB'    { $recIdx = 2 }
        'no_gpu' { $recIdx = 3 }
    }
    $profileChoice = Read-Choice -Prompt 'Pick the hardware profile to tune for:' -Options $tierOptions -Default $recIdx

    switch ($profileChoice) {
        0 { $gpuLayers = 999; $ctxDefault = 262144; $predictDefault = 32768; $batchDefault = 128; $ubatchDefault = 128 }
        1 { $gpuLayers = 999; $ctxDefault = 262144; $predictDefault = 32768; $batchDefault = 128; $ubatchDefault = 128 }
        2 { $gpuLayers = 999; $ctxDefault = 262144; $predictDefault = 32768; $batchDefault = 128; $ubatchDefault = 128 }
        3 { $gpuLayers = 0;   $ctxDefault = 32768;  $predictDefault = 2048;  $batchDefault = 64;  $ubatchDefault = 64  }
    }
    if ($profileChoice -ne 3) {
        if ($recommendedKey -ne 'no_gpu') {
            $ctxDefault = $rec.Ctx
            $predictDefault = $rec.Predict
            $batchDefault = $rec.Batch
            $ubatchDefault = $rec.UBatch
        }
    }

    Write-Section 'Step 5/7 - Context and generation'
    Write-Host '   Context sizes: 2K, 4K, 8K, 16K, 32K, 64K, 128K, 192K, 256K' -ForegroundColor DarkGray
    Write-Host ('   Recommended for your machine: {0}' -f $ctxDefault) -ForegroundColor DarkGray
    $ctx = Read-Int 'Context window (tokens)' $ctxDefault
    $predict = Read-Int 'Max tokens per reply' $predictDefault
    if ($predict -gt $ctx) { $predict = $ctx; Write-Warn ('PREDICT clamped to CTX=' + $ctx) }

    Write-Section 'Step 6/7 - Server settings'
    $port = Read-Int 'HTTP port' 8080
    $parallel = Read-Int 'Parallel server slots' 1

    Write-Section 'Step 7/7 - Optional features'
    $enableTools = Read-YesNo 'Enable built-in agent tools (file read/write, shell, grep)?' $true
    $tools = 'all'
    if ($enableTools) {
        Write-Host '     Tool list options:' -ForegroundColor DarkGray
        Write-Host '       all                                              (7 tools)' -ForegroundColor DarkGray
        Write-Host '       read_file,write_file,edit_file,grep_search       (4 core coding tools)' -ForegroundColor DarkGray
        $tools = Read-Text 'Tools' 'all'
    }
    $enableMetrics = Read-YesNo 'Enable metrics endpoint (needed by status.bat)?' $true
    $useNoMmap = Read-YesNo 'Disable memory mapping for USB compatibility?' $true
    $flashAttn = Read-Text 'Flash Attention (on/off/auto)' 'on'

    $threads = Read-Int 'CPU threads' ([Math]::Max(2, [Math]::Min($Detection.Cpu.Cores, 8)))

    Write-Config `
        -Tier $tierForCfg `
        -ModelPath $modelRel `
        -Ctx $ctx `
        -Predict $predict `
        -Threads $threads `
        -GpuLayers $gpuLayers `
        -Batch $batchDefault `
        -UBatch $ubatchDefault `
        -CacheK 'q4_0' `
        -CacheV 'q4_0' `
        -HostName '127.0.0.1' `
        -Port $port `
        -Parallel $parallel `
        -EnableMetrics $enableMetrics `
        -EnableTools $enableTools `
        -Tools $tools `
        -UseNoMmap $useNoMmap `
        -FlashAttn $flashAttn `
        -BrowserTimeout 30

    Update-ModelIndex

    Write-SuccessBanner `
        -ModelName (Split-Path $modelRel -Leaf) `
        -TierLabel (Get-TierLabel $tierForCfg) `
        -ServerUrl ('http://127.0.0.1:{0}/' -f $port)

    return 0
}

# ============================================================================
# MAIN
# ============================================================================
try {
    Write-Banner

    Write-Host '   This wizard will:' -ForegroundColor White
    Write-Host '     - detect your hardware' -ForegroundColor DarkGray
    Write-Host '     - download the llamafile runtime if needed' -ForegroundColor DarkGray
    Write-Host '     - download a model that fits your machine' -ForegroundColor DarkGray
    Write-Host '     - write config.json for launcher.bat and status.bat' -ForegroundColor DarkGray
    Write-Host ''

    $mode = Read-Choice -Prompt 'Choose a setup mode:' -Options @(
        'AUTO      - one-click, detect and install everything (recommended for new users)',
        'SEMI-AUTO - guided manual, you choose model/tier/context/tools',
        'Exit'
    ) -Default 0

    if ($mode -eq 2) {
        Write-Host ''
        Write-Info 'Exiting without changes.'
        exit 0
    }

    if ($mode -eq 0) {
        $rc = Invoke-AutoMode
        if ($rc -ne 0) {
            Write-Host ''
            Write-Err 'Automatic setup did not complete. Re-run setup.bat to try again.'
            Read-Host '   Press Enter to close' | Out-Null
            exit $rc
        }
        Read-Host '   Press Enter to close' | Out-Null
        exit 0
    }

    $detection = Invoke-Detection
    $rc = Invoke-SemiAutoMode -Detection $detection

    if ($rc -ne 0) {
        Write-Host ''
        Write-Err 'Setup did not complete. Re-run setup.bat to try again.'
        exit $rc
    }

    Read-Host '   Press Enter to close' | Out-Null
    exit 0
}
catch {
    Write-Host ''
    Write-Err ('Unexpected error: ' + $_.Exception.Message)
    Write-Host ('   At: ' + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '   Press Enter to close' | Out-Null
    exit 1
}