//! Plugin artwork is metadata, never an arbitrary network URL exposed to the UI.
use super::*;
use lekis_types::{CoreEvent, LibraryScope, TrackId};
use std::time::Duration;

const URL_PREFIX: &str = "plugin.artwork.";
const MAX_BYTES: usize = 8 * 1024 * 1024;

fn legacy_album_match(source: &str) -> bool {
    matches!(
        source,
        "coverartarchive" | "itunes" | "deezer" | "netease" | "musicbrainz" | "vocadb" | "bangumi"
    )
}

#[derive(Serialize, Deserialize)]
struct ArtworkReference {
    plugin_id: String,
    external_id: String,
    url: String,
}

fn permitted_url(permissions: &Permissions, raw: &str) -> Result<url::Url> {
    if raw.len() > 8192 || !permissions.allows_url(raw) {
        return Err(LekisError::unsupported("封面地址超出插件声明的网络权限"));
    }
    let url = url::Url::parse(raw).map_err(|_| LekisError::invalid("封面地址无效"))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err(LekisError::unsupported("封面地址不能包含登录凭据"));
    }
    Ok(url)
}

async fn download_image(permissions: &Permissions, raw: &str) -> Result<Vec<u8>> {
    let mut target = permitted_url(permissions, raw)?;
    // Validate every redirect against the same manifest. Never inherit source credentials.
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|_| LekisError::internal("封面客户端初始化失败"))?;
    for _ in 0..=4 {
        let mut response = client
            .get(target.clone())
            .send()
            .await
            .map_err(|_| LekisError::not_found("封面下载失败"))?;
        if response.status().is_redirection() {
            let next = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| LekisError::invalid("封面重定向缺少地址"))?;
            let next = target
                .join(next)
                .map_err(|_| LekisError::invalid("封面重定向地址无效"))?;
            target = permitted_url(permissions, next.as_str())?;
            continue;
        }
        if !response.status().is_success() {
            return Err(LekisError::not_found(format!(
                "封面 HTTP {}",
                response.status().as_u16()
            )));
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_BYTES as u64)
        {
            return Err(LekisError::invalid("封面超过 8 MiB 上限"));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if !mime.starts_with("image/") && !mime.starts_with("application/octet-stream") {
            return Err(LekisError::unsupported("封面响应不是图片"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| LekisError::not_found("封面读取失败"))?
        {
            if bytes.len() + chunk.len() > MAX_BYTES {
                return Err(LekisError::invalid("封面超过 8 MiB 上限"));
            }
            bytes.extend_from_slice(&chunk);
        }
        if bytes.is_empty() {
            return Err(LekisError::invalid("封面为空"));
        }
        return Ok(bytes);
    }
    Err(LekisError::unsupported("封面重定向次数过多"))
}

impl PluginManager {
    /// Use the application's ordinary artwork cache; the frontend keeps its existing DTO/path API.
    pub fn with_artwork_cache(mut self, cache_dir: &Path) -> Self {
        self.artwork_cache = cache_dir.to_path_buf();
        self
    }

    pub(crate) fn with_artwork_events(mut self, events: crate::events::EventBus) -> Self {
        self.artwork_events = Some(events);
        self
    }

    pub(super) async fn remember_artwork(
        &self,
        plugin_id: &str,
        id: TrackId,
        external_id: &str,
        raw: &str,
    ) -> Result<()> {
        let (_, manifest) = self.find_installed(plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        permitted_url(&Permissions::new(&manifest.permissions, &[]), raw)?;
        let value = serde_json::to_string(&ArtworkReference {
            plugin_id: plugin_id.to_string(),
            external_id: external_id.to_string(),
            url: raw.to_string(),
        })
        .map_err(|_| LekisError::invalid("插件封面元资料无效"))?;
        self.artwork_retry_after.lock().await.remove(&id);
        self.library
            .set_setting(&format!("{URL_PREFIX}{id}"), &value)
            .await
    }

    /// Artwork failures are cosmetic: return the existing image/None, never fail search or playback.
    pub(crate) async fn artwork_for_track(
        &self,
        id: TrackId,
        refresh_metadata: bool,
    ) -> Option<lekis_library::ArtworkRow> {
        let gate = {
            let mut gates = self.artwork_gates.lock().await;
            gates.retain(|_, gate| gate.strong_count() > 0);
            let gate = gates
                .get(&id)
                .and_then(std::sync::Weak::upgrade)
                .unwrap_or_else(|| Arc::new(tokio::sync::Mutex::new(())));
            gates.insert(id, Arc::downgrade(&gate));
            gate
        };
        let now = std::time::Instant::now();
        self.artwork_retry_after
            .lock()
            .await
            .retain(|_, deadline| *deadline > now);
        let _guard = gate.lock().await;
        let existing = self.library.effective_artwork(id).await.ok().flatten();
        let files = self.library.track_files(id).await.ok()?;
        let plugin_only = !files.is_empty()
            && files
                .iter()
                .all(|file| file.source_kind == lekis_types::SourceKind::Plugin);
        if !plugin_only {
            return existing;
        }
        // Website catalog entries must not display old album-search matches on failure.
        let user_selected = self
            .library
            .effective_artwork_is_user_selected(id)
            .await
            .unwrap_or(false);
        let plugin_selected = self
            .library
            .track_artwork_is_plugin(id)
            .await
            .unwrap_or(false);
        let existing = existing
            .filter(|art| user_selected || plugin_selected || !legacy_album_match(&art.source));
        if let Some(art) = &existing {
            let cached = self
                .artwork_cache
                .join(lekis_library::cache_relative_path(&art.hash, 256));
            if (user_selected || plugin_selected || !legacy_album_match(&art.source))
                && (cached.is_file() || (!plugin_selected && !art.source.starts_with("plugin:")))
            {
                return existing;
            }
        }
        if self
            .artwork_retry_after
            .lock()
            .await
            .get(&id)
            .is_some_and(|deadline| *deadline > std::time::Instant::now())
        {
            return existing;
        }
        match self.load_artwork(id, refresh_metadata).await {
            Ok(Some(art)) => Some(art),
            Ok(None) => existing,
            Err(error) => {
                let mut retries = self.artwork_retry_after.lock().await;
                retries.retain(|_, deadline| *deadline > std::time::Instant::now());
                if retries.len() >= 512 && !retries.contains_key(&id) {
                    if let Some(oldest) = retries
                        .iter()
                        .min_by_key(|(_, deadline)| *deadline)
                        .map(|(id, _)| *id)
                    {
                        retries.remove(&oldest);
                    }
                }
                retries.insert(id, std::time::Instant::now() + Duration::from_secs(30));
                drop(retries);
                tracing::debug!(target:"lekis_core::plugins", track_id=%id, code=%error.code.as_str(), "插件封面暂不可用");
                existing
            }
        }
    }

    async fn load_artwork(
        &self,
        id: TrackId,
        refresh_metadata: bool,
    ) -> Result<Option<lekis_library::ArtworkRow>> {
        let previous = self.library.effective_artwork_id(id).await?;
        let mut saved = self
            .library
            .get_setting(&format!("{URL_PREFIX}{id}"))
            .await?;
        if saved.is_none() && refresh_metadata {
            // Legacy imports dropped artworkUrl. Refresh only the exact external ID at playback,
            // without importing keyword matches or replacing user-edited metadata.
            for file in self.library.track_files(id).await? {
                if file.source_kind != lekis_types::SourceKind::Plugin {
                    continue;
                }
                let source = self.library.get_source(file.source_id).await?;
                if !source.enabled {
                    continue;
                }
                let Some(external_id) = file.external_id else {
                    continue;
                };
                let value = self
                    .call(
                        &source.root_path,
                        Capability::Search,
                        serde_json::json!({"query":external_id,"type":"track","limit":1}),
                    )
                    .await?;
                let page: TrackPage = serde_json::from_value(value)
                    .map_err(|_| LekisError::invalid("插件封面元资料无效"))?;
                if let Some(track) = page.items.iter().find(|t| t.id == external_id) {
                    if let Some(raw) = &track.artwork_url {
                        self.remember_artwork(&source.root_path, id, &external_id, raw)
                            .await?;
                        saved = self
                            .library
                            .get_setting(&format!("{URL_PREFIX}{id}"))
                            .await?;
                    }
                }
                break;
            }
        }
        let Some(saved) = saved else {
            return Ok(None);
        };
        let reference: ArtworkReference =
            serde_json::from_str(&saved).map_err(|_| LekisError::invalid("封面元资料无效"))?;
        let files = self.library.track_files(id).await?;
        let mut authorized = false;
        for file in files {
            if file.source_kind == lekis_types::SourceKind::Plugin
                && file.external_id.as_deref() == Some(&reference.external_id)
            {
                let source = self.library.get_source(file.source_id).await?;
                authorized |= source.enabled && source.root_path == reference.plugin_id;
            }
        }
        if !authorized {
            return Ok(None);
        }
        let (_, manifest) = self.find_installed(&reference.plugin_id)?;
        let manifest = manifest.ok_or_else(|| LekisError::invalid("插件清单无效"))?;
        if self
            .library
            .get_setting(&format!("{ENABLED_PREFIX}{}", reference.plugin_id))
            .await?
            .as_deref()
            == Some("false")
        {
            return Ok(None);
        }
        let permissions = Permissions::new(&manifest.permissions, &[]);
        let _permit = self
            .artwork_downloads
            .acquire()
            .await
            .map_err(|_| LekisError::internal("封面下载任务已停止"))?;
        let raw = tokio::time::timeout(
            Duration::from_secs(12),
            download_image(&permissions, &reference.url),
        )
        .await
        .map_err(|_| LekisError::not_found("封面下载超时"))??;
        let artwork_id = crate::enrich::store_artwork_bytes(
            &self.artwork_cache,
            &self.library,
            crate::enrich::ArtworkTarget {
                track_id: None,
                album_id: None,
                replace_album: false,
            },
            raw,
            &format!("plugin:{}", reference.plugin_id),
        )
        .await?;
        // A user/embedded/sidecar cover always wins; an edit during download also wins.
        self.library
            .set_plugin_artwork_if_unchanged(id, artwork_id, previous)
            .await?;
        if let Some(events) = &self.artwork_events {
            events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            });
        }
        self.library.effective_artwork(id).await
    }

    pub(crate) fn prefetch_artwork_for_track(&self, id: TrackId) {
        let manager = self.clone();
        tokio::spawn(async move {
            let _ = manager.artwork_for_track(id, true).await;
        });
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;
    use axum::{routing::get, Router};
    use std::sync::atomic::{AtomicUsize, Ordering};

    async fn image_server() -> (String, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            320,
            180,
            image::Rgb([35, 80, 160]),
        ))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
        let png = Arc::new(png.into_inner());
        let hits = Arc::new(AtomicUsize::new(0));
        let count = hits.clone();
        let app = Router::new()
            .route(
                "/cover",
                get(move || {
                    let bytes = png.clone();
                    let count = count.clone();
                    async move {
                        count.fetch_add(1, Ordering::SeqCst);
                        ([("content-type", "image/png")], bytes.as_ref().clone())
                    }
                }),
            )
            .route(
                "/bad",
                get(|| async { ([("content-type", "text/html")], "not an image") }),
            )
            .route(
                "/redirect",
                get(|| async {
                    (
                        axum::http::StatusCode::FOUND,
                        [("location", "https://outside.invalid/cover")],
                    )
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (address, hits, task)
    }

    async fn fixture(cover: &str) -> (PathBuf, Library, PluginManager, TrackId) {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "lekis-plugin-artwork-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let plugin = root.join("package");
        fs::create_dir_all(&plugin).unwrap();
        fs::write(plugin.join("plugin.json"), r#"{"id":"dev.test.cover","name":"Cover","version":"1.0.0","apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"js","entry":"index.js","kinds":["source"],"permissions":{"network":["127.0.0.1"]}}"#).unwrap();
        fs::write(plugin.join("index.js"), format!("export function search() {{return {{items:[{{id:'stable',title:'Video',artists:['Artist'],durationMs:1000,artworkUrl:{}}}]}};}}", serde_json::to_string(cover).unwrap())).unwrap();
        let lib = Library::open(&root.join("library.sqlite")).unwrap();
        let manager =
            PluginManager::new(&root, lib.clone()).with_artwork_cache(&root.join("cache"));
        manager.install(&plugin).await.unwrap();
        let rows = manager
            .search("dev.test.cover", "keyword", 3)
            .await
            .unwrap();
        (root, lib, manager, rows.tracks[0].id)
    }

    #[tokio::test]
    async fn imports_cover_metadata_lazily_deduplicates_and_persists_all_tiers() {
        let (base, hits, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/cover")).await;
        assert_eq!(
            hits.load(Ordering::SeqCst),
            0,
            "search does not wait for image downloads"
        );
        let arts =
            futures_util::future::join_all((0..8).map(|_| manager.artwork_for_track(id, false)))
                .await;
        let art = arts[0].as_ref().unwrap();
        assert!(arts
            .iter()
            .all(|a| a.as_ref().map(|a| a.id) == Some(art.id)));
        assert_eq!(
            hits.load(Ordering::SeqCst),
            1,
            "same-track requests share the download"
        );
        assert_eq!(lib.track_row(id).await.unwrap().artwork_id, Some(art.id));
        assert_eq!(art.source, "plugin:dev.test.cover");
        for size in [128, 256, 512, 1024] {
            let file = root
                .join("cache")
                .join(lekis_library::cache_relative_path(&art.hash, size));
            let bytes = fs::read(file).unwrap();
            assert_eq!(&bytes[..4], b"RIFF");
            assert_eq!(&bytes[8..12], b"WEBP");
        }
        let restarted = PluginManager::new(&root, lib).with_artwork_cache(&root.join("cache"));
        assert_eq!(
            restarted.artwork_for_track(id, false).await.unwrap().id,
            art.id
        );
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        server.abort();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn website_cover_reuses_existing_provider_hash_without_losing_reference_origin() {
        let (base, hits, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/cover")).await;
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            320,
            180,
            image::Rgb([35, 80, 160]),
        ))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
        let hash = lekis_enrich::artwork_ingest::hash_bytes(&png.into_inner());
        let prior = lib
            .upsert_artwork(hash, "itunes".into(), None, None, None)
            .await
            .unwrap();
        let art = manager.artwork_for_track(id, false).await.unwrap();
        assert_eq!(art.id, prior);
        assert_eq!(art.source, "itunes");
        assert!(lib.track_artwork_is_plugin(id).await.unwrap());
        assert_eq!(
            manager.artwork_for_track(id, false).await.unwrap().id,
            prior
        );
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        server.abort();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn artwork_coordination_releases_idle_gates_and_bounds_failed_retry_entries() {
        let (root, lib, manager, id) = fixture("https://outside.invalid/cover").await;
        for number in 100..140 {
            assert!(manager
                .artwork_for_track(TrackId(number), false)
                .await
                .is_none());
        }
        let gates = manager.artwork_gates.lock().await;
        assert!(gates.len() <= 1);
        assert!(gates.values().all(|gate| gate.strong_count() == 0));
        drop(gates);
        let now = std::time::Instant::now();
        manager
            .artwork_retry_after
            .lock()
            .await
            .insert(TrackId(99), now - Duration::from_secs(1));
        assert!(manager
            .artwork_for_track(TrackId(99), false)
            .await
            .is_none());
        assert!(manager.artwork_retry_after.lock().await.is_empty());
        for number in 100..612 {
            manager
                .artwork_retry_after
                .lock()
                .await
                .insert(TrackId(number), now + Duration::from_secs(60));
        }
        lib.set_setting(&format!("{URL_PREFIX}{id}"), "invalid metadata")
            .await
            .unwrap();
        assert!(manager.artwork_for_track(id, false).await.is_none());
        let retries = manager.artwork_retry_after.lock().await;
        assert_eq!(retries.len(), 512);
        assert!(retries.contains_key(&id));
        drop(retries);
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn legacy_track_can_backfill_exact_metadata_and_missing_cache_is_rebuilt() {
        let (base, hits, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/cover")).await;
        lib.delete_setting(&format!("{URL_PREFIX}{id}"))
            .await
            .unwrap();
        assert!(manager.artwork_for_track(id, false).await.is_none());
        let art = manager.artwork_for_track(id, true).await.unwrap();
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        assert_eq!(lib.track_row(id).await.unwrap().id, id);
        for size in [128, 256, 512, 1024] {
            fs::remove_file(
                root.join("cache")
                    .join(lekis_library::cache_relative_path(&art.hash, size)),
            )
            .unwrap();
        }
        assert_eq!(
            manager.artwork_for_track(id, false).await.unwrap().id,
            art.id
        );
        assert_eq!(hits.load(Ordering::SeqCst), 2);
        server.abort();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn website_cover_replaces_legacy_album_match_but_concurrent_manual_edit_wins() {
        let (base, hits, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/cover")).await;
        let legacy = lib
            .upsert_artwork("old-auto".into(), "itunes".into(), None, None, None)
            .await
            .unwrap();
        lib.set_track_artwork(id, Some(legacy)).await.unwrap();
        let art = manager.artwork_for_track(id, false).await.unwrap();
        assert_ne!(art.id, legacy);
        assert_eq!(art.source, "plugin:dev.test.cover");
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        let manual = lib
            .upsert_artwork("new-manual".into(), "user".into(), None, None, None)
            .await
            .unwrap();
        lib.set_track_artwork(id, Some(manual)).await.unwrap();
        assert!(!lib
            .set_plugin_artwork_if_unchanged(id, art.id, Some(legacy))
            .await
            .unwrap());
        assert!(!lib
            .set_plugin_artwork_if_unchanged(id, art.id, Some(manual))
            .await
            .unwrap());
        assert_eq!(lib.effective_artwork_id(id).await.unwrap(), Some(manual));
        server.abort();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn failed_website_cover_never_displays_legacy_album_match() {
        let (base, _, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/bad")).await;
        let old = lib
            .upsert_artwork("old-album".into(), "itunes".into(), None, None, None)
            .await
            .unwrap();
        lib.set_track_artwork(id, Some(old)).await.unwrap();
        assert!(manager.artwork_for_track(id, false).await.is_none());
        assert!(
            manager.artwork_for_track(id, false).await.is_none(),
            "retry cooldown must not reveal legacy cover"
        );
        assert_eq!(
            lib.effective_artwork_id(id).await.unwrap(),
            Some(old),
            "failure does not destructively erase stored artwork"
        );
        server.abort();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn ordinary_local_album_cover_is_preserved_by_shared_artwork_route() {
        let (root, lib, manager, _) = fixture("https://outside.invalid/cover").await;
        let source = lib
            .add_source(lekis_types::SourceConfig {
                id: None,
                kind: lekis_types::SourceKind::Local,
                name: "Local".into(),
                addresses: vec![],
                root_path: "/music".into(),
                credential_ref: None,
                options: Default::default(),
                enabled: true,
            })
            .await
            .unwrap();
        lib.upsert_scanned(vec![lekis_library::ScannedFile {
            source_id: source,
            path: "local.flac".into(),
            size: 1,
            mtime_ms: 1,
            tags: lekis_library::ScannedTags {
                title: "Local recording".into(),
                album: Some("Shared album".into()),
                ..Default::default()
            },
        }])
        .await
        .unwrap();
        let track = lib
            .list_track_rows(lekis_types::TrackQuery {
                sort: lekis_types::TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await
            .unwrap()
            .into_iter()
            .find(|track| track.title == "Local recording")
            .unwrap();
        let full = lib.get_track(track.id).await.unwrap();
        let old = lib
            .upsert_artwork("local-album".into(), "itunes".into(), None, None, None)
            .await
            .unwrap();
        lib.set_album_artwork(full.album_id.unwrap(), Some(old))
            .await
            .unwrap();
        assert_eq!(
            manager.artwork_for_track(track.id, false).await.unwrap().id,
            old
        );
        assert!(manager.artwork_retry_after.lock().await.is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn artwork_does_not_replace_manual_cover_and_invalid_urls_do_not_hide_tracks() {
        let (base, hits, server) = image_server().await;
        let (root, lib, manager, id) = fixture(&format!("{base}/cover")).await;
        let manual = lib
            .upsert_artwork("manual".into(), "itunes".into(), None, None, None)
            .await
            .unwrap();
        // A user can select identical bytes already stored as an automatic cover.
        // Provenance belongs to the reference, not the deduplicated hash row.
        let selected = lib
            .upsert_artwork("manual".into(), "user".into(), None, None, None)
            .await
            .unwrap();
        assert_eq!(manual, selected);
        lib.set_user_track_artwork(id, manual).await.unwrap();
        assert_eq!(
            manager.artwork_for_track(id, true).await.unwrap().id,
            manual
        );
        assert!(!lib
            .set_plugin_artwork_if_unchanged(id, manual, Some(manual))
            .await
            .unwrap());
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        assert!(!lib.set_track_artwork_if_missing(id, manual).await.unwrap());
        let (badroot, _, badmanager, badid) = fixture("https://outside.invalid/cover").await;
        assert!(badmanager.artwork_for_track(badid, false).await.is_none());
        assert_eq!(
            badmanager
                .search("dev.test.cover", "keyword", 1)
                .await
                .unwrap()
                .tracks[0]
                .id,
            badid
        );
        server.abort();
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(badroot);
    }

    #[tokio::test]
    async fn download_validates_redirect_destination_and_image_type() {
        let (base, _, server) = image_server().await;
        let manifest = PluginManifest::parse(r#"{"id":"dev.test.image","name":"Image","version":"1.0.0","apiVersion":"1.0","minAppVersion":"0.1.0","runtime":"js","entry":"index.js","kinds":["source"],"permissions":{"network":["127.0.0.1"]}}"#).unwrap();
        let permissions = Permissions::new(&manifest.permissions, &[]);
        assert_eq!(
            download_image(&permissions, &format!("{base}/redirect"))
                .await
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        assert_eq!(
            download_image(&permissions, &format!("{base}/bad"))
                .await
                .unwrap_err()
                .code,
            ErrorCode::Unsupported
        );
        assert!(permitted_url(&permissions, "http://user@127.0.0.1/cover").is_err());
        server.abort();
    }
}
