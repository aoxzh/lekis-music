//! 统一资料库（SRC-13）：查看一首歌的全部来源、手动合并重复曲目、手动拆出误合并的来源。
//!
//! 多源同名/同 MBID 曲目在扫描入库时会自动归并到同一条 `track` 下（各自保留一行
//! `track_file`）；当标签略有差异没能自动合并，或者误合到一起时，由本模块提供原子
//! 级的合并与拆分操作，且全程不删除任何磁盘文件。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{
    now_ms, AudioProps, LekisError, Result, SourceId, SourceKind, TrackId, TrackUid,
};
use rusqlite::{params, OptionalExtension, Transaction};

/// 一首歌下面的一个可播放来源（本地文件 / NAS 文件 / 媒体服务器曲目）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackSourceEntry {
    /// 所属音源 ID。
    pub source_id: SourceId,
    /// 音源显示名称。
    pub source_name: String,
    /// 音源类型。
    pub source_kind: SourceKind,
    /// 文件系统类音源对应的 `file.id`；服务器源为 `None`。
    pub file_id: Option<i64>,
    /// 源内相对路径（服务器源为空串）。
    pub path: String,
    /// 服务器源的曲目 ID（文件系统源为 `None`）。
    pub external_id: Option<String>,
    /// 文件大小（字节；服务器源或未知为 0）。
    pub size_bytes: u64,
    /// 音质徽章（如 `FLAC 24/96`、`MP3 320`）。
    pub format: Option<String>,
    /// 选源打分用的音质分（越大越好）。
    pub quality_score: i64,
}

