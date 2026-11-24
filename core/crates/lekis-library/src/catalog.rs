//! Scope used by the user's catalog. Plugin search results are a playback cache,
//! not imported library music. Direct ID and explicit playlist queries stay unscoped.

use crate::{db::DbResultExt, Library};
use lekis_types::TrackSourceScope;
use lekis_types::{
    AlbumId, ArtistCredit, ArtistId, ArtistRole, Result, ScopedTrackMetadata, TrackId,
};
use rusqlite::types::Value;

impl Library {
    /// Intersect the input with a source, retaining playlist order and repetitions.
    pub async fn filter_track_ids_by_source(
        &self,
        scope: TrackSourceScope,
        ids: Vec<TrackId>,
    ) -> Result<Vec<TrackId>> {
        self.source_batch(
            scope,
            ids,
            "SELECT t.id FROM json_each(?) input CROSS JOIN catalog_track t
             WHERE t.id = input.value ORDER BY input.key",
            |row| Ok(TrackId(row.get(0)?)),
        )
        .await
    }

    /// Fetch category metadata in a single read for all requested IDs.
    pub async fn track_metadata_by_source(
        &self,
        scope: TrackSourceScope,
        ids: Vec<TrackId>,
    ) -> Result<Vec<ScopedTrackMetadata>> {
        self.source_batch(scope, ids,
            "SELECT t.id, t.album_id, a.artist_line,
                (SELECT json_group_array(json_array(ar.id, ar.name, ta.role) ORDER BY ta.position, ar.name, ta.role)
                 FROM track_artist ta JOIN artist ar ON ar.id = ta.artist_id WHERE ta.track_id = t.id),
                COALESCE(CASE WHEN json_valid(t.overlay_json) THEN json_extract(t.overlay_json,'$.genres') END,
                    (SELECT json_group_array(g.name ORDER BY g.name) FROM track_genre tg
                     JOIN genre g ON g.id = tg.genre_id WHERE tg.track_id = t.id)),
                CASE WHEN json_valid(t.tag_overrides_json) THEN json_extract(t.tag_overrides_json,'$.genre') END
             FROM (SELECT value, min(key) AS ordinal FROM json_each(?) GROUP BY value) input
             CROSS JOIN catalog_track t LEFT JOIN album a ON a.id = t.album_id
             WHERE t.id = input.value ORDER BY input.ordinal",
            |row| {
                let credits: Vec<(i64, String, String)> = json_column(row, 3)?;
                Ok(ScopedTrackMetadata {
                    track_id: TrackId(row.get(0)?),
                    album_id: row.get::<_, Option<i64>>(1)?.map(AlbumId),
                    album_artist: row.get(2)?,
                    artists: credits.into_iter().map(|(id, name, role)| ArtistCredit {
                        artist_id: Some(ArtistId(id)), name, role: ArtistRole::from_db(&role),
                    }).collect(),
                    genres: match row.get::<_, Option<String>>(5)? {
                        Some(genre) => crate::tracks::split_tag_genres(&genre),
                        None => json_column(row, 4)?,
                    },
                })
            }).await
    }

    async fn source_batch<T: Send + 'static>(
        &self,
        scope: TrackSourceScope,
        ids: Vec<TrackId>,
        select: &'static str,
        map: fn(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
    ) -> Result<Vec<T>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let (sql, mut args) = scoped_query(Some(scope), select);
        args.push(
            serde_json::to_string(&ids)
                .map_err(std::io::Error::other)?
                .into(),
        );
        self.read(move |conn| {
            let mut stmt = conn.prepare_cached(&sql).db()?;
            let rows = stmt.query_map(rusqlite::params_from_iter(args), map).db()?;
            rows.collect::<rusqlite::Result<_>>().db()
        })
        .await
    }
}

