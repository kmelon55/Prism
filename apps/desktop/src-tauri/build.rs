fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        build_dictation();
    }
    tauri_build::build()
}

fn build_dictation() {
    use std::{path::PathBuf, process::Command};
    let source = PathBuf::from("native/dictation");
    println!("cargo:rerun-if-changed={}", source.display());
    let output = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => panic!("Unsupported macOS architecture: {other}"),
    };
    let mut sources: Vec<_> = std::fs::read_dir(&source)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "swift")
        })
        .collect();
    sources.sort();
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-emit-library",
            "-static",
            "-parse-as-library",
            "-O",
            "-module-name",
            "PrismDictation",
            "-target",
        ])
        .arg(format!("{arch}-apple-macosx14.0"))
        .args(&sources)
        .arg("-o")
        .arg(output.join("libPrismDictation.a"))
        .status()
        .expect("Install Apple Command Line Tools to compile native dictation");
    assert!(status.success(), "Could not compile Prism native dictation");
    let swift = Command::new("xcrun")
        .args(["--find", "swiftc"])
        .output()
        .unwrap();
    let compiler = PathBuf::from(String::from_utf8(swift.stdout).unwrap().trim());
    let runtime = compiler
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("lib/swift/macosx");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-search=native={}", runtime.display());
    println!("cargo:rustc-link-search=native=/usr/lib/swift");
    println!("cargo:rustc-link-lib=static=PrismDictation");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    for framework in [
        "AVFoundation",
        "AudioToolbox",
        "AppKit",
        "SwiftUI",
        "ApplicationServices",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
