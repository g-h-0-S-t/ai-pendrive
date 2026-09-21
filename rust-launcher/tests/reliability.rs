use std::{fs, process::Command};

fn launcher() -> Command { Command::new(env!("CARGO_BIN_EXE_ai-pendrive-launcher")) }

fn temp_dir(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("ai-pendrive-reliability-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("create temporary directory");
    path
}

fn manifest_path() -> std::path::PathBuf { std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("models.json") }

#[test]
fn preflight_without_setup_fails_safely() {
    let dir = temp_dir("preflight");
    let output = launcher().arg("--portable-dir").arg(&dir).arg("--manifest").arg(manifest_path()).arg("preflight").output().expect("launcher should run");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Run 'ai-pendrive setup' first"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn cancellation_removes_only_partial_download() {
    let dir = temp_dir("cancel");
    let partial_dir = dir.join("models");
    fs::create_dir_all(&partial_dir).expect("create models directory");
    let partial = partial_dir.join("example-light.gguf.partial");
    fs::write(&partial, b"partial").expect("write partial file");
    let output = launcher().arg("--portable-dir").arg(&dir).arg("--manifest").arg(manifest_path()).args(["cancel-download", "example-light-cpu"]).output().expect("launcher should run");
    assert!(output.status.success());
    assert!(!partial.exists());
    assert!(!partial_dir.join("example-light.gguf").exists());
    let _ = fs::remove_dir_all(dir);
}