fn json_column<T: serde::de::DeserializeOwned>(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<T> {
    serde_json::from_str(&row.get::<_, String>(index)?).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

pub(crate) fn scoped_query(scope: Option<TrackSourceScope>, sql: &str) -> (String, Vec<Value>) {
    let Some(scope) = scope else {
        return (query(sql), Vec::new());
    };
    let mut args = Vec::new();
    let predicate = match scope {
        TrackSourceScope::Local => "s.kind = 'local' AND f.id IS NOT NULL",
        TrackSourceScope::Nas => {
            "((s.kind IN ('smb', 'web_dav', 'nfs', 'sftp') AND f.id IS NOT NULL)
              OR (s.kind IN ('open_subsonic', 'jellyfin', 'emby', 'plex')
                  AND length(trim(tf.external_id)) > 0))"
        }
        TrackSourceScope::Plugin(id) => {
            args.push(id.into());
            "s.kind = 'plugin' AND s.root_path = ? AND length(trim(tf.external_id)) > 0"
        }
    };
    (
        format!(
            "WITH catalog_track AS NOT MATERIALIZED (
        SELECT t.* FROM track t WHERE EXISTS (
            SELECT 1 FROM track_file tf JOIN source s ON s.id = tf.source_id
            LEFT JOIN file f ON f.id = tf.file_id AND f.source_id = s.id
            WHERE tf.track_id = t.id AND {predicate})
        ), catalog_album AS NOT MATERIALIZED (
            SELECT a.* FROM album a WHERE EXISTS (
                SELECT 1 FROM catalog_track t WHERE t.album_id = a.id)
        ) {sql}"
        ),
        args,
    )
}

/// Query-local views avoid a schema migration and apply the same origin rule to
/// every list, count and aggregate. A real non-plugin copy keeps a merged track in
/// the catalog; NAS/server sources count as library music too. The UID guard also
/// keeps cached plugin rows hidden after their source has been removed.
pub(crate) fn query(sql: impl AsRef<str>) -> String {
    format!(
        "WITH catalog_track AS NOT MATERIALIZED (
           SELECT t.* FROM track t
           WHERE (t.uid NOT LIKE 'plugin:%' AND NOT EXISTS (
             SELECT 1 FROM track_file tf JOIN source s ON s.id = tf.source_id
             WHERE tf.track_id = t.id AND s.kind = 'plugin'))
           OR EXISTS (
             SELECT 1 FROM track_file tf JOIN source s ON s.id = tf.source_id
             WHERE tf.track_id = t.id AND s.kind <> 'plugin')
         ), catalog_album AS NOT MATERIALIZED (
           SELECT a.* FROM album a WHERE EXISTS (
             SELECT 1 FROM catalog_track t WHERE t.album_id = a.id)
         ), catalog_artist AS NOT MATERIALIZED (
           SELECT ar.* FROM artist ar WHERE EXISTS (
             SELECT 1 FROM track_artist ta JOIN catalog_track t ON t.id = ta.track_id
             WHERE ta.artist_id = ar.id)
           OR EXISTS (
             SELECT 1 FROM album_artist aa JOIN catalog_album a ON a.id = aa.album_id
             WHERE aa.artist_id = ar.id)
         ) {}",
        sql.as_ref()
    )
}

#[cfg(test)]
mod tests {
    use crate::db::test_util::temp_library;
    use crate::{Library, RemoteTrackRow, ScannedFile, ScannedTags, SmartRules, TrackContext};
    use lekis_types::{Result, SourceConfig, SourceId, SourceKind, TrackQuery, TrackSort};
    use std::collections::BTreeMap;

    async fn source(lib: &Library, kind: SourceKind, name: &str) -> Result<SourceId> {
        lib.add_source(SourceConfig {
            id: None,
            kind,
            name: name.into(),
            addresses: vec![],
            root_path: name.into(),
            credential_ref: None,
            options: BTreeMap::new(),
            enabled: true,
        })
        .await
    }

