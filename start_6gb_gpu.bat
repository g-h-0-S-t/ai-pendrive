@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Local LLM Server - 256K Context

rem ============================================================================
rem START_6GB_GPU.BAT - Portable local LLM server launcher
rem ============================================================================
rem Required layout:
rem start_6gb_gpu.bat
rem server\llamafile-0.10.5.exe
rem models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf
rem models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
rem models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
rem
rem ============================================================================

rem ============================== CONFIGURATION ===============================

rem Hardware profile to distribute: 4, 6, or 8.
rem 4 = designated 4 GB model and conservative GPU layers.
rem 6 = designated 6 GB model and a larger GPU-layer target.
rem 8 = designated 8 GB Qwen model and maximum GPU-layer target.
set "TIER=6"

rem Llamafile executable location, relative to this batch file.
set "LLAMA_RELATIVE_PATH=server\llamafile-0.10.5.exe"

rem Model locations, relative to this batch file.
set "MODEL_4GB=models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf"
set "MODEL_6GB=models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
set "MODEL_8GB=models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"

rem Server bind address. 127.0.0.1 allows access only from this computer.
set "HOST=127.0.0.1"

rem Server HTTP port. The browser opens at http://127.0.0.1:8080/.
set "PORT=8080"

rem ============================================================================
rem CONTEXT WINDOW (CTX) REFERENCE
rem ============================================================================
rem CTX is the maximum active context in tokens. It includes system prompt,
rem chat history, pasted text/files, tool output, and newly generated tokens.
rem One English token is roughly 0.75 words on average.
rem
rem Larger CTX consumes more RAM/VRAM through the KV cache. Memory for the
rem configured maximum is allocated at startup. Keep PARALLEL=1 if one user
rem must have the full CTX value available.
rem
rem CTX=2048 Tiny/fast chat; short questions; about 1,500 English words.
rem CTX=4096 Basic chat and small coding tasks; about 3,000 words.
rem CTX=8192 Normal technical work and moderate code; about 6,000 words.
rem CTX=16384 Longer coding, agent prompts, and medium documents; ~12,000.
rem CTX=32768 Large logs, source files, RAG chunks; about 24,000 words.
rem CTX=65536 64K mode: long documents, large logs, long agent/coding work;
rem about 48,000 words.
rem CTX=98304 96K specialist mode. Test the exact model and memory budget.
rem CTX=131072 128K very-long context. Often too memory-heavy for 4-8 GB VRAM.
rem CTX=196608 192K. Good fallback if 256K fails to load.
rem CTX=262144 256K extreme context. Qwen3.5 native maximum. This is the
rem current distribution default, for one-shot game/software builds.
rem
rem Do NOT use CTX=0 for this distribution. 0 loads the context size advertised
rem by the GGUF, which may be 256K+ and can cause an immediate OOM.
rem If 256K fails: try CTX=196608, then CTX=131072, then lower batch sizes
rem to 64, or use a smaller model. Lower GPU layers only if CPU offload is
rem acceptable.
rem ============================================================================
set "CTX=262144"

rem ============================================================================
rem MAX GENERATION (PREDICT) REFERENCE
rem ============================================================================
rem PREDICT is the maximum number of tokens the model may generate in ONE
rem response or ONE tool call (for example, one write_file call).
rem
rem PREDICT is NOT extra context. Generated tokens come out of CTX.
rem Setting PREDICT equal to CTX does not add memory; it only lets a stuck
rem model run for a very long time.
rem
rem If PREDICT is too low, large write_file calls get cut off mid-string and
rem the server shows: "Failed to parse tool call arguments as JSON".
rem
rem PREDICT=4096 Short answers and small edits.
rem PREDICT=8192 Medium files (~600-800 lines of code).
rem PREDICT=16384 Large files (~1,200-1,500 lines of code).
rem PREDICT=32768 Very large files. Current distribution default.
rem PREDICT=65536 Only if one single file truly needs it. Slower if it loops.
rem PREDICT=-1 Unlimited until context is full. Not recommended.
rem ============================================================================
set "PREDICT=32768"

rem Parallel server slots. 1 preserves the full CTX for one active request.
set "PARALLEL=1"

rem CPU threads for each VRAM profile. Higher can improve prompt processing,
rem but too many threads can reduce responsiveness on weaker CPUs.
rem Tip: set to your CPU's physical core count if it has fewer than 8 cores.
set "THREADS_4GB=8"
set "THREADS_6GB=8"
set "THREADS_8GB=8"

