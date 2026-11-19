//! 歌词（ENR-03 / ENR-07）。
//!
//! 一首歌可以有多份歌词（内嵌、sidecar、LRCLIB、插件……），但**同时只有一份生效**：
//! `lyrics.is_active` 标记生效的那份，其余留作备选。写入时优先级高的来源会顶掉低优先级的，
//! 但用户手动调整过的偏移（`offset_ms`）在切换来源时保留。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{now_ms, Lyrics, LyricsFormat, Result, TrackId, TrackUid};
use rusqlite::{params, OptionalExtension};

/// 歌词来源的优先级（数值越大越优先）。同优先级按置信度、再按入库时间取新的。
fn source_rank(source: &str) -> i64 {
    let base = source.split(':').next().unwrap_or(source);
    match base {
        "embedded" => 100,
        "sidecar" => 90,
        "manual" => 80,
        "plugin" => 50,
        "lrclib" => 40,
        "server" => 30,
        _ => 10,
    }
}

/// 一条歌词记录（含本机 ID 与生效标记）。
#[derive(Debug, Clone, PartialEq)]
pub struct LyricsRow {
    /// 本机 ID。
    pub id: i64,
    /// 归属曲目。
    pub track_id: TrackId,
    /// 歌词本身。
    pub lyrics: Lyrics,
    /// 是否生效。
    pub is_active: bool,
    /// 入库时间（Unix 毫秒）。
    pub created_at: i64,
}

/// 数据库里存的字符串（snake_case）。
fn format_to_db(format: LyricsFormat) -> &'static str {
    match format {
        LyricsFormat::Plain => "plain",
        LyricsFormat::Lrc => "lrc",
        LyricsFormat::EnhancedLrc => "enhanced_lrc",
        LyricsFormat::Ttml => "ttml",
    }
}

/// 未知值按纯文本处理（向前兼容）。
fn format_from_db(value: &str) -> LyricsFormat {
    match value {
        "lrc" => LyricsFormat::Lrc,
        "enhanced_lrc" => LyricsFormat::EnhancedLrc,
        "ttml" => LyricsFormat::Ttml,
        _ => LyricsFormat::Plain,
    }
}

fn map_lyrics_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<LyricsRow> {
    let format: String = r.get(2)?;
    let confidence: f64 = r.get(6)?;
    Ok(LyricsRow {
        id: r.get(0)?,
        track_id: TrackId(r.get(1)?),
        lyrics: Lyrics {
            format: format_from_db(&format),
            content: r.get(3)?,
            source: r.get(4)?,
            offset_ms: r.get::<_, i64>(5)?.clamp(i32::MIN as i64, i32::MAX as i64) as i32,
            confidence: confidence as f32,
        },
        is_active: r.get::<_, i64>(7)? != 0,
        created_at: r.get(8)?,
    })
}

