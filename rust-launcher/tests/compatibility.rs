use std::process::Command;

fn launcher() -> Command {
    Command::new(env!("CARGO_BIN_EXE_ai-pendrive-launcher"))
}

#[test]
fn inspect_returns_machine_json() {
    let output = launcher().arg("--manifest").arg("models.json").arg("inspect").output().expect("launcher should run");
    assert!(output.status.success());
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).expect("inspect should emit JSON");
    assert!(json["os"].is_string());
    assert!(json["arch"].is_string());
    assert!(json["memory_gib"].is_number());
    assert!(json["free_disk_gib"].is_number());
    assert!(json["gpu"].is_object());
}

#[test]
fn unknown_model_fails_without_downloading() {
    let output = launcher().arg("--manifest").arg("models.json").args(["download", "does-not-exist"]).output().expect("launcher should run");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Unknown model id"));
}

#[test]
fn disabled_template_cannot_be_downloaded() {
    let output = launcher().arg("--manifest").arg("models.json").args(["download", "example-light-cpu"]).output().expect("launcher should run");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("disabled"));
}