rem Maximum model layers offloaded to GPU. 999 means attempt all layers that fit.
rem Reduce only when a profile needs CPU offload to avoid GPU out-of-memory.
rem Check the startup log for "offloaded X/Y layers to GPU".
set "GPU_LAYERS_4GB=999"
set "GPU_LAYERS_6GB=999"
set "GPU_LAYERS_8GB=999"

rem Prompt batch / micro-batch sizes. Larger is faster for prompt ingestion but
rem uses more VRAM. Keep 128 as a conservative 256K-context distribution default.
rem Use 64 if you run out of VRAM. Try 256 or 512 only with spare VRAM.
set "BATCH_4GB=128"
set "BATCH_6GB=128"
set "BATCH_8GB=128"
set "UBATCH_4GB=128"
set "UBATCH_6GB=128"
set "UBATCH_8GB=128"

rem KV-cache data types for keys and values. q8_0 is a quality/memory balance.
rem If you run out of VRAM, use q4_0.
rem Currently defaulting it to q4_0 (needed for 256K on 4-8 GB VRAM).
rem Remember -
rem q8_0 = better quality, higher vRAM consumption, slower
rem q4_0 = lower quality, lesser vRAM consumption, faster
rem Tip: if you lower CTX to 65536, you can try q8_0 on the 8 GB profile.
set "CACHE_K_4GB=q4_0"
set "CACHE_K_6GB=q4_0"
set "CACHE_K_8GB=q4_0"
set "CACHE_V_4GB=q4_0"
set "CACHE_V_6GB=q4_0"
set "CACHE_V_8GB=q4_0"

rem Loading behavior. none disables model-file memory mapping (old --no-mmap).
rem It can help removable-drive compatibility but can use more system RAM and
rem is not guaranteed to load faster. Change to mmap only after testing.
set "USE_NO_MMAP=1"

rem Flash Attention: on, off, or auto. Keep on for long context and quantized KV.
rem A quantized V cache (q4_0/q8_0) requires Flash Attention.
set "FLASH_ATTN=on"

rem Chat-template option. --jinja uses the GGUF's model-specific chat template.
set "JINJA=--jinja"

rem Set to 1 to expose the Prometheus /metrics endpoint for status.bat.
rem Requires a server restart after changing this setting.
set "ENABLE_METRICS=1"

rem Built-in agent tools: read_file, write_file, edit_file, grep_search,
rem file_glob_search, exec_shell_command, get_datetime.
rem Set to 1 to enable llamafile's built-in agent tools so the model can edit
rem files, search code, and run shell commands through the web UI. When enabled,
rem llamafile restricts CORS to localhost automatically.
set "ENABLE_TOOLS=1"
rem Comma-separated tool list, or "all" to enable every available tool.
set "TOOLS=all"

rem Browser watcher timeout. Browser opens after the local HTTP server responds.
set "BROWSER_TIMEOUT_MINUTES=30"
set "HEALTH_PATH=/health"
set "OPEN_PATH=/"

rem ============================ END CONFIGURATION =============================

set "ROOT=%~dp0"
set "LLAMA=%ROOT%%LLAMA_RELATIVE_PATH%"

rem Optional fallback for an older extensionless llamafile filename.
if not exist "%LLAMA%" set "LLAMA=%ROOT%server\llamafile-0.10.5"

if not exist "%LLAMA%" (
echo.
echo ERROR: Llamafile was not found.
echo Expected: %ROOT%%LLAMA_RELATIVE_PATH%
echo.
pause
exit /b 1
)

rem Validate manually configured hardware profile.
if not "%TIER%"=="4" if not "%TIER%"=="6" if not "%TIER%"=="8" (
echo.
echo ERROR: TIER must be 4, 6, or 8. Current value: %TIER%
echo.
pause
exit /b 1
)

rem Resolve active profile variables.
if "%TIER%"=="4" (
set "MODEL=%ROOT%%MODEL_4GB%"
set "THREADS=%THREADS_4GB%"
set "GPU_LAYERS=%GPU_LAYERS_4GB%"
set "BATCH=%BATCH_4GB%"
set "UBATCH=%UBATCH_4GB%"
set "CACHE_K=%CACHE_K_4GB%"
set "CACHE_V=%CACHE_V_4GB%"
)