impl Library {
    /// 写入一份歌词，并在它该生效时把同曲目的其它歌词置为非生效。
    ///
    /// 生效规则（ENR-03）：来源优先级高者胜；同优先级比置信度；再相同则保留原有的那一份
    /// （避免重复刮削时反复覆盖用户看到的内容）。返回写入行的 ID。
    pub async fn save_lyrics(&self, track: TrackId, lyrics: Lyrics) -> Result<i64> {
        if lyrics.content.trim().is_empty() {
            return Err(lekis_types::LekisError::invalid(
                "lyrics content must not be empty",
            ));
        }
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            // 当前生效的那份（用于比较优先级）。
            let current: Option<(i64, String, f64)> = tx
                .query_row(
                    "SELECT id, source, confidence FROM lyrics
                     WHERE track_id = ?1 AND is_active = 1
                     ORDER BY created_at DESC, id DESC LIMIT 1",
                    params![track.0],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()
                .db()?;

            let wins = match &current {
                None => true,
                Some((_, src, conf)) => {
                    let new_rank = source_rank(&lyrics.source);
                    let old_rank = source_rank(src);
                    if new_rank != old_rank {
                        new_rank > old_rank
                    } else if (lyrics.confidence as f64 - conf).abs() > f64::EPSILON {
                        lyrics.confidence as f64 > *conf
                    } else {
                        false
                    }
                }
            };

            if wins {
                tx.execute(
                    "UPDATE lyrics SET is_active = 0 WHERE track_id = ?1 AND is_active = 1",
                    params![track.0],
                )
                .db()?;
            }
            tx.execute(
                "INSERT INTO lyrics (track_id, format, content, source, offset_ms, confidence,
                                     is_active, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    track.0,
                    format_to_db(lyrics.format),
                    lyrics.content,
                    lyrics.source,
                    lyrics.offset_ms as i64,
                    lyrics.confidence as f64,
                    if wins { 1 } else { 0 },
                    now
                ],
            )
            .db()?;
            let id = tx.last_insert_rowid();
            tx.commit().db()?;
            Ok(id)
        })
        .await
    }

    /// 取一首歌当前生效的歌词；没有返回 `None`。
    pub async fn active_lyrics(&self, track: TrackId) -> Result<Option<Lyrics>> {
        self.read(move |c| {
            c.query_row(
                "SELECT id, track_id, format, content, source, offset_ms, confidence, is_active, created_at
                 FROM lyrics WHERE track_id = ?1 AND is_active = 1
                 ORDER BY created_at DESC, id DESC LIMIT 1",
                params![track.0],
                map_lyrics_row,
            )
            .optional()
            .db()
            .map(|v| v.map(|r| r.lyrics))
        })
        .await
    }

    /// 列出一首歌所有歌词（含未生效的备选），按来源优先级从高到低。
    pub async fn list_lyrics(&self, track: TrackId) -> Result<Vec<LyricsRow>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT id, track_id, format, content, source, offset_ms, confidence, is_active,
                            created_at
                     FROM lyrics WHERE track_id = ?1",
                )
                .db()?;
            let rows = stmt.query_map(params![track.0], map_lyrics_row).db()?;
            let mut out = rows.collect::<rusqlite::Result<Vec<_>>>().db()?;
            out.sort_by(|a, b| {
                source_rank(&b.lyrics.source)
                    .cmp(&source_rank(&a.lyrics.source))
                    .then(b.lyrics.confidence.total_cmp(&a.lyrics.confidence))
                    .then(b.id.cmp(&a.id))
            });
            Ok(out)
        })
        .await
    }

    /// 指定某一份歌词为生效（用户在"手动选择歌词"里切换）。
    pub async fn activate_lyrics(&self, track: TrackId, lyrics_id: i64) -> Result<()> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let exists: Option<i64> = tx
                .query_row(
                    "SELECT id FROM lyrics WHERE id = ?1 AND track_id = ?2",
                    params![lyrics_id, track.0],
                    |r| r.get(0),
                )
                .optional()
                .db()?;
            if exists.is_none() {
                return Err(lekis_types::LekisError::not_found(format!(
                    "lyrics {lyrics_id} of track {track}"
                )));
            }
            tx.execute(
                "UPDATE lyrics SET is_active = 0 WHERE track_id = ?1 AND is_active = 1",
                params![track.0],
            )
            .db()?;
            tx.execute(
                "UPDATE lyrics SET is_active = 1 WHERE id = ?1",
                params![lyrics_id],
            )
            .db()?;
            tx.commit().db()?;
            Ok(())
        })
        .await
    }

    /// 调整生效歌词的整体偏移（ENR-07，正数表示歌词延后）。
    pub async fn set_lyrics_offset(&self, track: TrackId, offset_ms: i32) -> Result<()> {
        self.write(move |c| {
            let n = c
                .execute(
                    "UPDATE lyrics SET offset_ms = ?2 WHERE track_id = ?1 AND is_active = 1",
                    params![track.0, offset_ms as i64],
                )
                .db()?;
            if n == 0 {
                return Err(lekis_types::LekisError::not_found(format!(
                    "active lyrics of track {track}"
                )));
            }
            Ok(())
        })
        .await
    }

    /// 删除一首歌的全部歌词（重新刮削前清理）。
    pub async fn clear_lyrics(&self, track: TrackId) -> Result<u64> {
        self.write(move |c| {
            let n = c
                .execute("DELETE FROM lyrics WHERE track_id = ?1", params![track.0])
                .db()?;
            Ok(n as u64)
        })
        .await
    }

    /// 按曲目 UID 取生效歌词（同步 / FFI 用，避免先查一次 ID）。
    pub async fn active_lyrics_by_uid(&self, uid: TrackUid) -> Result<Option<Lyrics>> {
        let id = self
            .read(move |c| {
                c.query_row("SELECT id FROM track WHERE uid = ?1", params![uid.0], |r| {
                    r.get::<_, i64>(0)
                })
                .optional()
                .db()
            })
            .await?;
        match id {
            Some(id) => self.active_lyrics(TrackId(id)).await,
            None => Ok(None),
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::test_util::temp_library;
    use crate::ScannedFile;
    use lekis_types::{SourceConfig, SourceId, SourceKind};
    use std::collections::BTreeMap;

    async fn seed(lib: &Library) -> Result<TrackId> {
        let source = lib
            .add_source(SourceConfig {
                id: None,
                kind: SourceKind::Local,
                name: "local".into(),
                addresses: vec![],
                root_path: "/music".into(),
                credential_ref: None,
                options: BTreeMap::new(),
                enabled: true,
            })
            .await?;
        seed_file(lib, source).await
    }

    async fn seed_file(lib: &Library, source: SourceId) -> Result<TrackId> {
        lib.upsert_scanned(vec![ScannedFile {
            source_id: source,
            path: "a.flac".into(),
            size: 1,
            mtime_ms: 1,
            tags: crate::ScannedTags {
                title: "晴天".into(),
                artists: vec!["周杰伦".into()],
                album: Some("叶惠美".into()),
                duration_ms: 1000,
                ..Default::default()
            },
        }])
        .await?;
        Ok(lib
            .list_track_rows(lekis_types::TrackQuery {
                sort: lekis_types::TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?[0]
            .id)
    }

    fn lyrics(source: &str, format: LyricsFormat, content: &str, confidence: f32) -> Lyrics {
        Lyrics {
            format,
            content: content.into(),
            source: source.into(),
            offset_ms: 0,
            confidence,
        }
    }

    #[tokio::test]
    async fn higher_priority_source_wins_and_keeps_history() -> Result<()> {
        let lib = temp_library("lyrics")?;
        let track = seed(&lib).await?;

        let low = lib
            .save_lyrics(
                track,
                lyrics("lrclib", LyricsFormat::Lrc, "[00:01.00]晴天", 0.9),
            )
            .await?;
        assert!(lib.active_lyrics(track).await?.is_some());

        // sidecar 优先级更高 → 顶掉 lrclib。
        let high = lib
            .save_lyrics(
                track,
                lyrics("sidecar", LyricsFormat::Lrc, "[00:01.00]同目录歌词", 0.5),
            )
            .await?;
        let active = lib.active_lyrics(track).await?.expect("有生效歌词");
        assert_eq!(active.source, "sidecar");
        assert_eq!(lib.list_lyrics(track).await?.len(), 2, "旧歌词保留作备选");

        // 同优先级但置信度更低 → 不顶掉。
        lib.save_lyrics(
            track,
            lyrics("sidecar", LyricsFormat::Plain, "更低置信度", 0.2),
        )
        .await?;
        assert_eq!(
            lib.active_lyrics(track).await?.map(|l| l.content),
            Some("[00:01.00]同目录歌词".to_string())
        );

        // 用户手动切回 lrclib。
        lib.activate_lyrics(track, low).await?;
        assert_eq!(
            lib.active_lyrics(track).await?.map(|l| l.source),
            Some("lrclib".to_string())
        );

        // 偏移只改生效的那份。
        lib.set_lyrics_offset(track, -500).await?;
        assert_eq!(
            lib.active_lyrics(track).await?.map(|l| l.offset_ms),
            Some(-500)
        );
        let rows = lib.list_lyrics(track).await?;
        assert_eq!(rows.len(), 3, "三份都留作备选");
        // sidecar(90) 的两份排在 lrclib(40) 前面，同来源按置信度从高到低。
        assert_eq!(rows[0].id, high, "sidecar 0.5 置信度排第一");
        assert!(rows[1].lyrics.source == "sidecar" && rows[1].lyrics.confidence < 0.5);
        assert_eq!(rows[2].id, low, "lrclib 优先级最低，排最后");
        assert!(rows[2].is_active, "用户手动切回的这份是生效的");
        assert_eq!(rows[2].lyrics.offset_ms, -500);
        assert!(!rows[0].is_active && !rows[1].is_active);
        assert_eq!(rows[0].lyrics.offset_ms, 0);

        // 空内容拒绝，切到不存在的行报 not_found，清理后为空。
        assert_eq!(
            lib.save_lyrics(track, lyrics("lrclib", LyricsFormat::Plain, "  ", 1.0))
                .await
                .unwrap_err()
                .code,
            lekis_types::ErrorCode::InvalidArgument
        );
        assert_eq!(
            lib.activate_lyrics(track, 9_999).await.unwrap_err().code,
            lekis_types::ErrorCode::NotFound
        );
        assert_eq!(lib.clear_lyrics(track).await?, 3);
        assert!(lib.active_lyrics(track).await?.is_none());
        assert_eq!(
            lib.set_lyrics_offset(track, 0).await.unwrap_err().code,
            lekis_types::ErrorCode::NotFound
        );
        Ok(())
    }

    #[tokio::test]
    async fn lyrics_lookup_by_uid() -> Result<()> {
        let lib = temp_library("lyrics-uid")?;
        let track = seed(&lib).await?;
        let uid = lib.get_track(track).await?;
        lib.save_lyrics(
            track,
            lyrics("embedded", LyricsFormat::Plain, "内嵌歌词", 1.0),
        )
        .await?;
        assert_eq!(
            lib.active_lyrics_by_uid(uid.uid.clone())
                .await?
                .map(|l| l.content),
            Some("内嵌歌词".to_string())
        );
        assert!(lib
            .active_lyrics_by_uid(lekis_types::TrackUid("nope".into()))
            .await?
            .is_none());
        Ok(())
    }
}
