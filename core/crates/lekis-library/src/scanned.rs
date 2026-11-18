//! 扫描结果入库。
//!
//! 扫描器把一批 [`ScannedFile`] 交给 [`Library::upsert_scanned`]，这里负责：
//! 写 `file` 表 → 按规范化名称合并艺人和专辑 → 生成或复用曲目 → 关联 `track_file` → 更新搜索索引。

use crate::db::DbResultExt;
use crate::normalize::{norm_key, search_keys, sort_key};
use crate::Library;
use lekis_types::{now_ms, AudioProps, ReplayGain, Result, SourceId, TrackUid};
use rusqlite::{params, OptionalExtension, Transaction};

/// 从文件标签里读出来的信息（扫描器填充）。
#[derive(Debug, Clone, Default)]
pub struct ScannedTags {
    /// 标题（没有标签时由扫描器用文件名代替）。
    pub title: String,
    /// 曲目艺人（多值标签已经拆分好）。
    pub artists: Vec<String>,
    /// 专辑。
    pub album: Option<String>,
    /// 专辑艺人。
    pub album_artists: Vec<String>,
    /// 曲目号。
    pub track_no: Option<u32>,
    /// 碟片号。
    pub disc_no: Option<u32>,
    /// 年份。
    pub year: Option<i32>,
    /// 流派。
    pub genres: Vec<String>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// MusicBrainz 录音 ID。
    pub mbid_recording: Option<String>,
    /// 音频属性。
    pub audio: Option<AudioProps>,
    /// ReplayGain。
    pub replaygain: ReplayGain,
}

/// 扫描到的一个文件。
#[derive(Debug, Clone)]
pub struct ScannedFile {
    /// 音源。
    pub source_id: SourceId,
    /// 相对路径（`VfsPath` 的字符串形式）。
    pub path: String,
    /// 大小。
    pub size: u64,
    /// 修改时间。
    pub mtime_ms: i64,
    /// 标签。
    pub tags: ScannedTags,
}

/// 入库统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UpsertStats {
    /// 新增文件。
    pub added: u64,
    /// 更新文件。
    pub updated: u64,
}

impl Library {
    /// 批量写入扫描结果（一个事务）。
    pub async fn upsert_scanned(&self, batch: Vec<ScannedFile>) -> Result<UpsertStats> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let mut stats = UpsertStats::default();
            for file in &batch {
                if upsert_one(&tx, file)? {
                    stats.added += 1;
                } else {
                    stats.updated += 1;
                }
            }
            tx.commit().db()?;
            Ok(stats)
        })
        .await
    }

    /// 删除某个音源下 `last_seen_at < before` 的文件（扫描结束后调用，清理已经不存在的文件）。
    pub async fn remove_unseen_files(&self, source_id: SourceId, before: i64) -> Result<u64> {
        self.write(move |conn| {
            let n = conn
                .execute(
                    "DELETE FROM file WHERE source_id = ?1 AND last_seen_at < ?2",
                    params![source_id.0, before],
                )
                .db()?;
            // TODO(LIB-04)：清理没有任何文件的曲目、专辑、艺人，以及对应的搜索索引。
            Ok(n as u64)
        })
        .await
    }
}

