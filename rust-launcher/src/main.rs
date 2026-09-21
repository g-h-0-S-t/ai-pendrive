use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use fs2::FileExt;
use reqwest::{blocking::Client, header::{ACCEPT_RANGES, CONTENT_LENGTH, RANGE}};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};
use sysinfo::System;

const CONFIG_FILE: &str = "config.json";
const LOG_FILE: &str = "logs/launcher.log";

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
    Status,
    Preflight { id: Option<String> },
    Setup {
        #[arg(long)] model: Option<String>,
        #[arg(long)] accept_download: bool,
        #[arg(long)] skip_download: bool,
    },
    Download { id: String },
    CancelDownload { id: String },
    Verify { id: String },
    Launch { id: Option<String>, #[arg(long)] runtime: Option<String>, #[arg(last = true)] args: Vec<String> },
}

#[derive(Debug, Clone, Serialize)]
struct Machine { os: String, arch: String, memory_gib: f64, available_memory_gib: f64, free_disk_gib: f64, gpu: GpuInfo }

#[derive(Debug, Clone, Serialize)]
struct GpuInfo { probe: String, available: bool, name: Option<String>, vram_gib: Option<f64>, note: String }

#[derive(Debug, Deserialize)]
struct Manifest { version: u32, models: Vec<Model> }

#[derive(Debug, Deserialize)]
struct Model {
    id: String, name: String, description: String, filename: String, url: String, sha256: String,
    size_bytes: u64, min_memory_gib: f64, min_free_disk_gib: f64, #[serde(default)] min_vram_gib: Option<f64>,
    supported_os: Vec<String>, supported_arch: Vec<String>, runtime_profile: RuntimeProfile, enabled: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum RuntimeProfile { Cpu, NvidiaCuda, Metal, Vulkan }

impl RuntimeProfile {
    fn as_str(&self) -> &'static str { match self { Self::Cpu => "cpu", Self::NvidiaCuda => "nvidia_cuda", Self::Metal => "metal", Self::Vulkan => "vulkan" } }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AppConfig { version: u32, selected_model_id: String }

fn main() -> Result<()> {
    let cli = Cli::parse();
    let base = cli.portable_dir.unwrap_or_else(default_base_dir);
    let manifest_path = resolve_manifest(&base, &cli.manifest);
    let manifest = load_manifest(&manifest_path)?;
    let machine = inspect_machine(&base);
    log_event(&base, "INFO", "launcher started");

    let result = match cli.command.unwrap_or(Commands::Status) {
        Commands::Inspect => { println!("{}", serde_json::to_string_pretty(&machine)?); Ok(()) }
        Commands::List => { list_models(&manifest, &machine, cli.allow_cpu_fallback); Ok(()) }
        Commands::Status => show_status(&manifest, &machine, &base, cli.allow_cpu_fallback),
        Commands::Preflight { id } => preflight(&manifest, &machine, &base, cli.allow_cpu_fallback, id.as_deref()),
        Commands::Setup { model, accept_download, skip_download } => setup(&manifest, &machine, &base, cli.allow_cpu_fallback, model.as_deref(), accept_download, skip_download),
        Commands::Download { id } => download_model(find_safe_model(&manifest, &machine, &id, cli.allow_cpu_fallback)?, &base),
        Commands::CancelDownload { id } => cancel_download(find_model(&manifest, &id)?, &base),
        Commands::Verify { id } => verify_model(find_model(&manifest, &id)?, &base),
        Commands::Launch { id, runtime, args } => {
            let selected = match id { Some(id) => id, None => load_config(&base)?.selected_model_id };
            let model = find_safe_model(&manifest, &machine, &selected, cli.allow_cpu_fallback)?;
            launch_model(model, &base, runtime.as_deref(), &args)
        }
    };
    if let Err(error) = &result { log_event(&base, "ERROR", &format!("{error:#}")); }
    result
}

fn default_base_dir() -> PathBuf { std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_else(|| PathBuf::from(".")) }
fn resolve_manifest(base: &Path, manifest: &Path) -> PathBuf { if manifest.is_absolute() { manifest.to_path_buf() } else { base.join(manifest) } }
fn config_path(base: &Path) -> PathBuf { base.join(CONFIG_FILE) }
fn log_path(base: &Path) -> PathBuf { base.join(LOG_FILE) }
fn partial_path(model: &Model, base: &Path) -> PathBuf { model_path(model, base).with_extension(format!("{}.partial", Path::new(&model.filename).extension().and_then(|v| v.to_str()).unwrap_or("download"))) }
fn lock_path(model: &Model, base: &Path) -> PathBuf { model_path(model, base).with_extension(format!("{}.lock", Path::new(&model.filename).extension().and_then(|v| v.to_str()).unwrap_or("download"))) }

fn unix_timestamp() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|value| value.as_secs()).unwrap_or(0) }
fn log_event(base: &Path, level: &str, message: &str) {
    let path = log_path(base);
    if let Some(parent) = path.parent() { let _ = fs::create_dir_all(parent); }
    let cleaned = message.replace('\n', " ").replace('\r', " ");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) { let _ = writeln!(file, "{} [{}] {}", unix_timestamp(), level, cleaned); }
}

