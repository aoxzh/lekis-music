//! 扫描结果入库。
//!
//! 扫描器把一批 [`ScannedFile`] 交给 [`Library::upsert_scanned`]，这里负责：
//! 写 `file` 表 → 按规范化名称合并艺人和专辑 → 生成或复用曲目 → 关联 `track_file` → 更新搜索索引。

use crate::db::DbResultExt;
use crate::normalize::{norm_key, sort_key};
use crate::Library;
use lekis_types::{now_ms, AudioProps, ReplayGain, Result, SourceId, TrackUid};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// 音质打分（SRC-13）。同一个曲目有多个文件时，`lekis-core` 按这个分数选源。
///
/// 分数只有相对意义：无损 > 有损，位深 / 采样率 / 码率越高越好。范围 0..=1000。
pub fn quality_score(audio: Option<&AudioProps>) -> i64 {
    let Some(a) = audio else {
        // 没有音频属性（例如服务器源只给了标题）：比任何已知的有损文件都低。
        return 10;
    };
    let mut score: i64 = if a.codec.is_lossless() { 600 } else { 200 };
    score += match a.bit_depth {
        Some(b) if b >= 32 => 120,
        Some(b) if b >= 24 => 100,
        Some(b) if b >= 16 => 60,
        Some(_) => 20,
        None => 0,
    };
    score += match a.sample_rate {
        sr if sr >= 192_000 => 180,
        sr if sr >= 96_000 => 140,
        sr if sr >= 88_200 => 120,
        sr if sr >= 48_000 => 80,
        sr if sr > 0 => 40,
        _ => 0,
    };
    if !a.codec.is_lossless() {
        // 有损格式的码率最多再补 200 分（1600kbps 封顶）。
        score += (i64::from(a.bitrate_kbps.unwrap_or(0)) / 8).min(200);
    }
    score.min(1000)
}

