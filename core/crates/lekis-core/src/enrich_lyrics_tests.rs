//! Tests for lyrics cascade behavior with original, deterministic providers.
use super::*;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

struct Provider {
    result: Result<Vec<Candidate<LyricsPayload>>>,
    calls: Arc<AtomicUsize>,
}
#[async_trait::async_trait]
impl LyricsProvider for Provider {
    fn name(&self) -> &str {
        "test"
    }
    async fn find_lyrics(&self, _: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.result.clone()
    }
}
fn candidate(format: LyricsFormat, confidence: f32) -> Candidate<LyricsPayload> {
    Candidate {
        payload: LyricsPayload {
            format,
            content: format!("{format:?} original fixture"),
        },
        source: "lrclib".into(),
        matched: TrackHint {
            title: "勇者".into(),
            artists: vec!["YOASOBI".into()],
            duration_ms: 196_000,
            ..Default::default()
        },
        provider_confidence: confidence,
    }
}
pub(super) fn pipeline(
    results: Vec<Result<Vec<Candidate<LyricsPayload>>>>,
) -> (EnrichPipeline, Vec<Arc<AtomicUsize>>) {
    let mut calls = Vec::new();
    let lyrics_providers = results
        .into_iter()
        .map(|result| {
            let count = Arc::new(AtomicUsize::new(0));
            calls.push(count.clone());
            Box::new(Provider {
                result,
                calls: count,
            }) as Box<dyn LyricsProvider>
        })
        .collect();
    (
        EnrichPipeline {
            lyrics_providers,
            artwork_providers: vec![],
            cache_dir: std::env::temp_dir(),
        },
        calls,
    )
}
#[tokio::test]
async fn lyrics_cascade_prefers_strong_synced_without_double_scoring_and_stops() {
    let (pipeline, calls) = pipeline(vec![
        Ok(vec![candidate(LyricsFormat::Plain, 0.99)]),
        Ok(vec![candidate(LyricsFormat::Lrc, 0.87)]),
        Err(LekisError::internal("must not run")),
    ]);
    let found = pipeline
        .query_lyrics_cascade(&TrackHint::default())
        .await
        .unwrap();
    assert_eq!(found[0].payload.format, LyricsFormat::Lrc);
    assert_eq!(found[0].provider_confidence, 0.87);
    assert_eq!(
        calls
            .iter()
            .map(|n| n.load(Ordering::SeqCst))
            .collect::<Vec<_>>(),
        vec![1, 1, 0]
    );
    let (pipeline, _) = self::pipeline(vec![
        Ok(vec![candidate(LyricsFormat::Lrc, 0.70)]),
        Ok(vec![candidate(LyricsFormat::Plain, 0.90)]),
    ]);
    assert_eq!(
        pipeline
            .query_lyrics_cascade(&TrackHint::default())
            .await
            .unwrap()[0]
            .payload
            .format,
        LyricsFormat::Plain
    );
}
#[tokio::test]
async fn lyrics_cascade_distinguishes_no_result_errors_and_usable_fallback() {
    let (pipeline, _) = pipeline(vec![Ok(vec![]), Ok(vec![])]);
    assert!(pipeline
        .query_lyrics_cascade(&TrackHint::default())
        .await
        .unwrap()
        .is_empty());
    let (pipeline, _) = self::pipeline(vec![
        Err(LekisError::new(ErrorCode::Network, "offline")),
        Ok(vec![]),
    ]);
    assert_eq!(
        pipeline
            .query_lyrics_cascade(&TrackHint::default())
            .await
            .unwrap_err()
            .code,
        ErrorCode::Network
    );
    let (pipeline, _) = self::pipeline(vec![
        Ok(vec![candidate(LyricsFormat::Plain, 0.90)]),
        Err(LekisError::new(ErrorCode::Network, "offline")),
    ]);
    assert_eq!(
        pipeline
            .query_lyrics_cascade(&TrackHint::default())
            .await
            .unwrap()
            .len(),
        1
    );
}
pub(super) async fn library(name: &str) -> (std::path::PathBuf, Library, TrackId) {
    library_with_kind(name, SourceKind::Local).await
}
pub(super) async fn library_with_kind(
    name: &str,
    kind: SourceKind,
) -> (std::path::PathBuf, Library, TrackId) {
    let root = std::env::temp_dir().join(format!("lekis-lyrics-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let library = Library::open(&root.join("library.sqlite")).unwrap();
    let source = library
        .add_source(SourceConfig {
            id: None,
            kind,
            name: "test".into(),
            addresses: vec![],
            root_path: "/music".into(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        })
        .await
        .unwrap();
    library
        .upsert_scanned(vec![lekis_library::ScannedFile {
            source_id: source,
            path: "a.flac".into(),
            size: 1,
            mtime_ms: 1,
            tags: lekis_library::ScannedTags {
                title: "勇者".into(),
                artists: vec!["YOASOBI".into()],
                duration_ms: 196_000,
                ..Default::default()
            },
        }])
        .await
        .unwrap();
    let id = library
        .list_track_rows(TrackQuery {
            sort: TrackSort::Title,
            offset: 0,
            limit: 10,
        })
        .await
        .unwrap()[0]
        .id;
    (root, library, id)
}
#[tokio::test]
async fn lyrics_fetch_force_preserves_selection_and_candidates_are_selectable() {
    let (root, library, id) = library("force").await;
    let (pipeline, calls) = pipeline(vec![Ok(vec![
        candidate(LyricsFormat::Lrc, 0.87),
        candidate(LyricsFormat::Lrc, 0.87),
        candidate(LyricsFormat::Plain, 0.65),
    ])]);
    assert!(pipeline.fetch_lyrics(&library, id, false).await.unwrap());
    assert_eq!(
        library.active_lyrics(id).await.unwrap().unwrap().format,
        LyricsFormat::Lrc
    );
    assert_eq!(
        library.list_lyrics(id).await.unwrap().len(),
        2,
        "review candidate available for manual selection"
    );
    let plain = library
        .list_lyrics(id)
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.lyrics.format == LyricsFormat::Plain)
        .unwrap();
    library.activate_lyrics(id, plain.id).await.unwrap();
    assert!(!pipeline.fetch_lyrics(&library, id, false).await.unwrap());
    assert_eq!(calls[0].load(Ordering::SeqCst), 1);
    assert!(pipeline.fetch_lyrics(&library, id, true).await.unwrap());
    assert_eq!(calls[0].load(Ordering::SeqCst), 2);
    assert_eq!(
        library.active_lyrics(id).await.unwrap().unwrap().format,
        LyricsFormat::Plain,
        "explicit retry respects selected version"
    );
    assert_eq!(
        library.list_lyrics(id).await.unwrap().len(),
        2,
        "retry does not duplicate versions"
    );
    drop(library);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn builtin_qq_reuses_the_selected_plugin_version_and_pending_review() {
    let (root, library, id) = library("qq-upgrade").await;
    let mut qq = candidate(LyricsFormat::Lrc, 0.72);
    qq.source = format!("plugin:{QQ_EXAMPLE_ID}");
    let hint = qq.matched.clone();
    let (pipeline, _) = pipeline(vec![]);
    pipeline
        .apply_lyrics(&library, id, &hint, vec![qq.clone()])
        .await
        .unwrap();
    let selected = library.list_lyrics(id).await.unwrap()[0].id;
    library.activate_lyrics(id, selected).await.unwrap();

    qq.source = QqLyrics::NAME.into();
    pipeline
        .apply_lyrics(&library, id, &hint, vec![qq])
        .await
        .unwrap();
    let versions = library.list_lyrics(id).await.unwrap();
    assert_eq!(versions.len(), 1);
    assert_eq!(versions[0].id, selected);
    assert!(versions[0].is_active);
    assert_eq!(library.list_pending_candidates(10).await.unwrap().len(), 1);
    drop(library);
    std::fs::remove_dir_all(root).unwrap();
}