fn load_manifest(path: &Path) -> Result<Manifest> {
    let raw = fs::read_to_string(path).with_context(|| format!("Could not read model manifest: {}", path.display()))?;
    let manifest: Manifest = serde_json::from_str(&raw).context("Model manifest is not valid JSON")?;
    if manifest.version != 1 { bail!("Unsupported model manifest version {}", manifest.version); }
    Ok(manifest)
}

fn load_config(base: &Path) -> Result<AppConfig> {
    let path = config_path(base);
    let raw = fs::read_to_string(&path).with_context(|| format!("No setup configuration found at {}. Run 'ai-pendrive setup' first.", path.display()))?;
    let config: AppConfig = serde_json::from_str(&raw).context("Configuration is not valid JSON")?;
    if config.version != 1 { bail!("Unsupported configuration version {}", config.version); }
    Ok(config)
}

fn save_config(base: &Path, config: &AppConfig) -> Result<()> {
    fs::create_dir_all(base)?;
    let final_path = config_path(base);
    let temporary_path = base.join(format!("{CONFIG_FILE}.partial"));
    let json = serde_json::to_vec_pretty(config)?;
    { let mut file = File::create(&temporary_path)?; file.write_all(&json)?; file.write_all(b"\n")?; file.sync_all()?; }
    fs::rename(temporary_path, final_path)?;
    log_event(base, "INFO", &format!("saved selected model {}", config.selected_model_id));
    Ok(())
}

fn inspect_machine(base: &Path) -> Machine {
    let mut system = System::new_all(); system.refresh_all();
    let disk = fs2::available_space(base).or_else(|_| fs2::available_space(".")).unwrap_or(0);
    Machine { os: std::env::consts::OS.to_string(), arch: std::env::consts::ARCH.to_string(), memory_gib: bytes_to_gib(system.total_memory()), available_memory_gib: bytes_to_gib(system.available_memory()), free_disk_gib: bytes_to_gib(disk), gpu: probe_gpu() }
}

