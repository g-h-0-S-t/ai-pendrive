use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use sysinfo::System;

#[derive(Parser, Debug)]
#[command(name = "ai-pendrive", version, about = "Hardware-aware local AI launcher")]
struct Cli {
    #[arg(long, default_value = "models.json", global = true)]
    manifest: PathBuf,
    #[arg(long, global = true)]
    portable_dir: Option<PathBuf>,
    #[arg(long, global = true, help = "Allow a CPU profile when an accelerated profile is unavailable")]
    allow_cpu_fallback: bool,
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Inspect,
    List,
    Download { id: String },
    Verify { id: String },
    Launch { id: String, #[arg(long)] runtime: Option<String>, #[arg(last = true)] args: Vec<String> },
}

#[derive(Debug, Clone, Serialize)]
struct Machine {
    os: String,
    arch: String,
    memory_gib: f64,
    available_memory_gib: f64,
    free_disk_gib: f64,
    gpu: GpuInfo,
}

#[derive(Debug, Clone, Serialize)]
struct GpuInfo {
    probe: String,
    available: bool,
    name: Option<String>,
    vram_gib: Option<f64>,
    note: String,
}

#[derive(Debug, Deserialize)]
struct Manifest {
    version: u32,
    models: Vec<Model>,
}

#[derive(Debug, Deserialize)]
struct Model {
    id: String,
    name: String,
    description: String,
    filename: String,
    url: String,
    sha256: String,
    size_bytes: u64,
    min_memory_gib: f64,
    min_free_disk_gib: f64,
    #[serde(default)]
    min_vram_gib: Option<f64>,
    supported_os: Vec<String>,
    supported_arch: Vec<String>,
    runtime_profile: RuntimeProfile,
    enabled: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum RuntimeProfile { Cpu, NvidiaCuda, Metal, Vulkan }

impl RuntimeProfile {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Cpu => "cpu",
            Self::NvidiaCuda => "nvidia_cuda",
            Self::Metal => "metal",
            Self::Vulkan => "vulkan",
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let base = cli.portable_dir.unwrap_or_else(default_base_dir);
    let manifest_path = resolve_manifest(&base, &cli.manifest);
    let manifest = load_manifest(&manifest_path)?;
    let machine = inspect_machine(&base);

