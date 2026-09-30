@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Local LLM Server - CPU Only (no GPU)

rem ============================================================================
rem START_NO_GPU.BAT - Portable local LLM server launcher (CPU only)
rem ============================================================================
rem Required layout:
rem start_no_gpu.bat
rem server\llamafile-0.10.5.exe
rem models\no_gpu\xyz.gguf
rem
rem Use this launcher on machines with no usable GPU backend. Integrated
rem graphics do NOT count: llamafile offloads through CUDA or ROCm, and an
rem integrated GPU has neither, so everything still runs on the CPU.
rem
rem TUNED FOR LOW-RAM CPU MACHINES. Target class: a 4-core laptop-class CPU
rem with 8 GB system RAM and no usable GPU backend.
rem The defaults below were validated against a ~1.9 GB Q4_K_M model on that
rem class of hardware. See the RAM BUDGET section before raising CTX.
rem
rem The model filename is a placeholder. Replace xyz.gguf below with the real
rem GGUF you picked from Hugging Face, and update MODEL_NOGPU to match.
rem ============================================================================

rem ============================== CONFIGURATION ===============================

rem Model location, relative to this batch file.
rem Replace xyz.gguf with the actual model filename once chosen.
set "MODEL_NOGPU=models\no_gpu\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"

rem Llamafile executable location, relative to this batch file.
set "LLAMA_RELATIVE_PATH=server\llamafile-0.10.5.exe"

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
rem On CPU, the KV cache lives in system RAM, not VRAM. It is allocated in
rem full at startup, so CTX is usually the first thing to exhaust RAM.
rem
rem CTX=2048 Tiny/fast chat; short questions; about 1,500 English words.
rem CTX=4096 Basic chat and small coding tasks; about 3,000 words.
rem CTX=8192 Bare minimum; too small for the bundled web UI. See below.
rem CTX=16384 Still not enough for the bundled web UI. See below.
rem CTX=32768 Current default. Smallest value that reliably works.
rem CTX=65536 Extra headroom if the web UI prompt grows again.
rem
rem IMPORTANT - WHY CTX MUST BE AT LEAST 32768 HERE:
rem The bundled llamafile web UI sends a very large system prompt on EVERY
rem request, measured at roughly 19,400 prompt tokens before your message is
rem even counted. Two separate causes were ruled out:
rem   - Agent tools are NOT the cause. Cutting the tool list from all 7 tools
rem     to 4 only saved 388 tokens (19,755 -> 19,367). Do not bother trimming
rem     TOOLS to fix a context error; it will not work.
rem   - The cost is the web UI's own prompt text. Measured on this model,
rem     roughly 20,000 characters of system text costs about 4,000 tokens,
rem     so 19,400 tokens is on the order of 95,000 characters.
rem At CTX=16384 the web UI fails with:
rem   "request (19367 tokens) exceeds the available context size"
rem Raising CTX is the only fix that does not require changing the UI.
rem
rem Memory cost of the larger window is modest because the KV cache is
rem quantized (see CACHE_K/CACHE_V). Re-check the RAM budget below first.
rem
rem Do NOT use CTX=0. Zero loads the context size advertised by the GGUF,
rem which may be 128K or more and will exhaust RAM immediately.
rem ============================================================================
set "CTX=32768"

rem ============================================================================
rem MAX GENERATION (PREDICT) REFERENCE
rem ============================================================================
rem PREDICT is the maximum number of tokens generated per reply.
rem
rem Setting PREDICT equal to CTX does not add memory; it only lets a stuck
rem model run for a very long time. On CPU, a very long reply is also very
rem slow, because every token is computed on the processor.
rem
rem If PREDICT is too low, large write_file calls get cut off mid-string and
rem the server shows: "Failed to parse tool call arguments as JSON".
rem
rem PREDICT=1024 Short answers and small edits.
rem PREDICT=2048 Medium work; covers most single-file edits. Current default.
rem PREDICT=4096 Large files (~300-400 lines of code). Slow on CPU.
rem PREDICT=8192+ Only if one single file truly needs it.
rem PREDICT=-1 Unlimited until context is full. Not recommended.
rem ============================================================================
set "PREDICT=2048"