fn probe_gpu() -> GpuInfo {
    let output = Command::new("nvidia-smi").args(["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]).output();
    match output {
        Ok(result) if result.status.success() => {
            let line = String::from_utf8_lossy(&result.stdout).lines().next().unwrap_or_default().trim().to_string();
            let mut fields = line.splitn(2, ',').map(str::trim);
            let name = fields.next().filter(|value| !value.is_empty()).map(ToOwned::to_owned);
            let vram_mib = fields.next().and_then(|value| value.parse::<f64>().ok());
            GpuInfo { probe: "nvidia-smi".into(), available: name.is_some() && vram_mib.is_some(), name, vram_gib: vram_mib.map(|value| value / 1024.0), note: "NVIDIA GPU information obtained from nvidia-smi.".into() }
        }
        Ok(_) => GpuInfo { probe: "nvidia-smi".into(), available: false, name: None, vram_gib: None, note: "nvidia-smi ran but did not return a usable NVIDIA GPU record.".into() },
        Err(_) => GpuInfo { probe: "none".into(), available: false, name: None, vram_gib: None, note: "No supported GPU probe was available. GPU capability is unknown; CPU profiles remain available.".into() },
    }
}

fn bytes_to_gib(bytes: u64) -> f64 { bytes as f64 / 1024.0_f64.powi(3) }
fn print_machine(machine: &Machine) {
    println!("Machine: {} {} | {:.1} GiB RAM ({:.1} GiB available) | {:.1} GiB disk free", machine.os, machine.arch, machine.memory_gib, machine.available_memory_gib, machine.free_disk_gib);
    match (&machine.gpu.name, machine.gpu.vram_gib) { (Some(name), Some(vram)) => println!("GPU: {name} | {vram:.1} GiB VRAM ({})", machine.gpu.probe), _ => println!("GPU: unknown ({})", machine.gpu.note) }
}

fn list_models(manifest: &Manifest, machine: &Machine, allow_cpu_fallback: bool) {
    print_machine(machine); println!();
    for model in &manifest.models { print_model(model, incompatibilities(model, machine, allow_cpu_fallback).as_slice()); }
}

fn print_model(model: &Model, reasons: &[String]) {
    let status = if reasons.is_empty() { "SAFE" } else { "UNAVAILABLE" };
    println!("[{status}] {} ({}) [{}]", model.name, model.id, model.runtime_profile.as_str());
    println!("  {}", model.description);
    println!("  Download: {:.2} GiB | Minimum RAM: {:.1} GiB | Minimum disk: {:.1} GiB", bytes_to_gib(model.size_bytes), model.min_memory_gib, model.min_free_disk_gib);
    if let Some(vram) = model.min_vram_gib { println!("  Minimum NVIDIA VRAM: {vram:.1} GiB"); }
    if !reasons.is_empty() { println!("  Reason: {}", reasons.join("; ")); }
}

fn selected_model<'a>(manifest: &'a Manifest, base: &Path, requested: Option<&str>) -> Result<&'a Model> {
    match requested { Some(id) => find_model(manifest, id), None => find_model(manifest, &load_config(base)?.selected_model_id) }
}

fn preflight(manifest: &Manifest, machine: &Machine, base: &Path, allow_cpu_fallback: bool, requested: Option<&str>) -> Result<()> {
    println!("AI Pendrive preflight");
    print_machine(machine);
    println!("Portable directory: {}", base.display());
    let model = selected_model(manifest, base, requested)?;
    println!("Profile: {} ({})", model.name, model.id);
    let reasons = incompatibilities(model, machine, allow_cpu_fallback);
    if !reasons.is_empty() { bail!("Profile is not eligible: {}", reasons.join("; ")); }
    println!("Compatibility: OK");
    let model_file = model_path(model, base);
    if model_file.exists() { verify_model(model, base)?; println!("Model: verified"); } else { println!("Model: not downloaded ({})", model_file.display()); }
    let runtime = resolve_runtime(&model.runtime_profile, base, None)?;
    println!("Runtime: {}", runtime.display());
    println!("Preflight: OK");
    log_event(base, "INFO", &format!("preflight passed for {}", model.id));
    Ok(())
}

fn show_status(manifest: &Manifest, machine: &Machine, base: &Path, allow_cpu_fallback: bool) -> Result<()> {
    print_machine(machine); println!("Portable directory: {}", base.display()); println!("Log file: {}", log_path(base).display());
    let config = match load_config(base) { Ok(config) => config, Err(_) => { println!("Setup: not configured. Run 'ai-pendrive setup'."); return Ok(()); } };
    let model = match find_model(manifest, &config.selected_model_id) { Ok(model) => model, Err(_) => { println!("Setup: selected model '{}' is not present in the current manifest.", config.selected_model_id); return Ok(()); } };
    println!("Selected model: {} ({})", model.name, model.id);
    let reasons = incompatibilities(model, machine, allow_cpu_fallback);
    if reasons.is_empty() { println!("Compatibility: eligible"); } else { println!("Compatibility: unavailable — {}", reasons.join("; ")); }
    let path = model_path(model, base);
    if !path.exists() { println!("Model file: missing ({})", path.display()); } else { match verify_model(model, base) { Ok(()) => println!("Model file: verified"), Err(error) => println!("Model file: failed verification — {error:#}") } }
    let partial = partial_path(model, base);
    if partial.exists() { println!("Partial download: {} ({:.2} GiB)", partial.display(), bytes_to_gib(fs::metadata(&partial)?.len())); }
    match resolve_runtime(&model.runtime_profile, base, None) { Ok(runtime) => println!("Runtime: {}", runtime.display()), Err(error) => println!("Runtime: unavailable — {error:#}") }
    Ok(())
}

