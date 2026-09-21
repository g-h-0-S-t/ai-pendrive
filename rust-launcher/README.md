# AI Pendrive Rust launcher prototype

This branch contains an intentionally small, auditable Rust replacement for manual GPU-tier batch-file selection. It is a CLI prototype, not yet a GUI or a complete inference runtime. It never changes the repository's existing launch scripts.

## What it does

- Detects the current operating system and CPU architecture.
- Reads total/available RAM and free disk space.
- Lists only model profiles that meet the declared OS, architecture, RAM, and disk requirements.
- Refuses a download or launch when the declared compatibility requirements are not met.
- Downloads to a temporary partial file, verifies exact size and SHA-256, and only then moves the model into `models/`.
- Re-verifies model size and SHA-256 before launching a runtime.
- Supports a portable directory so executable, manifest, runtime, models, and logs can live on a USB SSD.

GPU VRAM detection is deliberately not claimed yet. Reliable GPU capability detection needs platform-specific adapters and a tested compatibility matrix. The first safe release should default to CPU/RAM-safe profiles and add validated back ends individually.

## Build

Install a stable Rust toolchain, then run:

```sh
cd rust-launcher
cargo build --release
```

The executable is written to `target/release/` (`ai-pendrive-launcher.exe` on Windows).

## Commands

Run from the `rust-launcher` directory, or pass an absolute `--manifest` path.

```sh
# Inspect the host in JSON
./target/release/ai-pendrive-launcher inspect

# List safe and unavailable profiles, with reasons
./target/release/ai-pendrive-launcher list

# Download a compatible, enabled model
./target/release/ai-pendrive-launcher download model-id

# Re-check an existing model before use
./target/release/ai-pendrive-launcher verify model-id

# Launch a verified model through a configured local runtime
AI_PENDRIVE_RUNTIME=/path/to/llama-server ./target/release/ai-pendrive-launcher launch model-id -- --port 8080
```

On Windows PowerShell, set the runtime for the current session first:

```powershell
$env:AI_PENDRIVE_RUNTIME = "C:\AI-Pendrive\runtimes\llama-server.exe"
.\target\release\ai-pendrive-launcher.exe launch model-id -- --port 8080
```

## Portable mode

Use `--portable-dir` to make the launcher use a folder on a USB drive for the manifest and model store:

```sh
./ai-pendrive-launcher --portable-dir /media/AI-Pendrive list
```

A practical release folder is:

```text
AI-Pendrive/
  ai-pendrive-launcher[.exe]
  models.json
  models/
  runtimes/
  logs/
```

## Adding a real model

`models.json` contains disabled templates only. This is intentional: the launcher refuses placeholder checksums and disabled profiles. Before enabling a model, verify all of the following:

1. The model license permits the intended commercial use and distribution path.
2. The download URL is controlled by, or explicitly authorized by, the model publisher.
3. `size_bytes` is the exact release-file size.
4. `sha256` is an exact 64-character SHA-256 for that immutable file.
5. The RAM/disk requirements have been validated on supported operating systems and hardware.
6. The runtime can load the selected file format.

Example profile fields:

```json
{
  "id": "vendor-model-q4",
  "filename": "vendor-model-q4.gguf",
  "url": "https://official.example/model.gguf",
  "sha256": "exact_64_character_sha256_here",
  "size_bytes": 4680000000,
  "min_memory_gib": 8.0,
  "min_free_disk_gib": 7.0,
  "supported_os": ["windows", "macos", "linux"],
  "supported_arch": ["x86_64", "aarch64"],
  "enabled": true
}
```

## Safety model

The manifest is a local policy file in this prototype. A production release should fetch a versioned signed model catalog over HTTPS, pin the public key in the application, validate catalog signatures, and retain local verified manifests for offline use. HTTPS plus a file hash protects a file transfer; a signed catalog protects the model metadata itself.

Do not add a model just because it is popular. Its model license, redistribution terms, support status, checksum, runtime compatibility, and measured resource requirements are all release requirements.

## Known limits / next work

- CPU/RAM/disk/OS/architecture checks are implemented; GPU and VRAM detection are not.
- Downloads are safe but do not resume partial downloads yet.
- The runtime command is supplied via `AI_PENDRIVE_RUNTIME`; it does not bundle `llama.cpp` or `llamafile`.
- No updater, licensing, GUI, code signing, telemetry, or cross-platform installer is included.
- Add tests, signed catalog support, Windows/macOS/Linux packaging, and a small GUI before treating this as a commercial release.