impl Library {
    /// 列出 `track_id` 关联的全部音源文件，按音质分降序排列。
    pub async fn track_source_entries(&self, track_id: TrackId) -> Result<Vec<TrackSourceEntry>> {
        self.read(move |conn| {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT tf.source_id, s.name, s.kind, tf.file_id,
                            COALESCE(f.path, ''), tf.external_id,
                            COALESCE(f.size, 0), f.audio_json, tf.quality_score
                       FROM track_file tf
                       JOIN source s ON s.id = tf.source_id
                  LEFT JOIN file f ON f.id = tf.file_id
                      WHERE tf.track_id = ?1
                   ORDER BY tf.quality_score DESC, tf.source_id ASC",
                )
                .db()?;
            let rows = stmt
                .query_map(params![track_id.0], |r| {
                    let kind_raw: String = r.get(2)?;
                    let kind = serde_json::from_value(serde_json::Value::String(kind_raw))
                        .unwrap_or(SourceKind::Local);
                    let ext_raw: Option<String> = r.get(5)?;
                    let external_id = ext_raw.filter(|s| !s.is_empty());
                    let audio_json: Option<String> = r.get(7)?;
                    let format = audio_json
                        .as_deref()
                        .and_then(|j| serde_json::from_str::<AudioProps>(j).ok())
                        .map(|a| a.quality_badge());
                    Ok(TrackSourceEntry {
                        source_id: SourceId(r.get(0)?),
                        source_name: r.get(1)?,
                        source_kind: kind,
                        file_id: r.get(3)?,
                        path: r.get(4)?,
                        external_id,
                        size_bytes: r.get::<_, i64>(6)?.max(0) as u64,
                        format,
                        quality_score: r.get(8)?,
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 把 `absorb_ids` 中的曲目合并到 `keep_id` 下（SRC-13 手动合并）。
    ///
    /// 所有 `track_file` 挪到 `keep_id`，用户数据（喜欢、评分、播放次数、歌单、封面、歌词、
    /// 离线下载）按新曲目优先规则合并，随后清理变空的旧曲目并刷新 `quality_badge`。
    /// 返回实际被合并掉的曲目数量。
    pub async fn merge_tracks(&self, keep_id: TrackId, absorb_ids: Vec<TrackId>) -> Result<u64> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS (SELECT 1 FROM track WHERE id = ?1)",
                    params![keep_id.0],
                    |r| r.get(0),
                )
                .db()?;
            if !exists {
                return Err(LekisError::not_found(format!("track {keep_id}")));
            }

            let mut merged = 0u64;
            for old_id in absorb_ids {
                if old_id == keep_id {
                    continue;
                }
                let old_exists: bool = tx
                    .query_row(
                        "SELECT EXISTS (SELECT 1 FROM track WHERE id = ?1)",
                        params![old_id.0],
                        |r| r.get(0),
                    )
                    .db()?;
                if !old_exists {
                    continue;
                }

                // 挪移 track_file：遇到完全相同 (source, file, external) 时跳过避免主键冲突。
                tx.execute(
                    "INSERT OR IGNORE INTO track_file
                       (track_id, file_id, source_id, external_id, quality_score)
                     SELECT ?1, file_id, source_id, external_id, quality_score
                       FROM track_file WHERE track_id = ?2",
                    params![keep_id.0, old_id.0],
                )
                .db()?;
                tx.execute(
                    "DELETE FROM track_file WHERE track_id = ?1",
                    params![old_id.0],
                )
                .db()?;

                crate::scanned::carry_over_user_data(&tx, old_id.0, keep_id.0)?;
                merged += 1;
            }

            if merged > 0 {
                refresh_best_quality_badge(&tx, keep_id.0)?;
                crate::scanned::sweep_orphans(&tx)?;
                crate::browse::refresh_track_index(&tx, keep_id.0)?;
            }
            tx.commit().db()?;
            Ok(merged)
        })
        .await
    }

    /// 把挂在 `track_id` 下的某一个来源拆成一条独立曲目（SRC-13 手动拆分）。
    ///
    /// 只有当该曲目关联至少 2 个来源时才允许拆分；返回新拆出来的 `TrackId`。
    pub async fn split_track_source(
        &self,
        track_id: TrackId,
        source_id: SourceId,
        file_id: Option<i64>,
        external_id: Option<String>,
    ) -> Result<TrackId> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let count: i64 = tx
                .query_row(
                    "SELECT COUNT(*) FROM track_file WHERE track_id = ?1",
                    params![track_id.0],
                    |r| r.get(0),
                )
                .db()?;
            if count == 0 {
                return Err(LekisError::not_found(format!("track {track_id}")));
            }
            if count < 2 {
                return Err(LekisError::invalid(
                    "cannot split a track that only has one source",
                ));
            }

            let ext_key = external_id.clone().unwrap_or_default();
            let quality: Option<i64> = if let Some(fid) = file_id {
                tx.query_row(
                    "SELECT quality_score FROM track_file
                      WHERE track_id = ?1 AND source_id = ?2 AND file_id = ?3",
                    params![track_id.0, source_id.0, fid],
                    |r| r.get(0),
                )
                .optional()
                .db()?
            } else {
                tx.query_row(
                    "SELECT quality_score FROM track_file
                      WHERE track_id = ?1 AND source_id = ?2 AND file_id IS NULL
                        AND COALESCE(external_id, '') = ?3",
                    params![track_id.0, source_id.0, ext_key],
                    |r| r.get(0),
                )
                .optional()
                .db()?
            };
            let Some(quality_score) = quality else {
                return Err(LekisError::not_found("track source entry not found"));
            };

            let now = now_ms();
            // 生成稳定且不冲突的新 UID，避免撞上原曲目的 UNIQUE(uid)。
            let salt = format!(
                "split:{}:{}:{}:{}:{}",
                track_id.0,
                source_id.0,
                file_id.unwrap_or(0),
                ext_key,
                now
            );
            let new_uid = TrackUid::from_metadata(&salt, "split", "", now.max(0) as u64);

            let new_id: i64 = tx
                .query_row(
                    "INSERT INTO track
                       (uid, title, sort_title, title_sort_key, artist_line, album_id,
                        track_no, disc_no, year, duration_ms, mbid_recording,
                        replaygain_json, quality_badge, artwork_id, created_at, updated_at)
                     SELECT ?1, title, sort_title, title_sort_key, artist_line, album_id,
                            track_no, disc_no, year, duration_ms, NULL,
                            replaygain_json, quality_badge, artwork_id, ?2, ?2
                       FROM track WHERE id = ?3
                     RETURNING id",
                    params![new_uid.0, now, track_id.0],
                    |r| r.get(0),
                )
                .db()?;

            tx.execute(
                "INSERT OR IGNORE INTO track_artist (track_id, artist_id, role, position)
                 SELECT ?1, artist_id, role, position FROM track_artist WHERE track_id = ?2",
                params![new_id, track_id.0],
            )
            .db()?;
            tx.execute(
                "INSERT OR IGNORE INTO track_genre (track_id, genre_id)
                 SELECT ?1, genre_id FROM track_genre WHERE track_id = ?2",
                params![new_id, track_id.0],
            )
            .db()?;

            // 把目标 track_file 移到新曲目。
            if let Some(fid) = file_id {
                tx.execute(
                    "DELETE FROM track_file
                      WHERE track_id = ?1 AND source_id = ?2 AND file_id = ?3",
                    params![track_id.0, source_id.0, fid],
                )
                .db()?;
                tx.execute(
                    "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
                     VALUES (?1, ?2, ?3, '', ?4)",
                    params![new_id, fid, source_id.0, quality_score],
                )
                .db()?;
            } else {
                tx.execute(
                    "DELETE FROM track_file
                      WHERE track_id = ?1 AND source_id = ?2 AND file_id IS NULL
                        AND COALESCE(external_id, '') = ?3",
                    params![track_id.0, source_id.0, ext_key],
                )
                .db()?;
                tx.execute(
                    "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
                     VALUES (?1, NULL, ?2, ?3, ?4)",
                    params![new_id, source_id.0, ext_key, quality_score],
                )
                .db()?;
            }

            refresh_best_quality_badge(&tx, track_id.0)?;
            refresh_best_quality_badge(&tx, new_id)?;
            crate::browse::refresh_track_index(&tx, new_id)?;
            tx.commit().db()?;
            Ok(TrackId(new_id))
        })
        .await
    }

    /// 从资料库移除某一个来源文件副本（`file` + `track_file`），
    /// 若该副本对应的曲目还有其他更高音质来源则只更新音质徽标，否则连带清理孤儿曲目/专辑/艺人。
    pub async fn remove_file_copy(&self, source_id: SourceId, path: String) -> Result<bool> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let file_id: Option<i64> = tx
                .query_row(
                    "SELECT id FROM file WHERE source_id = ?1 AND path = ?2",
                    params![source_id.0, path],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            let Some(file_id) = file_id else {
                return Ok(false);
            };

            let affected_tracks: Vec<i64> = {
                let mut stmt = tx
                    .prepare("SELECT DISTINCT track_id FROM track_file WHERE file_id = ?1")
                    .db()?;
                let rows = stmt.query_map(params![file_id], |r| r.get::<_, i64>(0)).db()?;
                rows.collect::<rusqlite::Result<Vec<_>>>().db()?
            };

            tx.execute("DELETE FROM track_file WHERE file_id = ?1", params![file_id])
                .db()?;
            tx.execute("DELETE FROM file WHERE id = ?1", params![file_id])
                .db()?;

            crate::scanned::sweep_orphans(&tx)?;
            for tid in affected_tracks {
                let still_exists: bool = tx
                    .query_row(
                        "SELECT EXISTS (SELECT 1 FROM track WHERE id = ?1)",
                        params![tid],
                        |r| r.get(0),
                    )
                    .db()?;
                if still_exists {
                    refresh_best_quality_badge(&tx, tid)?;
                    crate::browse::refresh_track_index(&tx, tid)?;
                }
            }
            tx.commit().db()?;
            Ok(true)
        })
        .await
    }
}