/// 返回 `true` 表示新增，`false` 表示更新。
fn upsert_one(tx: &Transaction<'_>, f: &ScannedFile) -> Result<bool> {
    let now = now_ms();
    let t = &f.tags;
    let audio_json = t
        .audio
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .map_err(json_err)?;

    let existing: Option<i64> = tx
        .query_row(
            "SELECT id FROM file WHERE source_id = ?1 AND path = ?2",
            params![f.source_id.0, f.path],
            |r| r.get(0),
        )
        .optional()
        .db()?;
    let is_new = existing.is_none();

    let file_id: i64 = tx
        .query_row(
            "INSERT INTO file (source_id, path, size, mtime_ms, scan_state, audio_json, last_seen_at)
             VALUES (?1, ?2, ?3, ?4, 'tagged', ?5, ?6)
             ON CONFLICT (source_id, path) DO UPDATE SET
               size = excluded.size, mtime_ms = excluded.mtime_ms, scan_state = 'tagged',
               scan_error = NULL, audio_json = excluded.audio_json, last_seen_at = excluded.last_seen_at
             RETURNING id",
            params![f.source_id.0, f.path, f.size as i64, f.mtime_ms, audio_json, now],
            |r| r.get(0),
        )
        .db()?;

    let artist_line = t.artists.join(" / ");
    let album_artist_line = if t.album_artists.is_empty() {
        artist_line.clone()
    } else {
        t.album_artists.join(" / ")
    };

    let album_id = match &t.album {
        Some(title) if !title.trim().is_empty() => {
            Some(upsert_album(tx, title, &album_artist_line, t.year, now)?)
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
    let replaygain_json = serde_json::to_string(&t.replaygain).map_err(json_err)?;
    let quality_badge = t.audio.as_ref().map(AudioProps::quality_badge);

    let track_id: i64 = tx
        .query_row(
            "INSERT INTO track (uid, title, title_sort_key, artist_line, album_id, track_no, disc_no,
                                year, duration_ms, mbid_recording, replaygain_json, quality_badge,
                                created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)
             ON CONFLICT (uid) DO UPDATE SET
               title = excluded.title, title_sort_key = excluded.title_sort_key,
               artist_line = excluded.artist_line, album_id = excluded.album_id,
               track_no = excluded.track_no, disc_no = excluded.disc_no, year = excluded.year,
               duration_ms = excluded.duration_ms, replaygain_json = excluded.replaygain_json,
               quality_badge = excluded.quality_badge, updated_at = excluded.updated_at
             RETURNING id",
            params![
                uid.0,
                t.title,
                sort_key(&t.title),
                artist_line,
                album_id,
                t.track_no,
                t.disc_no,
                t.year,
                t.duration_ms as i64,
                t.mbid_recording,
                replaygain_json,
                quality_badge,
                now
            ],
            |r| r.get(0),
        )
        .db()?;

    // TODO(SRC-13)：quality_score 按编码 / 位深 / 采样率计算，统一资料库选源时用。
    tx.execute(
        "INSERT OR IGNORE INTO track_file (track_id, file_id, source_id, external_id, quality_score)
         VALUES (?1, ?2, ?3, '', 0)",
        params![track_id, file_id, f.source_id.0],
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

fn upsert_album(
    tx: &Transaction<'_>,
    title: &str,
    artist_line: &str,
    year: Option<i32>,
    now: i64,
) -> Result<i64> {
    tx.query_row(
        "INSERT INTO album (title, sort_title, title_norm, artist_line, artist_norm, year, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (title_norm, artist_norm) DO UPDATE SET year = COALESCE(album.year, excluded.year)
         RETURNING id",
        params![title, sort_key(title), norm_key(title), artist_line, norm_key(artist_line), year, now],
        |r| r.get(0),
    )
    .db()
}

fn json_err(e: serde_json::Error) -> lekis_types::LekisError {
    lekis_types::LekisError::internal(format!("json: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use lekis_types::{SourceConfig, SourceKind, TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    fn sample(source_id: SourceId, path: &str, title: &str) -> ScannedFile {
        ScannedFile {
            source_id,
            path: path.into(),
            size: 1000,
            mtime_ms: 1,
            tags: ScannedTags {
                title: title.into(),
                artists: vec!["周杰伦".into()],
                album: Some("叶惠美".into()),
                duration_ms: 269_000,
                ..Default::default()
            },
        }
    }

    #[tokio::test]
    async fn upsert_then_list_and_search() -> Result<()> {
        let lib = temp_library("upsert")?;
        let source_id = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Music".into(),
                addresses: vec!["/music".into()],
                root_path: String::new(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;

        let stats = lib
            .upsert_scanned(vec![
                sample(source_id, "a/晴天.flac", "晴天"),
                sample(source_id, "a/以父之名.flac", "以父之名"),
            ])
            .await?;
        assert_eq!(
            stats,
            UpsertStats {
                added: 2,
                updated: 0
            }
        );

        let again = lib
            .upsert_scanned(vec![sample(source_id, "a/晴天.flac", "晴天")])
            .await?;
        assert_eq!(
            again,
            UpsertStats {
                added: 0,
                updated: 1
            }
        );

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 50,
            })
            .await?;
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.artist_line == "周杰伦"));

        let found = lib.search("晴天", 10).await?;
        assert_eq!(found.tracks.len(), 1);
        Ok(())
    }
}
