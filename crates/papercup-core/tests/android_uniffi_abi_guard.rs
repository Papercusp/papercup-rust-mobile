// SPDX-License-Identifier: GPL-3.0-or-later
//! Regression coverage for the Android ABI and owned automatic verification guards.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn fixture() -> (PathBuf, PathBuf, Vec<PathBuf>) {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "papercup-android-abi-guard-{}-{nonce}",
        std::process::id()
    ));
    let bin = root.join("bin");
    fs::create_dir_all(&bin).expect("create fixture bin");

    let kotlin = root.join("papercup.kt");
    fs::write(
        &kotlin,
        r#"
interface UniffiLib {
    fun uniffi_papercup_checksum_func_version(): Short
    fun uniffi_papercup_checksum_method_synccache_get(): Short
}
"#,
    )
    .expect("write Kotlin fixture");

    let readelf = bin.join("readelf");
    fs::write(
        &readelf,
        r#"#!/usr/bin/env bash
set -euo pipefail
file="${!#}"
printf '%s\n' '1: 0 0 FUNC GLOBAL DEFAULT 1 uniffi_papercup_checksum_func_version'
if [[ "$file" != *missing-symbol* ]]; then
  printf '%s\n' '2: 0 0 FUNC GLOBAL DEFAULT 1 uniffi_papercup_checksum_method_synccache_get'
fi
"#,
    )
    .expect("write fake readelf");
    fs::set_permissions(&readelf, fs::Permissions::from_mode(0o755))
        .expect("make fake readelf executable");

    let libraries = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
        .into_iter()
        .map(|abi| {
            let path = root.join(format!("{abi}-libpapercup.so"));
            fs::write(&path, b"ELF fixture").expect("write library fixture");
            path
        })
        .collect();

    (root, kotlin, libraries)
}

fn run_guard(root: &Path, kotlin: &Path, libraries: &[PathBuf]) -> std::process::Output {
    let guard = repo_root().join("tools/build-scripts/verify-android-uniffi-abi.sh");
    let mut command = Command::new("bash");
    command.arg(guard).arg(kotlin).args(libraries);
    command.env("READELF", root.join("bin/readelf"));
    command.output().expect("run ABI guard")
}

#[test]
fn accepts_all_four_libraries_when_the_checksum_contract_matches() {
    let (root, kotlin, libraries) = fixture();
    let output = run_guard(&root, &kotlin, &libraries);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "stdout={stdout}\nstderr={stderr}");
    assert!(stdout.contains("Verified 2 UniFFI checksum symbols across 4 Android ABI libraries"));
    fs::remove_dir_all(root).expect("clean fixture");
}

fn write_external_checksum_declarations(kotlin: &Path) {
    // UniFFI 0.32 uses JNA direct mapping and multiline external methods.
    fs::write(
        kotlin,
        r#"
internal object IntegrityCheckingUniffiLib {
    external fun uniffi_papercup_checksum_func_version(
    ): Int
    external fun uniffi_papercup_checksum_method_synccache_get(
    ): Int
}
"#,
    )
    .expect("write external Kotlin declarations");
}

#[test]
fn accepts_external_checksum_declarations() {
    let (root, kotlin, libraries) = fixture();
    write_external_checksum_declarations(&kotlin);
    let output = run_guard(&root, &kotlin, &libraries);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout)
        .contains("Verified 2 UniFFI checksum symbols across 4 Android ABI libraries"));
    fs::remove_dir_all(root).expect("clean fixture");
}

#[test]
fn rejects_missing_exports_for_external_checksum_declarations() {
    let (root, kotlin, mut libraries) = fixture();
    write_external_checksum_declarations(&kotlin);
    let missing = root.join("x86_64-missing-symbol-libpapercup.so");
    fs::write(&missing, b"ELF fixture").expect("write missing-symbol fixture");
    libraries[3] = missing;
    let output = run_guard(&root, &kotlin, &libraries);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "missing export unexpectedly accepted"
    );
    assert!(
        stderr.contains("x86_64-missing-symbol-libpapercup.so"),
        "{stderr}"
    );
    assert!(
        stderr.contains("uniffi_papercup_checksum_method_synccache_get"),
        "{stderr}"
    );
    fs::remove_dir_all(root).expect("clean fixture");
}