if "%TIER%"=="6" (
set "MODEL=%ROOT%%MODEL_6GB%"
set "THREADS=%THREADS_6GB%"
set "GPU_LAYERS=%GPU_LAYERS_6GB%"
set "BATCH=%BATCH_6GB%"
set "UBATCH=%UBATCH_6GB%"
set "CACHE_K=%CACHE_K_6GB%"
set "CACHE_V=%CACHE_V_6GB%"
)

if "%TIER%"=="8" (
set "MODEL=%ROOT%%MODEL_8GB%"
set "THREADS=%THREADS_8GB%"
set "GPU_LAYERS=%GPU_LAYERS_8GB%"
set "BATCH=%BATCH_8GB%"
set "UBATCH=%UBATCH_8GB%"
set "CACHE_K=%CACHE_K_8GB%"
set "CACHE_V=%CACHE_V_8GB%"
)

if not exist "%MODEL%" (
echo.
echo ERROR: Model for the %TIER% GB profile was not found.
echo Expected: %MODEL%
echo.
pause
exit /b 1
)

rem Safety check: PREDICT must never be larger than CTX.
rem PREDICT=-1 (unlimited) is left untouched.
if %PREDICT% GTR %CTX% set "PREDICT=%CTX%"

rem Expand optional flags before the multi-line launch command.
set "METRICS_FLAG="
if "%ENABLE_METRICS%"=="1" set "METRICS_FLAG=--metrics"

rem --no-mmap disables GGUF memory mapping.
rem Set to 1 for USB/removable-drive compatibility; set to 0 for default mmap.
set "NO_MMAP_FLAG="
if "%USE_NO_MMAP%"=="1" set "NO_MMAP_FLAG=--no-mmap"

rem Expand the tools flag. Empty when tools are disabled.
set "TOOLS_FLAG="
if "%ENABLE_TOOLS%"=="1" set "TOOLS_FLAG=--tools %TOOLS%"

set "BASE_URL=http://%HOST%:%PORT%"
set "HEALTH_URL=%BASE_URL%%HEALTH_PATH%"
set "OPEN_URL=%BASE_URL%%OPEN_PATH%"

cls
echo ============================================================================
echo LOCAL LLM SERVER STARTING
echo ============================================================================
echo.
echo Hardware profile : %TIER% GB
echo Model : %MODEL%
echo Llamafile : %LLAMA%
echo Server URL : %OPEN_URL%
echo Context : %CTX% tokens
echo Max generation : %PREDICT% tokens
echo Parallel slots : %PARALLEL%
echo GPU layers : %GPU_LAYERS%
echo CPU threads : %THREADS%
echo Batch / uBatch : %BATCH% / %UBATCH%
echo KV cache K / V : %CACHE_K% / %CACHE_V%
echo No memory mapping : %USE_NO_MMAP%
echo Flash Attention : %FLASH_ATTN%
echo Metrics endpoint : %ENABLE_METRICS%
echo Agent tools : %ENABLE_TOOLS% (%TOOLS%)
echo.
echo Loading model. The browser opens automatically when the server is ready.
echo Press Ctrl+C to stop the server.
echo ============================================================================
echo.

rem Browser watcher starts separately and leaves this CMD window visible.
start "Llamafile browser watcher" /b powershell -NoProfile -ExecutionPolicy Bypass -Command "$url='%HEALTH_URL%'; $open='%OPEN_URL%'; $deadline=(Get-Date).AddMinutes(%BROWSER_TIMEOUT_MINUTES%); while((Get-Date) -lt $deadline){ try { $r=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2; if($r.StatusCode -ge 200 -and $r.StatusCode -lt 500){ Start-Process $open; exit 0 } } catch {} Start-Sleep -Milliseconds 750 }"

rem Run the server in this visible CMD window.
rem Every continued line ends in ^ except the final line.
"%LLAMA%" --server ^
-m "%MODEL%" ^
--host %HOST% ^
--port %PORT% ^
%JINJA% ^
-c %CTX% ^
-n %PREDICT% ^
-np %PARALLEL% ^
-ngl %GPU_LAYERS% ^
-t %THREADS% ^
--flash-attn %FLASH_ATTN% ^
--cache-type-k %CACHE_K% ^
--cache-type-v %CACHE_V% ^
--batch-size %BATCH% ^
--ubatch-size %UBATCH% ^
%METRICS_FLAG% ^
%NO_MMAP_FLAG% ^
%TOOLS_FLAG%

echo.
echo Server stopped.
pause
