//! 真机验证 Connect 的"本机遥控另一台设备"方向（桌面端界面调的是同一组核心 API）。
//!
//! 用法（在 `core/` 下）：
//! ```text
//! cargo run -p lekis-core --example connect_probe -- <对方 IP> [端口=47655] [音乐目录]
//! ```
//!
//! 流程：手动添加设备 → 配对（对方屏幕显示配对码时，把码写进
//! `$TEMP/lekis-connect-code.txt`，程序会等这个文件）→ 读状态 → 暂停 / 播放 /
//! 下一首 / 跳转 / 音量 → 读队列和封面。给了音乐目录时，再把本机扫到的前几首歌
//! 推到对方播放（对方从本机的串流服务器拉流）。每一步打印结果，失败就退出非 0。

use std::sync::Arc;
use std::time::Duration;

use lekis_core::connect::{ConnectStartOptions, Control, PairStart};
use lekis_core::{CoreConfig, LekisCore, PlatformServices};
use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};

type R<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> R<()> {
    let host = std::env::args()
        .nth(1)
        .ok_or("用法: connect_probe <对方 IP> [端口] [音乐目录]")?;
    let port: u16 = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "47655".into())
        .parse()?;
    let music = std::env::args().nth(3);

    // 固定数据目录：配对后的长期密钥留着，第二次运行不用再输配对码。
    let root = std::env::temp_dir().join("lekis-connect-probe");
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
        let my_port = core
            .connect_start(ConnectStartOptions {
                port: Some(0),
                mdns: false,
            })
            .await?;
        println!("本机 Connect 端口 {my_port}");

        let device = core.connect_add_device(host.clone(), port).await?;
        println!("找到设备：{} ({})", device.name, device.device_id);
        let id = device.device_id.clone();

        match core.connect_pair(id.clone()).await? {
            PairStart::AlreadyPaired => println!("已配对，直接认证"),
            PairStart::NeedsCode => {
                let file = std::env::temp_dir().join("lekis-connect-code.txt");
                let _ = std::fs::remove_file(&file);
                println!("请把对方屏幕上的配对码写进 {}", file.display());
                let code = loop {
                    if let Ok(c) = std::fs::read_to_string(&file) {
                        if !c.trim().is_empty() {
                            break c;
                        }
                    }
                    tokio::time::sleep(Duration::from_millis(300)).await;
                };
                core.connect_pair_confirm(id.clone(), code).await?;
                println!("配对成功");
            }
        }

        let show = |label: &str, s: &lekis_core::connect::RemoteState| {
            println!(
                "{label}: {:?} {} {}/{} ms 音量 {:.2} 队列 {:?}/{}",
                s.state,
                s.track.as_ref().map(|t| t.title.as_str()).unwrap_or("-"),
                s.position_ms,
                s.duration_ms,
                s.volume,
                s.queue_index,
                s.queue_len
            );
        };
        let state = core.connect_remote_state(id.clone()).await?;
        show("初始状态", &state);

        if let Some(dir) = music {
            let source = core
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Local,
                    name: "Probe".into(),
                    addresses: vec![dir],
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
                if rows.len() >= 2 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            let ids: Vec<_> = rows.iter().map(|r| r.id).collect();
            println!("推送本机 {} 首到对方", ids.len());
            let report = core.connect_play_on(id.clone(), ids, 0, 0, true).await?;
            println!("对方接收：{report:?}");
            tokio::time::sleep(Duration::from_secs(4)).await;
            show("推送后", &core.connect_remote_state(id.clone()).await?);
        }

        let steps: Vec<(&str, Control)> = vec![
            ("暂停", Control::Pause),
            ("播放", Control::Play),
            ("下一首", Control::Next),
            (
                "跳到 30 s",
                Control::Seek {
                    position_ms: 30_000,
                },
            ),
            ("音量 0.5", Control::Volume { volume: 0.5 }),
            ("音量 1.0", Control::Volume { volume: 1.0 }),
            ("上一首", Control::Previous),
        ];
        for (label, action) in steps {
            core.connect_control(id.clone(), action).await?;
            tokio::time::sleep(Duration::from_millis(1500)).await;
            show(label, &core.connect_remote_state(id.clone()).await?);
        }

        let queue = core.connect_remote_queue(id.clone(), 0, 5).await?;
        println!("队列前 {} 项：", queue.len());
        for t in &queue {
            println!("  {} — {}", t.title, t.artist);
        }
        let current = core.connect_remote_state(id.clone()).await?;
        if let Some(t) = current.track {
            let art = core
                .connect_remote_artwork(id.clone(), t.id, t.uid.clone())
                .await?;
            println!("当前曲封面：{:?} 字节", art.map(|a| a.len()));
        }
        core.connect_control(id.clone(), Control::Pause).await?;
        core.connect_disconnect(id).await?;
        println!("完成");
        Ok::<_, Box<dyn std::error::Error>>(())
    })
}
