# AI Pendrive Rust launcher prototype

This branch contains an intentionally small, auditable Rust replacement for manual GPU-tier batch-file selection. It is a CLI prototype, not yet a GUI or a complete inference runtime. It does not alter the existing batch scripts on `master`.

## What it does

- Detects operating system, CPU architecture, total/available RAM, and free disk space.
- Tries an NVIDIA probe through `nvidia-smi`; it reports **unknown** when the command is unavailable or unusable instead of guessing GPU compatibility.
- Filters model profiles by OS, architecture, RAM, disk requirements, runtime profile, and—where known—NVIDIA VRAM.
- Refuses downloads and launches that fail these declared safety checks.
- Downloads only to a temporary partial file, verifies exact byte size and SHA-256, then moves the verified file into `models/`.
- Re-verifies the model file immediately before launch.
- Supports a portable directory so launcher, catalog, models, runtimes, and logs can be kept together on a USB SSD.
- Selects runtime binaries from `runtimes/` automatically, with an explicit command-line or environment override when needed.

The launcher currently supports four runtime profile labels: `cpu`, `nvidia_cuda`, `metal`, and `vulkan`. These are catalog policies, not a claim that every runtime binary works on every device. Test each runtime/profile pair before enabling it for customers.

## Build

Install a stable Rust toolchain, then run:

```sh
cd rust-launcher
cargo build --release
```

The executable is written to `target/release/` (`ai-pendrive-launcher.exe` on Windows).

## Commands

```sh
# Inspect OS, architecture, memory, disk, and GPU-probe result as JSON
./target/release/ai-pendrive-launcher inspect

# List available and unavailable model profiles with exact reasons
./target/release/ai-pendrive-launcher list

# Download a compatible, enabled model
./target/release/ai-pendrive-launcher download model-id

# Verify a previously downloaded model
./target/release/ai-pendrive-launcher verify model-id

# Launch through an automatically selected portable runtime
./target/release/ai-pendrive-launcher launch model-id -- --port 8080

# Override the runtime explicitly
./target/release/ai-pendrive-launcher launch model-id --runtime /path/to/llama-server -- --port 8080
```

If an NVIDIA profile cannot be verified but you have independently tested a compatible CPU-capable runtime, you may explicitly permit the policy fallback:

```sh
./target/release/ai-pendrive-launcher --allow-cpu-fallback list
```

This flag changes catalog eligibility only. It does **not** transform a CUDA-only executable into a CPU runtime. Use a compatible runtime binary.

## Runtime layout

By default, the launcher searches the portable directory for runtime binaries in this order:

| Profile | Candidate names |
|---|---|
| `cpu` | `llama-server-cpu`, `llama-server`, `llamafile` |
| `nvidia_cuda` | `llama-server-cuda`, `llama-server` |
| `metal` | `llama-server-metal`, `llama-server` |
| `vulkan` | `llama-server-vulkan`, `llama-server` |

The `.exe` suffix is automatically used on Windows. Put the selected executable in `runtimes/`, set `AI_PENDRIVE_RUNTIME`, or pass `--runtime`.

```text
AI-Pendrive/
  ai-pendrive-launcher[.exe]
  models.json
  models/
  runtimes/
    llama-server-cpu[.exe]
    llama-server-cuda[.exe]
  logs/
```

## Portable mode

Use `--portable-dir` to make the launcher resolve the manifest, model store, and runtimes from a USB directory:

```sh
./ai-pendrive-launcher --portable-dir /media/AI-Pendrive list
```

## Adding a real model

`models.json` contains disabled templates only. The launcher refuses a disabled model and rejects all-zero placeholder hashes. Before enabling a model, confirm:

1. The model license permits your commercial use and chosen distribution path.
2. The model source URL is official or explicitly authorized.
3. `size_bytes` matches the immutable release file exactly.
4. `sha256` is an exact 64-character SHA-256 for that file.
5. RAM, disk, GPU/VRAM, runtime, and operating-system requirements are tested rather than guessed.
6. The runtime profile points to an actual binary you ship or support.

## Tests and CI

Run the local checks with:

```sh
cargo fmt --all -- --check
cargo check --all-targets
cargo test
```

GitHub Actions runs those checks on Ubuntu, Windows, and macOS for changes affecting `rust-launcher/`. The tests intentionally use the disabled templates: they verify that inspection works and unsafe/unknown downloads are refused without contacting any model host.

## Known limits / next work

- Only NVIDIA detection via `nvidia-smi` is implemented; AMD, Intel, Apple unified-memory, and Vulkan capability checks need platform-specific probing and device testing.
- GPU information remains unknown when the probe is unavailable; that is safer than estimating VRAM.
- Downloads do not resume yet.
- The local catalog is not cryptographically signed yet. A commercial release should verify a versioned signed catalog using a pinned public key.
- No GUI, updater, licensing system, code signing, installer, telemetry, or bundled inference runtime is included yet.
- Do not merge this into `master` or sell it before you test actual model/runtime combinations and complete code-signing and release packaging.
