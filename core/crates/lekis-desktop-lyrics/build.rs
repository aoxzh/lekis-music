//! Compile the macOS-only AppKit renderer and carry Swift's runtime link information into Cargo.
#![allow(clippy::panic, clippy::expect_used)] // Build failures must stop compilation with a useful diagnostic.

use std::{env, path::PathBuf, process::Command};

fn checked(command: &mut Command, description: &str) -> Vec<u8> {
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("{description}: {error}"));
    assert!(
        output.status.success(),
        "{description}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    for warning in String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter(|line| !line.trim().is_empty())
    {
        println!("cargo:warning={warning}");
    }
    output.stdout
}

fn main() {
    println!("cargo:rerun-if-changed=src/mac/DesktopLyricsPanel.swift");
    for name in ["SWIFTC", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let swift = env::var("SWIFTC").unwrap_or_else(|_| "swiftc".into());
    let architecture = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        other => panic!("unsupported macOS desktop lyrics architecture: {other:?}"),
    };
    let deployment = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "12.0".into());
    let triple = format!("{architecture}-apple-macos{deployment}");
    let sdk = env::var("SDKROOT").unwrap_or_else(|_| {
        String::from_utf8_lossy(&checked(
            Command::new("xcrun").args(["--sdk", "macosx", "--show-sdk-path"]),
            "find macOS SDK (install Xcode or Command Line Tools)",
        ))
        .trim()
        .to_string()
    });
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    let object = out.join("DesktopLyricsPanel.o");
    checked(
        Command::new(&swift)
            .args([
                "-parse-as-library",
                "-emit-object",
                "-O",
                "-target",
                &triple,
                "-sdk",
                &sdk,
                "-module-name",
                "LekisDesktopLyricsNative",
                "src/mac/DesktopLyricsPanel.swift",
                "-o",
            ])
            .arg(&object),
        "compile macOS desktop lyrics AppKit backend",
    );
    let archive = out.join("liblekis_lyrics_macos.a");
    checked(
        Command::new("ar").arg("rcs").arg(&archive).arg(&object),
        "archive macOS desktop lyrics backend",
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=lekis_lyrics_macos");

    // Do not assume Xcode's location. Newer Swift compilers need their static back-deployment
    // libraries even though the system Swift runtime is provided by macOS 12 and later.
    let info: serde_json::Value = serde_json::from_slice(&checked(
        Command::new(&swift).args(["-print-target-info", "-target", &triple]),
        "query Swift runtime paths",
    ))
    .expect("Swift target-info JSON");
    for path in info["paths"]["runtimeLibraryPaths"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p.as_str())
    {
        println!("cargo:rustc-link-search=native={path}");
    }
    for library in info["target"]["compatibilityLibraries"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if library["filter"].as_str() == Some("all") {
            if let Some(name) = library["libraryName"].as_str() {
                println!("cargo:rustc-link-lib=static={name}");
            }
        }
    }
    println!("cargo:rustc-link-lib=dylib=swiftCore");
    // Swift concurrency's system dylib uses an @rpath install name. Cargo's standalone tests
    // and examples do not inherit an Xcode Runner's Swift runtime runpath.
    let system_runpath = "-rpath,/usr/lib/swift";
    if !env::var("CARGO_ENCODED_RUSTFLAGS")
        .unwrap_or_default()
        .contains(system_runpath)
    {
        println!("cargo:rustc-link-arg=-Wl,{system_runpath}");
    }
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=Foundation");
}