#[test]
fn rejects_a_library_missing_a_generated_checksum_symbol() {
    let (root, kotlin, mut libraries) = fixture();
    let missing = root.join("x86_64-missing-symbol-libpapercup.so");
    fs::write(&missing, b"ELF fixture").expect("write missing-symbol fixture");
    libraries[3] = missing;

    let output = run_guard(&root, &kotlin, &libraries);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "guard unexpectedly passed");
    assert!(stderr.contains("x86_64-missing-symbol-libpapercup.so"));
    assert!(stderr.contains("uniffi_papercup_checksum_method_synccache_get"));
    fs::remove_dir_all(root).expect("clean fixture");
}

#[test]
fn rejects_a_missing_abi_library() {
    let (root, kotlin, mut libraries) = fixture();
    libraries[2] = root.join("x86-absent-libpapercup.so");

    let output = run_guard(&root, &kotlin, &libraries);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "guard unexpectedly passed");
    assert!(stderr.contains("Android ABI library missing or empty"));
    assert!(stderr.contains("x86-absent-libpapercup.so"));
    fs::remove_dir_all(root).expect("clean fixture");
}

// These tests expose the maintained shell guards to the existing Cargo
// acceptance-check engine. They inspect the real owned workflow/runner and
// require both working positive controls and rejected mutated inputs.
#[test]
fn android_ci_reachability_rejects_omitted_checks_and_failed_proof_caching() {
    let repo = repo_root();
    let guard = repo.join("tools/tests/android-ci-contract-test.sh");
    let source =
        fs::read_to_string(repo.join(".github/workflows/ci.yml")).expect("owned CI exists");
    let (root, _, _) = fixture();
    let baseline = Command::new("bash")
        .arg(&guard)
        .output()
        .expect("run current CI guard");
    assert!(
        baseline.status.success(),
        "{}",
        String::from_utf8_lossy(&baseline.stderr)
    );
    assert!(String::from_utf8_lossy(&baseline.stdout)
        .contains("Android CI reachability contract: passed"));
    for (name, original, replacement) in [
        ("manual-only", "  schedule:", "  disabled_schedule:"),
        (
            "missing-host-gate",
            "make check-android-host",
            "make disabled-host-gate",
        ),
        (
            "missing-native-gate",
            "bash tools/run-android-checks.sh connected",
            "bash disabled-native-gate",
        ),
        ("stale-source-cache", "'crates/**'", "'unrelated/**'"),
        ("failed-proof-cache", "if: success() &&", "if: always() &&"),
    ] {
        let mutated = source.replace(original, replacement);
        assert_ne!(mutated, source, "mutation must exercise {name}");
        let yaml = root.join(format!("{name}.yml"));
        fs::write(&yaml, mutated).expect("write CI mutation fixture");
        let result = Command::new("bash")
            .arg(&guard)
            .arg(yaml)
            .output()
            .expect("run mutation guard");
        assert!(!result.status.success(), "CI guard accepted {name}");
    }
    fs::remove_dir_all(root).expect("clean CI fixtures");
}

#[test]
fn android_ci_results_require_executed_host_and_native_tests() {
    let repo = repo_root();
    let runner = repo.join("tools/run-android-checks.sh");
    let (root, _, _) = fixture();
    let directories = [
        "test-results/testDebugUnitTest",
        "test-results/testReleaseUnitTest",
        "outputs/androidTest-results/connected/debug/device",
    ];
    let good = "<testsuite tests=\"1\"><testcase name=\"executed\"/></testsuite>";
    for directory in directories {
        fs::create_dir_all(root.join(directory)).expect("create result fixture");
        fs::write(root.join(directory).join("TEST-check.xml"), good).expect("write passing result");
    }
    let verify = |mode| {
        Command::new("bash")
            .arg(&runner)
            .arg("verify-results")
            .arg(&root)
            .arg(mode)
            .output()
            .expect("run result guard")
    };
    assert!(
        verify("host").status.success(),
        "valid host results must pass"
    );
    assert!(
        verify("connected").status.success(),
        "valid native results must pass"
    );
    let release = root.join(directories[1]).join("TEST-check.xml");
    for bad in [
        "<testsuite tests=\"0\"/>",
        "<testsuite tests=\"1\"><testcase><skipped/></testcase></testsuite>",
        "<testsuite tests=\"1\"><testcase><failure/></testcase></testsuite>",
        "invalid XML",
    ] {
        fs::write(&release, bad).expect("write rejected result");
        assert!(
            !verify("host").status.success(),
            "unexecuted/failed result accepted: {bad}"
        );
    }
    fs::remove_file(root.join(directories[2]).join("TEST-check.xml"))
        .expect("remove native result");
    assert!(
        !verify("connected").status.success(),
        "missing native result accepted"
    );
    fs::remove_dir_all(root).expect("clean result fixtures");
}
