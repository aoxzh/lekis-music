//! 服务器源的曲目入库（SRC-04~06）。
//!
//! 服务器源没有"文件"，曲目直接用服务器上的 `external_id` 关联到 `track_file`。
//! 这里不依赖 `lekis-providers`（依赖方向只允许 providers → types），所以入参是本模块自己的结构体，
//! 由 `lekis-core` 把 `RemoteTrack` 转换过来。

use crate::db::DbResultExt;
use crate::normalize::{norm_key, search_keys, sort_key};
use crate::Library;
use lekis_types::{now_ms, Result, SourceId, TrackUid};
use rusqlite::{params, Transaction};

/// 服务器上的一首歌（入库用）。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RemoteTrackRow {
    /// 服务器上的 ID。
    pub external_id: String,
    /// 标题。
    pub title: String,
    /// 艺人。
    pub artists: Vec<String>,
    /// 专辑。
    pub album: Option<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// MusicBrainz 录音 ID。
    pub mbid_recording: Option<String>,
    /// 音质分（服务器转码源一般比本地文件低）。
    pub quality_score: i64,
}

/// 入库统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RemoteUpsertStats {
    /// 新增。
    pub added: u64,
    /// 更新。
    pub updated: u64,
}

impl Library {
    /// 整批替换某个服务器源的曲目（一个事务）。
    ///
    /// 做法：先 upsert 所有曲目并把 `last_seen_at` 刷成现在，再删掉这个源里这次没见到的
    /// `track_file` 行（服务器侧删歌），最后清理孤儿。
    pub async fn upsert_remote_tracks(
        &self,
        source_id: SourceId,
        tracks: Vec<RemoteTrackRow>,
    ) -> Result<RemoteUpsertStats> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            let mut stats = RemoteUpsertStats::default();
            for t in &tracks {
                if upsert_remote_one(&tx, source_id, t, now)? {
                    stats.added += 1;
                } else {
                    stats.updated += 1;
                }
            }
            // 服务器侧已经不存在的曲目。
            let json = serde_json::to_string(
                &tracks.iter().map(|t| t.external_id.as_str()).collect::<Vec<_>>(),
            )
            .unwrap_or_else(|_| "[]".into());
            let deleted = tx
                .execute(
                    "DELETE FROM track_file WHERE source_id = ?1 AND external_id IS NOT NULL
                       AND external_id NOT IN (SELECT value FROM json_each(?2))",
                    params![source_id.0, json],
                )
                .db()?;
            tracing::debug!(target: "library", source_id = ?source_id, deleted, "pruned remote tracks");
            crate::scanned::sweep_orphans(&tx)?;
            tx.commit().db()?;
            Ok(stats)
        })
        .await
    }

    /// 某个服务器源上次同步成功的曲目数。
    pub async fn remote_track_count(&self, source_id: SourceId) -> Result<u64> {
        self.read(move |c| {
            c.query_row(
                "SELECT COUNT(*) FROM track_file WHERE source_id = ?1 AND external_id IS NOT NULL",
                params![source_id.0],
                |r| r.get::<_, i64>(0),
            )
            .db()
            .map(|n| n.max(0) as u64)
        })
        .await
    }
}

