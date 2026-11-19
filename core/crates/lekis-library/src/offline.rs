//! 离线下载记录（OFF-01/02）。
//!
//! 缓存文件由 `lekis-core` 负责拷贝到 `<data_dir>/offline/`；这里只持久化"哪首歌已下载、
//! 源是谁、缓存路径、大小和状态"。表结构见 `migrations/0007_offline_download.sql`。
//!
//! 状态机：`queued` → `downloading` → `ready`；失败 / 取消进入 `failed`。
//! 应用重启时，停在 `downloading` 的行会被改回 `queued`（不自动继续，重试由用户发起）。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, OfflineState, Result, SourceId, TrackId};
use rusqlite::{params, OptionalExtension, Row};

/// 一条离线下载记录。
#[derive(Debug, Clone, PartialEq)]
pub struct OfflineDownload {
    /// 曲目。
    pub track_id: TrackId,
    /// 下载时使用的音源。
    pub source_id: SourceId,
    /// 缓存文件的本机绝对路径。
    pub cache_path: String,
    /// 已经写进缓存文件的字节数。
    pub bytes: u64,
    /// 源文件总字节数（未知时为 0）。
    pub total_bytes: u64,
    /// 状态。
    pub state: OfflineState,
    /// 最近一次失败 / 取消的原因（给开发者看，不直接展示）。
    pub error: Option<String>,
    /// 创建时间（Unix 毫秒）。
    pub created_at: i64,
    /// 最后更新时间（Unix 毫秒）。
    pub updated_at: i64,
}

/// 离线下载汇总（"已下载 N 首 / 共 X MB"）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OfflineStats {
    /// 已经可离线播放的曲目数。
    pub count: u64,
    /// 这些曲目的缓存文件总字节数。
    pub bytes: u64,
}

const OFFLINE_COLUMNS: &str = "track_id, source_id, cache_path, bytes, total_bytes, state, error,
                               created_at, updated_at";

fn map_offline_row(r: &Row<'_>) -> rusqlite::Result<OfflineDownload> {
    let state: String = r.get(5)?;
    Ok(OfflineDownload {
        track_id: TrackId(r.get(0)?),
        source_id: SourceId(r.get(1)?),
        cache_path: r.get(2)?,
        bytes: r.get::<_, i64>(3)?.max(0) as u64,
        total_bytes: r.get::<_, i64>(4)?.max(0) as u64,
        state: OfflineState::from_db(&state).unwrap_or(OfflineState::Failed),
        error: r.get(6)?,
        created_at: r.get(7)?,
        updated_at: r.get(8)?,
    })
}

impl Library {
    /// 取某个曲目的离线记录（任何状态）。
    pub async fn offline_download(&self, track_id: TrackId) -> Result<Option<OfflineDownload>> {
        let sql = format!("SELECT {OFFLINE_COLUMNS} FROM offline_download WHERE track_id = ?1");
        self.read(move |c| {
            c.query_row(&sql, params![track_id.0], map_offline_row)
                .optional()
                .db()
        })
        .await
    }

    /// 取某个曲目"可以播放"的离线记录（`state = ready`）。
    pub async fn offline_ready_download(
        &self,
        track_id: TrackId,
    ) -> Result<Option<OfflineDownload>> {
        let sql = format!(
            "SELECT {OFFLINE_COLUMNS} FROM offline_download
             WHERE track_id = ?1 AND state = 'ready'"
        );
        self.read(move |c| {
            c.query_row(&sql, params![track_id.0], map_offline_row)
                .optional()
                .db()
        })
        .await
    }

