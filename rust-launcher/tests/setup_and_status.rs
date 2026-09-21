use std::{fs, process::Command};

fn launcher() -> Command {
    Command::new(env!("CARGO_BIN_EXE_ai-pendrive-launcher"))
}

fn temp_dir(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("ai-pendrive-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("create temporary directory");
    path
}

#[test]
fn status_succeeds_when_setup_has_not_run() {
    let dir = temp_dir("status-empty");
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("models.json");
    let output = launcher().arg("--portable-dir").arg(&dir).arg("--manifest").arg(&manifest).arg("status").output().expect("launcher should run");
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("Setup: not configured"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn setup_requires_explicit_noninteractive_download_acceptance() {
    let dir = temp_dir("setup-safe");
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("models.json");
    let output = launcher().arg("--portable-dir").arg(&dir).arg("--manifest").arg(&manifest).args(["setup", "--model", "example-light-cpu"]).output().expect("launcher should run");
    assert!(!output.status.success());
    assert!(!dir.join("models").exists());
    let _ = fs::remove_dir_all(dir);
}