    match cli.command.unwrap_or(Commands::List) {
        Commands::Inspect => println!("{}", serde_json::to_string_pretty(&machine)?),
        Commands::List => list_models(&manifest, &machine, cli.allow_cpu_fallback),
        Commands::Download { id } => download_model(find_safe_model(&manifest, &machine, &id, cli.allow_cpu_fallback)?, &base),
        Commands::Verify { id } => verify_model(find_model(&manifest, &id)?, &base),
        Commands::Launch { id, runtime, args } => {
            let model = find_safe_model(&manifest, &machine, &id, cli.allow_cpu_fallback)?;
            launch_model(model, &base, runtime.as_deref(), &args)
        }
    }
}

fn default_base_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_else(|| PathBuf::from("."))
}

fn resolve_manifest(base: &Path, manifest: &Path) -> PathBuf {
    if manifest.is_absolute() { manifest.to_path_buf() } else { base.join(manifest) }
}

fn load_manifest(path: &Path) -> Result<Manifest> {
    let raw = fs::read_to_string(path).with_context(|| format!("Could not read model manifest: {}", path.display()))?;
    let manifest: Manifest = serde_json::from_str(&raw).context("Model manifest is not valid JSON")?;
    if manifest.version != 1 { bail!("Unsupported model manifest version {}", manifest.version); }
    Ok(manifest)
}

fn inspect_machine(base: &Path) -> Machine {
    let mut system = System::new_all();
    system.refresh_all();
    let disk = fs2::available_space(base).or_else(|_| fs2::available_space(".")).unwrap_or(0);
    Machine {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        memory_gib: bytes_to_gib(system.total_memory()),
        available_memory_gib: bytes_to_gib(system.available_memory()),
        free_disk_gib: bytes_to_gib(disk),
        gpu: probe_gpu(),
    }
}

fn probe_gpu() -> GpuInfo {
    let output = Command::new("nvidia-smi").args(["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]).output();
    match output {
        Ok(result) if result.status.success() => {
            let line = String::from_utf8_lossy(&result.stdout).lines().next().unwrap_or_default().trim().to_string();
            let mut fields = line.splitn(2, ',').map(str::trim);
            let name = fields.next().filter(|value| !value.is_empty()).map(ToOwned::to_owned);
            let vram_mib = fields.next().and_then(|value| value.parse::<f64>().ok());
            GpuInfo {
                probe: "nvidia-smi".into(), available: name.is_some() && vram_mib.is_some(), name,
                vram_gib: vram_mib.map(|value| value / 1024.0),
                note: "NVIDIA GPU information obtained from nvidia-smi.".into(),
            }
        }
        Ok(_) => GpuInfo {
            probe: "nvidia-smi".into(), available: false, name: None, vram_gib: None,
            note: "nvidia-smi ran but did not return a usable NVIDIA GPU record.".into(),
        },
        Err(_) => GpuInfo {
            probe: "none".into(), available: false, name: None, vram_gib: None,
            note: "No supported GPU probe was available. GPU capability is unknown; CPU profiles remain available.".into(),
        },
    }
}

fn bytes_to_gib(bytes: u64) -> f64 { bytes as f64 / 1024.0_f64.powi(3) }

fn list_models(manifest: &Manifest, machine: &Machine, allow_cpu_fallback: bool) {
    println!("Machine: {} {} | {:.1} GiB RAM ({:.1} GiB available) | {:.1} GiB disk free", machine.os, machine.arch, machine.memory_gib, machine.available_memory_gib, machine.free_disk_gib);
    match (&machine.gpu.name, machine.gpu.vram_gib) {
        (Some(name), Some(vram)) => println!("GPU: {name} | {vram:.1} GiB VRAM ({})", machine.gpu.probe),
        _ => println!("GPU: unknown ({})", machine.gpu.note),
    }
    println!();
    for model in &manifest.models {
        let reasons = incompatibilities(model, machine, allow_cpu_fallback);
        let status = if reasons.is_empty() { "SAFE" } else { "UNAVAILABLE" };
        println!("[{status}] {} ({}) [{}]", model.name, model.id, model.runtime_profile.as_str());
        println!("  {}", model.description);
        println!("  Download: {:.2} GiB", bytes_to_gib(model.size_bytes));
        if !reasons.is_empty() { println!("  Reason: {}", reasons.join("; ")); }
    }
}

fn find_model<'a>(manifest: &'a Manifest, id: &str) -> Result<&'a Model> {
    manifest.models.iter().find(|model| model.id == id).with_context(|| format!("Unknown model id: {id}"))
}

fn find_safe_model<'a>(manifest: &'a Manifest, machine: &Machine, id: &str, allow_cpu_fallback: bool) -> Result<&'a Model> {
    let model = find_model(manifest, id)?;
    let reasons = incompatibilities(model, machine, allow_cpu_fallback);
    if !reasons.is_empty() { bail!("Model '{}' is not safe for this machine: {}", model.name, reasons.join("; ")); }
    Ok(model)
}

fn incompatibilities(model: &Model, machine: &Machine, allow_cpu_fallback: bool) -> Vec<String> {
    let mut reasons = Vec::new();
    if !model.enabled { reasons.push("model is disabled in the manifest".into()); }
    if !model.supported_os.iter().any(|value| value == &machine.os) { reasons.push(format!("OS '{}' is unsupported", machine.os)); }
    if !model.supported_arch.iter().any(|value| value == &machine.arch) { reasons.push(format!("architecture '{}' is unsupported", machine.arch)); }
    if machine.memory_gib < model.min_memory_gib { reasons.push(format!("needs {:.1} GiB RAM", model.min_memory_gib)); }
    if machine.free_disk_gib < model.min_free_disk_gib { reasons.push(format!("needs {:.1} GiB free disk", model.min_free_disk_gib)); }
    if model.runtime_profile == RuntimeProfile::NvidiaCuda && !allow_cpu_fallback {
        match machine.gpu.vram_gib {
            Some(vram) if model.min_vram_gib.map_or(true, |minimum| vram >= minimum) => {}
            Some(vram) => reasons.push(format!("needs {:.1} GiB NVIDIA VRAM; detected {vram:.1} GiB", model.min_vram_gib.unwrap_or(0.0))),
            None => reasons.push("NVIDIA VRAM could not be verified; use a CPU profile or --allow-cpu-fallback after testing the runtime".into()),
        }
    }
    if model.runtime_profile == RuntimeProfile::Metal && machine.os != "macos" { reasons.push("Metal profiles require macOS".into()); }
    if model.runtime_profile == RuntimeProfile::Vulkan && machine.os == "macos" { reasons.push("Vulkan profile is not enabled for macOS in this catalog".into()); }
    reasons
}