fn refresh_best_quality_badge(tx: &Transaction<'_>, track_id: i64) -> Result<()> {
    let best_audio: Option<String> = tx
        .query_row(
            "SELECT f.audio_json
               FROM track_file tf
          LEFT JOIN file f ON f.id = tf.file_id
              WHERE tf.track_id = ?1
           ORDER BY tf.quality_score DESC
              LIMIT 1",
            params![track_id],
            |r| r.get(0),
        )
        .optional()
        .db()?
        .flatten();
    let badge = best_audio
        .as_deref()
        .and_then(|j| serde_json::from_str::<AudioProps>(j).ok())
        .map(|a| a.quality_badge());
    tx.execute(
        "UPDATE track SET quality_badge = ?2 WHERE id = ?1",
        params![track_id, badge],
    )
    .db()?;
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::{RemoteTrackRow, ScannedFile, ScannedTags};
    use lekis_types::{Codec, SourceConfig, TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    async fn add_src(lib: &Library, kind: SourceKind, name: &str) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind,
            name: name.into(),
            addresses: vec!["/music".into()],
            root_path: String::new(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    #[tokio::test]
    async fn merge_and_split_preserve_sources_and_user_data() -> Result<()> {
        let lib = temp_library("unified-merge-split")?;
        let local = add_src(&lib, SourceKind::Local, "本机").await?;
        let nas = add_src(&lib, SourceKind::Smb, "群晖 NAS").await?;
        let server = add_src(&lib, SourceKind::Jellyfin, "Jellyfin").await?;

        // 同一首歌因为时长差 1 秒产生了两条不同的 track。
        lib.upsert_scanned(vec![ScannedFile {
            source_id: local,
            path: "a.flac".into(),
            size: 30_000_000,
            mtime_ms: 1,
            tags: ScannedTags {
                title: "夜曲".into(),
                artists: vec!["周杰伦".into()],
                album: Some("十一月的萧邦".into()),
                duration_ms: 226_000,
                audio: Some(AudioProps {
                    codec: Codec::Flac,
                    sample_rate: 96_000,
                    bit_depth: Some(24),
                    channels: 2,
                    bitrate_kbps: Some(2800),
                }),
                ..Default::default()
            },
        }])
        .await?;
        lib.upsert_scanned(vec![ScannedFile {
            source_id: nas,
            path: "a.mp3".into(),
            size: 8_000_000,
            mtime_ms: 1,
            tags: ScannedTags {
                title: "夜曲".into(),
                artists: vec!["周杰伦".into()],
                album: Some("十一月的萧邦".into()),
                duration_ms: 227_000,
                audio: Some(AudioProps {
                    codec: Codec::Mp3,
                    sample_rate: 44_100,
                    bit_depth: None,
                    channels: 2,
                    bitrate_kbps: Some(320),
                }),
                ..Default::default()
            },
        }])
        .await?;
        // 服务器源和本机完全同元数据 → 自动归并。
        lib.upsert_remote_tracks(
            server,
            vec![RemoteTrackRow {
                external_id: "jf-1".into(),
                title: "夜曲".into(),
                artists: vec!["周杰伦".into()],
                album: Some("十一月的萧邦".into()),
                duration_ms: 226_000,
                mbid_recording: None,
                quality_score: 150,
            }],
        )
        .await?;

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        assert_eq!(rows.len(), 2);
        let flac_id = rows
            .iter()
            .find(|r| r.quality_badge.as_deref() == Some("FLAC 24/96"))
            .unwrap()
            .id;
        let mp3_id = rows.iter().find(|r| r.id != flac_id).unwrap().id;

        // 给待合并的 MP3 打上喜欢并记播放次数，合并后不能丢。
        let mp3_uid = lib.get_track(mp3_id).await?.uid;
        lib.set_loved(mp3_uid.clone(), true).await?;
        lib.record_play(mp3_uid, "dev-1".into(), 200_000, now_ms())
            .await?;

        let merged = lib.merge_tracks(flac_id, vec![mp3_id]).await?;
        assert_eq!(merged, 1);

        let after_rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        assert_eq!(after_rows.len(), 1);
        assert!(after_rows[0].loved, "合并必须继承旧曲目的喜欢状态");

        let sources = lib.track_source_entries(flac_id).await?;
        assert_eq!(
            sources.len(),
            3,
            "本机 FLAC + NAS MP3 + Jellyfin 全部挂在一起"
        );
        assert_eq!(sources[0].source_id, local);
        assert_eq!(sources[0].format.as_deref(), Some("FLAC 24/96"));

        // 把 Jellyfin 那一份拆回独立曲目。
        let jf = sources.iter().find(|s| s.source_id == server).unwrap();
        let split_id = lib
            .split_track_source(flac_id, server, None, jf.external_id.clone())
            .await?;
        assert_ne!(split_id, flac_id);
        assert_eq!(lib.track_source_entries(flac_id).await?.len(), 2);
        assert_eq!(lib.track_source_entries(split_id).await?.len(), 1);

        // 单源曲目不允许再拆。
        let err = lib
            .split_track_source(split_id, server, None, jf.external_id.clone())
            .await
            .unwrap_err();
        assert_eq!(err.code, lekis_types::ErrorCode::InvalidArgument);
        Ok(())
    }
}