    #[tokio::test]
    async fn source_pages_follow_file_links_and_preserve_track_rows() -> Result<()> {
        use crate::db::DbResultExt;
        use lekis_types::{TrackId, TrackSourceScope};
        let library = temp_library("source-pages")?;
        library
            .write(|conn| {
                conn.execute_batch(
                    "
                INSERT INTO source(id,kind,name,root_path,created_at) VALUES
                  (1,'local','Local','/music',0),(2,'smb','Share','music',0),
                  (3,'jellyfin','Server','media',0),(4,'plugin','B station','dev.mygo.bilibili',0),
                  (5,'plugin','Same name','bilibili',0),(6,'web_dav','DAV','music',0);
                INSERT INTO track(id,uid,title,title_sort_key,created_at,updated_at) VALUES
                  (1,'legacy','Merged','m',0,0),(2,'plugin:old','Local','l',0,0),
                  (3,'third','Server','s',0,0),(4,'fourth','Plugin','p',0,0),
                  (5,'fifth','Other plugin','o',0,0),(6,'sixth','Orphan','o',0,0),
                  (7,'seventh','Broken','b',0,0),(8,'eighth','DAV','d',0,0);
                INSERT INTO file(id,source_id,path,size,mtime_ms,last_seen_at) VALUES
                  (1,1,'m.flac',1,0,0),(2,1,'m.mp3',1,0,0),(3,2,'m.flac',1,0,0),
                  (4,1,'local.flac',1,0,0),(5,6,'dav.flac',1,0,0);
                INSERT INTO track_file(track_id,source_id,file_id,external_id) VALUES
                  (1,1,1,''),(1,1,2,''),(1,2,3,''),(1,4,NULL,'a'),(1,4,NULL,'alias'),
                  (2,1,4,''),(3,3,NULL,'srv'),(4,4,NULL,'b'),(5,5,NULL,'b'),
                  (7,1,NULL,'fake'),(7,2,1,''),(7,3,NULL,''),(7,4,NULL,' '),(8,6,5,'');
            ",
                )
                .db()
            })
            .await?;
        let plugin = || TrackSourceScope::Plugin("dev.mygo.bilibili".into());
        for (scope, expected) in [
            (TrackSourceScope::Local, vec![2, 1]),
            (TrackSourceScope::Nas, vec![8, 1, 3]),
            (plugin(), vec![1, 4]),
            (TrackSourceScope::Plugin("bilibili".into()), vec![5]),
            (TrackSourceScope::Plugin("unknown".into()), vec![]),
        ] {
            let queue = library
                .context_track_ids(TrackContext::SourceLibrary(scope.clone(), TrackSort::Title))
                .await?;
            assert_eq!(
                queue,
                expected
                    .iter()
                    .map(|id| Some(TrackId(*id)))
                    .collect::<Vec<_>>()
            );
            let page = library
                .list_tracks_by_source(
                    scope,
                    TrackQuery {
                        sort: TrackSort::Title,
                        offset: 0,
                        limit: 500,
                    },
                )
                .await?;
            assert_eq!(
                page.iter().map(|row| row.id.0).collect::<Vec<_>>(),
                expected
            );
            for row in page {
                assert_eq!(row, library.track_row(row.id).await?);
            }
        }
        for sort in [
            TrackSort::Artist,
            TrackSort::Album,
            TrackSort::MostPlayed,
            TrackSort::RecentlyAdded,
        ] {
            let expected = if sort == TrackSort::RecentlyAdded {
                [4, 1]
            } else {
                [1, 4]
            };
            for offset in 0..=2 {
                let page = library
                    .list_tracks_by_source(
                        plugin(),
                        TrackQuery {
                            sort,
                            offset,
                            limit: 1,
                        },
                    )
                    .await?;
                assert_eq!(
                    page.into_iter().map(|row| row.id).collect::<Vec<_>>(),
                    expected
                        .get(offset as usize)
                        .copied()
                        .map(TrackId)
                        .into_iter()
                        .collect::<Vec<_>>()
                );
            }
        }
        for limit in [0, TrackQuery::MAX_LIMIT + 1] {
            assert!(library
                .list_tracks_by_source(
                    plugin(),
                    TrackQuery {
                        sort: TrackSort::Title,
                        offset: 0,
                        limit
                    }
                )
                .await
                .is_err());
        }
        Ok(())
    }

