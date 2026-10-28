fn main() {
    #[cfg(target_os = "macos")]
    swift_link_search();
    tauri_build::build()
}

/// screencapturekit's Swift bridge needs the Swift compatibility libraries.
/// Its build script only looks inside a full Xcode install; with just the
/// Command Line Tools they live under `usr/lib/swift/macosx` instead.
#[cfg(target_os = "macos")]
fn swift_link_search() {
    let Ok(out) = std::process::Command::new("xcode-select").arg("-p").output() else {
        return;
    };
    let dev = String::from_utf8_lossy(&out.stdout).trim().to_string();
    for sub in ["usr/lib/swift/macosx", "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"] {
        let p = std::path::Path::new(&dev).join(sub);
        if p.exists() {
            println!("cargo:rustc-link-search=native={}", p.display());
        }
    }
}
