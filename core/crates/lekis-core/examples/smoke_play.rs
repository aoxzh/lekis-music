//! 冒烟测试：把真实音频文件扫描入库，然后真的播一下，看播放进度是否推进。
//!
//! 用法（在 `core/` 下）：
//! ```text
//! cargo run -p lekis-core --example smoke_play -- <音乐目录> [播几秒=6]
//! ```
//!
//! 退出码 0 表示"扫到了文件 + 播放进度在推进（等于解码器和音频输出都真的在工作）"。

use std::sync::Arc;
use std::time::Duration;

use lekis_core::{CoreConfig, LekisCore, PlatformServices};
use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let music = std::env::args()
        .nth(1)
        .ok_or("用法: smoke_play <音乐目录> [播几秒]")?;
    let seconds: u64 = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "6".into())
        .parse()?;

    let root = std::env::temp_dir().join(format!("lekis-smoke-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root)?;

    let core = Arc::new(LekisCore::new(
        CoreConfig::for_tests(&root),
        PlatformServices::in_memory(),
    )?);

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;

    rt.block_on(async {
        let source = core
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Smoke".into(),
                addresses: vec![music.clone()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await?;
        core.start_scan(source).await?;

        let mut rows = Vec::new();
        for _ in 0..600 {
            rows = core
                .list_tracks(TrackQuery {
                    sort: TrackSort::Title,
                    offset: 0,
                    limit: 5,
                })
                .await?;
            if !rows.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if rows.is_empty() {
            return Err::<(), Box<dyn std::error::Error>>("扫描没扫到任何曲目".into());
        }
        println!("扫到 {} 首（取前 5）：", rows.len());
        for r in &rows {
            println!(
                "  id={} title={:?} artist={:?} duration={}s",
                r.id,
                r.title,
                r.artist_line,
                r.duration_ms / 1000
            );
        }

        let devices = core.list_output_devices()?;
        println!("输出设备 {} 个：", devices.len());
        for d in &devices {
            println!(
                "  id={} name={:?} default={} exclusive={}",
                d.id, d.name, d.is_default, d.supports_exclusive
            );
        }

        let ids: Vec<_> = rows.iter().map(|r| r.id).collect();
        core.set_volume(0.0)?; // 冒烟测试不出声
        core.play_tracks(ids.clone(), 0)?;

        let mut last = 0u64;
        for i in 0..(seconds * 10) {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let snap = core.playback_snapshot();
            if i % 10 == 0 || snap.position_ms != last {
                println!(
                    "  t={:>4}ms state={:?} track={:?} pos={}ms dur={}ms",
                    (i + 1) * 100,
                    snap.state,
                    snap.track_id,
                    snap.position_ms,
                    snap.duration_ms
                );
            }
            if snap.position_ms != last {
                last = snap.position_ms;
            }
        }

        if last == 0 {
            return Err::<(), Box<dyn std::error::Error>>(
                "播放进度一直是 0 —— 解码或音频输出没工作".into(),
            );
        }
        println!("播放成功：{}ms 内进度推进到 {}ms", seconds * 1000, last);
        core.pause()?;
        Ok::<(), Box<dyn std::error::Error>>(())
    })?;

    drop(core);
    let _ = std::fs::remove_dir_all(&root);
    println!("OK");
    Ok(())
}
