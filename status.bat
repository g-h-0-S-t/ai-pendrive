@echo off
setlocal EnableExtensions
set "SELF_DIR=%~dp0"

rem ============================================================================
rem status.bat - Llamafile live terminal dashboard
rem ============================================================================
rem Put this file beside start.bat, then run start.bat first.
rem
rem Data cycle:
rem   collect all data -> render completed dashboard -> wait -> collect again
rem
rem The render uses ANSI cursor-home plus erase-to-end-of-screen. Therefore it
rem does not use CLS during normal refreshes, does not leave old text behind,
rem and does not blank the display during the five-second wait.
rem
rem Press Ctrl+C inside the dashboard to close it.
rem ============================================================================

rem ============================== CONFIGURATION ===============================

rem Must match HOST and PORT in start.bat.
set "HOST=127.0.0.1"
set "PORT=8080"

rem Seconds to keep a fully rendered frame on screen before collecting again.
set "REFRESH_SECONDS=5"

rem Number of characters in CPU, RAM, GPU, VRAM, and KV-cache bars.
set "BAR_WIDTH=36"

rem ============================ END CONFIGURATION =============================

rem A temporary PS1 avoids fragile CMD parsing of a large inline PowerShell script.
set "PS1=%TEMP%\llamafile_status_dashboard_%RANDOM%_%RANDOM%.ps1"

