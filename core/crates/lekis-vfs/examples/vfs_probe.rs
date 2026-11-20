//! 手动连通性探针：列出一个 SMB / WebDAV 源的目录并读第一个音频文件的文件头。
//!
//! ```text
//! cargo run -p lekis-vfs --example vfs_probe -- smb://192.168.1.10/Share/Music
//! ```
//!
//! 密码只从环境变量 `LEKIS_PROBE_PASSWORD` 读取（不放命令行、不打印）；不设置时按访客 / 匿名连接。
//! 用户名写在 URL 里（`smb://user@host/share`）。

use lekis_types::{SourceConfig, SourceKind};
use lekis_vfs::{is_audio_file, EntryKind, VfsPath};
use std::collections::BTreeMap;

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let Some(url) = std::env::args().nth(1) else {
        eprintln!("用法: vfs_probe <smb://… | http(s)://…>");
        std::process::exit(2);
    };
    let kind = if url.starts_with("smb://") {
        SourceKind::Smb
    } else {
        SourceKind::WebDav
    };
    let password = std::env::var("LEKIS_PROBE_PASSWORD").ok();
    let config = SourceConfig {
        addresses: vec![url.clone()],
        kind,
        ..probe_config()
    };
    let vfs = match lekis_vfs::open(&config, password) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("open 失败: {e}");
            std::process::exit(1);
        }
    };
    let started = std::time::Instant::now();
    let root = VfsPath::root();
    let entries = match vfs.list_dir(&root).await {
        Ok(e) => e,
        Err(e) => {
            eprintln!("list_dir 失败 ({:?}): {e}", e.code);
            std::process::exit(1);
        }
    };
    println!("根目录 {} 项（{:?}）", entries.len(), started.elapsed());
    for e in entries.iter().take(10) {
        println!("  {:?} {} {}B", e.meta.kind, e.path.as_str(), e.meta.size);
    }
    // 广度优先找第一个音频文件（最多翻 50 个目录）。
    let mut queue: Vec<VfsPath> = vec![root];
    let mut visited = 0;
    while let Some(dir) = queue.pop() {
        visited += 1;
        if visited > 50 {
            break;
        }
        let Ok(list) = vfs.list_dir(&dir).await else {
            continue;
        };
        for e in list {
            match e.meta.kind {
                EntryKind::File if is_audio_file(&e.path) => {
                    let head = vfs.read_range(&e.path, 0..16).await;
                    match head {
                        Ok(b) => println!(
                            "音频文件 {} ({}B) 头 16 字节: {:02x?}",
                            e.path.as_str(),
                            e.meta.size,
                            &b[..]
                        ),
                        Err(err) => println!("读取 {} 失败: {err}", e.path.as_str()),
                    }
                    return;
                }
                EntryKind::Dir => queue.insert(0, e.path),
                _ => {}
            }
        }
    }
    println!("没找到音频文件（翻了 {visited} 个目录）");
}

fn probe_config() -> SourceConfig {
    SourceConfig {
        id: None,
        name: "probe".into(),
        kind: SourceKind::Smb,
        addresses: vec![],
        root_path: String::new(),
        credential_ref: None,
        options: BTreeMap::new(),
        enabled: true,
    }
}