fn model_path(model: &Model, base: &Path) -> PathBuf { base.join("models").join(&model.filename) }

fn download_model(model: &Model, base: &Path) -> Result<()> {
    if model.sha256.len() != 64 || model.sha256.chars().all(|value| value == '0') { bail!("Refusing to download '{}': set a real 64-character SHA-256 in models.json first", model.id); }
    let destination = model_path(model, base);
    if destination.exists() { verify_model(model, base)?; println!("Already downloaded and verified: {}", destination.display()); return Ok(()); }
    fs::create_dir_all(destination.parent().expect("model path has a parent"))?;
    let partial = destination.with_extension(format!("{}.partial", destination.extension().and_then(|value| value.to_str()).unwrap_or("download")));
    println!("Downloading {}…", model.name);
    let mut response = reqwest::blocking::get(&model.url).with_context(|| format!("Request failed: {}", model.url))?.error_for_status()?;
    let mut output = File::create(&partial)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    let mut received = 0_u64;
    loop {
        let read = response.read(&mut buffer)?;
        if read == 0 { break; }
        output.write_all(&buffer[..read])?;
        hasher.update(&buffer[..read]);
        received += read as u64;
        eprint!("\rDownloaded {:.1}%", received as f64 * 100.0 / model.size_bytes.max(1) as f64);
    }
    eprintln!();
    output.sync_all()?;
    if received != model.size_bytes { let _ = fs::remove_file(&partial); bail!("Downloaded size mismatch: expected {}, received {}", model.size_bytes, received); }
    let actual = hex::encode(hasher.finalize());
    if !actual.eq_ignore_ascii_case(&model.sha256) { let _ = fs::remove_file(&partial); bail!("SHA-256 mismatch. Expected {}, received {}", model.sha256, actual); }
    fs::rename(partial, &destination)?;
    println!("Verified and saved: {}", destination.display());
    Ok(())
}

fn verify_model(model: &Model, base: &Path) -> Result<()> {
    let path = model_path(model, base);
    let metadata = fs::metadata(&path).with_context(|| format!("Model is not downloaded: {}", path.display()))?;
    if metadata.len() != model.size_bytes { bail!("Size mismatch: expected {}, received {}", model.size_bytes, metadata.len()); }
    let actual = sha256_file(&path)?;
    if !actual.eq_ignore_ascii_case(&model.sha256) { bail!("SHA-256 mismatch: expected {}, received {}", model.sha256, actual); }
    println!("Verified: {}", path.display());
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 { break; }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn runtime_candidates(profile: &RuntimeProfile, base: &Path) -> Vec<PathBuf> {
    let windows = std::env::consts::OS == "windows";
    let suffix = if windows { ".exe" } else { "" };
    let names: &[&str] = match profile {
        RuntimeProfile::Cpu => &["llama-server-cpu", "llama-server", "llamafile"],
        RuntimeProfile::NvidiaCuda => &["llama-server-cuda", "llama-server"],
        RuntimeProfile::Metal => &["llama-server-metal", "llama-server"],
        RuntimeProfile::Vulkan => &["llama-server-vulkan", "llama-server"],
    };
    names.iter().map(|name| base.join("runtimes").join(format!("{name}{suffix}"))).collect()
}

fn resolve_runtime(profile: &RuntimeProfile, base: &Path, override_runtime: Option<&str>) -> Result<PathBuf> {
    if let Some(runtime) = override_runtime { return Ok(PathBuf::from(runtime)); }
    if let Some(runtime) = std::env::var_os("AI_PENDRIVE_RUNTIME") { return Ok(PathBuf::from(runtime)); }
    runtime_candidates(profile, base).into_iter().find(|candidate| candidate.is_file()).with_context(|| format!("No runtime found for '{}' profile. Put a compatible runtime in {}/runtimes or set AI_PENDRIVE_RUNTIME", profile.as_str(), base.display()))
}

fn launch_model(model: &Model, base: &Path, override_runtime: Option<&str>, args: &[String]) -> Result<()> {
    verify_model(model, base)?;
    let model_file = model_path(model, base);
    let runtime = resolve_runtime(&model.runtime_profile, base, override_runtime)?;
    println!("Launching '{}' with {}", model.name, runtime.display());
    let status = Command::new(runtime).arg("-m").arg(model_file).args(args).current_dir(base).stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit()).status().context("Failed to start local runtime")?;
    if !status.success() { bail!("Runtime exited with {status}"); }
    Ok(())
}