rem Parallel server slots. 1 preserves the full CTX for one active request.
rem Keep 1 on CPU: extra slots do not add speed, they just split the same
rem few cores between concurrent requests and slow each one down.
set "PARALLEL=1"

rem CPU threads. This is the single biggest speed lever on a GPU-less machine.
rem Set it to the CPU's PHYSICAL core count. Hyperthreaded siblings add
rem little for llama.cpp and can hurt prompt ingestion.
rem   4-core laptop CPU  -> THREADS=4   (this default)
rem   6-core laptop CPU  -> THREADS=6
rem   8-core desktop CPU -> THREADS=8
rem Leave 1-2 cores free if the machine is also running other work.
set "THREADS=4"

rem ============================================================================
rem GPU OFFLOAD
rem ============================================================================
rem 0 means no layers are offloaded; the whole model stays in system RAM.
rem Do not raise this on a machine without a working GPU backend.
rem Watch the startup log for "offloaded 0/N layers to GPU".
set "GPU_LAYERS=0"

rem Prompt batch / micro-batch sizes. Larger is faster for prompt ingestion
rem but uses more memory and, on a 4-core CPU, more time per batch.
rem 64 is the conservative default for low-RAM CPU machines. Raise to 128 or
rem 256 only if RAM and CPU headroom allow; never lower UBATCH below 32.
set "BATCH=64"
set "UBATCH=64"

rem ============================================================================
rem KV-CACHE DATA TYPES  (IMPORTANT ON LOW-RAM CPU MACHINES)
rem ============================================================================
rem This is the biggest RAM lever after CTX. Allowed values:
rem   f32 = 4 bytes/element (highest quality, most RAM)
rem   f16 = 2 bytes/element (llamafile default)
rem   q8_0 / q4_0 / q4_1 = sub-2-byte, smallest RAM, lowest quality
rem
rem q4_0 is the default here for a specific reason: on an 8 GB machine the KV
rem cache, not the model weights, is what causes the out-of-memory failure.
rem A Llama-3.x class model at 8K context costs roughly 0.88 GB of KV cache
rem at f16 but only about 0.25 GB at q4_0.
rem
rem NOTE: a quantized V cache (q4_0/q8_0) requires Flash Attention. That is
rem why FLASH_ATTN below is "on" and must stay consistent with these two.
rem If your llamafile build rejects flash attention on CPU, change BOTH
rem CACHE_K and CACHE_V to f16 AND set FLASH_ATTN=off together, in one edit.
rem ============================================================================
set "CACHE_K=q4_0"
set "CACHE_V=q4_0"

rem ============================================================================
rem FLASH ATTENTION
rem ============================================================================
rem Required by the q4_0 V cache above. Keep "on" unless you switch the cache
rem types to f16, in which case set this to "off" in the same edit.
rem Valid values: on, off, auto.
rem ============================================================================
set "FLASH_ATTN=on"

rem Loading behavior. 1 disables model-file memory mapping (--no-mmap).
rem It helps when reading the model from a USB drive or external SSD, at the
rem cost of a slower load. This is a portable package, so 1 is the default.
rem Important for low RAM: with mmap ENABLED, unread model pages can be
rem evicted under memory pressure, which can rescue a tight-RAM machine.
rem So if you keep the model on an internal drive and still hit out-of-memory
rem on an 8 GB system, try USE_NO_MMAP=0 before lowering CTX further.
set "USE_NO_MMAP=1"

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
rem
rem TOOLS LIST - THIS DOMINATES PROMPT SIZE.
rem Every tool listed here adds its full schema to the prompt on EVERY
rem request. Measured cost is roughly 250-300 tokens per tool.
rem
rem   all                                                7 tools, about 2,000 tokens, plus
rem                                                      llamafile's own tool instructions.
rem                                                      This is what pushed the web UI prompt
rem                                                      to about 20,000 tokens and made every
rem                                                      message fail with "request exceeds the
rem                                                      available context size".
rem
rem   read_file,write_file,edit_file,grep_search         4 core coding tools, about 1,000 tokens.
rem                                                      Recommended default for this profile.
rem
rem   (empty)                                            No tools. Smallest prompt, fastest
rem                                                      prefill. Best for plain chat.
rem
rem Enabling file tools lets the model modify anything it can reach, so keep
rem this list short unless you specifically want agent behavior.
set "ENABLE_TOOLS=1"
rem Comma-separated tool list, or "all" to enable every available tool.
set "TOOLS=all"