fn setup(manifest: &Manifest, machine: &Machine, base: &Path, allow_cpu_fallback: bool, requested_id: Option<&str>, accept_download: bool, skip_download: bool) -> Result<()> {
    if accept_download && requested_id.is_none() { bail!("--accept-download requires --model <id> so setup remains explicit in non-interactive use"); }
    if accept_download && skip_download { bail!("Choose either --accept-download or --skip-download, not both"); }
    print_machine(machine); println!("Portable directory: {}", base.display());
    let selected = match requested_id { Some(id) => find_safe_model(manifest, machine, id, allow_cpu_fallback)?, None => choose_model_interactively(manifest, machine, allow_cpu_fallback)? };
    println!(); println!("Selected: {} ({})", selected.name, selected.id); println!("Runtime profile: {}", selected.runtime_profile.as_str()); println!("Download size: {:.2} GiB", bytes_to_gib(selected.size_bytes));
    save_config(base, &AppConfig { version: 1, selected_model_id: selected.id.clone() })?;
    if skip_download { println!("Download skipped. Run 'ai-pendrive download {}' after configuring an enabled, verified profile.", selected.id); return Ok(()); }
    let should_download = if requested_id.is_some() { accept_download } else { confirm("Download and verify this model now? [y/N] ")? };
    if !should_download { println!("Download not started. Your selection was saved."); return Ok(()); }
    download_model(selected, base)
}

fn choose_model_interactively<'a>(manifest: &'a Manifest, machine: &Machine, allow_cpu_fallback: bool) -> Result<&'a Model> {
    let eligible: Vec<&Model> = manifest.models.iter().filter(|model| incompatibilities(model, machine, allow_cpu_fallback).is_empty()).collect();
    if eligible.is_empty() { println!("No eligible model profiles are available. Run 'ai-pendrive list' for reasons."); bail!("Setup cannot continue without an enabled compatible model profile") }
    println!("Eligible profiles:");
    for (index, model) in eligible.iter().enumerate() { println!("  {}) {} — {:.2} GiB, {}", index + 1, model.name, bytes_to_gib(model.size_bytes), model.runtime_profile.as_str()); }
    print!("Choose a profile number [1-{}]: ", eligible.len()); io::stdout().flush()?;
    let mut answer = String::new(); io::stdin().read_line(&mut answer)?;
    let index = answer.trim().parse::<usize>().context("Enter a profile number")?;
    eligible.get(index.saturating_sub(1)).copied().context("Profile selection is out of range")
}

fn confirm(prompt: &str) -> Result<bool> { print!("{prompt}"); io::stdout().flush()?; let mut answer = String::new(); io::stdin().read_line(&mut answer)?; Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")) }
fn find_model<'a>(manifest: &'a Manifest, id: &str) -> Result<&'a Model> { manifest.models.iter().find(|model| model.id == id).with_context(|| format!("Unknown model id: {id}")) }
fn find_safe_model<'a>(manifest: &'a Manifest, machine: &Machine, id: &str, allow_cpu_fallback: bool) -> Result<&'a Model> { let model = find_model(manifest, id)?; let reasons = incompatibilities(model, machine, allow_cpu_fallback); if !reasons.is_empty() { bail!("Model '{}' is not safe for this machine: {}", model.name, reasons.join("; ")); } Ok(model) }

fn incompatibilities(model: &Model, machine: &Machine, allow_cpu_fallback: bool) -> Vec<String> {
    let mut reasons = Vec::new();
    if !model.enabled { reasons.push("model is disabled in the manifest".into()); }
    if !model.supported_os.iter().any(|value| value == &machine.os) { reasons.push(format!("OS '{}' is unsupported", machine.os)); }
    if !model.supported_arch.iter().any(|value| value == &machine.arch) { reasons.push(format!("architecture '{}' is unsupported", machine.arch)); }
    if machine.memory_gib < model.min_memory_gib { reasons.push(format!("needs {:.1} GiB RAM", model.min_memory_gib)); }
    if machine.free_disk_gib < model.min_free_disk_gib { reasons.push(format!("needs {:.1} GiB free disk", model.min_free_disk_gib)); }
    if model.runtime_profile == RuntimeProfile::NvidiaCuda && !allow_cpu_fallback {
        match machine.gpu.vram_gib { Some(vram) if model.min_vram_gib.map_or(true, |minimum| vram >= minimum) => {}, Some(vram) => reasons.push(format!("needs {:.1} GiB NVIDIA VRAM; detected {vram:.1} GiB", model.min_vram_gib.unwrap_or(0.0))), None => reasons.push("NVIDIA VRAM could not be verified; use a CPU profile or --allow-cpu-fallback after testing the runtime".into()) }
    }
    if model.runtime_profile == RuntimeProfile::Metal && machine.os != "macos" { reasons.push("Metal profiles require macOS".into()); }
    if model.runtime_profile == RuntimeProfile::Vulkan && machine.os == "macos" { reasons.push("Vulkan profile is not enabled for macOS in this catalog".into()); }
    reasons
}

