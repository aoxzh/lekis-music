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
    /// Opaque album identity scoped to this source.
    pub external_album_id: Option<String>,
    /// Album-level artists.
    pub album_artists: Vec<String>,
    /// Disc and track position.
    pub disc_no: Option<u32>,
    /// Track number within the disc.
    pub track_no: Option<u32>,
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
    /// Server references for an album, scoped by source.
    pub async fn remote_album_sources(&self, id: lekis_types::AlbumId) -> Result<Vec<(SourceId, String)>> {
        self.read(move |c| {
            let mut stmt = c.prepare("SELECT source_id, external_id FROM remote_album WHERE album_id = ?1 ORDER BY source_id").db()?;
            let rows = stmt.query_map(params![id.0], |r| Ok((SourceId(r.get(0)?), r.get(1)?))).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        }).await
    }

    /// Track image candidates for a server album, in disc order.
    pub async fn remote_album_track_ids(&self, album: lekis_types::AlbumId, source: SourceId) -> Result<Vec<String>> {
        self.read(move |c| {
            let mut stmt = c.prepare("SELECT f.external_id FROM track t JOIN track_file f ON f.track_id = t.id WHERE t.album_id = ?1 AND f.source_id = ?2 AND f.external_id IS NOT NULL ORDER BY t.disc_no, t.track_no, t.title_sort_key LIMIT 3").db()?;
            let rows = stmt.query_map(params![album.0, source.0], |r| r.get(0)).db()?;
            rows.collect::<rusqlite::Result<Vec<_>>>().db()
        }).await
    }

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
                if upsert_remote_one(&tx, source_id, t, now, None)? {
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

    /// Append plugin search results without pruning songs referenced by queues or playlists.
    /// Returns rows in provider order, with stable local IDs.
    pub async fn append_plugin_tracks(
        &self,
        source_id: SourceId,
        tracks: Vec<RemoteTrackRow>,
    ) -> Result<Vec<lekis_types::TrackRow>> {
        self.write(move |conn| {
            let tx = conn.transaction().db()?;
            let now = now_ms();
            let plugin_id: String = tx
                .query_row(
                    "SELECT root_path FROM source WHERE id = ?1",
                    params![source_id.0],
                    |r| r.get(0),
                )
                .db()?;
            let mut rows = Vec::new();
            for track in tracks {
                upsert_remote_one(&tx, source_id, &track, now, Some(&plugin_id))?;
                let sql = format!(
                    "SELECT {} FROM track t
                    LEFT JOIN album a ON a.id = t.album_id
                    LEFT JOIN user_state u ON u.track_uid = t.uid
                    JOIN track_file tf ON tf.track_id = t.id
                    WHERE tf.source_id = ?1 AND tf.external_id = ?2 LIMIT 1",
                    crate::tracks::TRACK_ROW_COLUMNS
                );
                rows.push(
                    tx.query_row(
                        &sql,
                        params![source_id.0, track.external_id],
                        crate::tracks::map_track_row,
                    )
                    .db()?,
                );
            }
            tx.commit().db()?;
            Ok(rows)
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
    plugin_identity: Option<&str>,
) -> Result<bool> {
    let existed: Option<i64> = tx.query_row(
        "SELECT track_id FROM track_file WHERE source_id = ?1 AND external_id = ?2 LIMIT 1",
        params![source_id.0, t.external_id], |r| r.get(0),
    ).ok();
    let artist_line = t.artists.join(" / ");
    let album_artist_line = if t.album_artists.is_empty() { artist_line.clone() } else { t.album_artists.join(" / ") };
    let album_id = match &t.album {
        Some(title) if !title.trim().is_empty() => {
            let id = if let Some(external_id) = t.external_album_id.as_deref().filter(|id| !id.is_empty()) {
                upsert_remote_album(tx, source_id, external_id, title, &album_artist_line, now, existed)?
            } else { upsert_album(tx, title, &album_artist_line, now)? };
            if !t.album_artists.is_empty() {
                tx.execute("DELETE FROM album_artist WHERE album_id = ?1", params![id]).db()?;
            }
            for (pos, name) in t.album_artists.iter().enumerate() {
                let artist_id = upsert_artist(tx, name)?;
                tx.execute("INSERT OR IGNORE INTO album_artist (album_id, artist_id, position) VALUES (?1, ?2, ?3)", params![id, artist_id, pos as i64]).db()?;
            }
            Some(id)
        }
        _ => None,
    };

    // A plugin may enrich metadata on a later browse/search. Its remote identity
    // must not change along with duration, artist or title (queue and user state).
    let uid = if let Some(plugin_id) = plugin_identity {
        // Provider IDs are opaque and case-sensitive (e.g. video IDs). Encode
        // their bytes without metadata normalization; plugin IDs are portable
        // across devices, unlike the local numeric source ID.
        TrackUid(format!(
            "plugin:{plugin_id}:{}",
            percent_encoding::utf8_percent_encode(
                &t.external_id,
                percent_encoding::NON_ALPHANUMERIC
            )
        ))
    } else if t.external_album_id.is_some() {
        let previous_uid: Option<String> = if let Some(id) = existed {
            tx.query_row("SELECT uid FROM track WHERE id = ?1 AND (SELECT COUNT(*) FROM track_file WHERE track_id = ?1) = 1", params![id], |r| r.get(0)).ok()
        } else { None };
        TrackUid(previous_uid.unwrap_or_else(|| format!("server:{}:{}", source_id.0, percent_encoding::utf8_percent_encode(&t.external_id, percent_encoding::NON_ALPHANUMERIC))))
    } else {
        match &t.mbid_recording {
            Some(mbid) => TrackUid::from_mbid(mbid),
            None => TrackUid::from_metadata(
                &artist_line,
                &t.title,
                t.album.as_deref().unwrap_or(""),
                t.duration_ms,
            ),
        }
    };

    let is_new = existed.is_none();

    let track_id: i64 = tx
        .query_row(
            "INSERT INTO track (uid, title, title_sort_key, artist_line, album_id, duration_ms,
                                mbid_recording, created_at, updated_at, disc_no, track_no)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?10)
             ON CONFLICT (uid) DO UPDATE SET
               title = excluded.title, title_sort_key = excluded.title_sort_key,
               artist_line = excluded.artist_line, album_id = excluded.album_id,
               duration_ms = excluded.duration_ms, updated_at = excluded.updated_at,
               disc_no = excluded.disc_no, track_no = excluded.track_no
             RETURNING id",
            params![
                uid.0,
                t.title,
                sort_key(&t.title),
                artist_line,
                album_id,
                t.duration_ms as i64,
                t.mbid_recording,
                now,
                t.disc_no,
                t.track_no
            ],
            |r| r.get(0),
        )
        .db()?;

    if let Some(old_id) = existed.filter(|old| *old != track_id) {
        // The original may still serve another source. Copy user edits rather
        // than moving them away from that shared track.
        tx.execute("INSERT OR IGNORE INTO user_state (track_uid, loved, rating, play_count, last_played, updated_hlc) SELECT new.uid, u.loved, u.rating, u.play_count, u.last_played, u.updated_hlc FROM track old JOIN user_state u ON u.track_uid = old.uid JOIN track new ON new.id = ?2 WHERE old.id = ?1", params![old_id, track_id]).db()?;
        tx.execute("UPDATE track SET overlay_json = COALESCE(overlay_json, (SELECT overlay_json FROM track WHERE id = ?1)), tag_overrides_json = COALESCE(tag_overrides_json, (SELECT tag_overrides_json FROM track WHERE id = ?1)), artwork_id = COALESCE(artwork_id, (SELECT artwork_id FROM track WHERE id = ?1)) WHERE id = ?2", params![old_id, track_id]).db()?;
        tx.execute("INSERT INTO lyrics (track_id, format, content, source, offset_ms, confidence, is_active, created_at) SELECT ?2, format, content, source, offset_ms, confidence, is_active, created_at FROM lyrics WHERE track_id = ?1 AND NOT EXISTS (SELECT 1 FROM lyrics WHERE track_id = ?2)", params![old_id, track_id]).db()?;
        tx.execute("DELETE FROM track_file WHERE track_id = ?1 AND source_id = ?2 AND external_id = ?3", params![old_id, source_id.0, t.external_id]).db()?;
    }

    tx.execute(
        "INSERT INTO track_file (track_id, file_id, source_id, external_id, quality_score)
         VALUES (?1, NULL, ?2, ?3, ?4)
         ON CONFLICT (track_id, source_id, external_id)
           WHERE external_id IS NOT NULL AND external_id <> ''
         DO UPDATE SET quality_score = excluded.quality_score",
        params![track_id, source_id.0, t.external_id, t.quality_score],
    )
    .db()?;

    tx.execute(
        "DELETE FROM track_artist WHERE track_id = ?1 AND role = 'main'",
        params![track_id],
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

    let keys = search_keys(&[&t.title, &artist_line, t.album.as_deref().unwrap_or("")]);
    crate::browse::write_index_row(
        tx,
        crate::browse::INDEX_TRACK,
        track_id,
        &t.title,
        &artist_line,
        &keys,
        true,
    )?;

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

fn upsert_remote_album(tx: &Transaction<'_>, source_id: SourceId, external_id: &str, title: &str, artist_line: &str, now: i64, old_track: Option<i64>) -> Result<i64> {
    let identity_key = format!("remote:{}:{}", source_id.0, external_id.as_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>());
    let existing: Option<i64> = tx.query_row("SELECT album_id FROM remote_album WHERE source_id = ?1 AND external_id = ?2", params![source_id.0, external_id], |r| r.get(0)).ok();
    if let Some(id) = existing {
        tx.execute("UPDATE album SET title = ?1, sort_title = ?2, artist_line = ?3, title_norm = ?4, artist_norm = ?5 WHERE id = ?6", params![title, sort_key(title), artist_line, identity_key, norm_key(artist_line), id]).db()?;
        return Ok(id);
    }
    // Adopt an unmapped legacy album only if every file belongs to this source.
    // This keeps its ID and manual artwork on the first rescan without claiming
    // an album shared with a local library or another server.
    let legacy: Option<i64> = old_track.and_then(|track| tx.query_row(
        "SELECT a.id FROM track t JOIN album a ON a.id = t.album_id WHERE t.id = ?1
         AND NOT EXISTS (SELECT 1 FROM remote_album r WHERE r.album_id = a.id)
         AND NOT EXISTS (SELECT 1 FROM track other JOIN track_file f ON f.track_id = other.id WHERE other.album_id = a.id AND f.source_id <> ?2)",
        params![track, source_id.0], |r| r.get(0)).ok());
    if let Some(id) = legacy {
        tx.execute("INSERT INTO remote_album (source_id, external_id, album_id) VALUES (?1, ?2, ?3)", params![source_id.0, external_id, id]).db()?;
        tx.execute("UPDATE album SET title = ?1, sort_title = ?2, artist_line = ?3, title_norm = ?4, artist_norm = ?5 WHERE id = ?6", params![title, sort_key(title), artist_line, identity_key, norm_key(artist_line), id]).db()?;
        return Ok(id);
    }
    let id: i64 = tx.query_row("INSERT INTO album (title, sort_title, title_norm, artist_line, artist_norm, created_at, artwork_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, (SELECT a.artwork_id FROM track t JOIN album a ON a.id = t.album_id WHERE t.id = ?7)) RETURNING id", params![title, sort_key(title), identity_key, artist_line, norm_key(artist_line), now, old_track], |r| r.get(0)).db()?;
    tx.execute("INSERT INTO remote_album (source_id, external_id, album_id) VALUES (?1, ?2, ?3)", params![source_id.0, external_id, id]).db()?;
    Ok(id)
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
            external_album_id: None, album_artists: vec![], disc_no: None, track_no: None,
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
    async fn remote_album_identity_keeps_compilations_and_releases_separate() -> Result<()> {
        let lib = temp_library("remote-album-identities")?;
        let src = server_source(&lib).await?;
        let mut a = row("1", "Second disc");
        a.external_album_id = Some("release-a".into());
        a.album_artists = vec!["Various Artists".into()];
        a.artists = vec!["Singer A".into()];
        a.disc_no = Some(2); a.track_no = Some(1);
        let mut b = a.clone(); b.external_id = "2".into(); b.title = "First disc".into(); b.artists = vec!["Singer B".into()]; b.disc_no = Some(1);
        let mut c = a.clone(); c.external_id = "3".into(); c.title = "Other release".into(); c.external_album_id = Some("release-b".into());
        lib.upsert_remote_tracks(src, vec![a.clone(), b.clone(), c]).await?;
        let albums = lib.list_albums(lekis_types::TrackSort::Title, 0, 20).await?;
        assert_eq!(albums.len(), 2);
        let album = albums.iter().find(|x| x.track_count == 2).expect("compilation");
        assert_eq!(album.artist_line, "Various Artists");
        let tracks = lib.album_tracks(album.id, 0, 20).await?;
        assert_eq!(tracks.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["First disc", "Second disc"]);
        assert_eq!(lib.album_artists(album.id).await?[0].name, "Various Artists");
        lib.upsert_remote_tracks(src, vec![a, b]).await?;
        assert_eq!(lib.album_tracks(album.id, 0, 20).await?.len(), 2);
        Ok(())
    }

    #[tokio::test]
    async fn external_album_ids_are_scoped_to_source() -> Result<()> {
        let lib = temp_library("remote-album-source")?;
        let first = server_source(&lib).await?;
        let second = lib.add_source(SourceConfig { id: None, kind: SourceKind::Jellyfin, name: "other".into(), addresses: vec!["http://other.local".into()], root_path: String::new(), credential_ref: None, options: BTreeMap::new(), enabled: true }).await?;
        let mut a = row("a", "First source track"); a.external_album_id = Some("same-id".into());
        let mut b = row("b", "Second source track"); b.external_album_id = Some("same-id".into());
        lib.upsert_remote_tracks(first, vec![a]).await?;
        lib.upsert_remote_tracks(second, vec![b]).await?;
        assert_eq!(lib.list_albums(lekis_types::TrackSort::Title, 0, 20).await?.len(), 2);
        Ok(())
    }

    #[tokio::test]
    async fn legacy_album_keeps_identity_and_artwork_on_rescan() -> Result<()> {
        let lib = temp_library("legacy-remote-album")?;
        let src = server_source(&lib).await?;
        let mut track = row("one", "Song");
        lib.upsert_remote_tracks(src, vec![track.clone()]).await?;
        let album = lib.list_albums(lekis_types::TrackSort::Title, 0, 10).await?.remove(0);
        let artwork = lib.upsert_artwork("old-cover".into(), "user".into(), None, None, None).await?;
        lib.set_album_artwork(album.id, Some(artwork)).await?;
        track.external_album_id = Some("server-album".into());
        track.album_artists = vec!["New album artist".into()];
        lib.upsert_remote_tracks(src, vec![track]).await?;
        let updated = lib.get_album(album.id).await?;
        assert_eq!(updated.artwork_id, Some(artwork));
        assert_eq!(updated.artist_line, "New album artist");
        assert_eq!(lib.remote_album_sources(album.id).await?, vec![(src, "server-album".into())]);
        Ok(())
    }

    #[tokio::test]
    async fn shared_legacy_track_is_split_before_assigning_server_album() -> Result<()> {
        let lib = temp_library("shared-legacy-track")?;
        let first = server_source(&lib).await?;
        let second = lib.add_source(SourceConfig { id: None, kind: SourceKind::Jellyfin, name: "other".into(), addresses: vec!["http://other.local".into()], root_path: String::new(), credential_ref: None, options: BTreeMap::new(), enabled: true }).await?;
        let mut a = row("a", "Same recording");
        let mut b = a.clone(); b.external_id = "b".into();
        lib.upsert_remote_tracks(first, vec![a.clone()]).await?;
        lib.upsert_remote_tracks(second, vec![b.clone()]).await?;
        let old_album = lib.list_albums(lekis_types::TrackSort::Title, 0, 10).await?.remove(0);
        let art = lib.upsert_artwork("shared-cover".into(), "user".into(), None, None, None).await?;
        lib.set_album_artwork(old_album.id, Some(art)).await?;
        let original = lib.album_tracks(old_album.id, 0, 10).await?.remove(0);
        lib.set_loved(lib.get_track(original.id).await?.uid, true).await?;
        a.external_album_id = Some("first".into());
        b.external_album_id = Some("second".into());
        lib.upsert_remote_tracks(first, vec![a]).await?;
        lib.upsert_remote_tracks(second, vec![b]).await?;
        let albums = lib.list_albums(lekis_types::TrackSort::Title, 0, 10).await?;
        assert_eq!(albums.len(), 2);
        assert!(albums.iter().any(|a| a.id == old_album.id));
        assert!(albums.iter().all(|a| a.track_count == 1));
        for album in albums {
            assert_eq!(album.artwork_id, Some(art));
            let track = lib.album_tracks(album.id, 0, 10).await?.remove(0);
            assert!(track.loved);
        }
        Ok(())
    }

    #[tokio::test]
    async fn plugin_identity_survives_metadata_updates_and_does_not_merge_remote_ids() -> Result<()>
    {
        let lib = temp_library("plugin-identity")?;
        let src = server_source(&lib).await?;
        let first = lib
            .append_plugin_tracks(src, vec![row("one", "Initial")])
            .await?;
        let id = first[0].id;
        let mut changed = row("one", "Enriched");
        changed.duration_ms = 180000;
        changed.artists = vec!["Updated artist".into()];
        let updated = lib.append_plugin_tracks(src, vec![changed.clone()]).await?;
        assert_eq!(updated[0].id, id);
        assert_eq!(updated[0].title, "Enriched");
        assert_eq!(updated[0].artist_line, "Updated artist");
        assert_eq!(lib.remote_track_count(src).await?, 1);
        assert_eq!(lib.track_files(id).await?.len(), 1);
        changed.external_id = "ONE".into();
        let other = lib.append_plugin_tracks(src, vec![changed]).await?;
        assert_ne!(other[0].id, id);
        assert_eq!(lib.search("Enriched", 10).await?.tracks.len(), 2);
        Ok(())
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
