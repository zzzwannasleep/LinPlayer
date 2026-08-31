// 链接方式照抄 crates/mpv/build.rs:Windows 上用仓库自带的导入库 mpv.lib,
// 运行时找同目录的 libmpv-2.dll,并把它拷进 target/<profile>/ 让产物能直接跑。
use std::path::Path;

fn main() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    // docs/go-migration/spikes/s1-2/lpcore-stub -> 上溯 5 层到仓库根
    let repo = Path::new(manifest).ancestors().nth(5).expect("上溯到仓库根失败");
    let libdir = repo.join("crates").join("mpv").join("libmpv");

    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default() != "windows" {
        // Linux(S1.4)走运行时 dlopen,这里什么都不发。理由同 crates/mpv/build.rs
        return;
    }

    println!("cargo:rustc-link-search=native={}", libdir.display());
    println!("cargo:rustc-link-lib=dylib=mpv");

    if let Ok(out) = std::env::var("OUT_DIR") {
        if let Some(profile_dir) = Path::new(&out).ancestors().nth(3) {
            let _ = std::fs::copy(libdir.join("libmpv-2.dll"), profile_dir.join("libmpv-2.dll"));
        }
    }
}
