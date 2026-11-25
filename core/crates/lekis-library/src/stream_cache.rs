//! NAS / 远端流媒体播放缓存表（OFF-03）。
//!
//! 独立于用户主动触发的离线下载（`offline_download`）：
//! - 播过的 NAS / 服务器曲目自动缓存在 `<cache_dir>/stream_cache/`；
//! - 每次命中刷新 `last_used`；
//! - 超过上限时按 `last_used ASC`（LRU）淘汰最久未播的条目；
//! - 断网或 NAS 不可达时，选源层优先播放这里已经完整落盘的缓存。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, Result, SourceId, TrackId};
use rusqlite::{params, OptionalExtension, Row};

/// 一条流媒体播放缓存记录。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamCacheEntry {
    /// 曲目 ID。
    pub track_id: TrackId,
    /// 来源音源 ID。
    pub source_id: SourceId,
    /// 本机缓存文件的绝对路径。
    pub cache_path: String,
    /// 文件大小（字节）。
    pub bytes: u64,
    /// 最近一次播放命中时间（Unix 毫秒，LRU 排序键）。
    pub last_used: i64,
    /// 创建时间（Unix 毫秒）。
    pub created_at: i64,
}

/// 流媒体播放缓存统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StreamCacheStats {
    /// 已缓存曲目数。
    pub count: u64,
    /// 已占用总字节数。
    pub bytes: u64,
}

const COLUMNS: &str = "track_id, source_id, cache_path, bytes, last_used, created_at";

fn map_row(r: &Row<'_>) -> rusqlite::Result<StreamCacheEntry> {
    Ok(StreamCacheEntry {
        track_id: TrackId(r.get(0)?),
        source_id: SourceId(r.get(1)?),
        cache_path: r.get(2)?,
        bytes: r.get::<_, i64>(3)?.max(0) as u64,
        last_used: r.get(4)?,
        created_at: r.get(5)?,
    })
}

impl Library {
    /// 查询某首曲目的流媒体播放缓存。
    pub async fn stream_cache_get(&self, track_id: TrackId) -> Result<Option<StreamCacheEntry>> {
        let sql = format!("SELECT {COLUMNS} FROM stream_cache WHERE track_id = ?1");
        self.read(move |c| {
            c.query_row(&sql, params![track_id.0], map_row)
                .optional()
                .db()
        })
        .await
    }

    /// 命中缓存后刷新 `last_used`（LRU 保活）。
    pub async fn stream_cache_touch(&self, track_id: TrackId) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "UPDATE stream_cache SET last_used = ?2 WHERE track_id = ?1",
                params![track_id.0, now_ms()],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 写入或更新一条流媒体播放缓存记录。
    pub async fn stream_cache_upsert(
        &self,
        track_id: TrackId,
        source_id: SourceId,
        cache_path: String,
        bytes: u64,
    ) -> Result<()> {
        self.write(move |c| {
            let now = now_ms();
            c.execute(
                "INSERT INTO stream_cache (track_id, source_id, cache_path, bytes, last_used, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5)
                 ON CONFLICT (track_id) DO UPDATE SET
                   source_id = excluded.source_id,
                   cache_path = excluded.cache_path,
                   bytes = excluded.bytes,
                   last_used = excluded.last_used",
                params![track_id.0, source_id.0, cache_path, bytes as i64, now],
            )
            .db()?;
            Ok(())
        })
        .await
    }

    /// 统计当前流媒体播放缓存条目数与总大小。
    pub async fn stream_cache_stats(&self) -> Result<StreamCacheStats> {
        self.read(|c| {
            c.query_row(
                "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM stream_cache",
                [],
                |r| {
                    Ok(StreamCacheStats {
                        count: r.get::<_, i64>(0)?.max(0) as u64,
                        bytes: r.get::<_, i64>(1)?.max(0) as u64,
                    })
                },
            )
            .db()
        })
        .await
    }

