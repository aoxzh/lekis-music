//! Network fixtures exercise the real download, decode and provider cascade.
#![allow(clippy::unwrap_used)]
use super::*;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
struct Cover {
    url: String,
    calls: Arc<AtomicUsize>,
}
#[async_trait::async_trait]
impl ArtworkProvider for Cover {
    fn name(&self) -> &str {
        "test"
    }
    async fn find_artwork(&self, _: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(vec![Candidate {
            payload: ArtworkPayload {
                url: self.url.clone(),
                width: None,
                height: None,
            },
            source: "itunes".into(),
            matched: TrackHint::default(),
            provider_confidence: 0.9,
        }])
    }
}
#[tokio::test]
async fn dead_high_confidence_cover_falls_back_and_lyrics_outage_does_not_block_artwork() {
    let (root, library, id) = super::lyrics_tests::library("artwork-cascade").await;
    let mut bytes = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(32, 32)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    let png = bytes.into_inner();
    let router = axum::Router::new().route(
        "/cover",
        axum::routing::get(move || {
            let png = png.clone();
            async move { ([("content-type", "image/png")], png) }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let (mut pipeline, _) =
        super::lyrics_tests::pipeline(vec![Err(LekisError::new(ErrorCode::Network, "offline"))]);
    pipeline.cache_dir = root.join("cache");
    let counts: Vec<_> = (0..3).map(|_| Arc::new(AtomicUsize::new(0))).collect();
    pipeline.artwork_providers = ["/404", "/cover", "/must-not-run"]
        .iter()
        .zip(&counts)
        .map(|(path, calls)| {
            Box::new(Cover {
                url: format!("{base}{path}"),
                calls: calls.clone(),
            }) as Box<dyn ArtworkProvider>
        })
        .collect();
    assert_eq!(
        pipeline
            .fetch_lyrics(&library, id, true)
            .await
            .unwrap_err()
            .code,
        ErrorCode::Network
    );
    let report = pipeline.enrich_track(&library, id).await.unwrap();
    assert_eq!(
        report.auto_applied, 1,
        "provider's 0.9 score must not be multiplied a second time"
    );
    assert_eq!(report.discarded, 1);
    assert!(library.effective_artwork_id(id).await.unwrap().is_some());
    assert_eq!(
        counts
            .iter()
            .map(|c| c.load(Ordering::SeqCst))
            .collect::<Vec<_>>(),
        vec![1, 1, 0]
    );
    let accepted = lekis_library::EnrichCandidateRow {
        id: 2,
        track_id: Some(id),
        album_id: None,
        kind: "artwork".into(),
        payload_json: serde_json::json!({"url":format!("{base}/cover")}).to_string(),
        source: "itunes".into(),
        score: 0.7,
        state: "pending".into(),
        created_at: 0,
        decided_at: None,
    };
    pipeline.apply_candidate(&library, &accepted).await.unwrap();
    assert!(library
        .effective_artwork_is_user_selected(id)
        .await
        .unwrap());
    assert_eq!(
        library.effective_artwork(id).await.unwrap().unwrap().source,
        "itunes"
    );
    server.abort();
    let _ = std::fs::remove_dir_all(root);
}
#[tokio::test]
async fn plugin_only_tracks_skip_album_search_and_reject_old_candidates() {
    let (root, library, _) = super::lyrics_tests::library("plugin-cover-guard").await;
    let source = library
        .add_source(lekis_types::SourceConfig {
            id: None,
            kind: SourceKind::Plugin,
            name: "plugin".into(),
            addresses: vec![],
            root_path: "test.plugin".into(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        })
        .await
        .unwrap();
    let ids = library
        .append_plugin_tracks(
            source,
            vec![lekis_library::RemoteTrackRow {
            external_album_id: None, album_artists: vec![], disc_no: None, track_no: None,
                external_id: "stable".into(),
                title: "Online".into(),
                ..Default::default()
            }],
        )
        .await
        .unwrap();
    let id = ids[0].id;
    let (mut pipeline, _) = super::lyrics_tests::pipeline(vec![]);
    let calls = Arc::new(AtomicUsize::new(0));
    pipeline.artwork_providers.push(Box::new(Cover {
        url: "http://127.0.0.1:1/never".into(),
        calls: calls.clone(),
    }));
    pipeline.enrich_track(&library, id).await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let row = lekis_library::EnrichCandidateRow {
        id: 1,
        track_id: Some(id),
        album_id: None,
        kind: "artwork".into(),
        payload_json: r#"{"url":"http://127.0.0.1:1/never"}"#.into(),
        source: "itunes".into(),
        score: 0.9,
        state: "pending".into(),
        created_at: 0,
        decided_at: None,
    };
    assert_eq!(
        pipeline
            .apply_candidate(&library, &row)
            .await
            .unwrap_err()
            .code,
        ErrorCode::Unsupported
    );
    assert!(library.effective_artwork_id(id).await.unwrap().is_none());
    let _ = std::fs::remove_dir_all(root);
}
