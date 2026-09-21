# AI Pendrive Rust launcher prototype

This branch contains an intentionally small, auditable Rust replacement for manual GPU-tier batch-file selection. It is a CLI prototype, not yet a GUI or a complete inference runtime. It does not alter the existing batch scripts on `master`.

## What it does

- Detects operating system, CPU architecture, total/available RAM, free disk space, and NVIDIA GPU/VRAM when `nvidia-smi` is available.
- Reports GPU capability as **unknown** rather than guessing when it cannot probe it safely.
- Filters profiles by OS, architecture, RAM, disk, runtime profile, and known NVIDIA VRAM.
- Provides a native interactive `setup` wizard and durable portable `config.json` selection state.
- Provides `status` for a one-command view of hardware, selected model, verification state, and runtime availability.
- Downloads only to a temporary partial file, verifies byte size and SHA-256, then atomically moves the file into `models/`.
- Re-verifies model data before launch.
- Finds portable runtime binaries in `runtimes/` or accepts an explicit runtime override.

The runtime labels `cpu`, `nvidia_cuda`, `metal`, and `vulkan` are catalog policies. They do not guarantee that an arbitrary runtime binary works on a given device. Validate each supported model/runtime pair before enabling it for customers.

## Build

```sh
cd rust-launcher
cargo build --release
```

The executable is written to `target/release/` (`ai-pendrive-launcher.exe` on Windows).

## First-run setup

Run the setup wizard from the portable directory:

```sh
./target/release/ai-pendrive-launcher setup
```

The wizard:

1. Inspects the computer.
2. Lists only enabled, compatible profiles.
3. Requires the user to choose a profile.
4. Saves the chosen profile to `config.json` in the portable directory.
5. Requires a separate explicit `y`/`yes` confirmation before it starts downloading.

The repository intentionally ships only disabled example profiles. Therefore the wizard correctly reports no eligible profile until you add a real reviewed profile to `models.json`.

## Non-interactive setup

Automation must name a specific profile and explicitly accept download. This prevents an unattended script from silently downloading a multi-gigabyte file.

```sh
# Save a chosen profile but do not download it
./ai-pendrive setup --model vendor-model-q4 --skip-download

# Download only after explicit acceptance
./ai-pendrive setup --model vendor-model-q4 --accept-download
```

## Status and launch

```sh
# Hardware, selected profile, model verification, and runtime availability
./ai-pendrive status

# Launch the model selected during setup
./ai-pendrive launch -- --port 8080

# Launch a named profile instead of the saved selection
./ai-pendrive launch vendor-model-q4 -- --port 8080
```

If no setup has been completed, `status` remains successful and tells the user to run `setup`; `launch` refuses with an actionable error.

## Runtime layout

```text
AI-Pendrive/
  ai-pendrive-launcher[.exe]
  models.json
  config.json
  models/
  runtimes/
    llama-server-cpu[.exe]
    llama-server-cuda[.exe]
  logs/
```

The launcher checks `runtimes/` first, then `AI_PENDRIVE_RUNTIME`, then an explicit `launch --runtime /path/to/runtime` override. Candidate runtime names depend on the chosen profile.

## Safety requirements for real profiles

Before setting `enabled: true` in `models.json`, verify:

1. The model license permits your commercial use and distribution method.
2. The URL is official or expressly authorized.
3. `size_bytes` and the 64-character `sha256` match the immutable source file.
4. The model has been tested against the declared RAM, disk, OS, architecture, GPU, and runtime profile.
5. A compatible runtime binary is included or clearly supported.

## Tests and CI

```sh
cargo fmt --all -- --check
cargo check --all-targets
cargo test
```

GitHub Actions runs formatting, compile, and test checks on Ubuntu, Windows, and macOS for launcher changes.

## Current limits

- Only NVIDIA probing via `nvidia-smi` is implemented. AMD, Intel, Apple unified-memory, and Vulkan capability checks need validated platform-specific probes.
- Partial downloads do not resume yet.
- The catalog is local and unsigned; production should use a versioned signed catalog verified with a pinned public key.
- No GUI, installer, updater, licensing, code signing, telemetry, or bundled inference runtime is included yet.
- Do not sell or merge this work to `master` before actual model/runtime testing, signing, packaging, and legal review are complete.