fn model_path(model: &Model, base: &Path) -> PathBuf { base.join("models").join(&model.filename) }

fn cancel_download(model: &Model, base: &Path) -> Result<()> {
    let partial = partial_path(model, base);
    let lock = lock_path(model, base);
    if model_path(model, base).exists() { bail!("Refusing to cancel '{}': a completed model file exists. Cancellation only removes partial downloads.", model.id); }
    let lock_file = OpenOptions::new().create(true).read(true).write(true).open(&lock)?;
    if lock_file.try_lock_exclusive().is_err() { bail!("Download for '{}' is active in another launcher process.", model.id); }
    if partial.exists() { fs::remove_file(&partial)?; println!("Removed partial download: {}", partial.display()); log_event(base, "INFO", &format!("cancelled partial download for {}", model.id)); } else { println!("No partial download found for '{}'.", model.id); }
    let _ = fs::remove_file(&lock);
    Ok(())
}

fn download_model(model: &Model, base: &Path) -> Result<()> {
    if model.sha256.len() != 64 || model.sha256.chars().all(|value| value == '0') { bail!("Refusing to download '{}': set a real 64-character SHA-256 in models.json first", model.id); }
    let destination = model_path(model, base);
    if destination.exists() { verify_model(model, base)?; println!("Already downloaded and verified: {}", destination.display()); return Ok(()); }
    fs::create_dir_all(destination.parent().expect("model path has a parent"))?;
    let partial = partial_path(model, base);
    let lock = lock_path(model, base);
    let lock_file = OpenOptions::new().create(true).read(true).write(true).open(&lock)?;
    lock_file.try_lock_exclusive().with_context(|| format!("Another launcher is already downloading '{}'.", model.id))?;
    let result = download_with_resume(model, &partial, &destination, base);
    let _ = fs::remove_file(&lock);
    result
}

fn download_with_resume(model: &Model, partial: &Path, destination: &Path, base: &Path) -> Result<()> {
    let existing = fs::metadata(partial).map(|value| value.len()).unwrap_or(0);
    if existing > model.size_bytes { fs::remove_file(partial)?; bail!("Partial download was larger than the declared model size and was removed. Retry the download."); }
    let client = Client::builder().build()?;
    let mut request = client.get(&model.url);
    if existing > 0 { request = request.header(RANGE, format!("bytes={existing}-")); }
    log_event(base, "INFO", &format!("download started for {} at byte {}", model.id, existing));
    let mut response = request.send().with_context(|| format!("Request failed: {}", model.url))?.error_for_status()?;
    let resumed = response.status().as_u16() == 206;
    if existing > 0 && !resumed {
        log_event(base, "WARN", &format!("server did not honor range request for {}; restarting", model.id));
        fs::remove_file(partial)?;
    }
    if existing > 0 && resumed && response.headers().get(ACCEPT_RANGES).is_none() {
        log_event(base, "INFO", &format!("server resumed {} without advertising Accept-Ranges", model.id));
    }
    let starting = if existing > 0 && resumed { existing } else { 0 };
    if let Some(length) = response.headers().get(CONTENT_LENGTH).and_then(|value| value.to_str().ok()).and_then(|value| value.parse::<u64>().ok()) {
        if starting.saturating_add(length) != model.size_bytes { bail!("Server content length does not match the declared model size for '{}'.", model.id); }
    }
    let mut output = OpenOptions::new().create(true).read(true).write(true).open(partial)?;
    if starting == 0 { output.set_len(0)?; output.seek(SeekFrom::Start(0))?; } else { output.seek(SeekFrom::End(0))?; }
    println!("Downloading {}{}…", model.name, if starting > 0 { " (resuming)" } else { "" });
    let mut buffer = [0_u8; 1024 * 1024];
    let mut received = starting;
    loop {
        let read = response.read(&mut buffer)?;
        if read == 0 { break; }
        output.write_all(&buffer[..read])?;
        received += read as u64;
        eprint!("\rDownloaded {:.1}%", received as f64 * 100.0 / model.size_bytes.max(1) as f64);
    }
    eprintln!(); output.sync_all()?;
    if received != model.size_bytes { bail!("Download incomplete: expected {} bytes, received {}. The partial file is retained; run download again to resume.", model.size_bytes, received); }
    let actual = sha256_file(partial)?;
    if !actual.eq_ignore_ascii_case(&model.sha256) { log_event(base, "ERROR", &format!("hash mismatch for {}; keeping partial for investigation", model.id)); bail!("SHA-256 mismatch. Expected {}, received {}. The partial file was retained for inspection; use cancel-download {} to remove it.", model.sha256, actual, model.id); }
    fs::rename(partial, destination)?;
    log_event(base, "INFO", &format!("download verified for {}", model.id));
    println!("Verified and saved: {}", destination.display());
    Ok(())
}