>"%PS1%" echo param(
>>"%PS1%" echo     [string]$HostName,
>>"%PS1%" echo     [int]$Port,
>>"%PS1%" echo     [int]$RefreshSeconds,
>>"%PS1%" echo     [int]$BarWidth
>>"%PS1%" echo )
>>"%PS1%" echo.
>>"%PS1%" echo $ErrorActionPreference = 'SilentlyContinue'
>>"%PS1%" echo $BaseUrl = "http://$HostName`:$Port"
>>"%PS1%" echo $Esc = [char]27
>>"%PS1%" echo $FirstRender = $true
>>"%PS1%" echo.
>>"%PS1%" echo function Get-Bar([double]$Value, [int]$Width) {
>>"%PS1%" echo     $Value = [Math]::Max(0, [Math]::Min(100, $Value))
>>"%PS1%" echo     $Filled = [int][Math]::Round($Value * $Width / 100)
>>"%PS1%" echo     return ('#' * $Filled) + ('-' * ($Width - $Filled))
>>"%PS1%" echo }
>>"%PS1%" echo.
>>"%PS1%" echo function Get-Metric([string]$Text, [string]$Name) {
>>"%PS1%" echo     $Match = [regex]::Match($Text, "(?m)^" + [regex]::Escape($Name) + "\s+([-+0-9.Ee]+)\s*$")
>>"%PS1%" echo     if ($Match.Success) { return [double]$Match.Groups[1].Value }
>>"%PS1%" echo     return $null
>>"%PS1%" echo }
>>"%PS1%" echo.
>>"%PS1%" echo function Show-Value($Value, [int]$Digits = 2) {
>>"%PS1%" echo     if ($null -eq $Value) { return 'N/A' }
>>"%PS1%" echo     return [Math]::Round([double]$Value, $Digits)
>>"%PS1%" echo }
>>"%PS1%" echo.
>>"%PS1%" echo while ($true) {
>>"%PS1%" echo     # ------------------------ COLLECT SERVER DATA ------------------------
>>"%PS1%" echo     $Health = 'OFFLINE'
>>"%PS1%" echo     $Model = 'N/A'
>>"%PS1%" echo     $Context = 'N/A'
>>"%PS1%" echo     $PromptTps = $null
>>"%PS1%" echo     $GenerateTps = $null
>>"%PS1%" echo     $KvRatio = $null
>>"%PS1%" echo     $KvTokens = $null
>>"%PS1%" echo     $RequestsProcessing = $null
>>"%PS1%" echo     $RequestsPending = $null
>>"%PS1%" echo     $Detail = ''
>>"%PS1%" echo.
>>"%PS1%" echo     try {
>>"%PS1%" echo         $HealthReply = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 2
>>"%PS1%" echo         $Health = 'READY'
>>"%PS1%" echo         if ($HealthReply.status) { $Health = [string]$HealthReply.status }
>>"%PS1%" echo.
>>"%PS1%" echo         try {
>>"%PS1%" echo             $Props = Invoke-RestMethod -Uri "$BaseUrl/props" -TimeoutSec 2
>>"%PS1%" echo             if ($Props.default_generation_settings.n_ctx) { $Context = $Props.default_generation_settings.n_ctx }
>>"%PS1%" echo             elseif ($Props.n_ctx) { $Context = $Props.n_ctx }
>>"%PS1%" echo             if ($Props.model_path) { $Model = [string]$Props.model_path }
>>"%PS1%" echo             elseif ($Props.model) { $Model = [string]$Props.model }
>>"%PS1%" echo         } catch {}
>>"%PS1%" echo.
>>"%PS1%" echo         try {
>>"%PS1%" echo             $Metrics = (Invoke-WebRequest -Uri "$BaseUrl/metrics" -UseBasicParsing -TimeoutSec 2).Content
>>"%PS1%" echo             $PromptTps = Get-Metric $Metrics 'llamacpp:prompt_tokens_seconds'
>>"%PS1%" echo             $GenerateTps = Get-Metric $Metrics 'llamacpp:predicted_tokens_seconds'
>>"%PS1%" echo             $KvRatio = Get-Metric $Metrics 'llamacpp:kv_cache_usage_ratio'
>>"%PS1%" echo             $KvTokens = Get-Metric $Metrics 'llamacpp:kv_cache_tokens'
>>"%PS1%" echo             $RequestsProcessing = Get-Metric $Metrics 'llamacpp:requests_processing'
>>"%PS1%" echo             $RequestsPending = Get-Metric $Metrics 'llamacpp:requests_deferred'
>>"%PS1%" echo         } catch {
>>"%PS1%" echo             $Detail = 'Metrics endpoint is unavailable. Verify --metrics in start.bat, then restart the server.'
>>"%PS1%" echo         }
>>"%PS1%" echo     } catch {
>>"%PS1%" echo         $Detail = 'Server unavailable at ' + $BaseUrl
>>"%PS1%" echo     }
>>"%PS1%" echo.
>>"%PS1%" echo     # ------------------------ COLLECT CPU AND RAM ------------------------
>>"%PS1%" echo     $CpuPercent = 0
>>"%PS1%" echo     $RamUsedGb = 0
>>"%PS1%" echo     $RamTotalGb = 0
>>"%PS1%" echo     $RamPercent = 0
>>"%PS1%" echo     try {
>>"%PS1%" echo         $Os = Get-CimInstance Win32_OperatingSystem
>>"%PS1%" echo         $RamTotalGb = [Math]::Round($Os.TotalVisibleMemorySize / 1MB, 1)
>>"%PS1%" echo         $RamUsedGb = [Math]::Round(($Os.TotalVisibleMemorySize - $Os.FreePhysicalMemory) / 1MB, 1)
>>"%PS1%" echo         $RamPercent = [Math]::Round(($RamUsedGb / $RamTotalGb) * 100, 1)
>>"%PS1%" echo         $Cpu = Get-CimInstance Win32_Processor ^| Measure-Object -Property LoadPercentage -Average
>>"%PS1%" echo         $CpuPercent = [Math]::Round($Cpu.Average, 1)
>>"%PS1%" echo     } catch {}
>>"%PS1%" echo.
>>"%PS1%" echo     # ----------------------- COLLECT NVIDIA GPU DATA ----------------------
>>"%PS1%" echo     $GpuName = 'NVIDIA GPU unavailable'
>>"%PS1%" echo     $GpuPercent = 0
>>"%PS1%" echo     $GpuUsedMiB = 0
>>"%PS1%" echo     $GpuTotalMiB = 0
>>"%PS1%" echo     $GpuTemp = 'N/A'
>>"%PS1%" echo     $GpuPower = 'N/A'
>>"%PS1%" echo     try {
>>"%PS1%" echo         $GpuLine = ^& nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2^>$null ^| Select-Object -First 1
>>"%PS1%" echo         if ($GpuLine) {
>>"%PS1%" echo             $GpuFields = $GpuLine -split ','
>>"%PS1%" echo             $GpuName = $GpuFields[0].Trim()
>>"%PS1%" echo             $GpuPercent = [double]$GpuFields[1].Trim()
>>"%PS1%" echo             $GpuUsedMiB = [double]$GpuFields[2].Trim()
>>"%PS1%" echo             $GpuTotalMiB = [double]$GpuFields[3].Trim()
>>"%PS1%" echo             $GpuTemp = $GpuFields[4].Trim()
>>"%PS1%" echo             $GpuPower = $GpuFields[5].Trim()
>>"%PS1%" echo         }
>>"%PS1%" echo     } catch {}
>>"%PS1%" echo.
>>"%PS1%" echo     $GpuMemoryPercent = 0
>>"%PS1%" echo     if ($GpuTotalMiB -gt 0) { $GpuMemoryPercent = [Math]::Round(($GpuUsedMiB / $GpuTotalMiB) * 100, 1) }
>>"%PS1%" echo.
>>"%PS1%" echo     $KvPercent = 0
>>"%PS1%" echo     if ($null -ne $KvRatio) {
>>"%PS1%" echo         if ($KvRatio -le 1) { $KvPercent = [Math]::Round($KvRatio * 100, 1) }
>>"%PS1%" echo         else { $KvPercent = [Math]::Round($KvRatio, 1) }
>>"%PS1%" echo     }
>>"%PS1%" echo.
>>"%PS1%" echo     # ----------------------------- RENDER -------------------------------
>>"%PS1%" echo     # All data exists before this point. Home + J erases the old frame only
>>"%PS1%" echo     # at the instant the new complete frame is rendered.
>>"%PS1%" echo     $Now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
>>"%PS1%" echo     $Lines = @(
>>"%PS1%" echo         ''
>>"%PS1%" echo         '  =============================================================================='
>>"%PS1%" echo         ('   LOCAL LLM STATUS DASHBOARD                                  ' + $Now)
>>"%PS1%" echo         '  =============================================================================='
>>"%PS1%" echo         ''
>>"%PS1%" echo         ('   SERVER       : ' + $Health)
>>"%PS1%" echo         ('   URL          : ' + $BaseUrl)
>>"%PS1%" echo         ('   MODEL        : ' + $Model)
>>"%PS1%" echo         ('   CONTEXT      : ' + $Context + ' tokens')
>>"%PS1%" echo         ''
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         '   THROUGHPUT'
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         ('   Prompt speed : ' + (Show-Value $PromptTps) + ' tok/s')
>>"%PS1%" echo         ('   Generate     : ' + (Show-Value $GenerateTps) + ' tok/s')
>>"%PS1%" echo         ('   Requests     : processing ' + (Show-Value $RequestsProcessing 0) + '   pending ' + (Show-Value $RequestsPending 0))
>>"%PS1%" echo         ''
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         '   SYSTEM'
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         ('   CPU          : [' + (Get-Bar $CpuPercent $BarWidth) + '] ' + $CpuPercent + '%%')
>>"%PS1%" echo         ('   System RAM   : [' + (Get-Bar $RamPercent $BarWidth) + '] ' + $RamPercent + '%%  (' + $RamUsedGb + ' / ' + $RamTotalGb + ' GB)')
>>"%PS1%" echo         ('   GPU          : ' + $GpuName)
>>"%PS1%" echo         ('   GPU compute  : [' + (Get-Bar $GpuPercent $BarWidth) + '] ' + $GpuPercent + '%%')
>>"%PS1%" echo         ('   GPU VRAM     : [' + (Get-Bar $GpuMemoryPercent $BarWidth) + '] ' + $GpuMemoryPercent + '%%  (' + $GpuUsedMiB + ' / ' + $GpuTotalMiB + ' MiB)')
>>"%PS1%" echo         ('   GPU temp     : ' + $GpuTemp + ' C   ^|   GPU power: ' + $GpuPower + ' W')
>>"%PS1%" echo         ''
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         '   CONTEXT / KV CACHE'
>>"%PS1%" echo         '  ------------------------------------------------------------------------------'
>>"%PS1%" echo         ('   KV cache     : [' + (Get-Bar $KvPercent $BarWidth) + '] ' + $KvPercent + '%%  (' + (Show-Value $KvTokens 0) + ' cached tokens)')
>>"%PS1%" echo         ('   Max context  : ' + $Context + ' tokens')
>>"%PS1%" echo         '   GPU offload  : Exact GPU/CPU layer count appears once in start.bat startup logs.'
>>"%PS1%" echo         ''
>>"%PS1%" echo         '  =============================================================================='
>>"%PS1%" echo         ('   Collect -> render -> wait ' + $RefreshSeconds + ' seconds -> repeat. Ctrl+C closes.')
>>"%PS1%" echo         '  =============================================================================='
>>"%PS1%" echo         ''
>>"%PS1%" echo     )
>>"%PS1%" echo.
>>"%PS1%" echo     if ($Detail) { $Lines += ('   Detail: ' + $Detail) }
>>"%PS1%" echo.
>>"%PS1%" echo     if ($FirstRender) {
>>"%PS1%" echo         Clear-Host
>>"%PS1%" echo         $FirstRender = $false
>>"%PS1%" echo     } else {
>>"%PS1%" echo         # ESC[H = cursor home. ESC[J = erase from home to end of display.
>>"%PS1%" echo         Write-Host ($Esc + '[H' + $Esc + '[J') -NoNewline
>>"%PS1%" echo     }
>>"%PS1%" echo.
>>"%PS1%" echo     Write-Host ($Lines -join [Environment]::NewLine) -NoNewline
>>"%PS1%" echo     Start-Sleep -Seconds $RefreshSeconds
>>"%PS1%" echo }

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -HostName "%HOST%" -Port %PORT% -RefreshSeconds %REFRESH_SECONDS% -BarWidth %BAR_WIDTH%
set "EXIT_CODE=%ERRORLEVEL%"

del "%PS1%" >nul 2>&1

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Dashboard stopped with exit code %EXIT_CODE%.
    echo.
    pause
)

endlocal
exit /b %EXIT_CODE%
