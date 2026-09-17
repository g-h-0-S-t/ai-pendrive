# AI Pendrive

A portable Windows local-LLM package built around [llamafile](https://github.com/mozilla-ai/llamafile). Double-click the launcher for your hardware tier (`start_4gb_gpu.bat`, `start_6gb_gpu.bat`, or `start_8gb_gpu.bat`) to start a local server and browser UI; run `status.bat` in another window for a live terminal dashboard.

The current implementation is deliberately simple: three tier-specific launchers, paths relative to the project/USB root, and one manually selected hardware profile. It does **not** auto-detect hardware, scan model folders, show a model picker, download anything automatically, or prompt for context size at runtime.

**AI Pendrive by Cyberbatman**

## Quick start

### Required layout

Keep this layout. Each launcher builds every path from its own location, so the package works from `D:`, `E:`, a USB pendrive, or an external SSD without hardcoded drive letters.

```text
ai-pendrive/
├── start_4gb_gpu.bat
├── start_6gb_gpu.bat
├── start_8gb_gpu.bat
├── status.bat
├── server/
│   └── llamafile-0.10.5.exe
└── models/
    ├── 4GB/
    │   ├── Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf
    │   └── instructions.txt
    ├── 6GB/
    │   ├── Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
    │   └── instructions.txt
    └── 8GB/
        ├── Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
        └── instructions.txt
```

Model weights and the llamafile executable are intentionally excluded from Git.

### Install the runtime

Download the Windows executable for llamafile 0.10.5 and save it as:

```text
server\llamafile-0.10.5.exe
```

Each launcher expects that exact location. If you use a different build or filename, edit this variable near the top of the selected launcher:

```bat
set "LLAMA_RELATIVE_PATH=server\llamafile-0.10.5.exe"
```

### Download models

Place the designated Qwen3.5 GGUF files at the exact paths shown below:

```text
models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf
models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
```

See the tier-specific files for the current manual download workflow:

```text
models\4GB\instructions.txt
models\6GB\instructions.txt
models\8GB\instructions.txt
```

The launchers do not download models automatically. Run the appropriate Hugging Face CLI command from the AI directory:

```bat
hf download hf://HauhauCS/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf --local-dir "models\4GB"
```

```bat
hf download hf://HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf --local-dir "models\6GB"
```

```bat
hf download hf://HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf --local-dir "models\8GB"
```

If the model repository is gated, install and authenticate the Hugging Face CLI first:

```bat
pip install -U "huggingface_hub[cli]"
hf auth login
```

### Choose profile

Each launcher defaults to the tier in its filename:

| Launcher | `TIER` | Model path | GPU-layer target | Intended hardware |
|---|---:|---|---:|---|
| `start_4gb_gpu.bat` | `4` | `models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf` | `999` | Approximately 4 GB VRAM |
| `start_6gb_gpu.bat` | `6` | `models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | `999` | Approximately 6 GB VRAM |
| `start_8gb_gpu.bat` | `8` | `models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | `999` | Approximately 8 GB or more VRAM |

There is no hardware detection or menu. `TIER` is a fixed distribution/profile choice. The launchers contain all three model paths, but use the path selected by `TIER`; edit `TIER` only when intentionally changing the profile.

`-ngl 999` means “try to offload all possible layers to the GPU.” It is a request, not a guarantee. The actual GPU/CPU layer split appears once in the selected launcher’s startup log.

### Launch and monitor

Double-click the launcher for your hardware tier:

```text
start_4gb_gpu.bat
```

```text
start_6gb_gpu.bat
```

```text
start_8gb_gpu.bat
```

The server remains in the visible CMD window. Once the model has loaded and the local health endpoint responds, the default browser opens automatically at:

```text
http://127.0.0.1:8080/
```

Keep the launcher window open while using the model. Press `Ctrl+C` in that window to stop it.

To monitor the running server, double-click:

```text
status.bat
```

`status.bat` follows this cycle:

```text
collect complete data → render one dashboard frame → wait 5 seconds → repeat
```

It does not blank the terminal before the five-second wait. Normal refreshes use ANSI cursor-home plus erase-to-end-of-display to avoid stale text and excessive flicker.

Press `Ctrl+C` in the dashboard window to close it.

## What it does

- Runs an external GGUF through `server\llamafile-0.10.5.exe`.
- Starts a local llama.cpp/llamafile server and bundled browser UI at `127.0.0.1:8080`.
- Binds only to localhost by default, so devices on the same LAN cannot directly connect.
- Uses a manually configured 4 GB, 6 GB, or 8 GB hardware profile.
- Uses an explicit configurable context window, defaulting to 64K tokens.
- Uses a single server slot so one request can use the full configured context.
- Enables Flash Attention and Q8 KV-cache quantization by default.
- Enables `--metrics` so `status.bat` can read supported Prometheus metrics.
- Optionally passes `--no-mmap` for removable-drive compatibility testing.
- Opens the browser only after the server becomes reachable.

## Files

| File | Purpose |
|---|---|
| `start_4gb_gpu.bat` | 4 GB launcher. Uses `TIER=4` by default, starts llamafile, and opens the browser when the server is ready. |
| `start_6gb_gpu.bat` | 6 GB launcher. Uses `TIER=6` by default, starts llamafile, and opens the browser when the server is ready. |
| `start_8gb_gpu.bat` | 8 GB launcher. Uses `TIER=8` by default, starts llamafile, and opens the browser when the server is ready. |
| `status.bat` | Live terminal dashboard. Polls local server endpoints, Windows CPU/RAM, and NVIDIA GPU data every five seconds. |
| `server\llamafile-0.10.5.exe` | Llamafile runtime. Download separately; it is not included in Git. |
| `models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf` | Designated Qwen3.5 2B Q8 model for the 4 GB profile. |
| `models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | Designated Qwen3.5 4B Q4 model for the 6 GB profile. |
| `models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | Designated Qwen3.5 9B Q4 model for the 8 GB profile. |
| `models\4GB\instructions.txt` | Manual model download instructions for the 4 GB profile. |
| `models\6GB\instructions.txt` | Manual model download instructions for the 6 GB profile. |
| `models\8GB\instructions.txt` | Manual model download instructions for the 8 GB profile. |

## Configuration

All settings below are near the top of each launcher under the `CONFIGURATION` heading. The three launchers share the same configuration structure and differ by their default `TIER` value.

| Variable | Default | Description |
|---|---:|---|
| `TIER` | `4` / `6` / `8` | Fixed profile to use; each launcher defaults to the tier in its filename. |
| `LLAMA_RELATIVE_PATH` | `server\llamafile-0.10.5.exe` | Llamafile executable path relative to the selected launcher. |
| `MODEL_4GB` | `models\4GB\Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf` | Model path selected when `TIER=4`. |
| `MODEL_6GB` | `models\6GB\Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | Model path selected when `TIER=6`. |
| `MODEL_8GB` | `models\8GB\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf` | Model path selected when `TIER=8`. |
| `HOST` | `127.0.0.1` | Local-only bind address. |
| `PORT` | `8080` | Server and bundled web UI port. |
| `CTX` | `65536` | Maximum context window, in tokens. |
| `PARALLEL` | `1` | Server slots. Keep `1` when one conversation needs the entire configured context. |
| `THREADS_*` | `6 / 8 / 8` | CPU thread count for the chosen profile. |
| `GPU_LAYERS_*` | `999 / 999 / 999` | Maximum model layers requested on GPU for each profile. |
| `BATCH_*` | `128` | Prompt-processing batch size. More can improve prompt ingestion but needs more VRAM. |
| `UBATCH_*` | `128` | Prompt micro-batch size. Lower it if prompt ingestion causes GPU out-of-memory errors. |
| `CACHE_K_*` | `q8_0` | KV-cache K precision. |
| `CACHE_V_*` | `q8_0` | KV-cache V precision. Flash Attention remains enabled for this configuration. |
| `USE_NO_MMAP` | `1` | Controls whether `--no-mmap` is passed. |
| `FLASH_ATTN` | `on` | Flash Attention mode: `on`, `off`, or `auto` where supported. |
| `JINJA` | `--jinja` | Uses the chat template provided by GGUF metadata. |
| `ENABLE_METRICS` | `1` | Passes `--metrics`, enabling the local `/metrics` endpoint used by `status.bat`. |
| `BROWSER_TIMEOUT_MINUTES` | `30` | Maximum wait for a healthy server before the browser watcher stops. |

## Context settings

`CTX` is the maximum active context in tokens. It includes the system prompt, chat history, pasted documents/code/logs, tool output, and generated output. A rough English estimate is 1 token ≈ 0.75 words, but code and other languages differ.

The KV cache grows with context length. Llamafile allocates the configured context capacity during initialization, so raising `CTX` can cause an out-of-memory failure before the first prompt.

| `CTX` | Name | Suitable work | Approx. English capacity | 4–8 GB VRAM expectation |
|---:|---|---|---:|---|
| `2048` | 2K | Short chat, small questions | 1,500 words | Easy |
| `4096` | 4K | Basic chat, small code snippets | 3,000 words | Easy |
| `8192` | 8K | Normal technical work and moderate code | 6,000 words | Usually easy |
| `16384` | 16K | Longer coding tasks, medium documents, agent prompts | 12,000 words | Usually practical |
| `32768` | 32K | Large logs, multiple files, RAG chunks | 24,000 words | Model-dependent |
| `65536` | 64K | Long documents/logs and extended coding/agent work | 48,000 words | Current default; test each exact profile |
| `98304` | 96K | Specialist long-context tasks | 72,000 words | Usually tight on 4–8 GB VRAM |
| `131072` | 128K | Very large documents/repositories | 96,000 words | Often impractical without a smaller model or CPU offload |
| `262144` | 256K | Extreme context; requires explicit model support | 192,000 words | Not a dependable 4–8 GB distribution preset |

Do not set:

```bat
set "CTX=0"
```

In llama.cpp-family runtimes, `0` commonly asks the runtime to use context metadata from the model. That might be 128K, 256K, or higher and can cause an immediate allocation failure. Use an explicit value such as:

```bat
set "CTX=65536"
```

If your 64K requirement causes out-of-memory errors, try these in order:

1. Keep `CTX=65536` and change the affected `CACHE_K_*` and `CACHE_V_*` values from `q8_0` to `q4_0`.
2. Reduce the affected `BATCH_*` and `UBATCH_*` values from `128` to `64`.
3. Choose a smaller GGUF/model for that profile.
4. Reduce `GPU_LAYERS_*` only if CPU offload is acceptable.

## Runtime flags

For the default 8 GB profile, the launcher produces the equivalent of this command shape:

```bat
llamafile-0.10.5.exe --server -m "MODEL.gguf" --host 127.0.0.1 --port 8080 --jinja -c 65536 -np 1 -ngl 999 -t 8 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 --batch-size 128 --ubatch-size 128 --metrics --no-mmap
```

Exact values depend on `TIER` and the variables in the selected launcher.

| Flag | Purpose |
|---|---|
| `--server` | Starts the local HTTP server and bundled web UI. |
| `-m "...gguf"` | Loads the selected external GGUF file. |
| `--host 127.0.0.1` | Restricts direct access to the current machine. |
| `--port 8080` | Sets the HTTP server port. |
| `--jinja` | Applies the model’s GGUF chat template. |
| `-c N` | Sets explicit context capacity. |
| `-np 1` | Creates one server slot. |
| `-ngl N` | Requests up to N model layers on GPU. Check startup logs for actual layers offloaded. |
| `-t N` | Sets CPU inference threads. |
| `--flash-attn on` | Enables Flash Attention. |
| `--cache-type-k q8_0` | Uses Q8 KV-cache keys rather than FP16. |
| `--cache-type-v q8_0` | Uses Q8 KV-cache values rather than FP16. |
| `--batch-size N` | Prompt processing batch size. |
| `--ubatch-size N` | Prompt processing micro-batch size. |
| `--metrics` | Enables the Prometheus-style `/metrics` endpoint for the dashboard. |
| `--no-mmap` | Optional legacy llamafile flag that disables model memory-mapping. |

### USB loading

`llamafile-0.10.5.exe` rejects the newer llama.cpp option:

```bat
--load-mode none
```

Do not use that flag with this runtime. The compatible optional form is:

```bat
--no-mmap
```

`--no-mmap` can help compatibility with some removable media setups, but it is not guaranteed to load faster and can increase host-RAM pressure. Test both settings on the actual USB drive and target system:

```bat
set "USE_NO_MMAP=1"
```

or:

```bat
set "USE_NO_MMAP=0"
```

Do not pass both `--no-mmap` and `--load-mode none`.

## Status dashboard

`status.bat` reads local data every five seconds and displays:

- Server health from `/health`.
- Model/context properties from `/props` when exposed by the runtime.
- Prompt and generation token throughput from `/metrics` when available.
- Request counters from `/metrics` when available.
- Windows CPU percentage and system-RAM use.
- NVIDIA GPU model, utilization, VRAM use, temperature, and power via `nvidia-smi`.
- KV-cache metrics only when the particular llamafile build exports matching metrics.

The dashboard cannot reliably obtain the exact **actual GPU-layer split** after startup. That information is normally printed only during model initialization in the selected launcher’s console, for example:

```text
offloading N repeating layers to GPU
offloaded N/N layers to GPU
```

The dashboard’s live NVIDIA VRAM figure remains useful because it reflects actual GPU memory consumption at polling time.

## Local API

With a launcher running, the service is available at:

```text
http://127.0.0.1:8080
```

Common llama.cpp-compatible endpoints include:

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | `GET` | Readiness/server status. |
| `/props` | `GET` | Server/model properties, when supported. |
| `/metrics` | `GET` | Prometheus-style metrics when launched with `--metrics`. |
| `/v1/models` | `GET` | OpenAI-compatible model list. |
| `/v1/chat/completions` | `POST` | OpenAI-compatible chat completion. |
| `/v1/completions` | `POST` | Raw text completion. |
| `/v1/embeddings` | `POST` | Embeddings endpoint when supported by the model/runtime. |

No API key is configured by default. Binding to `127.0.0.1` prevents direct LAN access, but do not expose the port externally unless you intentionally add authentication and restrictive CORS settings.

## Troubleshooting

| Problem | Fix |
|---|---|
| `error: invalid argument: --load-mode` | Remove `--load-mode`. Llamafile 0.10.5 does not accept it; use optional `--no-mmap` instead. |
| Dashboard says metrics are unavailable | Confirm `ENABLE_METRICS=1`; ensure `--metrics` is inside the final continued llamafile command; stop and restart the server. |
| `--metrics` is shown in the launcher but unavailable | Verify the previous command line ends with `^`; otherwise CMD ends the launch command before `--metrics`. |
| Browser does not open | Wait for model load, then open `http://127.0.0.1:8080/` manually. Check that port 8080 is not already in use. |
| Model not found | Confirm the exact filename and folder match `MODEL_4GB`, `MODEL_6GB`, or `MODEL_8GB`. |
| `TIER must be 4, 6, or 8` | Set `TIER` to exactly `4`, `6`, or `8`. |
| CUDA/GPU out of memory | Keep 64K if required; try Q4 KV cache, lower batch/uBatch, choose a smaller model, or accept lower GPU layers/CPU offload. |
| `failed to fit params ... n_gpu_layers already set by user` | Expected if you explicitly pass `-ngl`, such as `999`. Auto-fit did not override your manual offload request. |
| `munmap failed` warning | Usually harmless when subsequent lines say `model loaded` and `listening on ...`. |
| Dashboard overlaps/looks garbled | Replace it with the current `status.bat`, which uses ANSI cursor-home plus erase-to-end-of-display. |
| `NVIDIA GPU unavailable` in the dashboard | Install/update NVIDIA drivers and ensure `nvidia-smi` works in Command Prompt. |

## Distribution notes

- This launcher/dashboard implementation targets Windows because it uses `.bat`, PowerShell, and `nvidia-smi`.
- Llamafile itself supports more operating systems, but this project’s current convenience scripts are Windows-specific.
- Do not hardcode a USB drive letter; retain paths relative to the project root.
- Windows SmartScreen may warn about unsigned binaries downloaded from the internet. Code-signing is recommended for public distribution.
- Run normally for a local server. Do not use administrator privileges unless a specific use case requires elevated file access.
- Validate the exact model, quantization, context size, GPU driver, background VRAM load, and system RAM together before promising a profile works across every machine in a VRAM tier.

## License

MIT — see `LICENSE`.