rem Browser watcher timeout. Browser opens after the local HTTP server responds.
set "BROWSER_TIMEOUT_MINUTES=30"
set "HEALTH_PATH=/health"
set "OPEN_PATH=/"

rem ============================ END CONFIGURATION =============================

rem ============================================================================
rem RAM BUDGET
rem ============================================================================
rem Peak RAM is roughly:  model file size
rem                     + KV cache (CTX x bytes-per-token, see CACHE_* above)
rem                     + compute buffers (scales with BATCH/UBATCH)
rem                     + Windows itself (about 1.5-2.5 GB).
rem
rem At the shipped defaults with the 1.18 GB Q4_K_M model
rem (CTX=16384, q4_0, BATCH=64):
rem   model 1.2 + KV 0.5 + buffers ~0.5 + Windows ~2.0 = about 4.2 GB peak.
rem That fits a low-RAM 8 GB CPU machine with room to spare.
rem
rem The KV figures below scale with the model's layer count, KV head count and
rem head dimension. For a Llama-3.x class model (28 layers, 8 KV heads,
rem 128 head dim) they are approximately:
rem   CTX      f16       q4_0
rem    8192    0.88 GB   0.25 GB
rem   16384    1.75 GB   0.49 GB
rem   32768    3.50 GB   0.98 GB
rem
rem Do not raise CTX without closing other applications. If Windows starts
rem using the page file during generation, lower CTX first, then the tool list.
rem ============================================================================

set "ROOT=%~dp0"
set "LLAMA=%ROOT%%LLAMA_RELATIVE_PATH%"
set "MODEL=%ROOT%%MODEL_NOGPU%"

rem Optional fallback for an older extensionless llamafile filename.
if not exist "%LLAMA%" set "LLAMA=%ROOT%server\llamafile-0.10.5"

if not exist "%LLAMA%" (
echo.
echo ERROR: Llamafile was not found.
echo Expected: %ROOT%%LLAMA_RELATIVE_PATH%
echo.
echo See server\instructions.txt for the download link.
echo.
pause
exit /b 1
)

if not exist "%MODEL%" (
echo.
echo ERROR: The CPU-only model was not found.
echo Expected: %MODEL%
echo.
echo Create the folder and add your chosen GGUF:
echo     models\no_gpu\
echo Then set MODEL_NOGPU in this file to that exact filename.
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
echo LOCAL LLM SERVER STARTING (CPU ONLY - NO GPU)
echo ============================================================================
echo.
echo Hardware profile : CPU only
echo Model : %MODEL%
echo Llamafile : %LLAMA%
echo Server URL : %OPEN_URL%
echo Context : %CTX% tokens
echo Max generation : %PREDICT% tokens
echo Parallel slots : %PARALLEL%
echo GPU layers : %GPU_LAYERS% (no offload)
echo CPU threads : %THREADS%
echo Batch / uBatch : %BATCH% / %UBATCH%
echo KV cache K / V : %CACHE_K% / %CACHE_V%
echo No memory mapping : %USE_NO_MMAP%
echo Flash Attention : %FLASH_ATTN%
echo Metrics endpoint : %ENABLE_METRICS%
echo Agent tools : %ENABLE_TOOLS% (%TOOLS%)
echo.
echo CPU generation is much slower than GPU generation. The first reply is
echo slow while the model warms up, and model loading can take over a minute.
echo The browser opens on its own once the server answers.
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