    #[tokio::test]
    async fn scoped_album_tracks_page_plugin_only_rows_in_disc_order() -> Result<()> {
        use crate::db::DbResultExt;
        use lekis_types::{AlbumId, TrackId, TrackSourceScope};
        let library = temp_library("scope-album-tracks")?;
        library.write(|conn| conn.execute_batch("
            INSERT INTO source(id,kind,name,root_path,created_at) VALUES
                (1,'plugin','First','p',0),(2,'plugin','Second','q',0);
            INSERT INTO album(id,title,title_norm,sort_title,artist_line,artist_norm,created_at) VALUES
                (1,'A','a','a','Band','band',0),(2,'B','b','b','Band','band',0);
            INSERT INTO track(id,uid,title,album_id,disc_no,track_no,title_sort_key,created_at,updated_at) VALUES
                (1,'one','Disc two',1,2,1,'a',0,0),(2,'two','Track two',1,1,2,'a',0,0),
                (3,'three','Z',1,1,1,'z',0,0),(4,'four','A',1,1,1,'a',0,0),
                (5,'five','A',1,1,1,'a',0,0),(6,'six','Foreign',1,1,1,'a',0,0),
                (7,'seven','Other album',2,1,1,'a',0,0);
            INSERT INTO track_file(track_id,source_id,external_id) VALUES
                (1,1,'1'),(2,1,'2'),(3,1,'3'),(4,1,'4'),(5,1,'5'),(5,1,'copy'),
                (5,2,'shared'),(6,2,'6'),(7,1,'7');
        ").db()).await?;
        let album = AlbumId(1);
        assert!(library.album_tracks(album, 0, 10).await?.is_empty());
        for (plugin, offset, expected) in [
            ("p", 0, vec![4, 5]),
            ("p", 2, vec![3, 2]),
            ("p", 4, vec![1]),
            ("p", 5, vec![]),
            ("q", 0, vec![5, 6]),
            ("missing", 0, vec![]),
        ] {
            let rows = library
                .album_tracks_by_source(TrackSourceScope::Plugin(plugin.into()), album, offset, 2)
                .await?;
            assert_eq!(
                rows.iter().map(|row| row.id).collect::<Vec<_>>(),
                expected.into_iter().map(TrackId).collect::<Vec<_>>()
            );
        }
        Ok(())
    }

    #[tokio::test]
    async fn scoped_album_sort_credits_genres_and_playlist_intersection() -> Result<()> {
        use crate::db::DbResultExt;
        use lekis_types::{ArtistRole, TrackId, TrackSourceScope};
        let library = temp_library("scope-categories")?;
        library.write(|conn| conn.execute_batch("
            INSERT INTO source(id,kind,name,root_path,created_at) VALUES
                (1,'plugin','Music','p',0),(2,'plugin','Other','other',0);
            INSERT INTO album(id,title,title_norm,sort_title,artist_line,artist_norm,created_at) VALUES
                (1,'Collection','collection','c','Various Artists','v',2),
                (2,'Collection','collection','c','Band','b',1);
            INSERT INTO track(id,uid,title,album_id,created_at,updated_at) VALUES
                (1,'one','First',1,0,0),(2,'two','Second',1,0,0),
                (3,'three','Third',2,0,0),(4,'foreign','Foreign',1,0,0);
            INSERT INTO track_file(track_id,source_id,external_id) VALUES
                (1,1,'one'),(1,1,'duplicate'),(2,1,'two'),(3,1,'three'),(4,2,'four');
            INSERT INTO artist(id,name,name_norm) VALUES (1,'A / B','a/b'),(2,'Guest','guest');
            INSERT INTO track_artist(track_id,artist_id,position,role) VALUES
                (1,1,0,'main'),(1,2,1,'featured');
            INSERT INTO genre(id,name) VALUES (1,'Jazz'),(2,'Fusion');
            INSERT INTO track_genre(track_id,genre_id) VALUES (1,1),(1,2);
            UPDATE track SET tag_overrides_json='{\"genre\":\" Rock ; Pop ; \"}' WHERE id=2;
            UPDATE track SET overlay_json='{\"genres\":[\"Live\"]}' WHERE id=3;
            INSERT INTO user_state(track_uid,play_count) VALUES ('foreign',100),('three',2);
        ").db()).await?;
        let scope = || TrackSourceScope::Plugin("p".into());
        for (sort, expected) in [
            (TrackSort::Title, [1, 2]),
            (TrackSort::Artist, [2, 1]),
            (TrackSort::RecentlyAdded, [1, 2]),
            (TrackSort::MostPlayed, [2, 1]),
        ] {
            let albums = library.list_albums_by_source(scope(), sort, 0, 10).await?;
            assert_eq!(
                albums.iter().map(|album| album.id.0).collect::<Vec<_>>(),
                expected
            );
            assert_eq!(
                albums
                    .iter()
                    .find(|album| album.id.0 == 1)
                    .map(|album| album.track_count),
                Some(2)
            );
            assert_eq!(
                library.list_albums_by_source(scope(), sort, 1, 1).await?,
                albums[1..]
            );
        }
        let input = [4, 2, 1, 2, -7, 3].map(TrackId).to_vec();
        let rows = library
            .track_metadata_by_source(scope(), input.clone())
            .await?;
        assert_eq!(
            rows.iter().map(|row| row.track_id.0).collect::<Vec<_>>(),
            [2, 1, 3]
        );
        assert_eq!(rows[1].album_id.map(|id| id.0), Some(1));
        assert_eq!(rows[1].album_artist.as_deref(), Some("Various Artists"));
        assert_eq!(
            rows[1]
                .artists
                .iter()
                .map(|a| (a.artist_id.map(|id| id.0), a.name.as_str(), a.role))
                .collect::<Vec<_>>(),
            [
                (Some(1), "A / B", ArtistRole::Main),
                (Some(2), "Guest", ArtistRole::Featured)
            ]
        );
        assert_eq!(rows[0].genres, ["Rock", "Pop"]);
        assert_eq!(rows[1].genres, ["Fusion", "Jazz"]);
        assert_eq!(rows[2].genres, ["Live"]);
        let ids = library.filter_track_ids_by_source(scope(), input).await?;
        assert_eq!(ids, [2, 1, 2, 3].map(TrackId));
        let long = vec![TrackId(1); 1200];
        assert_eq!(
            library
                .filter_track_ids_by_source(scope(), long.clone())
                .await?,
            long
        );
        assert!(library
            .filter_track_ids_by_source(scope(), vec![])
            .await?
            .is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn cache_is_separate_but_explicit_online_playlist_survives() -> Result<()> {
        let lib = temp_library("catalog-sources")?;
        let local = source(&lib, SourceKind::Local, "local").await?;
        let server = source(&lib, SourceKind::Jellyfin, "server").await?;
        let plugin = source(&lib, SourceKind::Plugin, "online.test").await?;
        lib.upsert_scanned(vec![ScannedFile {
            source_id: local,
            path: "a.flac".into(),
            size: 1,
            mtime_ms: 1,
            tags: ScannedTags {
                title: "Alpha local".into(),
                artists: vec!["Local artist".into()],
                album: Some("Shared album".into()),
                genres: vec!["Local genre".into()],
                duration_ms: 1000,
                ..Default::default()
            },
        }])
        .await?;
        lib.upsert_remote_tracks(
            server,
            vec![RemoteTrackRow {
                external_album_id: None,
                album_artists: vec![],
                disc_no: None,
                track_no: None,
                external_id: "server1".into(),
                title: "Beta server".into(),
                artists: vec!["Server artist".into()],
                album: Some("Server album".into()),
                ..Default::default()
            }],
        )
        .await?;
        let online = lib
            .append_plugin_tracks(
                plugin,
                vec![
                    RemoteTrackRow {
                        external_album_id: None,
                        album_artists: vec![],
                        disc_no: None,
                        track_no: None,
                        external_id: "online1".into(),
                        title: "Cache plugin".into(),
                        artists: vec!["Local artist".into()],
                        album: Some("Shared album".into()),
                        ..Default::default()
                    },
                    RemoteTrackRow {
                        external_album_id: None,
                        album_artists: vec![],
                        disc_no: None,
                        track_no: None,
                        external_id: "online2".into(),
                        title: "Cache exclusive".into(),
                        artists: vec!["Exclusive artist".into()],
                        album: Some("Plugin album".into()),
                        ..Default::default()
                    },
                ],
            )
            .await?;
        let online_id = online[0].id;
        lib.write(move |c| {
            c.execute("INSERT INTO genre (name) VALUES ('Online genre')", []).unwrap();
            c.execute("INSERT INTO track_genre (track_id, genre_id) SELECT ?1, id FROM genre WHERE name = 'Online genre'", [online_id.0]).unwrap();
            Ok(())
        }).await?;
        let all = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await?;
        assert_eq!(
            all.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(),
            ["Alpha local", "Beta server"]
        );
        assert_eq!(lib.track_count().await?, 2);
        assert_eq!(lib.album_count().await?, 2);
        assert_eq!(lib.artist_count().await?, 2);
        assert_eq!(lib.list_artists(0, 10).await?.len(), 2);
        let local_artist = lib
            .list_artists(0, 10)
            .await?
            .into_iter()
            .find(|a| a.name == "Local artist")
            .unwrap();
        assert_eq!(lib.artist_tracks(local_artist.id, 0, 10).await?.len(), 1);
        assert_eq!(lib.artist_albums(local_artist.id, 0, 10).await?.len(), 1);
        assert_eq!(lib.list_genres(10).await?.len(), 1);
        assert_eq!(lib.genre_track_count("Online genre").await?, 0);
        let page = lib
            .list_track_rows(TrackQuery {
                sort: TrackSort::Title,
                offset: 1,
                limit: 1,
            })
            .await?;
        assert_eq!(page[0].id, all[1].id);
        assert_eq!(
            lib.context_track_ids(TrackContext::Library(TrackSort::Title))
                .await?,
            all.iter().map(|r| Some(r.id)).collect::<Vec<_>>()
        );
        let albums = lib.list_albums(TrackSort::Title, 0, 10).await?;
        assert_eq!(albums.len(), 2);
        let shared = albums.iter().find(|a| a.title == "Shared album").unwrap();
        assert_eq!(lib.get_track(online[0].id).await?.album_id, Some(shared.id));
        assert_eq!(shared.track_count, 1);
        assert_eq!(
            lib.track_title_index_offsets()
                .await?
                .iter()
                .map(|v| v.letter.as_str())
                .collect::<Vec<_>>(),
            ["A", "B"]
        );
        assert_eq!(lib.artist_index_offsets().await?.len(), 2);
        assert_eq!(lib.get_album(shared.id).await?.track_count, 1);
        assert_eq!(lib.album_tracks(shared.id, 0, 10).await?.len(), 1);
        assert!(lib.search("Cache", 10).await?.tracks.is_empty());
        assert!(lib.search("Plugin", 10).await?.albums.is_empty());
        assert!(lib.search("Exclusive", 10).await?.artists.is_empty());
        assert_eq!(lib.list_genres(10).await?[0].track_count, 1);
        assert_eq!(lib.genre_track_count("Local genre").await?, 1);
        for row in all.iter().chain(online.iter()) {
            let track = lib.get_track(row.id).await?;
            lib.set_loved(track.uid.clone(), true).await?;
            lib.record_play(track.uid, "test".into(), 1000, 1000)
                .await?;
        }
        assert_eq!(lib.loved_count().await?, 2);
        assert_eq!(lib.list_loved(0, 10).await?.len(), 2);
        assert_eq!(lib.recently_added(10).await?.len(), 2);
        assert_eq!(lib.recently_played(10).await?.len(), 2);
        assert_eq!(lib.most_played(10).await?.len(), 2);
        let rules = SmartRules::parse(r#"{"all":[{"is":{"loved":true}}]}"#)?;
        assert_eq!(lib.count_smart_rules(&rules).await?, 2);
        assert_eq!(lib.evaluate_smart_rules(&rules, 0, 10).await?.len(), 2);
        let playlist = lib.create_playlist("Explicit favorite", None).await?;
        lib.add_to_playlist(playlist, lib.get_track(online[0].id).await?.uid, None, None)
            .await?;
        assert_eq!(lib.get_playlist(playlist).await?.track_count, 1);
        assert_eq!(
            lib.context_track_ids(TrackContext::Playlist(playlist))
                .await?,
            vec![Some(online[0].id)]
        );
        assert_eq!(lib.track_row(online[0].id).await?.id, online[0].id);
        lib.write(move |c| {
            c.execute("DELETE FROM source WHERE id = ?1", [plugin.0])
                .map_err(|e| lekis_types::LekisError::internal(e.to_string()))?;
            Ok(())
        })
        .await?;
        assert_eq!(lib.track_count().await?, 2);
        assert_eq!(lib.track_row(online[0].id).await?.id, online[0].id);
        // A real library/server copy makes the same merged track eligible.
        lib.write(move |c| {
            c.execute("INSERT INTO track_file (track_id, source_id, external_id) VALUES (?1, ?2, 'adopted')", rusqlite::params![online_id.0, server.0]).unwrap();
            Ok(())
        }).await?;
        assert_eq!(lib.track_count().await?, 3);
        Ok(())
    }
}
