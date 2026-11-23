//! Scope used by the user's catalog. Plugin search results are a playback cache,
//! not imported library music. Direct ID and explicit playlist queries stay unscoped.

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