/// 从文件标签里读出来的信息（扫描器填充）。
///
/// 可以序列化，这样能原样写进 NAS 共享索引（`lekis-scanner::shared_index` 的
/// `ShardEntry::tags_blob` 就是它的 CBOR 编码）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
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
            let mut relinked = false;
            for file in &batch {
                let outcome = upsert_one(&tx, file)?;
                relinked |= outcome.relinked;
                if outcome.is_new {
                    stats.added += 1;
                } else {
                    stats.updated += 1;
                }
            }
            // 有文件换了曲目（标签改了、或者之前只用文件名兜底），原来的曲目可能成了孤儿。
            if relinked {
                sweep_orphans(&tx)?;
            }
            tx.commit().db()?;
            Ok(stats)
        })
        .await
    }

    /// 刷新一批文件的 `last_seen_at`，不动标签（增量扫描用，LIB-04）。
    ///
    /// `files` 是 `(path, size, mtime_ms)`；`size` / `mtime_ms` 只用于日志和将来的校验，
    /// 这里只更新 `last_seen_at`——因为调用方已经确认这三者都没变。
    ///
    /// 返回真正命中的行数。命中数小于传入条数说明这些文件在库里并没有行
    /// （摘要来自别的设备写的共享索引，或者本地库被重建过）；调用方据此决定要不要真读标签。
    pub async fn touch_files(
        &self,
        source_id: SourceId,
        files: Vec<(String, u64, i64)>,
    ) -> Result<u64> {
        if files.is_empty() {
            return Ok(0);
        }
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            let mut touched = 0u64;
            {
                let mut stmt = tx
                    .prepare_cached(
                        "UPDATE file SET last_seen_at = ?3 WHERE source_id = ?1 AND path = ?2",
                    )
                    .db()?;
                for (path, _size, _mtime_ms) in &files {
                    touched += stmt.execute(params![source_id.0, path, now]).db()? as u64;
                }
            }
            tx.commit().db()?;
            Ok(touched)
        })
        .await
    }

    /// 这个音源里曲目时长为 0 的文件路径。
    ///
    /// 时长 0 基本就是标签没读出来、只用文件名兜底的文件（旧版扫描器读不了
    /// 内嵌大封面的文件）。扫描器对这些文件不走"没变就复用"，而是重读一次。
    pub async fn zero_duration_paths(&self, source_id: SourceId) -> Result<Vec<String>> {
        self.read(move |conn| {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT DISTINCT f.path FROM file f
                     JOIN track_file tf ON tf.file_id = f.id
                     JOIN track t ON t.id = tf.track_id
                     WHERE f.source_id = ?1 AND t.duration_ms <= 0",
                )
                .db()?;
            let rows = stmt
                .query_map(params![source_id.0], |r| r.get::<_, String>(0))
                .db()?;
            rows.collect::<std::result::Result<Vec<_>, _>>().db()
        })
        .await
    }

    /// 读出一个音源下所有已入库文件及其标签（写 NAS 共享索引用，LIB-05）。
    ///
    /// 标签要从 `track` / `artist` / `album` / `genre` 几张表拼回来，所以这里一次读全量。
    pub async fn scannable_files(&self, source_id: SourceId) -> Result<Vec<ScannedFile>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT f.id, f.path, f.size, f.mtime_ms, f.audio_json,
                            t.title, a.title, t.track_no, t.disc_no, t.year,
                            t.duration_ms, t.mbid_recording, t.replaygain_json
                     FROM file f
                     LEFT JOIN track_file tf ON tf.file_id = f.id
                     LEFT JOIN track t ON t.id = tf.track_id
                     LEFT JOIN album a ON a.id = t.album_id
                     WHERE f.source_id = ?1
                     ORDER BY f.path",
                )
                .db()?;
            let mut files: Vec<ScannedFile> = stmt
                .query_map(params![source_id.0], |r| {
                    let audio_json: Option<String> = r.get(4)?;
                    let replaygain_json: Option<String> = r.get(12)?;
                    let audio: Option<AudioProps> = audio_json
                        .as_deref()
                        .and_then(|s| serde_json::from_str(s).ok());
                    let replaygain: ReplayGain = replaygain_json
                        .as_deref()
                        .and_then(|s| serde_json::from_str(s).ok())
                        .unwrap_or_default();
                    let duration_ms = r.get::<_, Option<i64>>(10)?.unwrap_or(0).max(0) as u64;
                    Ok(ScannedFile {
                        source_id,
                        path: r.get(1)?,
                        size: r.get::<_, i64>(2)?.max(0) as u64,
                        mtime_ms: r.get(3)?,
                        tags: ScannedTags {
                            title: r.get::<_, Option<String>>(5)?.unwrap_or_default(),
                            artists: Vec::new(),
                            album: r.get(6)?,
                            album_artists: Vec::new(),
                            track_no: r.get(7)?,
                            disc_no: r.get(8)?,
                            year: r.get(9)?,
                            genres: Vec::new(),
                            duration_ms,
                            mbid_recording: r.get(11)?,
                            audio,
                            replaygain,
                        },
                    })
                })
                .db()?
                .collect::<rusqlite::Result<Vec<_>>>()
                .db()?;

            // 一个文件可能挂在多首曲目上（同一文件被多个曲目引用），按路径去重即可。
            files.sort_by(|a, b| a.path.cmp(&b.path));
            files.dedup_by(|a, b| a.path == b.path);
            if files.is_empty() {
                return Ok(files);
            }

            // 曲目艺人（`role = 'main'`，按 position 排）。
            let mut artists: HashMap<String, Vec<String>> = HashMap::new();
            {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT f.path, ar.name
                         FROM file f
                         JOIN track_file tf ON tf.file_id = f.id
                         JOIN track_artist ta ON ta.track_id = tf.track_id
                         JOIN artist ar ON ar.id = ta.artist_id
                         WHERE f.source_id = ?1 AND ta.role = 'main'
                         ORDER BY f.path, ta.position",
                    )
                    .db()?;
                let rows = stmt
                    .query_map(params![source_id.0], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    })
                    .db()?;
                for row in rows {
                    let (path, name) = row.db()?;
                    artists.entry(path).or_default().push(name);
                }
            }

            // 专辑艺人。
            let mut album_artists: HashMap<String, Vec<String>> = HashMap::new();
            {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT f.path, ar.name
                         FROM file f
                         JOIN track_file tf ON tf.file_id = f.id
                         JOIN track t ON t.id = tf.track_id
                         JOIN album_artist aa ON aa.album_id = t.album_id
                         JOIN artist ar ON ar.id = aa.artist_id
                         WHERE f.source_id = ?1
                         ORDER BY f.path, aa.position",
                    )
                    .db()?;
                let rows = stmt
                    .query_map(params![source_id.0], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    })
                    .db()?;
                for row in rows {
                    let (path, name) = row.db()?;
                    album_artists.entry(path).or_default().push(name);
                }
            }

            // 流派。
            let mut genres: HashMap<String, Vec<String>> = HashMap::new();
            {
                let mut stmt = c
                    .prepare_cached(
                        "SELECT f.path, g.name
                         FROM file f
                         JOIN track_file tf ON tf.file_id = f.id
                         JOIN track_genre tg ON tg.track_id = tf.track_id
                         JOIN genre g ON g.id = tg.genre_id
                         WHERE f.source_id = ?1
                         ORDER BY f.path, g.name",
                    )
                    .db()?;
                let rows = stmt
                    .query_map(params![source_id.0], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    })
                    .db()?;
                for row in rows {
                    let (path, name) = row.db()?;
                    genres.entry(path).or_default().push(name);
                }
            }

            for file in &mut files {
                if let Some(list) = artists.remove(&file.path) {
                    file.tags.artists = list;
                }
                if let Some(list) = album_artists.remove(&file.path) {
                    file.tags.album_artists = list;
                }
                if let Some(list) = genres.remove(&file.path) {
                    file.tags.genres = list;
                }
            }
            Ok(files)
        })
        .await
    }

    /// 删除某个音源下 `last_seen_at < before` 的文件（扫描结束后调用，清理已经不存在的文件）。
    ///
    /// 文件删掉后，可能有曲目 / 专辑 / 艺人变成孤儿，所以紧接着清理空壳并重建搜索索引（LIB-04）。
    pub async fn remove_unseen_files(&self, source_id: SourceId, before: i64) -> Result<u64> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let n = tx
                .execute(
                    "DELETE FROM file WHERE source_id = ?1 AND last_seen_at < ?2",
                    params![source_id.0, before],
                )
                .db()?;
            if n > 0 {
                sweep_orphans(&tx)?;
            }
            tx.commit().db()?;
            Ok(n as u64)
        })
        .await
    }
}