/// 返回 `true` 表示新增。
fn upsert_remote_one(
    tx: &Transaction<'_>,
    source_id: SourceId,
    t: &RemoteTrackRow,
    now: i64,
) -> Result<bool> {
    let artist_line = t.artists.join(" / ");
    let album_id = match &t.album {
        Some(title) if !title.trim().is_empty() => {
            Some(upsert_album(tx, title, &artist_line, now)?)
        }
        _ => None,
    };

    let uid = match &t.mbid_recording {
        Some(mbid) => TrackUid::from_mbid(mbid),
        None => TrackUid::from_metadata(
            &artist_line,
            &t.title,
            t.album.as_deref().unwrap_or(""),
            t.duration_ms,
        ),
    };

    let existed: Option<i64> = tx
        .query_row(
            "SELECT track_id FROM track_file WHERE source_id = ?1 AND external_id = ?2",
            params![source_id.0, t.external_id],
            |r| r.get(0),
        )
        .ok();
    let is_new = existed.is_none();

    let track_id: i64 = tx
        .query_row(
            "INSERT INTO track (uid, title, title_sort_key, artist_line, album_id, duration_ms,
                                mbid_recording, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
             ON CONFLICT (uid) DO UPDATE SET
               title = excluded.title, title_sort_key = excluded.title_sort_key,
               artist_line = excluded.artist_line, album_id = excluded.album_id,
               duration_ms = excluded.duration_ms, updated_at = excluded.updated_at
             RETURNING id",
            params![
                uid.0,
                t.title,
                sort_key(&t.title),
                artist_line,
                album_id,
                t.duration_ms as i64,
                t.mbid_recording,
                now
            ],
            |r| r.get(0),
        )
        .db()?;

    tx.execute(
        "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
         VALUES (?1, NULL, ?2, ?3, ?4)
         ON CONFLICT (track_id, source_id, external_id) WHERE external_id IS NOT NULL
         DO UPDATE SET quality_score = excluded.quality_score",
        params![track_id, source_id.0, t.external_id, t.quality_score],
    )
    .db()?;

    for (pos, name) in t.artists.iter().enumerate() {
        let artist_id = upsert_artist(tx, name)?;
        tx.execute(
            "INSERT OR IGNORE INTO track_artist (track_id, artist_id, role, position)
             VALUES (?1, ?2, 'main', ?3)",
            params![track_id, artist_id, pos as i64],
        )
        .db()?;
    }

    tx.execute(
        "DELETE FROM search_index WHERE kind = 'track' AND ref_id = ?1",
        params![track_id],
    )
    .db()?;
    tx.execute(
        "INSERT INTO search_index (kind, ref_id, title, subtitle, keys) VALUES ('track', ?1, ?2, ?3, ?4)",
        params![
            track_id,
            t.title,
            artist_line,
            search_keys(&[&t.title, &artist_line, t.album.as_deref().unwrap_or("")])
        ],
    )
    .db()?;

    Ok(is_new)
}

fn upsert_artist(tx: &Transaction<'_>, name: &str) -> Result<i64> {
    tx.query_row(
        "INSERT INTO artist (name, sort_name, name_norm) VALUES (?1, ?2, ?3)
         ON CONFLICT (name_norm) DO UPDATE SET name = artist.name
         RETURNING id",
        params![name, sort_key(name), norm_key(name)],
        |r| r.get(0),
    )
    .db()
}

fn upsert_album(tx: &Transaction<'_>, title: &str, artist_line: &str, now: i64) -> Result<i64> {
    tx.query_row(
        "INSERT INTO album (title, sort_title, title_norm, artist_line, artist_norm, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT (title_norm, artist_norm) DO UPDATE SET title = album.title
         RETURNING id",
        params![
            title,
            sort_key(title),
            norm_key(title),
            artist_line,
            norm_key(artist_line),
            now
        ],
        |r| r.get(0),
    )
    .db()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    async fn server_source(lib: &Library) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind: SourceKind::OpenSubsonic,
            name: "nav".into(),
            addresses: vec!["http://nav.local:4533".into()],
            root_path: String::new(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    fn row(id: &str, title: &str) -> RemoteTrackRow {
        RemoteTrackRow {
            external_id: id.into(),
            title: title.into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            mbid_recording: None,
            quality_score: 120,
        }
    }

    #[tokio::test]
    async fn upsert_and_prune() -> Result<()> {
        let lib = temp_library("remote")?;
        let src = server_source(&lib).await?;

        let stats = lib
            .upsert_remote_tracks(src, vec![row("s1", "晴天"), row("s2", "以父之名")])
            .await?;
        assert_eq!(
            stats,
            RemoteUpsertStats {
                added: 2,
                updated: 0
            }
        );
        assert_eq!(lib.remote_track_count(src).await?, 2);

        // 再同步一次，只回来一首：另一首应当被清掉。
        let again = lib
            .upsert_remote_tracks(src, vec![row("s1", "晴天")])
            .await?;
        assert_eq!(again.added, 0);
        assert_eq!(lib.remote_track_count(src).await?, 1);

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "晴天");

        // 搜索索引也跟着更新了。
        assert_eq!(lib.search("以父之名", 10).await?.tracks.len(), 0);
        assert_eq!(lib.search("晴天", 10).await?.tracks.len(), 1);
        Ok(())
    }

    #[tokio::test]
    async fn same_track_from_two_sources_gets_two_files() -> Result<()> {
        let lib = temp_library("remote-merge")?;
        let a = server_source(&lib).await?;
        let b = server_source(&lib).await?;
        lib.upsert_remote_tracks(a, vec![row("a1", "晴天")]).await?;
        lib.upsert_remote_tracks(b, vec![row("b1", "晴天")]).await?;

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        // 同一首歌（相同的艺人/标题/专辑/时长）应当合并成一条曲目。
        assert_eq!(rows.len(), 1);
        let files = lib.track_files(rows[0].id).await?;
        assert_eq!(files.len(), 2);
        assert!(files.iter().all(|f| !f.source_kind.is_filesystem()));
        Ok(())
    }
}
