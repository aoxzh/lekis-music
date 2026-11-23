//! Jellyfin album sync and authenticated artwork integration.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use axum::{routing::get, Json, Router};
use lekis_core::{CoreConfig, CredentialStore, EventListener, LekisCore, MemoryCredentialStore, PlatformServices};
use lekis_types::{CoreEvent, SourceConfig, SourceKind, TrackSort};
use serde_json::json;
use std::{collections::BTreeMap, sync::Arc};
use tokio::sync::mpsc;
struct Listener(mpsc::UnboundedSender<CoreEvent>);
impl EventListener for Listener { fn on_event(&self, event: CoreEvent) { let _ = self.0.send(event); } }

#[tokio::test]
async fn jellyfin_album_sync_and_artwork_fallback() {
    let mut image = Vec::new();
    image::RgbImage::from_pixel(8, 8, image::Rgb([80, 20, 30]))
        .write_to(&mut std::io::Cursor::new(&mut image), image::ImageFormat::Png).unwrap();
    let app = Router::new()
        .route("/System/Info", get(|| async { Json(json!({"Id":"s","ServerName":"Mock"})) }))
        .route("/Users/Me", get(|| async { Json(json!({"Id":"u"})) }))
        .route("/Items", get(|| async { Json(json!({"Items":[
            {"Id":"t2","Name":"Second","Album":"Compilation","AlbumId":"album","Artists":["Singer B"],"AlbumArtists":[{"Name":"Various Artists"}],"ParentIndexNumber":2,"IndexNumber":1},
            {"Id":"t1","Name":"First","Album":"Compilation","AlbumId":"album","Artists":["Singer A"],"AlbumArtists":[{"Name":"Various Artists"}],"ParentIndexNumber":1,"IndexNumber":1}
        ]})) }))
        .route("/Items/t1/Images/Primary", get(move |headers: axum::http::HeaderMap| { let image = image.clone(); async move {
            assert_eq!(headers.get("x-emby-token").unwrap(), "secret"); image
        }}));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let tmp = std::env::temp_dir().join(format!("lekis-jf-album-{}", lekis_types::now_ms()));
    std::fs::create_dir_all(&tmp).unwrap();
    let creds = Arc::new(MemoryCredentialStore::default()); creds.set("jf", "secret").unwrap();
    let core = LekisCore::with_runtime(CoreConfig::for_tests(&tmp), PlatformServices { credentials: creds }, tokio::runtime::Handle::current()).unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel(); core.add_listener(Arc::new(Listener(tx)));
    let source = core.add_source(SourceConfig { id: None, kind: SourceKind::Jellyfin, name: "Mock".into(), addresses: vec![format!("http://{address}")], root_path: String::new(), credential_ref: Some("jf".into()), options: BTreeMap::new(), enabled: true }).await.unwrap();
    core.start_scan(source).await.unwrap();
    loop { match tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv()).await.unwrap().unwrap() {
        CoreEvent::ScanFinished { source_id, .. } if source_id == source => break,
        CoreEvent::ScanFailed { detail, .. } => panic!("scan: {detail}"), _ => {}
    }}
    let albums = core.list_albums(TrackSort::Title, 0, 10).await.unwrap();
    assert_eq!(albums.len(), 1); assert_eq!(albums[0].artist_line, "Various Artists");
    let tracks = core.album_tracks(albums[0].id, 0, 10).await.unwrap();
    assert_eq!(tracks.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["First", "Second"]);
    let art = core.album_artwork(albums[0].id).await.unwrap().unwrap();
    assert_eq!(art.source, "server");
    server.abort();
    assert_eq!(core.album_artwork(albums[0].id).await.unwrap().unwrap().id, art.id);
    drop(core); let _ = std::fs::remove_dir_all(tmp);
}