fn verify_model(model: &Model, base: &Path) -> Result<()> {
    let path = model_path(model, base);
    let metadata = fs::metadata(&path).with_context(|| format!("Model is not downloaded: {}", path.display()))?;
    if metadata.len() != model.size_bytes { bail!("Size mismatch: expected {}, received {}", model.size_bytes, metadata.len()); }
    let actual = sha256_file(&path)?;
    if !actual.eq_ignore_ascii_case(&model.sha256) { bail!("SHA-256 mismatch: expected {}, received {}", model.sha256, actual); }
    log_event(base, "INFO", &format!("verified model {}", model.id));
    println!("Verified: {}", path.display());
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?; let mut hasher = Sha256::new(); let mut buffer = [0_u8; 1024 * 1024];
    loop { let read = file.read(&mut buffer)?; if read == 0 { break; } hasher.update(&buffer[..read]); }
    Ok(hex::encode(hasher.finalize()))
}

fn runtime_candidates(profile: &RuntimeProfile, base: &Path) -> Vec<PathBuf> {
    let suffix = if std::env::consts::OS == "windows" { ".exe" } else { "" };
    let names: &[&str] = match profile { RuntimeProfile::Cpu => &["llama-server-cpu", "llama-server", "llamafile"], RuntimeProfile::NvidiaCuda => &["llama-server-cuda", "llama-server"], RuntimeProfile::Metal => &["llama-server-metal", "llama-server"], RuntimeProfile::Vulkan => &["llama-server-vulkan", "llama-server"] };
    names.iter().map(|name| base.join("runtimes").join(format!("{name}{suffix}"))).collect()
}

fn resolve_runtime(profile: &RuntimeProfile, base: &Path, override_runtime: Option<&str>) -> Result<PathBuf> {
    if let Some(runtime) = override_runtime { return Ok(PathBuf::from(runtime)); }
    if let Some(runtime) = std::env::var_os("AI_PENDRIVE_RUNTIME") { return Ok(PathBuf::from(runtime)); }
    runtime_candidates(profile, base).into_iter().find(|candidate| candidate.is_file()).with_context(|| format!("No runtime found for '{}' profile. Put a compatible runtime in {}/runtimes or set AI_PENDRIVE_RUNTIME", profile.as_str(), base.display()))
}

fn launch_model(model: &Model, base: &Path, override_runtime: Option<&str>, args: &[String]) -> Result<()> {
    preflight_for_launch(model, base)?;
    let model_file = model_path(model, base); let runtime = resolve_runtime(&model.runtime_profile, base, override_runtime)?;
    log_event(base, "INFO", &format!("launching {} with {}", model.id, runtime.display()));
    println!("Launching '{}' with {}", model.name, runtime.display());
    let status = Command::new(runtime).arg("-m").arg(model_file).args(args).current_dir(base).stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit()).status().context("Failed to start local runtime")?;
    if !status.success() { bail!("Runtime exited with {status}"); }
    Ok(())
}

fn preflight_for_launch(model: &Model, base: &Path) -> Result<()> { verify_model(model, base)?; resolve_runtime(&model.runtime_profile, base, None).map(|_| ()) }
