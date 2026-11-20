//! 「在其他设备上播放」的曲目匹配（CST-03）。
//!
//! 控制端把队列里的曲目描述（跨设备 ID、所在音源和路径）发给被控端，被控端用这里的查询
//! 在**自己的**资料库里找同一首歌：先按具体文件（同一个音源上的同一路径 / 服务器 ID），
//! 再按跨设备稳定 ID（`TrackUid`）、MusicBrainz 录音 ID。

use crate::db::DbResultExt;
use crate::Library;
use lekis_types::{Result, SourceId, TrackId};
use rusqlite::{params, OptionalExtension};

impl Library {
    /// 按跨设备 ID 找本机曲目。
    pub async fn find_track_by_uid(&self, uid: &str) -> Result<Option<TrackId>> {
        let uid = uid.to_string();
        self.read(move |c| {
            c.query_row("SELECT id FROM track WHERE uid = ?1", params![uid], |r| {
                r.get::<_, i64>(0)
            })
            .optional()
            .db()
            .map(|id| id.map(TrackId))
        })
        .await
    }

    /// 按 MusicBrainz 录音 ID 找本机曲目（不区分大小写）。
    pub async fn find_track_by_mbid(&self, mbid: &str) -> Result<Option<TrackId>> {
        let mbid = mbid.trim().to_ascii_lowercase();
        if mbid.is_empty() {
            return Ok(None);
        }
        self.read(move |c| {
            c.query_row(
                "SELECT id FROM track WHERE lower(mbid_recording) = ?1 ORDER BY id LIMIT 1",
                params![mbid],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .db()
            .map(|id| id.map(TrackId))
        })
        .await
    }

    /// 文件系统类音源上某个路径对应的曲目（已扫描时）。
    pub async fn find_track_by_file(
        &self,
        source_id: SourceId,
        path: &str,
    ) -> Result<Option<TrackId>> {
        let path = path.to_string();
        self.read(move |c| {
            c.query_row(
                "SELECT tf.track_id FROM track_file tf JOIN file f ON f.id = tf.file_id
                 WHERE f.source_id = ?1 AND f.path = ?2 LIMIT 1",
                params![source_id.0, path],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .db()
            .map(|id| id.map(TrackId))
        })
        .await
    }

    /// 服务器类音源里某个条目 ID 对应的曲目（已同步时）。
    pub async fn find_track_by_external(
        &self,
        source_id: SourceId,
        external_id: &str,
    ) -> Result<Option<TrackId>> {
        let external_id = external_id.to_string();
        self.read(move |c| {
            c.query_row(
                "SELECT track_id FROM track_file WHERE source_id = ?1 AND external_id = ?2 LIMIT 1",
                params![source_id.0, external_id],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .db()
            .map(|id| id.map(TrackId))
        })
        .await
    }
}
