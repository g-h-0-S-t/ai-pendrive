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
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Inspect,
    List,
    Download { id: String },
    Verify { id: String },
    Launch { id: String, #[arg(last = true)] args: Vec<String> },
}

#[derive(Debug, Clone, Serialize)]
struct Machine {
    os: String,
    arch: String,
    memory_gib: f64,
    available_memory_gib: f64,
    free_disk_gib: f64,
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
    supported_os: Vec<String>,
    supported_arch: Vec<String>,
    enabled: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let base = cli.portable_dir.unwrap_or_else(default_base_dir);
    let manifest_path = resolve_manifest(&base, &cli.manifest);
    let manifest = load_manifest(&manifest_path)?;
    let machine = inspect_machine(&base)?;

    match cli.command.unwrap_or(Commands::List) {
        Commands::Inspect => println!("{}", serde_json::to_string_pretty(&machine)?),
        Commands::List => list_models(&manifest, &machine),
        Commands::Download { id } => download_model(find_safe_model(&manifest, &machine, &id)?, &base),
        Commands::Verify { id } => verify_model(find_model(&manifest, &id)?, &base),
        Commands::Launch { id, args } => launch_model(find_safe_model(&manifest, &machine, &id)?, &base, &args),
    }
}

fn default_base_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
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

fn inspect_machine(base: &Path) -> Result<Machine> {
    let mut system = System::new_all();
    system.refresh_all();
    let disk = fs2::available_space(base).or_else(|_| fs2::available_space("."))?;
    Ok(Machine {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        memory_gib: bytes_to_gib(system.total_memory()),
        available_memory_gib: bytes_to_gib(system.available_memory()),
        free_disk_gib: bytes_to_gib(disk),
    })
}

fn bytes_to_gib(bytes: u64) -> f64 { bytes as f64 / 1024.0_f64.powi(3) }

fn list_models(manifest: &Manifest, machine: &Machine) {
    println!("Machine: {} {} | {:.1} GiB RAM ({:.1} GiB available) | {:.1} GiB disk free", machine.os, machine.arch, machine.memory_gib, machine.available_memory_gib, machine.free_disk_gib);
    println!();
    for model in &manifest.models {
        let reasons = incompatibilities(model, machine);
        let status = if reasons.is_empty() { "SAFE" } else { "UNAVAILABLE" };
        println!("[{status}] {} ({})", model.name, model.id);
        println!("  {}", model.description);
        println!("  Download: {:.2} GiB", bytes_to_gib(model.size_bytes));
        if !reasons.is_empty() { println!("  Reason: {}", reasons.join("; ")); }
    }
}

fn find_model<'a>(manifest: &'a Manifest, id: &str) -> Result<&'a Model> {
    manifest.models.iter().find(|m| m.id == id).with_context(|| format!("Unknown model id: {id}"))
}

fn find_safe_model<'a>(manifest: &'a Manifest, machine: &Machine, id: &str) -> Result<&'a Model> {
    let model = find_model(manifest, id)?;
    let reasons = incompatibilities(model, machine);
    if !reasons.is_empty() { bail!("Model '{}' is not safe for this machine: {}", model.name, reasons.join("; ")); }
    Ok(model)
}

fn incompatibilities(model: &Model, machine: &Machine) -> Vec<String> {
    let mut reasons = Vec::new();
    if !model.enabled { reasons.push("model is disabled in the manifest".into()); }
    if !model.supported_os.iter().any(|v| v == &machine.os) { reasons.push(format!("OS '{}' is unsupported", machine.os)); }
    if !model.supported_arch.iter().any(|v| v == &machine.arch) { reasons.push(format!("architecture '{}' is unsupported", machine.arch)); }
    if machine.memory_gib < model.min_memory_gib { reasons.push(format!("needs {:.1} GiB RAM", model.min_memory_gib)); }
    if machine.free_disk_gib < model.min_free_disk_gib { reasons.push(format!("needs {:.1} GiB free disk", model.min_free_disk_gib)); }
    reasons
}

fn model_path(model: &Model, base: &Path) -> PathBuf { base.join("models").join(&model.filename) }

fn download_model(model: &Model, base: &Path) -> Result<()> {
    if model.sha256.len() != 64 || model.sha256.chars().all(|c| c == '0') {
        bail!("Refusing to download '{}': set a real 64-character SHA-256 in models.json first", model.id);
    }
    let destination = model_path(model, base);
    if destination.exists() {
        verify_model(model, base)?;
        println!("Already downloaded and verified: {}", destination.display());
        return Ok(());
    }
    fs::create_dir_all(destination.parent().expect("model path has a parent"))?;
    let partial = destination.with_extension(format!("{}.partial", destination.extension().and_then(|v| v.to_str()).unwrap_or("download")));
    println!("Downloading {}…", model.name);
    let mut response = reqwest::blocking::get(&model.url).with_context(|| format!("Request failed: {}", model.url))?.error_for_status()?;
    let mut output = File::create(&partial)?;
    let mut hasher = Sha256::new();
    let mut buf = [0_u8; 1024 * 1024];
    let mut received = 0_u64;
    loop {
        let read = response.read(&mut buf)?;
        if read == 0 { break; }
        output.write_all(&buf[..read])?;
        hasher.update(&buf[..read]);
        received += read as u64;
        eprint!("\rDownloaded {:.1}%", received as f64 * 100.0 / model.size_bytes.max(1) as f64);
    }
    eprintln!();
    output.sync_all()?;
    if received != model.size_bytes {
        let _ = fs::remove_file(&partial);
        bail!("Downloaded size mismatch: expected {}, received {}", model.size_bytes, received);
    }
    let actual = hex::encode(hasher.finalize());
    if !actual.eq_ignore_ascii_case(&model.sha256) {
        let _ = fs::remove_file(&partial);
        bail!("SHA-256 mismatch. Expected {}, received {}", model.sha256, actual);
    }
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
    let mut buf = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buf)?;
        if read == 0 { break; }
        hasher.update(&buf[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn launch_model(model: &Model, base: &Path, args: &[String]) -> Result<()> {
    verify_model(model, base)?;
    let model_file = model_path(model, base);
    let runtime = std::env::var_os("AI_PENDRIVE_RUNTIME").context("Set AI_PENDRIVE_RUNTIME to the local runtime executable before launch")?;
    println!("Launching '{}' with {}", model.name, runtime.to_string_lossy());
    let status = Command::new(runtime)
        .arg("-m")
        .arg(model_file)
        .args(args)
        .current_dir(base)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .context("Failed to start local runtime")?;
    if !status.success() { bail!("Runtime exited with {status}"); }
    Ok(())
}
