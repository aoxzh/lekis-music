//! 服务器源的同步（SRC-04~06）：从媒体服务器分页拉曲目，写进统一资料库。
//!
//! 和文件扫描的区别：没有文件、没有标签读取，服务器给什么就是什么；进度事件沿用
//! `ScanProgress`（阶段用 `ReadingTags`，因为对 UI 来说"正在读元数据"是一样的）。

use crate::events::EventBus;
use lekis_library::{Library, RemoteTrackRow};
use lekis_providers::{MediaServer, RemoteTrack};
use lekis_types::{CoreEvent, LekisError, Result, ScanPhase, SourceId};
use std::sync::Arc;

/// 每页拉多少首。
pub(crate) const PAGE_SIZE: u32 = 500;

/// 服务器源的音质分（SRC-13）：服务器流通常是转码或原始有损，比本地无损文件低。
const SERVER_QUALITY_SCORE: i64 = 150;

/// 把一个 `RemoteTrack` 转成入库行。
pub(crate) fn to_row(track: &RemoteTrack) -> RemoteTrackRow {
    RemoteTrackRow {
        external_album_id: track.external_album_id.clone(),
        album_artists: track.album_artists.clone(),
        disc_no: track.disc_no,
        track_no: track.track_no,
        external_id: track.external_id.clone(),
        title: track.title.clone(),
        artists: track.artists.clone(),
        album: track.album.clone(),
        duration_ms: track.duration_ms,
        mbid_recording: track.mbid_recording.clone(),
        quality_score: SERVER_QUALITY_SCORE,
    }
}

/// 全量同步一个服务器源。
pub(crate) async fn sync_source(
    server: Arc<dyn MediaServer>,
    library: Library,
    source_id: SourceId,
    events: EventBus,
) -> Result<u64> {
    server.ping().await?;

    let mut all: Vec<RemoteTrackRow> = Vec::new();
    let mut offset: u32 = 0;
    loop {
        let page = server.list_tracks(offset, PAGE_SIZE, None).await?;
        let got = page.len() as u32;
        all.extend(page.iter().map(to_row));
        events.emit(CoreEvent::ScanProgress {
            source_id,
            phase: ScanPhase::ReadingTags,
            done: all.len() as u64,
            total: None,
        });
        if got < PAGE_SIZE {
            break;
        }
        offset += got;
        // 防御：某些服务器在 offset 超界时还会重复返回最后一页。
        if offset > 5_000_000 {
            return Err(LekisError::internal(
                "media server pagination did not terminate",
            ));
        }
    }

    let total = all.len() as u64;
    let stats = library.upsert_remote_tracks(source_id, all).await?;
    library.mark_scanned(source_id).await?;
    let auto_merge = library
        .get_setting(crate::settings::UNIFIED_AUTO_MERGE)
        .await
        .ok()
        .flatten()
        .map(|v| v.trim() != "false" && v.trim() != "0")
        .unwrap_or(true);
    if auto_merge {
        if let Err(e) = library.auto_merge_cross_source_tracks().await {
            tracing::warn!(target: "core::unified", %source_id, error = %e, "unified auto-merge after remote sync failed");
        }
    }
    events.emit(CoreEvent::ScanFinished {
        source_id,
        added: stats.added,
        updated: stats.updated,
        removed: 0,
    });
    tracing::info!(target: "core", %source_id, total, ?stats, "media server sync finished");
    Ok(total)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use lekis_providers::{StreamQuality, StreamTarget};
    use lekis_types::SourceKind;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Mutex;

    /// 假服务器：`total` 首歌，按 offset/limit 分页。
    struct FakeServer {
        total: u32,
        calls: AtomicU32,
        all_titles: Mutex<Vec<String>>,
    }

    impl FakeServer {
        fn new(total: u32) -> Self {
            Self {
                total,
                calls: AtomicU32::new(0),
                all_titles: Mutex::new((0..total).map(|i| format!("曲目{i}")).collect()),
            }
        }
    }

    #[async_trait]
    impl MediaServer for FakeServer {
        fn kind(&self) -> SourceKind {
            SourceKind::OpenSubsonic
        }

        async fn ping(&self) -> Result<()> {
            Ok(())
        }

        async fn list_tracks(
            &self,
            offset: u32,
            limit: u32,
            _since_ms: Option<i64>,
        ) -> Result<Vec<RemoteTrack>> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            let total = self.total as usize;
            let titles = self.all_titles.lock().expect("lock");
            Ok(titles
                .iter()
                .take(total)
                .enumerate()
                .skip(offset as usize)
                .take(limit as usize)
                .map(|(i, t)| RemoteTrack {
                    external_album_id: None,
                    album_artists: vec![],
                    disc_no: None,
                    track_no: None,
                    external_id: format!("id{i}"),
                    title: t.clone(),
                    artists: vec!["周杰伦".into()],
                    album: Some("叶惠美".into()),
                    duration_ms: 200_000,
                    mbid_recording: None,
                    cover_id: None,
                })
                .collect())
        }

        async fn stream(&self, _id: &str, _q: StreamQuality) -> Result<StreamTarget> {
            Err(LekisError::not_implemented("fake stream"))
        }

        async fn scrobble(&self, _id: &str, _at: i64) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn paginates_until_short_page() -> Result<()> {
        let lib = Library::open(
            &std::env::temp_dir()
                .join(format!("lekis-remote-sync-{}", std::process::id()))
                .join("library.sqlite"),
        )
        .or_else(|_| {
            let dir =
                std::env::temp_dir().join(format!("lekis-remote-sync-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir)?;
            Library::open(&dir.join("library.sqlite"))
        })?;
        let source_id = lib
            .add_source(lekis_types::SourceConfig {
                id: None,
                kind: SourceKind::OpenSubsonic,
                name: "nav".into(),
                addresses: vec!["http://nav.local".into()],
                root_path: String::new(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await?;

        let server = Arc::new(FakeServer::new(1200));
        let n = sync_source(server.clone(), lib.clone(), source_id, EventBus::default()).await?;
        assert_eq!(n, 1200);
        // 1200 首 / 每页 500 → 3 次请求（500 + 500 + 200）。
        assert_eq!(server.calls.load(Ordering::Relaxed), 3);
        assert_eq!(lib.remote_track_count(source_id).await?, 1200);
        Ok(())
    }

    #[test]
    fn row_keeps_external_id_and_scores_below_local_lossless() {
        let t = RemoteTrack {
            external_album_id: None,
            album_artists: vec![],
            disc_no: None,
            track_no: None,
            external_id: "abc".into(),
            title: "晴天".into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            mbid_recording: None,
            cover_id: None,
        };
        let row = to_row(&t);
        assert_eq!(row.external_id, "abc");
        assert!(row.quality_score > 0);
        // 本地 16bit/44.1k 无损的分数至少是 600+60+40 = 700。
        assert!(row.quality_score < 700);
    }
}
