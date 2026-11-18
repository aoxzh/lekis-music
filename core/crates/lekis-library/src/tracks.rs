//! 曲目查询。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{
    ArtworkId, LekisError, ReplayGain, Result, Track, TrackId, TrackQuery, TrackRow, TrackSort,
    TrackUid,
};
use rusqlite::{params, Row};

/// 一首歌对应的一个可播放文件。
#[derive(Debug, Clone, PartialEq)]
pub struct TrackFile {
    /// 所在音源。
    pub source_id: lekis_types::SourceId,
    /// 源内路径。
    pub path: String,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// ReplayGain。
    pub replaygain: ReplayGain,
}

const TRACK_ROW_COLUMNS: &str =
    "t.id, t.title, t.artist_line, a.title, t.duration_ms, t.artwork_id,
     t.quality_badge, COALESCE(u.loved, 0)";

pub(crate) fn map_track_row(r: &Row<'_>) -> rusqlite::Result<TrackRow> {
    Ok(TrackRow {
        id: TrackId(r.get(0)?),
        title: r.get(1)?,
        artist_line: r.get(2)?,
        album_title: r.get(3)?,
        duration_ms: r.get::<_, i64>(4)?.max(0) as u64,
        artwork_id: r.get::<_, Option<i64>>(5)?.map(ArtworkId),
        quality_badge: r.get(6)?,
        loved: r.get::<_, i64>(7)? != 0,
    })
}

impl Library {
    /// 分页列出曲目（列表页用）。
    pub async fn list_track_rows(&self, q: TrackQuery) -> Result<Vec<TrackRow>> {
        if q.limit == 0 || q.limit > TrackQuery::MAX_LIMIT {
            return Err(LekisError::invalid(format!(
                "limit must be 1..={}",
                TrackQuery::MAX_LIMIT
            )));
        }
        let order = match q.sort {
            TrackSort::Title => "t.title_sort_key, t.id",
            TrackSort::Artist => "t.artist_line, a.title, t.disc_no, t.track_no",
            TrackSort::Album => "a.title, t.disc_no, t.track_no",
            TrackSort::RecentlyAdded => "t.created_at DESC, t.id DESC",
            TrackSort::MostPlayed => "COALESCE(u.play_count, 0) DESC, t.id",
        };
        let sql = format!(
            "SELECT {TRACK_ROW_COLUMNS}
             FROM track t
             LEFT JOIN album a ON a.id = t.album_id
             LEFT JOIN user_state u ON u.track_uid = t.uid
             ORDER BY {order}
             LIMIT ?1 OFFSET ?2"
        );
        self.read(move |c| {
            let mut stmt = c.prepare_cached(&sql).db()?;
            let rows = stmt
                .query_map(params![q.limit, q.offset], map_track_row)
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 取一首歌的完整信息。
    ///
    /// TODO：艺人署名（track_artist）、流派、音频属性、覆盖层合并。
    pub async fn get_track(&self, id: TrackId) -> Result<Track> {
        self.read(move |c| {
            c.query_row(
                "SELECT t.id, t.uid, t.title, t.sort_title, t.album_id, a.title, t.track_no,
                        t.disc_no, t.year, t.duration_ms, t.mbid_recording, t.replaygain_json,
                        t.artwork_id
                 FROM track t LEFT JOIN album a ON a.id = t.album_id
                 WHERE t.id = ?1",
                params![id.0],
                |r| {
                    let rg: Option<String> = r.get(11)?;
                    Ok(Track {
                        id: TrackId(r.get(0)?),
                        uid: TrackUid(r.get(1)?),
                        title: r.get(2)?,
                        sort_title: r.get(3)?,
                        artists: Vec::new(),
                        album_id: r.get::<_, Option<i64>>(4)?.map(lekis_types::AlbumId),
                        album_title: r.get(5)?,
                        track_no: r.get(6)?,
                        disc_no: r.get(7)?,
                        year: r.get(8)?,
                        duration_ms: r.get::<_, i64>(9)?.max(0) as u64,
                        genres: Vec::new(),
                        mbid_recording: r.get(10)?,
                        audio: None,
                        replaygain: rg
                            .and_then(|s| serde_json::from_str::<ReplayGain>(&s).ok())
                            .unwrap_or_default(),
                        artwork_id: r.get::<_, Option<i64>>(12)?.map(ArtworkId),
                    })
                },
            )
            .db()
        })
        .await
    }

    /// 列出一首歌所有可用的文件（按质量从高到低），播放时由 lekis-core 选源。
    ///
    /// TODO(SRC-13/SRC-14)：结合源的可达性、离线缓存、用户偏好排序。
    pub async fn track_files(&self, id: TrackId) -> Result<Vec<TrackFile>> {
        self.read(move |c| {
            let mut stmt = c
                .prepare_cached(
                    "SELECT tf.source_id, f.path, t.duration_ms, t.replaygain_json
                     FROM track_file tf
                     JOIN track t ON t.id = tf.track_id
                     JOIN file f ON f.id = tf.file_id
                     WHERE tf.track_id = ?1
                     ORDER BY tf.quality_score DESC",
                )
                .db()?;
            let rows = stmt
                .query_map(params![id.0], |r| {
                    let rg: Option<String> = r.get(3)?;
                    Ok(TrackFile {
                        source_id: lekis_types::SourceId(r.get(0)?),
                        path: r.get(1)?,
                        duration_ms: r.get::<_, i64>(2)?.max(0) as u64,
                        replaygain: rg
                            .and_then(|s| serde_json::from_str::<ReplayGain>(&s).ok())
                            .unwrap_or_default(),
                    })
                })
                .db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        })
        .await
    }

    /// 曲目总数。
    pub async fn track_count(&self) -> Result<u64> {
        self.read(|c| {
            c.query_row("SELECT COUNT(*) FROM track", [], |r| r.get::<_, i64>(0))
                .db()
                .map(|n| n as u64)
        })
        .await
    }

    /// 设置收藏状态。
    ///
    /// TODO(SYN-01)：同时写一条同步操作到 `sync_outbox`（由 lekis-core 通过 lekis-sync 完成）。
    pub async fn set_loved(&self, uid: TrackUid, loved: bool) -> Result<()> {
        self.write(move |c| {
            c.execute(
                "INSERT INTO user_state (track_uid, loved) VALUES (?1, ?2)
                 ON CONFLICT (track_uid) DO UPDATE SET loved = excluded.loved",
                params![uid.0, loved as i64],
            )
            .db()?;
            Ok(())
        })
        .await
    }
}
