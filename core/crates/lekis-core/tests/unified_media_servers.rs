//! 端到端集成测试：OpenSubsonic（SRC-04）+ Jellyfin（SRC-05）+ 统一资料库（SRC-13）
//! + 网络感知选源（SRC-14）。
//!
//! 启动两个真实本地 HTTP 模拟服务器，走完整的 `LekisCore::add_source` → `start_scan`
//! → 统一归并 / 手动合并 / 手动拆分 → Home / Away 选源切换链路。

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use axum::{routing::get, Json, Router};
use lekis_core::{
    CoreConfig, CredentialStore, EventListener, LekisCore, MemoryCredentialStore, NetworkContext,
    PlatformServices,
};
use lekis_types::{CoreEvent, SourceConfig, SourceKind, TrackQuery, TrackSort};
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

struct ChanListener(mpsc::UnboundedSender<CoreEvent>);
impl EventListener for ChanListener {
    fn on_event(&self, event: CoreEvent) {
        let _ = self.0.send(event);
    }
}

async fn spawn_opensubsonic() -> String {
    let app = Router::new()
        .route(
            "/rest/ping.view",
            get(|| async {
                Json(json!({
                    "subsonic-response": { "status": "ok", "version": "1.16.1" }
                }))
            }),
        )
        .route(
            "/rest/search3.view",
            get(|| async {
                Json(json!({
                    "subsonic-response": {
                        "status": "ok",
                        "version": "1.16.1",
                        "searchResult3": {
                            "song": [
                                {
                                    "id": "sub-1",
                                    "title": "晴天",
                                    "album": "叶惠美",
                                    "artist": "周杰伦",
                                    "artists": [{ "id": "ar-1", "name": "周杰伦" }],
                                    "duration": 269,
                                    "musicBrainzId": "mbid-qingtian-0001"
                                },
                                {
                                    "id": "sub-2",
                                    "title": "以父之名",
                                    "album": "叶惠美",
                                    "artist": "周杰伦",
                                    "artists": [{ "id": "ar-1", "name": "周杰伦" }],
                                    "duration": 342
                                }
                            ]
                        }
                    }
                }))
            }),
        );

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

async fn spawn_jellyfin() -> String {
    let app = Router::new()
        .route(
            "/System/Info",
            get(|| async {
                Json(json!({
                    "Id": "jf-srv-1",
                    "ServerName": "Test Jellyfin",
                    "Version": "10.9.0"
                }))
            }),
        )
        .route(
            "/Users/Me",
            get(|| async { Json(json!({ "Id": "user-1" })) }),
        )
        .route(
            "/Items",
            get(|| async {
                Json(json!({
                    "Items": [
                        {
                            "Name": "晴天",
                            "ServerId": "jf-srv-1",
                            "Id": "jf-item-1",
                            "RunTimeTicks": 2690000000_i64,
                            "Album": "叶惠美",
                            "Artists": ["周杰伦"],
                            "AlbumArtists": [{ "Name": "周杰伦", "Id": "ar-1" }],
                            "ProviderIds": { "MusicBrainzTrack": "mbid-qingtian-0001" },
                            "Type": "Audio"
                        },
                        {
                            "Name": "以父之名",
                            "ServerId": "jf-srv-1",
                            "Id": "jf-item-2",
                            "RunTimeTicks": 3430000000_i64,
                            "Album": "叶惠美",
                            "Artists": ["周杰伦"],
                            "AlbumArtists": [{ "Name": "周杰伦", "Id": "ar-1" }],
                            "Type": "Audio"
                        }
                    ],
                    "TotalRecordCount": 2
                }))
            }),
        );

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

async fn wait_scan_done(
    core: &LekisCore,
    rx: &mut mpsc::UnboundedReceiver<CoreEvent>,
    source_id: lekis_types::SourceId,
) {
    core.start_scan(source_id).await.unwrap();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        let ev = tokio::time::timeout(left, rx.recv())
            .await
            .expect("scan timed out")
            .unwrap();
        match ev {
            CoreEvent::ScanFinished { source_id: s, .. } if s == source_id => break,
            CoreEvent::ScanFailed {
                source_id: s,
                detail,
                ..
            } if s == source_id => panic!("scan failed: {detail}"),
            _ => {}
        }
    }
}

#[tokio::test]
async fn opensubsonic_and_jellyfin_unify_merge_split_and_respect_network_context() {
    let sub_url = spawn_opensubsonic().await;
    let jf_url = spawn_jellyfin().await;

    let tmp = std::env::temp_dir().join(format!("lekis-unified-{}", lekis_types::now_ms()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();

    let creds = Arc::new(MemoryCredentialStore::default());
    let core = LekisCore::with_runtime(
        CoreConfig::for_tests(&tmp),
        PlatformServices {
            credentials: creds.clone(),
        },
        tokio::runtime::Handle::current(),
    )
    .unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    core.add_listener(Arc::new(ChanListener(tx)));

    // 1. 注册 OpenSubsonic 音源并扫描。
    creds.set("sub-cred", "secret").unwrap();
    let mut sub_opts = BTreeMap::new();
    sub_opts.insert("username".into(), "alice".into());
    let sub_id = core
        .add_source(SourceConfig {
            id: None,
            kind: SourceKind::OpenSubsonic,
            name: "Navidrome".into(),
            addresses: vec![sub_url],
            root_path: String::new(),
            credential_ref: Some("sub-cred".into()),
            options: sub_opts,
            enabled: true,
        })
        .await
        .unwrap();
    wait_scan_done(&core, &mut rx, sub_id).await;

    // 2. 注册 Jellyfin 音源并扫描。
    creds.set("jf-cred", "jf-api-token").unwrap();
    let jf_id = core
        .add_source(SourceConfig {
            id: None,
            kind: SourceKind::Jellyfin,
            name: "家庭 Jellyfin".into(),
            addresses: vec![jf_url],
            root_path: String::new(),
            credential_ref: Some("jf-cred".into()),
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
        .unwrap();
    wait_scan_done(&core, &mut rx, jf_id).await;

    // 3. 验证统一资料库：
    //    - 《晴天》两个服务器有相同 MBID → 自动归并为 1 条 track，挂 2 个来源！
    //    - 《以父之名》两台服务器时长差 1 秒且无 MBID → 暂时是 2 条 track，随后手动合并！
    let rows = core
        .list_tracks(TrackQuery {
            sort: TrackSort::Title,
            offset: 0,
            limit: 20,
        })
        .await
        .unwrap();
    let qingtian: Vec<_> = rows.iter().filter(|r| r.title == "晴天").collect();
    assert_eq!(
        qingtian.len(),
        1,
        "同 MBID 曲目应跨 OpenSubsonic/Jellyfin 自动统一"
    );
    let qt_sources = core.track_sources(qingtian[0].id).await.unwrap();
    assert_eq!(qt_sources.len(), 2);
    assert_eq!(qt_sources.iter().filter(|s| s.preferred).count(), 1);

    // 标记 Navidrome 不可达 → Jellyfin 立即变成 preferred。
    core.report_source_reachability(sub_id, false);
    core.report_source_reachability(jf_id, true);
    let qt_after = core.track_sources(qingtian[0].id).await.unwrap();
    let preferred = qt_after.iter().find(|s| s.preferred).unwrap();
    assert_eq!(preferred.source_id, jf_id);
    assert_eq!(preferred.reachable, Some(true));

    // 网络切到 Away 仍可正常选到 Jellyfin。
    core.set_network_context(NetworkContext::Away);
    let qt_away = core.track_sources(qingtian[0].id).await.unwrap();
    assert_eq!(
        qt_away.iter().find(|s| s.preferred).unwrap().source_id,
        jf_id
    );

    // 4. 《以父之名》两台服务器时长差 1 秒且无 MBID → SRC-13 扫描后已自动归并成 1 条 track（2 个来源）。
    //    验证手动拆分后自动合并不会再强行合回，并且仍可手动重新合并。
    let yifu: Vec<_> = rows.iter().filter(|r| r.title == "以父之名").collect();
    assert_eq!(
        yifu.len(),
        1,
        "无 MBID 但歌名/艺人一致且时长差 1 秒的曲目应跨源自动合并"
    );
    let yifu_sources = core.track_sources(yifu[0].id).await.unwrap();
    assert_eq!(yifu_sources.len(), 2);

    let to_split = &yifu_sources[1];
    let split_id = core
        .split_track_source(
            yifu[0].id,
            to_split.source_id,
            to_split.file_id,
            to_split.external_id.clone(),
        )
        .await
        .unwrap();
    assert_ne!(split_id, yifu[0].id);
    assert_eq!(core.track_sources(yifu[0].id).await.unwrap().len(), 1);
    assert_eq!(core.track_sources(split_id).await.unwrap().len(), 1);

    // 手动拆分过的曲目对不会被自动合并重新合回。
    let report = core.auto_merge_unified_library(false).await.unwrap();
    assert_eq!(report.merged_tracks, 0);
    assert_eq!(core.track_sources(yifu[0].id).await.unwrap().len(), 1);
    assert_eq!(core.track_sources(split_id).await.unwrap().len(), 1);

    // 手动合并仍可把两条重新合并成一条。
    let merged = core.merge_tracks(yifu[0].id, vec![split_id]).await.unwrap();
    assert_eq!(merged, 1);
    assert_eq!(core.track_sources(yifu[0].id).await.unwrap().len(), 2);

    let _ = std::fs::remove_dir_all(&tmp);
}