    /// 删除单条缓存记录（例如发现磁盘文件已丢失）。
    pub async fn stream_cache_remove(&self, track_id: TrackId) -> Result<Option<StreamCacheEntry>> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let sql = format!("SELECT {COLUMNS} FROM stream_cache WHERE track_id = ?1");
            let existing = tx
                .query_row(&sql, params![track_id.0], map_row)
                .optional()
                .db()?;
            if existing.is_some() {
                tx.execute(
                    "DELETE FROM stream_cache WHERE track_id = ?1",
                    params![track_id.0],
                )
                .db()?;
            }
            tx.commit().db()?;
            Ok(existing)
        })
        .await
    }

    /// 按 LRU 淘汰最久未使用的缓存，直到总字节数不超过 `limit_bytes`（排除正在播放的 `protect` 曲目）。
    ///
    /// 返回已被从数据库移除的条目，调用方据此删磁盘文件。
    pub async fn stream_cache_evict_to(
        &self,
        limit_bytes: u64,
        protect: Option<TrackId>,
    ) -> Result<Vec<StreamCacheEntry>> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let mut total: u64 = tx
                .query_row(
                    "SELECT COALESCE(SUM(bytes), 0) FROM stream_cache",
                    [],
                    |r| Ok(r.get::<_, i64>(0)?.max(0) as u64),
                )
                .db()?;
            if total <= limit_bytes {
                return Ok(Vec::new());
            }
            let sql =
                format!("SELECT {COLUMNS} FROM stream_cache ORDER BY last_used ASC, track_id ASC");
            let candidates: Vec<StreamCacheEntry> = {
                let mut stmt = tx.prepare_cached(&sql).db()?;
                let rows = stmt.query_map([], map_row).db()?;
                rows.collect::<rusqlite::Result<Vec<_>>>().db()?
            };
            let mut evicted = Vec::new();
            for entry in candidates {
                if total <= limit_bytes {
                    break;
                }
                if protect == Some(entry.track_id) && limit_bytes > 0 {
                    continue;
                }
                tx.execute(
                    "DELETE FROM stream_cache WHERE track_id = ?1",
                    params![entry.track_id.0],
                )
                .db()?;
                total = total.saturating_sub(entry.bytes);
                evicted.push(entry);
            }
            tx.commit().db()?;
            Ok(evicted)
        })
        .await
    }

    /// 清空全部流媒体播放缓存记录，返回待删文件路径列表。
    pub async fn stream_cache_clear(&self) -> Result<Vec<StreamCacheEntry>> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let sql = format!("SELECT {COLUMNS} FROM stream_cache");
            let entries: Vec<StreamCacheEntry> = {
                let mut stmt = tx.prepare_cached(&sql).db()?;
                let rows = stmt.query_map([], map_row).db()?;
                rows.collect::<rusqlite::Result<Vec<_>>>().db()?
            };
            tx.execute("DELETE FROM stream_cache", []).db()?;
            tx.commit().db()?;
            Ok(entries)
        })
        .await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::{SourceConfig, SourceKind};
    use std::collections::BTreeMap;

    #[tokio::test]
    async fn lru_eviction_removes_oldest_entries_first() -> Result<()> {
        let lib = temp_library("stream-cache-lru")?;
        let source = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Smb,
                name: "NAS".into(),
                addresses: vec!["smb://nas/music".into()],
                root_path: String::new(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;

        let mut tids = Vec::new();
        for i in 1..=3 {
            let uid = format!("sc-track-{i}");
            let id = lib
                .write(move |c| {
                    c.execute(
                        "INSERT INTO track (uid, title, created_at, updated_at) VALUES (?1, ?1, 0, 0)",
                        params![uid],
                    )
                    .db()?;
                    Ok(TrackId(c.last_insert_rowid()))
                })
                .await?;
            tids.push(id);
            lib.stream_cache_upsert(id, source, format!("/cache/{i}.flac"), 1_000)
                .await?;
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        // Touch track 1 so track 2 becomes the oldest
        lib.stream_cache_touch(tids[0]).await?;

        let stats = lib.stream_cache_stats().await?;
        assert_eq!(
            stats,
            StreamCacheStats {
                count: 3,
                bytes: 3_000
            }
        );

        let evicted = lib.stream_cache_evict_to(2_000, None).await?;
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].track_id, tids[1]);
        assert!(lib.stream_cache_get(tids[0]).await?.is_some());
        assert!(lib.stream_cache_get(tids[1]).await?.is_none());
        assert!(lib.stream_cache_get(tids[2]).await?.is_some());
        Ok(())
    }
}
