<#
.SYNOPSIS
    Detects CPU, RAM, and GPU capabilities for AI Pendrive.
.DESCRIPTION
    Outputs a PSCustomObject (as JSON when -AsJson is used) describing:
      - CPU cores / threads
      - System RAM total (GB)
      - GPU vendor, name, VRAM (MB), backend (cuda / rocm / none)
      - Recommended tier: 4GB, 6GB, 8GB, or no_gpu
      - Recommended CTX, PREDICT, THREADS, GPU_LAYERS, BATCH, UBATCH
      - Recommended model file name
.PARAMETER AsJson
    Emit the result as JSON instead of a formatted object.
.PARAMETER Root
    Optional project root (unused, kept for symmetry).
#>
param(
    [switch]$AsJson,
    [string]$Root = ''
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-CpuInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cores = 0
    $threads = 0
    try {
        $cores   = [int]$cpu.NumberOfCores
        $threads = [int]$cpu.NumberOfLogicalProcessors
    } catch {}
    if ($cores -le 0) { $cores = [int]$env:NUMBER_OF_PROCESSORS }
    if ($threads -le 0) { $threads = $cores }
    return [pscustomobject]@{
        Name    = if ($cpu.Name) { $cpu.Name.Trim() } else { 'Unknown CPU' }
        Cores   = $cores
        Threads = $threads
    }
}

function Get-RamInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGb = 0
    $freeGb  = 0
    try {
        $totalGb = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGb  = [Math]::Round($os.FreePhysicalMemory     / 1MB, 1)
    } catch {}
    return [pscustomobject]@{
        TotalGb = $totalGb
        FreeGb  = $freeGb
    }
}

function Get-GpuInfo {
    $result = [pscustomobject]@{
        Vendor    = 'None'
        Name      = 'No GPU detected'
        VramMb    = 0
        Backend   = 'none'
        Driver    = ''
        IsNvidia  = $false
        IsAmd     = $false
    }

    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $line = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($line) {
                $parts = $line -split ','
                $result.Vendor  = 'NVIDIA'
                $result.Name    = $parts[0].Trim()
                $result.VramMb  = [int]([double]$parts[1].Trim())
                $result.Driver  = $parts[2].Trim()
                $result.Backend = 'cuda'
                $result.IsNvidia = $true
                return $result
            }
        } catch {}
    }

    try {
        $vid = Get-CimInstance Win32_VideoController | Where-Object {
            $_.Name -match 'Radeon|AMD|Radeon RX|Vega|Navi'
        } | Select-Object -First 1
        if ($vid) {
            $vram = 0
            if ($vid.AdapterRAM -and $vid.AdapterRAM -gt 0) {
                $vram = [int]([Math]::Round($vid.AdapterRAM / 1MB, 0))
            }
            $result.Vendor  = 'AMD'
            $result.Name    = $vid.Name
            $result.VramMb  = $vram
            $result.Backend = 'rocm'
            $result.IsAmd   = $true
            return $result
        }
    } catch {}

    try {
        $vid = Get-CimInstance Win32_VideoController | Select-Object -First 1
        if ($vid) {
            $result.Vendor  = if ($vid.Name -match 'Intel') { 'Intel' } else { 'Other' }
            $result.Name    = $vid.Name
            $result.Backend = 'none'
        }
    } catch {}

    return $result
}