    /// 全部离线记录：下载中 / 排队优先，其余按最近更新时间倒序。
    pub async fn offline_downloads(&self) -> Result<Vec<OfflineDownload>> {
        let sql = format!(
            "SELECT {OFFLINE_COLUMNS} FROM offline_download
             ORDER BY CASE state
                        WHEN 'downloading' THEN 0
                        WHEN 'queued' THEN 1
                        WHEN 'failed' THEN 2
                        ELSE 3
                      END,
                      updated_at DESC"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt.query_map([], map_offline_row).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 离线汇总：已经可播放的曲目数和缓存字节数（不包含下载中 / 失败的行）。
    pub async fn offline_stats(&self) -> Result<OfflineStats> {
        self.read(|c| {
            c.query_row(
                "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM offline_download
                 WHERE state = 'ready'",
                [],
                |r| {
                    Ok(OfflineStats {
                        count: r.get::<_, i64>(0)?.max(0) as u64,
                        bytes: r.get::<_, i64>(1)?.max(0) as u64,
                    })
                },
            )
            .db()
        })
        .await
    }

    /// 入队（或重新入队）：覆盖旧的源 / 路径 / 大小，清零进度。
    pub async fn upsert_offline_queued(
        &self,
        track_id: TrackId,
        source_id: SourceId,
        cache_path: String,
        total_bytes: u64,
    ) -> Result<()> {
        self.write(move |c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO offline_download
                   (track_id, source_id, cache_path, bytes, total_bytes, state, error,
                    created_at, updated_at)
                 VALUES (?1, ?2, ?3, 0, ?4, 'queued', NULL, ?5, ?5)
                 ON CONFLICT (track_id) DO UPDATE SET
                   source_id = excluded.source_id,
                   cache_path = excluded.cache_path,
                   bytes = 0,
                   total_bytes = excluded.total_bytes,
                   state = 'queued',
                   error = NULL,
                   updated_at = excluded.updated_at",
                params![track_id.0, source_id.0, cache_path, total_bytes as i64, now],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 标记开始下载。
    pub async fn mark_offline_downloading(&self, track_id: TrackId) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE offline_download
                    SET state = 'downloading', error = NULL, updated_at = ?2
                  WHERE track_id = ?1",
                params![track_id.0, now_ms()],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 更新已写字节数（`total_bytes` 为 `None` 时保持原值）。
    pub async fn update_offline_progress(
        &self,
        track_id: TrackId,
        bytes: u64,
        total_bytes: Option<u64>,
    ) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE offline_download
                    SET bytes = ?2,
                        total_bytes = COALESCE(?3, total_bytes),
                        updated_at = ?4
                  WHERE track_id = ?1",
                params![
                    track_id.0,
                    bytes as i64,
                    total_bytes.map(|n| n as i64),
                    now_ms()
                ],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 标记下载完成，缓存文件已经原子地改名到最终路径。
    pub async fn mark_offline_ready(&self, track_id: TrackId, bytes: u64) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE offline_download
                    SET state = 'ready', bytes = ?2, error = NULL, updated_at = ?3
                  WHERE track_id = ?1",
                params![track_id.0, bytes as i64, now_ms()],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 标记失败 / 取消，保留已经写入的字节数，方便 UI 展示。
    pub async fn mark_offline_failed(&self, track_id: TrackId, error: String) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE offline_download
                    SET state = 'failed', error = ?2, updated_at = ?3
                  WHERE track_id = ?1",
                params![track_id.0, error, now_ms()],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 删除记录并返回被删的那一行（调用方据此删缓存文件）。
    pub async fn remove_offline_download(
        &self,
        track_id: TrackId,
    ) -> Result<Option<OfflineDownload>> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let sql = format!("SELECT {OFFLINE_COLUMNS} FROM offline_download WHERE track_id = ?1");
            let existing = tx
                .query_row(&sql, params![track_id.0], map_offline_row)
                .optional()
                .db()?;
            if existing.is_some() {
                tx.execute(
                    "DELETE FROM offline_download WHERE track_id = ?1",
                    params![track_id.0],
                )
                .db()?;
            }
            tx.commit().db()?;
            Ok(existing)
        })
        .await
    }

    /// 启动时的状态恢复：停在 `downloading` 的行改回 `queued` 并记录中断原因。
    ///
    /// 不自动开始下载（网络可能还没准备好，重试是用户动作），也不动 `ready` / `failed`。
    /// 返回恢复的行数。
    pub async fn recover_stale_offline_downloads(&self) -> Result<u64> {
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE offline_download
                        SET state = 'queued',
                            error = '上次下载未完成，点击重试',
                            updated_at = ?1
                      WHERE state = 'downloading'",
                    params![now_ms()],
                )
                .db()?;
            Ok(n as u64)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::{SourceConfig, SourceKind};
    use rusqlite::params;
    use std::collections::BTreeMap;

    async fn add_track(lib: &Library, uid: &str) -> Result<TrackId> {
        let uid = uid.to_string();
        lib.write(move |c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO track (uid, title, created_at, updated_at) VALUES (?1, ?1, ?2, ?2)",
                params![uid, now],
            )
            .db()?;
            Ok(TrackId(c.last_insert_rowid()))
        })
        .await
    }

    async fn add_source(lib: &Library) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::Local,
            name: "Music".into(),
            addresses: vec!["/music".into()],
            root_path: String::new(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    #[tokio::test]
    async fn roundtrip_progress_stats_and_remove() -> Result<()> {
        let lib = temp_library("offline-roundtrip")?;
        let source = add_source(&lib).await?;
        let track = add_track(&lib, "offline-track-1").await?;

        lib.upsert_offline_queued(track, source, "/data/offline/1.flac".into(), 1_000)
            .await?;
        let row = lib.offline_download(track).await?.expect("queued row");
        assert_eq!(row.state, OfflineState::Queued);
        assert_eq!(row.total_bytes, 1_000);
        assert_eq!(row.bytes, 0);
        assert_eq!(row.error, None);

        lib.mark_offline_downloading(track).await?;
        lib.update_offline_progress(track, 400, Some(1_000)).await?;
        let row = lib.offline_download(track).await?.expect("downloading row");
        assert_eq!(row.state, OfflineState::Downloading);
        assert_eq!(row.bytes, 400);
        assert_eq!(lib.offline_ready_download(track).await?, None);

        lib.mark_offline_ready(track, 1_000).await?;
        let row = lib.offline_download(track).await?.expect("ready row");
        assert_eq!(row.state, OfflineState::Ready);
        assert_eq!(row.bytes, 1_000);
        assert_eq!(
            lib.offline_stats().await?,
            OfflineStats {
                count: 1,
                bytes: 1_000
            }
        );
        assert!(lib.offline_ready_download(track).await?.is_some());
        assert_eq!(lib.offline_downloads().await?.len(), 1);

        let removed = lib.remove_offline_download(track).await?;
        assert_eq!(
            removed.map(|r| r.cache_path),
            Some("/data/offline/1.flac".into())
        );
        assert_eq!(lib.offline_download(track).await?, None);
        assert_eq!(lib.offline_stats().await?, OfflineStats::default());
        // 再删一次不是错误，只是没有东西可删。
        assert_eq!(lib.remove_offline_download(track).await?, None);
        Ok(())
    }

    #[tokio::test]
    async fn requeue_resets_progress_and_keeps_created_at() -> Result<()> {
        let lib = temp_library("offline-requeue")?;
        let source = add_source(&lib).await?;
        let track = add_track(&lib, "offline-track-2").await?;
        lib.upsert_offline_queued(track, source, "/data/offline/2.flac".into(), 2_000)
            .await?;
        let first = lib.offline_download(track).await?.expect("row");
        lib.update_offline_progress(track, 900, None).await?;
        lib.mark_offline_failed(track, "network down".into())
            .await?;

        lib.upsert_offline_queued(track, source, "/data/offline/2.flac".into(), 2_000)
            .await?;
        let row = lib.offline_download(track).await?.expect("row");
        assert_eq!(row.state, OfflineState::Queued);
        assert_eq!(row.bytes, 0);
        assert_eq!(row.error, None);
        assert_eq!(row.created_at, first.created_at);
        assert!(row.updated_at >= first.updated_at);
        Ok(())
    }

    #[tokio::test]
    async fn stale_downloading_rows_recover_to_queued() -> Result<()> {
        let lib = temp_library("offline-stale")?;
        let source = add_source(&lib).await?;
        let t1 = add_track(&lib, "offline-stale-1").await?;
        let t2 = add_track(&lib, "offline-stale-2").await?;
        let t3 = add_track(&lib, "offline-stale-3").await?;

        lib.upsert_offline_queued(t1, source, "/data/offline/s1.flac".into(), 100)
            .await?;
        lib.upsert_offline_queued(t2, source, "/data/offline/s2.flac".into(), 100)
            .await?;
        lib.upsert_offline_queued(t3, source, "/data/offline/s3.flac".into(), 100)
            .await?;
        lib.mark_offline_downloading(t1).await?;
        lib.mark_offline_downloading(t2).await?;
        lib.mark_offline_ready(t3, 100).await?;

        assert_eq!(lib.recover_stale_offline_downloads().await?, 2);
        for id in [t1, t2] {
            let row = lib.offline_download(id).await?.expect("row");
            assert_eq!(
                row.state,
                OfflineState::Queued,
                "stale row must be requeued"
            );
            assert!(row.error.is_some());
        }
        let ready = lib.offline_download(t3).await?.expect("row");
        assert_eq!(ready.state, OfflineState::Ready);
        assert_eq!(ready.error, None);
        // 再跑一次没有可恢复的行。
        assert_eq!(lib.recover_stale_offline_downloads().await?, 0);
        Ok(())
    }
}
