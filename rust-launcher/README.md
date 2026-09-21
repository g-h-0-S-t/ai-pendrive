# AI Pendrive Rust launcher prototype

This branch is an auditable Rust replacement for manual GPU-tier batch-file selection. It is a CLI prototype, not yet a GUI or a complete inference runtime. It does not alter `master` or its existing batch scripts.

## Current capabilities

- Detects operating system, CPU architecture, total/available RAM, free disk space, and NVIDIA GPU/VRAM when `nvidia-smi` is available.
- Treats unprobed GPU capability as **unknown** rather than guessing.
- Filters profiles by OS, architecture, RAM, disk, runtime profile, and known NVIDIA VRAM.
- Provides `setup`, durable portable `config.json`, `status`, and `preflight` commands.
- Downloads through a `.partial` file, attempts HTTP Range resumption, validates declared content length when present, and verifies SHA-256 before making a model available.
- Prevents two launcher instances from writing the same model through a per-model lock file.
- Provides `cancel-download` that removes only a partial download and refuses when a completed model is present.
- Writes append-only local operational logs to `logs/launcher.log`.
- Finds portable runtime binaries in `runtimes/` or accepts a runtime override.

Runtime labels (`cpu`, `nvidia_cuda`, `metal`, `vulkan`) are catalog policies, not a guarantee that every runtime binary works on every machine. Validate each model/runtime pair before enabling it for customers.

## Build

```sh
cd rust-launcher
cargo fmt --all -- --check
cargo check --all-targets
cargo test
cargo build --release
```

## First-run setup

```sh
./target/release/ai-pendrive-launcher setup
```

The wizard inspects the machine, lists only enabled compatible profiles, saves the selection to `config.json`, then asks before downloading. The repository intentionally ships disabled templates, so setup reports no eligible profile until you add an approved model record.

For automation, both the target and download approval must be explicit:

```sh
./ai-pendrive setup --model vendor-model-q4 --skip-download
./ai-pendrive setup --model vendor-model-q4 --accept-download
```

## Operational commands

```sh
# Current hardware, selected profile, local model state, runtime, and log location
./ai-pendrive status

# Fail fast before launch; checks selection/profile eligibility/model/runtime
./ai-pendrive preflight
./ai-pendrive preflight vendor-model-q4

# Resume an interrupted download when the server honors HTTP Range requests
./ai-pendrive download vendor-model-q4

# Delete only an incomplete partial download; never a verified completed model
./ai-pendrive cancel-download vendor-model-q4

# Launch the selected configured model
./ai-pendrive launch -- --port 8080
```

A failed/incomplete download keeps `models/<file>.partial`; rerunning the same `download` command sends a Range request from the partial size. If the server ignores Range, the launcher discards the partial and starts over rather than appending incorrect bytes. If a downloaded file fails SHA-256 validation, the partial is retained for inspection and can be removed with `cancel-download`.

## Portable layout

```text
AI-Pendrive/
  ai-pendrive-launcher[.exe]
  models.json
  config.json
  models/
    model.gguf.partial
    model.gguf.lock
  runtimes/
    llama-server-cpu[.exe]
    llama-server-cuda[.exe]
  logs/
    launcher.log
```

## Logs and privacy

Logs are local and append-only. They record timestamps, event level, selected model IDs, download/verification/runtime events, and sanitized errors. They do not send telemetry or upload prompts, model contents, API keys, or user files.

## Real model profile checklist

Before setting `enabled: true` in `models.json`, verify:

1. Commercial-use and redistribution rights.
2. Official or expressly authorized source URL.
3. Exact immutable file size and 64-character SHA-256.
4. Tested RAM, disk, OS, architecture, GPU, and runtime constraints.
5. A compatible runtime binary you bundle or clearly support.

## Known limits

- Only NVIDIA probing through `nvidia-smi` is implemented. AMD, Intel, Apple unified memory, and Vulkan support need validated platform-specific probes.
- Resume works only when the download server supports byte ranges. The launcher safely restarts otherwise.
- The local catalog is not signed yet. A commercial release should verify a versioned signed catalog using a pinned public key.
- No GUI, installer, auto-updater, licensing, code signing, telemetry, or bundled inference runtime exists yet.
- Do not sell or merge this work to `master` before real model/runtime testing, code signing, packaging, and license review.