/// 清理孤儿行（LIB-04）：没有任何文件的曲目、没有曲目的专辑、没有曲目 / 专辑的艺人。
///
/// `track_file` / `track_artist` / `album_artist` / `track_genre` 都是 `ON DELETE CASCADE`，
/// 所以删掉 `track` / `album` / `artist` 时关联表会自动收缩；搜索索引是 fts5 虚表，
/// 需要手动按 `ref_id` 删，否则会留下指向不存在的行、搜索时 JOIN 掉但 `MATCH` 仍然命中。
pub(crate) fn sweep_orphans(tx: &Transaction<'_>) -> Result<()> {
    // 顺序很重要：先删实体，再清索引，否则索引里还会指向刚被删掉的行。
    tx.execute(
        "DELETE FROM track WHERE id NOT IN (SELECT track_id FROM track_file)",
        [],
    )
    .db()?;
    // playlist_item 按 track_uid 引用、没有外键；被删掉的曲目在歌单里要显示占位（PL-05），
    // 所以这里故意不动 playlist_item。
    tx.execute(
        "DELETE FROM album
         WHERE id NOT IN (SELECT album_id FROM track WHERE album_id IS NOT NULL)",
        [],
    )
    .db()?;
    tx.execute(
        "DELETE FROM artist
         WHERE id NOT IN (SELECT artist_id FROM track_artist)
           AND id NOT IN (SELECT artist_id FROM album_artist)",
        [],
    )
    .db()?;
    // 按 rowid 编码（ref_id * 4 + 类型码）判断，不读 UNINDEXED 列；整表只扫一遍 rowid。
    tx.execute(
        "DELETE FROM search_index
         WHERE (rowid % 4 = 1 AND rowid / 4 NOT IN (SELECT id FROM track))
            OR (rowid % 4 = 2 AND rowid / 4 NOT IN (SELECT id FROM album))
            OR (rowid % 4 = 3 AND rowid / 4 NOT IN (SELECT id FROM artist))",
        [],
    )
    .db()?;
    Ok(())
}

/// 返回 `true` 表示新增，`false` 表示更新。
/// [`upsert_one`] 的结果。
struct UpsertOutcome {
    /// 这个文件第一次入库。
    is_new: bool,
    /// 文件原来挂在另一首曲目上（标签变了，曲目身份跟着变），已经解开旧的关联。
    relinked: bool,
}