function Get-Recommendation {
    param(
        [pscustomobject]$Cpu,
        [pscustomobject]$Ram,
        [pscustomobject]$Gpu
    )

    $vramMb = [int]$Gpu.VramMb
    $ramGb  = [double]$Ram.TotalGb

    # IMPORTANT: tier keys must match $ModelCatalog in setup_core.ps1:
    # '4GB', '6GB', '8GB', 'no_gpu'.
    $tier       = 'no_gpu'
    $gpuLayers  = 0
    $ctx        = 32768
    $predict    = 2048
    $threads    = [Math]::Max(2, [Math]::Min($Cpu.Cores, 4))
    $batch      = 64
    $ubatch     = 64
    $modelFile  = 'Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
    $modelDir   = 'no_gpu'
    $cacheK     = 'q4_0'
    $cacheV     = 'q4_0'
    $reason     = 'No usable GPU backend detected; using CPU-only profile.'

    if ($Gpu.Backend -eq 'cuda' -or $Gpu.Backend -eq 'rocm') {
        $gpuLayers = 999
        if ($vramMb -ge 7500) {
            $tier      = '8GB'
            $modelFile = 'Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
            $modelDir  = '8GB'
            $ctx       = 262144
            $predict   = 32768
            $threads   = [Math]::Max(4, [Math]::Min($Cpu.Cores, 8))
            $batch     = 128
            $ubatch    = 128
            $reason    = ('GPU VRAM {0} MB >= 7.5 GB: 8 GB profile.' -f $vramMb)
        } elseif ($vramMb -ge 5500) {
            $tier      = '6GB'
            $modelFile = 'Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
            $modelDir  = '6GB'
            $ctx       = 262144
            $predict   = 32768
            $threads   = [Math]::Max(4, [Math]::Min($Cpu.Cores, 8))
            $batch     = 128
            $ubatch    = 128
            $reason    = ('GPU VRAM {0} MB >= 5.5 GB: 6 GB profile.' -f $vramMb)
        } elseif ($vramMb -ge 3500) {
            $tier      = '4GB'
            $modelFile = 'Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf'
            $modelDir  = '4GB'
            $ctx       = 131072
            $predict   = 16384
            $threads   = [Math]::Max(4, [Math]::Min($Cpu.Cores, 8))
            $batch     = 128
            $ubatch    = 128
            $reason    = ('GPU VRAM {0} MB >= 3.5 GB: 4 GB profile.' -f $vramMb)
        } else {
            $tier      = 'no_gpu'
            $gpuLayers = 0
            $reason    = ('GPU VRAM {0} MB is too small for reliable offload; using CPU-only profile.' -f $vramMb)
        }
    }

    if ($tier -ne 'no_gpu') {
        $minRam = 8
        if ($tier -eq '6GB') { $minRam = 12 }
        if ($tier -eq '8GB') { $minRam = 16 }
        if ($ramGb -lt $minRam) {
            $reason = ('System RAM {0} GB is below the {1} GB recommended for tier {2}; downgrading to CPU-only profile.' -f $ramGb, $minRam, $tier)
            $tier      = 'no_gpu'
            $gpuLayers = 0
            $ctx       = 32768
            $predict   = 2048
            $threads   = [Math]::Max(2, [Math]::Min($Cpu.Cores, 4))
            $batch     = 64
            $ubatch    = 64
            $modelFile = 'Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf'
            $modelDir  = 'no_gpu'
        }
    }

    return [pscustomobject]@{
        Tier       = $tier
        GpuLayers  = $gpuLayers
        Ctx        = $ctx
        Predict    = $predict
        Threads    = $threads
        Batch      = $batch
        UBatch     = $ubatch
        ModelFile  = $modelFile
        ModelDir   = $modelDir
        CacheK     = $cacheK
        CacheV     = $cacheV
        Reason     = $reason
    }
}

$cpu = Get-CpuInfo
$ram = Get-RamInfo
$gpu = Get-GpuInfo
$rec = Get-Recommendation -Cpu $cpu -Ram $ram -Gpu $gpu

$result = [pscustomobject]@{
    Cpu            = $cpu
    Ram            = $ram
    Gpu            = $gpu
    Recommendation = $rec
    DetectedAt     = (Get-Date).ToString('s')
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host '  =============================================================='
    Write-Host '   SYSTEM DETECTION'
    Write-Host '  =============================================================='
    Write-Host ('   CPU        : {0}' -f $cpu.Name)
    Write-Host ('   Cores      : {0} physical / {1} logical' -f $cpu.Cores, $cpu.Threads)
    Write-Host ('   System RAM : {0} GB total ({1} GB free)' -f $ram.TotalGb, $ram.FreeGb)
    Write-Host ('   GPU        : {0} {1}' -f $gpu.Vendor, $gpu.Name)
    Write-Host ('   VRAM       : {0} MB' -f $gpu.VramMb)
    Write-Host ('   Backend    : {0}' -f $gpu.Backend)
    Write-Host ''
    Write-Host '  --------------------------------------------------------------'
    Write-Host '   RECOMMENDED PROFILE'
    Write-Host '  --------------------------------------------------------------'
    Write-Host ('   Tier       : {0}' -f $rec.Tier)
    Write-Host ('   Model      : {0}' -f $rec.ModelFile)
    Write-Host ('   Context    : {0} tokens' -f $rec.Ctx)
    Write-Host ('   Max gen    : {0} tokens' -f $rec.Predict)
    Write-Host ('   Threads    : {0}' -f $rec.Threads)
    Write-Host ('   GPU layers : {0}' -f $rec.GpuLayers)
    Write-Host ('   Batch      : {0} / {1}' -f $rec.Batch, $rec.UBatch)
    Write-Host ('   KV cache   : {0} / {1}' -f $rec.CacheK, $rec.CacheV)
    Write-Host ('   Reason     : {0}' -f $rec.Reason)
    Write-Host '  =============================================================='
    Write-Host ''
}