fn upsert_one(tx: &Transaction<'_>, f: &ScannedFile) -> Result<UpsertOutcome> {
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

    // SRC-13：quality_score 按编码 / 位深 / 采样率 / 码率打分，统一资料库选源时按它排序。
    // 同一首歌在同一源上换了文件（file_id 变了）时会新增一行，旧行随 file 级联删除。
    let score = quality_score(t.audio.as_ref());
    tx.execute(
        "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
         VALUES (?1, ?2, ?3, '', ?4)
         ON CONFLICT (track_id, source_id, file_id, external_id)
         DO UPDATE SET quality_score = excluded.quality_score",
        params![track_id, file_id, f.source_id.0, score],
    )
    .db()?;
    // 一个文件只对应一首曲目：标签变了（曲目身份跟着变）时解开旧曲目，
    // 否则旧曲目会和新曲目一起留在列表里。
    let relinked = tx
        .execute(
            "DELETE FROM track_file WHERE file_id = ?1 AND track_id != ?2",
            params![file_id, track_id],
        )
        .db()?
        > 0;

    for (pos, name) in t.artists.iter().enumerate() {
        let artist_id = upsert_artist(tx, name)?;
        tx.execute(
            "INSERT OR IGNORE INTO track_artist (track_id, artist_id, role, position)
             VALUES (?1, ?2, 'main', ?3)",
            params![track_id, artist_id, pos as i64],
        )
        .db()?;
        // 艺人是刚建的话，搜索索引里也要有一行（LIB-07 按艺人搜）。
        crate::browse::ensure_artist_index(tx, artist_id)?;
    }

    // 专辑是刚建的话补上索引行（专辑行只含标题 + 艺人，入库不会改它们）。
    crate::browse::ensure_album_index(tx, album_id)?;

    // 流派（LIB-06：按流派浏览）。
    tx.execute(
        "DELETE FROM track_genre WHERE track_id = ?1",
        params![track_id],
    )
    .db()?;
    for name in &t.genres {
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let genre_id: i64 = tx
            .query_row(
                "INSERT INTO genre (name) VALUES (?1)
                 ON CONFLICT (name) DO UPDATE SET name = genre.name
                 RETURNING id",
                params![name],
                |r| r.get(0),
            )
            .db()?;
        tx.execute(
            "INSERT OR IGNORE INTO track_genre (track_id, genre_id) VALUES (?1, ?2)",
            params![track_id, genre_id],
        )
        .db()?;
    }

    // 重新扫描会覆盖原始标签，但用户的手工覆盖层仍然优先：统一走
    // `refresh_track_index`，它会读取 overlay / tag_overrides。
    crate::browse::refresh_track_index(tx, track_id)?;

    Ok(UpsertOutcome { is_new, relinked })
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

    /// 同一首歌的两个文件（同一源）都能入库：track 合并成一行，track_file 各留一行。
    /// 回归：0002 的部分唯一索引曾把本地行的空 external_id 也算进去，第二次插入就会
    /// 撞上 `UNIQUE constraint failed: track_file.track_id, track_file.source_id,
    /// track_file.external_id` 并让整次扫描回滚。
    #[tokio::test]
    async fn same_track_from_two_files_is_allowed() -> Result<()> {
        let lib = temp_library("two-files")?;
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

        lib.upsert_scanned(vec![
            sample(source_id, "a/晴天.flac", "晴天"),
            sample(source_id, "b/晴天.flac", "晴天"),
        ])
        .await?;

        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 50,
            })
            .await?;
        assert_eq!(rows.len(), 1, "同一首歌只应有一条 track");
        Ok(())
    }

    /// `touch_files` 只刷新 `last_seen_at`：命中的行数正确，标签不变，空批次是 0。
    #[tokio::test]
    async fn touch_files_only_refreshes_last_seen() -> Result<()> {
        let lib = temp_library("touch")?;
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
        lib.upsert_scanned(vec![
            sample(source_id, "a/one.flac", "一"),
            sample(source_id, "a/two.flac", "二"),
        ])
        .await?;

        assert_eq!(lib.touch_files(source_id, Vec::new()).await?, 0);

        let touched = lib
            .touch_files(
                source_id,
                vec![
                    ("a/one.flac".into(), 1000, 1),
                    ("a/two.flac".into(), 1000, 1),
                    ("a/missing.flac".into(), 1, 1),
                ],
            )
            .await?;
        assert_eq!(touched, 2, "缺失的文件不算命中");

        // 标签没被动过：列表里还是原来的两个标题。
        let rows = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 50,
            })
            .await?;
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|r| r.title == "一"));
        assert!(rows.iter().any(|r| r.title == "二"));

        // touch 之后立刻 remove_unseen_files(旧时间戳) 不会删掉它们。
        assert_eq!(lib.remove_unseen_files(source_id, 0).await?, 0);
        Ok(())
    }

    /// `scannable_files` 把曲目标签拼回 `ScannedFile`（写共享索引用）。
    #[tokio::test]
    async fn scannable_files_roundtrips_tags() -> Result<()> {
        let lib = temp_library("scannable")?;
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
        lib.upsert_scanned(vec![
            sample(source_id, "a/晴天.flac", "晴天"),
            sample(source_id, "b/以父之名.flac", "以父之名"),
        ])
        .await?;

        let files = lib.scannable_files(source_id).await?;
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "a/晴天.flac");
        assert_eq!(files[0].source_id, source_id);
        assert_eq!(files[0].size, 1000);
        assert_eq!(files[0].mtime_ms, 1);
        assert_eq!(files[0].tags.title, "晴天");
        assert_eq!(files[0].tags.artists, vec!["周杰伦".to_string()]);
        assert_eq!(files[0].tags.album.as_deref(), Some("叶惠美"));
        assert_eq!(files[0].tags.duration_ms, 269_000);
        assert_eq!(files[1].path, "b/以父之名.flac");

        // 别的音源的文件不会混进来。
        let other = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "Other".into(),
                addresses: vec!["/other".into()],
                root_path: String::new(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        assert!(lib.scannable_files(other).await?.is_empty());
        Ok(())
    }
}
