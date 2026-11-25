//! 元数据补全流水线（ENR-01~12）。
//!
//! 把 `lekis-enrich` 的提供方能力接进核心：
//!
//! ```text
//! Track → TrackHint → 并发问所有提供方 → 逐条打分（ENR-05）
//!       → ≥0.85 自动应用（写覆盖层 / 封面 / 歌词，不改原文件）
//!       → 0.5~0.85 进待确认队列（enrich_candidate）
//!       → <0.5 丢弃
//! ```
//!
//! 自动应用的封面会把图片下载下来、缩放成档位、编码 WebP 落到本机缓存目录
//! （数据库只存元数据），然后把 `artwork` 行和
//! 曲目/专辑的 `artwork_id` 一起写好。歌词直接进 `lyrics` 表。
//!
//! 所有网络失败都只记日志，不打断整批补全：一个提供方挂了不能影响另一个。

use crate::config::CoreConfig;
use lekis_enrich::artist_image::ArtistImages;
use lekis_enrich::artwork_ingest;
use lekis_enrich::bangumi::BangumiArtwork;
use lekis_enrich::providers::{AmllLyrics, CoverArtArchive, ITunes, Lrclib};
use lekis_enrich::providers_extra::{
    DeezerArtwork, KugouLyrics, LyricsOvh, MusicBrainzCoverArt, NetEaseArtwork, NetEaseLyrics,
    VocaDbArtwork,
};
use lekis_enrich::{
    decide, ArtworkPayload, ArtworkProvider, Candidate, Decision, LyricsPayload, LyricsProvider,
    QqLyrics, TrackHint, AUTO_APPLY_THRESHOLD,
};
use lekis_library::{cache_relative_path, Library, NewEnrichCandidate};
use lekis_types::*;

/// 在线查不到头像的艺人，隔多久再查一次（30 天）。
const ARTIST_MISS_RETRY_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// "群星" / "未知艺人" 这类占位名不去查头像。
fn is_placeholder_artist(name: &str) -> bool {
    let n = lekis_library::normalize::norm_key(name);
    n.is_empty()
        || matches!(
            n.as_str(),
            "various artists"
                | "various"
                | "va"
                | "unknown"
                | "unknown artist"
                | "群星"
                | "未知"
                | "未知艺人"
                | "未知歌手"
                | "佚名"
                | "[unknown]"
        )
}

/// 一次补全最多保留多少条候选。
const MAX_PROVIDERS_PER_KIND: usize = 8;
const QQ_EXAMPLE_ID: &str = "dev.lekis.example.qq-lyrics";

fn lyrics_source_key(source: &str) -> &str {
    if source.strip_prefix("plugin:") == Some(QQ_EXAMPLE_ID) {
        QqLyrics::NAME
    } else {
        source
    }
}

/// 补全范围设置键：`all`（默认）/ `artwork`（仅封面）/ `lyrics`（仅歌词）。
const ENRICH_SCOPE_SETTING_KEY: &str = "enrich.scope";

/// 缓存里为每张封面生成的尺寸档位（ENR-12：列表 128/256、网格 512、正在播放页 1024）。
const ARTWORK_TIERS: [u32; 4] = artwork_ingest::THUMBNAIL_WIDTHS;

/// 一次补全的结果统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnrichReport {
    /// 自动应用的条数（歌词 + 封面）。
    pub auto_applied: u32,
    /// 进入待确认队列的条数。
    pub queued: u32,
    /// 丢弃的条数。
    pub discarded: u32,
}

impl EnrichReport {
    /// 累加另一份统计（歌词、封面各跑一遍后合并）。
    fn absorb(&mut self, other: Self) {
        self.auto_applied += other.auto_applied;
        self.queued += other.queued;
        self.discarded += other.discarded;
    }
}

/// 补全流水线。持有所有免 Key 提供方实例（内部有连接池、限速器和缓存）。
pub(crate) struct EnrichPipeline {
    lyrics_providers: Vec<Box<dyn LyricsProvider>>,
    artwork_providers: Vec<Box<dyn ArtworkProvider>>,
    cache_dir: std::path::PathBuf,
    /// 艺人头像检索（网易云 / Deezer）。
    artist_images: Option<ArtistImages>,
    /// 串行化头像检索，避免列表和详情页同时为同一个艺人下载。
    artist_lock: tokio::sync::Mutex<()>,
    /// 本次运行已经试过的艺人（网络失败也不在同一次运行里反复重试）。
    artist_tried: std::sync::Mutex<std::collections::HashSet<ArtistId>>,
}

impl EnrichPipeline {
    /// 构造流水线。某个提供方构造失败（比如 TLS 初始化不了）时跳过它，不影响其它。
    pub(crate) fn new(config: &CoreConfig) -> Self {
        let mut lyrics_providers: Vec<Box<dyn LyricsProvider>> = Vec::new();
        if let Ok(p) = AmllLyrics::new() {
            lyrics_providers.push(Box::new(p));
        }
        if let Ok(p) = Lrclib::new() {
            lyrics_providers.push(Box::new(p));
        }
        if let Ok(p) = NetEaseLyrics::new() {
            lyrics_providers.push(Box::new(p));
        }
        if let Ok(p) = QqLyrics::new() {
            lyrics_providers.push(Box::new(p));
        }
        if let Ok(p) = KugouLyrics::new() {
            lyrics_providers.push(Box::new(p));
        }
        if let Ok(p) = LyricsOvh::new() {
            lyrics_providers.push(Box::new(p));
        }

        let mut artwork_providers: Vec<Box<dyn ArtworkProvider>> = Vec::new();
        if let Ok(p) = CoverArtArchive::new() {
            artwork_providers.push(Box::new(p));
        }
        if let Ok(p) = ITunes::new() {
            artwork_providers.push(Box::new(p));
        }
        if let Ok(p) = DeezerArtwork::new() {
            artwork_providers.push(Box::new(p));
        }
        if let Ok(p) = NetEaseArtwork::new() {
            artwork_providers.push(Box::new(p));
        }
        if let Ok(p) = MusicBrainzCoverArt::new() {
            artwork_providers.push(Box::new(p));
        }
        if let Ok(p) = VocaDbArtwork::new() {
            artwork_providers.push(Box::new(p));
        }

        if let Ok(p) = BangumiArtwork::new() {
            artwork_providers.push(Box::new(p));
        }

        Self {
            lyrics_providers,
            artwork_providers,
            cache_dir: config.cache_dir.clone(),
            artist_images: ArtistImages::new().ok(),
            artist_lock: tokio::sync::Mutex::new(()),
            artist_tried: Default::default(),
        }
    }

    async fn query_lyrics_cascade(
        &self,
        hint: &TrackHint,
    ) -> Result<Vec<Candidate<LyricsPayload>>> {
        let mut all = Vec::new();
        let mut first_error = None;
        for provider in &self.lyrics_providers {
            match provider.find_lyrics(hint).await {
                Ok(list) => {
                    let has_synced_hit = list.iter().any(|c| {
                        c.payload.format != LyricsFormat::Plain
                            && c.provider_confidence >= AUTO_APPLY_THRESHOLD
                    });
                    all.extend(list);
                    if has_synced_hit {
                        break;
                    }
                }
                Err(error) => {
                    tracing::warn!(target: "lekis_core::enrich", provider = provider.name(), code = %error.code.as_str(), "歌词提供方查询失败，继续下一个");
                    first_error.get_or_insert(error);
                }
            }
        }
        all.sort_by(|a, b| {
            let rank = |c: &Candidate<LyricsPayload>| {
                (
                    c.provider_confidence >= AUTO_APPLY_THRESHOLD,
                    c.payload.format != LyricsFormat::Plain,
                )
            };
            rank(b)
                .cmp(&rank(a))
                .then_with(|| b.provider_confidence.total_cmp(&a.provider_confidence))
        });
        if all.is_empty() {
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        Ok(all)
    }

    pub(crate) async fn manual_lyric_search(
        &self,
        library: &Library,
        track_id: TrackId,
        title: String,
        artist: String,
    ) -> Result<Vec<lekis_library::LyricSearchVersion>> {
        use futures_util::{stream, StreamExt};
        let title = title.trim();
        let artist = artist.trim();
        if title.is_empty() || title.chars().count() > 512 || artist.chars().count() > 512 {
            return Err(LekisError::invalid("invalid lyric search title or artist"));
        }
        let track = library.get_track(track_id).await?;
        let hint = TrackHint {
            title: title.to_owned(),
            artists: if artist.is_empty() {
                vec![]
            } else {
                vec![artist.to_owned()]
            },
            duration_ms: track.duration_ms,
            ..Default::default()
        };
        let hint = &hint;
        let mut requests = Vec::new();
        for (order, provider) in self.lyrics_providers.iter().enumerate() {
            if provider.name() == "lyrics.ovh" {
                continue;
            }
            requests.push(async move {
                let result = tokio::time::timeout(
                    std::time::Duration::from_secs(12),
                    provider.search_lyrics(hint),
                )
                .await
                .map_err(|_| LekisError::new(ErrorCode::Network, "lyric provider timeout"))
                .and_then(|r| r);
                (order, result)
            });
        }
        let responses = stream::iter(requests)
            .buffer_unordered(3)
            .collect::<Vec<_>>()
            .await;
        let mut candidates = Vec::new();
        let mut error = None;
        for (order, result) in responses {
            match result {
                Ok(list) => candidates.extend(list.into_iter().map(|candidate| (order, candidate))),
                Err(e) => {
                    error.get_or_insert(e);
                }
            }
        }
        if candidates.is_empty() {
            return error.map_or_else(|| Ok(Vec::new()), Err);
        }
        candidates.sort_by(|(order_a, a), (order_b, b)| {
            b.provider_confidence
                .total_cmp(&a.provider_confidence)
                .then(order_a.cmp(order_b))
        });
        let versions = candidates
            .into_iter()
            .take(20)
            .map(|(_, c)| lekis_library::LyricSearchVersion {
                row: lekis_library::LyricsRow {
                    id: 0,
                    track_id,
                    lyrics: Lyrics {
                        source: c.source,
                        format: c.payload.format,
                        content: c.payload.content,
                        offset_ms: 0,
                        confidence: c.provider_confidence,
                    },
                    is_active: false,
                    created_at: 0,
                },
                title: Some(c.matched.title).filter(|s| !s.trim().is_empty()),
                artists: c.matched.artists,
                album: c.matched.album,
                duration_ms: i64::try_from(c.matched.duration_ms).ok().filter(|d| *d > 0),
            })
            .collect();
        library.store_lyric_search(track_id, versions).await
    }

    // Stop only after an image has actually downloaded and decoded. A matching
    // MusicBrainz release can have no CAA image; its guessed URL is not success.
    async fn fill_artwork(
        &self,
        library: &Library,
        track: &Track,
        hint: &TrackHint,
    ) -> Result<EnrichReport> {
        let mut report = EnrichReport::default();
        for provider in &self.artwork_providers {
            match provider.find_artwork(hint).await {
                Ok(candidates) => {
                    let result = self.apply_artwork(library, track, hint, candidates).await?;
                    let applied = result.auto_applied > 0;
                    report.absorb(result);
                    if applied {
                        break;
                    }
                }
                Err(error) => {
                    tracing::warn!(target: "lekis_core::enrich", provider=provider.name(), code=%error.code.as_str(), "封面来源暂不可用，继续下一个")
                }
            }
        }
        Ok(report)
    }

    pub(crate) async fn fetch_plugin_lyrics(
        &self,
        library: &Library,
        manager: &crate::plugins::PluginManager,
        track_id: TrackId,
    ) -> Result<()> {
        let mut available = manager.list().await?;
        if self
            .lyrics_providers
            .iter()
            .any(|p| p.name() == QqLyrics::NAME)
        {
            available.retain(|plugin| plugin.id != QQ_EXAMPLE_ID);
        }
        if !available
            .iter()
            .any(|p| p.enabled && p.kinds.iter().any(|k| k == "lyrics" || k == "source"))
        {
            return Ok(());
        }
        let track = library.get_track(track_id).await?;
        let hint = hint_for(&track, library).await?;
        let candidates = manager.lyric_candidates(available, track_id, &hint).await?;
        if !candidates.is_empty() {
            self.apply_lyrics(library, track_id, &hint, candidates)
                .await?;
        }
        Ok(())
    }

    /// 只查歌词（按优先级级联所有免 Key 歌词源）。播放时按需调用，不碰封面。
    pub(crate) async fn fetch_lyrics(
        &self,
        library: &Library,
        track_id: TrackId,
        force: bool,
    ) -> Result<bool> {
        if self.lyrics_providers.is_empty() {
            return Ok(false);
        }
        if !force && library.active_lyrics(track_id).await?.is_some() {
            return Ok(false);
        }
        let track = library.get_track(track_id).await?;
        let hint = hint_for(&track, library).await?;
        let candidates = self.query_lyrics_cascade(&hint).await?;
        let found = !candidates.is_empty();
        self.apply_lyrics(library, track_id, &hint, candidates)
            .await?;
        Ok(found)
    }

    /// 对一首歌跑一次补全（遵守 `enrich.scope`：`all` / `artwork` / `lyrics`）。
    pub(crate) async fn enrich_track(
        &self,
        library: &Library,
        track_id: TrackId,
    ) -> Result<EnrichReport> {
        let scope = library
            .get_setting(ENRICH_SCOPE_SETTING_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| "all".to_string());
        let want_lyrics = scope != "artwork";
        let want_artwork = scope != "lyrics";

        let track = library.get_track(track_id).await?;
        let hint = hint_for(&track, library).await?;
        let mut report = EnrichReport::default();

        // ---- 歌词（ENR-03）----
        if want_lyrics && library.active_lyrics(track_id).await?.is_none() {
            match self.query_lyrics_cascade(&hint).await {
                Ok(candidates) => report.absorb(
                    self.apply_lyrics(library, track_id, &hint, candidates)
                        .await?,
                ),
                // Batch enrichment should still fetch artwork when every lyrics
                // source is unavailable. Explicit fetch/retry keeps typed errors.
                Err(error) => {
                    tracing::warn!(target: "lekis_core::enrich", code = %error.code.as_str(), "歌词查询失败，继续补全封面")
                }
            }
        }

        // ---- 封面（ENR-01）----
        if want_artwork
            && !plugin_only_track(library, track_id).await?
            && library.effective_artwork_id(track_id).await?.is_none()
        {
            report.absorb(self.fill_artwork(library, &track, &hint).await?);
        }

        Ok(report)
    }

    /// 逐条处理歌词候选。
    async fn apply_lyrics(
        &self,
        library: &Library,
        track_id: TrackId,
        _hint: &TrackHint,
        candidates: Vec<Candidate<LyricsPayload>>,
    ) -> Result<EnrichReport> {
        let mut report = EnrichReport::default();
        let mut queued: Vec<NewEnrichCandidate> = Vec::new();
        let existing = library.list_lyrics(track_id).await?;
        let mut selected = existing.iter().find(|row| row.is_active).map(|row| row.id);
        let mut seen = Vec::new();
        for candidate in &candidates {
            let identity = (lyrics_source_key(&candidate.source), &candidate.payload);
            if seen.contains(&identity) {
                continue;
            }
            if seen.len() == MAX_PROVIDERS_PER_KIND {
                break;
            }
            seen.push(identity);
            // Providers already combine metadata identity and their own reliability.
            let score = candidate.provider_confidence;
            let decision = decide(score);
            if matches!(decision, Decision::Discard) {
                report.discarded += 1;
                continue;
            }
            let lyrics = Lyrics {
                format: candidate.payload.format,
                content: candidate.payload.content.clone(),
                source: candidate.source.clone(),
                offset_ms: 0,
                confidence: score,
            };
            let existing_row = existing.iter().find(|row| {
                lyrics_source_key(&row.lyrics.source) == lyrics_source_key(&lyrics.source)
                    && row.lyrics.format == lyrics.format
                    && row.lyrics.content == lyrics.content
            });
            let id = if let Some(row) = existing_row {
                row.id
            } else {
                library
                    .save_lyrics_inactive(track_id, lyrics.clone())
                    .await?
            };
            match decision {
                Decision::AutoApply => {
                    if selected.is_none() { selected = Some(id); report.auto_applied += 1; }
                }
                Decision::Review => queued.push(NewEnrichCandidate {
                    track_id: Some(track_id), album_id: None, kind: "lyrics".into(),
                    payload_json: serde_json::json!({ "format": format_to_str(lyrics.format), "content": lyrics.content }).to_string(),
                    source: existing_row.map(|row| &row.lyrics.source).unwrap_or(&candidate.source).clone(), score,
                }),
                Decision::Discard => {}
            }
        }
        if let Some(id) = selected {
            library.activate_lyrics_if_empty(track_id, id).await?;
        }
        report.queued = library.insert_enrich_candidates(queued).await? as u32;
        Ok(report)
    }

    /// 逐条处理封面候选。
    async fn apply_artwork(
        &self,
        library: &Library,
        track: &Track,
        _hint: &TrackHint,
        candidates: Vec<Candidate<ArtworkPayload>>,
    ) -> Result<EnrichReport> {
        let mut report = EnrichReport::default();
        let mut queued: Vec<NewEnrichCandidate> = Vec::new();

        for candidate in candidates.into_iter().take(MAX_PROVIDERS_PER_KIND) {
            // Built-in providers already score metadata once (see providers.rs).
            let score = candidate.provider_confidence.clamp(0.0, 1.0);
            let payload_json = serde_json::json!({
                "url": candidate.payload.url,
                "width": candidate.payload.width,
                "height": candidate.payload.height,
            })
            .to_string();

            match decide(score) {
                Decision::AutoApply => match store_artwork(
                    &self.cache_dir,
                    library,
                    ArtworkTarget {
                        track_id: None,
                        album_id: None,
                        replace_album: false,
                    },
                    &candidate.payload.url,
                    &candidate.source,
                )
                .await
                {
                    Ok(artwork_id) => {
                        // The user may have selected a cover while the download was running.
                        // Attach only if both track and album are still uncovered.
                        if library
                            .set_track_artwork_if_missing(track.id, artwork_id)
                            .await?
                        {
                            report.auto_applied += 1;
                        }
                        break;
                    }
                    Err(e) => {
                        // 下载/解码失败的失效图直接跳过，避免把破图放进待确认误导用户。
                        tracing::warn!(
                            target: "lekis_core::enrich",
                            provider = %candidate.source,
                            code = %e.code.as_str(),
                            "高置信度封面下载/处理失败，跳过并尝试下一条候选"
                        );
                        report.discarded += 1;
                    }
                },
                Decision::Review => queued.push(NewEnrichCandidate {
                    track_id: Some(track.id),
                    album_id: track.album_id,
                    kind: "artwork".into(),
                    payload_json,
                    source: candidate.source,
                    score,
                }),
                Decision::Discard => report.discarded += 1,
            }
        }

        report.queued = library.insert_enrich_candidates(queued).await? as u32;
        Ok(report)
    }

    /// 艺人头像：已有就直接返回；没有就在线找一次（网易云 / Deezer，名字须一致），
    /// 下载进封面缓存并写回 `artist.artwork_id`。找不到的记一笔，[`ARTIST_MISS_RETRY_MS`] 内不再查。
    pub(crate) async fn artist_artwork(
        &self,
        library: &Library,
        id: ArtistId,
    ) -> Result<Option<lekis_library::ArtworkRow>> {
        if let Some(artwork_id) = library.get_artist(id).await?.artwork_id {
            return library.get_artwork(artwork_id).await.map(Some);
        }
        let Some(images) = &self.artist_images else {
            return Ok(None);
        };
        let _guard = self.artist_lock.lock().await;
        // 排队期间可能已经被别的调用补上了。
        let artist = library.get_artist(id).await?;
        if let Some(artwork_id) = artist.artwork_id {
            return library.get_artwork(artwork_id).await.map(Some);
        }
        if !self
            .artist_tried
            .lock()
            .map(|mut t| t.insert(id))
            .unwrap_or(false)
        {
            return Ok(None);
        }
        if is_placeholder_artist(&artist.name) {
            return Ok(None);
        }
        let miss_key = format!("artist.image.miss.{}", id.0);
        if let Some(at) = library.get_setting(&miss_key).await? {
            if now_ms() - at.parse::<i64>().unwrap_or(0) < ARTIST_MISS_RETRY_MS {
                return Ok(None);
            }
        }

        let same = |a: &str, b: &str| {
            lekis_library::normalize::norm_key(a) == lekis_library::normalize::norm_key(b)
        };
        let found = match images.find(&artist.name, same).await {
            Ok(found) => found,
            Err(error) => {
                // 网络问题：下次启动再试，不记"查无此人"。
                tracing::debug!(target: "lekis_core::enrich", code = %error.code.as_str(), "艺人头像检索失败");
                return Ok(None);
            }
        };
        let Some(image) = found else {
            library
                .set_setting(&miss_key, &now_ms().to_string())
                .await?;
            return Ok(None);
        };
        let target = ArtworkTarget {
            track_id: None,
            album_id: None,
            replace_album: false,
        };
        match store_artwork(&self.cache_dir, library, target, &image.url, image.source).await {
            Ok(artwork_id) => {
                library.set_artist_artwork(id, Some(artwork_id)).await?;
                let _ = library.delete_setting(&miss_key).await;
                library.get_artwork(artwork_id).await.map(Some)
            }
            Err(error) => {
                tracing::debug!(target: "lekis_core::enrich", source = image.source, code = %error.code.as_str(), "艺人头像下载失败");
                Ok(None)
            }
        }
    }

    /// 应用一条已经入库的待确认候选（用户点"接受"时调）。
    pub(crate) async fn apply_candidate(
        &self,
        library: &Library,
        row: &lekis_library::EnrichCandidateRow,
    ) -> Result<()> {
        apply_candidate(&self.cache_dir, library, row).await
    }
}

/// Plugin catalog entries get their artwork from the website, never album search.
async fn plugin_only_track(library: &Library, track_id: TrackId) -> Result<bool> {
    let files = library.track_files(track_id).await?;
    Ok(!files.is_empty() && files.iter().all(|f| f.source_kind == SourceKind::Plugin))
}

/// 封面要挂到哪里。
#[derive(Debug, Clone, Copy)]
pub(crate) struct ArtworkTarget {
    /// 曲目（有就总是设成曲目级封面）。
    pub(crate) track_id: Option<TrackId>,
    /// 专辑。
    pub(crate) album_id: Option<AlbumId>,
    /// `true`：无条件替换专辑封面；`false`：专辑没有封面时才补上。
    pub(crate) replace_album: bool,
}

/// 下载（带节流 + 缓存）→ 生成各档缩略图 → 落盘到封面缓存 → 入库 → 挂到曲目 / 专辑上。
///
/// 只写本机缓存目录和数据库，**从不改用户的原始音频文件**。返回封面 ID。
pub(crate) async fn store_artwork(
    cache_dir: &std::path::Path,
    library: &Library,
    target: ArtworkTarget,
    url: &str,
    source: &str,
) -> Result<ArtworkId> {
    let raw = artwork_ingest::fetch_image_cached(url).await?;
    store_artwork_bytes(cache_dir, library, target, raw.to_vec(), source).await
}

/// 和 [`store_artwork`] 一样，但输入已经是图片字节（本地内嵌 / 侧车封面用）。
pub(crate) async fn store_artwork_bytes(
    cache_dir: &std::path::Path,
    library: &Library,
    target: ArtworkTarget,
    raw: Vec<u8>,
    source: &str,
) -> Result<ArtworkId> {
    let tiers =
        tokio::task::spawn_blocking(move || artwork_ingest::process_tiers(&raw, &ARTWORK_TIERS))
            .await
            .map_err(|e| LekisError::internal(format!("封面处理任务失败：{e}")))??;

    // 同哈希的文件已经在就不重写（同一张封面从不同提供方拿到时去重）。
    for (width, bytes) in &tiers.files {
        let path = cache_dir.join(cache_relative_path(&tiers.hash, *width));
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        if !path.exists() {
            write_atomic(&path, bytes).await?;
        }
    }

    let artwork_id = library
        .upsert_artwork(
            tiers.hash,
            source.to_string(),
            Some(tiers.width),
            Some(tiers.height),
            Some(tiers.palette),
        )
        .await?;

    // 曲目级优先；同时给专辑打上，让别的曲目也能用（ENR-01）。
    if let Some(track_id) = target.track_id {
        if source == "user" {
            library.set_user_track_artwork(track_id, artwork_id).await?;
        } else {
            library
                .set_track_artwork(track_id, Some(artwork_id))
                .await?;
        }
    }
    if let Some(album_id) = target.album_id {
        if target.replace_album || library.get_album(album_id).await?.artwork_id.is_none() {
            library
                .set_album_artwork(album_id, Some(artwork_id))
                .await?;
            if source == "user" {
                library.set_user_album_artwork(album_id, artwork_id).await?;
            }
        }
    }
    // 封面落盘生效后，自动清理该曲目及所属专辑下所有已过期的待确认封面候选。
    let _ = library.dismiss_stale_artwork_candidates().await;
    Ok(artwork_id)
}

/// 先写临时文件再改名，避免 UI 读到写了一半的图。
async fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("webp.tmp");
    tokio::fs::write(&tmp, bytes).await?;
    if let Err(e) = tokio::fs::rename(&tmp, path).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        // 并发写同一张图时对方可能已经改名成功了。
        if !path.exists() {
            return Err(e.into());
        }
    }
    Ok(())
}

/// 把 `Library` 里的曲目信息转成提供方要的查询线索。
async fn hint_for(track: &Track, library: &Library) -> Result<TrackHint> {
    let mbid_release = match track.album_id {
        Some(id) => library
            .get_album(id)
            .await
            .ok()
            .and_then(|a| a.mbid_release),
        None => None,
    };
    Ok(TrackHint {
        title: track.title.clone(),
        artists: track.artists.iter().map(|a| a.name.clone()).collect(),
        album: track.album_title.clone(),
        duration_ms: track.duration_ms,
        mbid_recording: track.mbid_recording.clone(),
        mbid_release,
    })
}

/// `LyricsFormat` → 存进候选 JSON 的字符串。
fn format_to_str(format: LyricsFormat) -> &'static str {
    match format {
        LyricsFormat::Plain => "plain",
        LyricsFormat::Lrc => "lrc",
        LyricsFormat::EnhancedLrc => "enhanced_lrc",
        LyricsFormat::Ttml => "ttml",
    }
}

/// 候选 JSON 里的格式字符串 → `LyricsFormat`（未知按 LRC，逐行歌词最常见）。
fn format_from_str(raw: &str) -> LyricsFormat {
    match raw {
        "plain" => LyricsFormat::Plain,
        "enhanced_lrc" => LyricsFormat::EnhancedLrc,
        "ttml" => LyricsFormat::Ttml,
        _ => LyricsFormat::Lrc,
    }
}

/// 应用一条已经入库的待确认候选（用户点"接受"时调）。
///
/// 支持 `lyrics`（直接入库）、`tags`（写覆盖层）和 `artwork`（下载 → 缩略图 → 设成曲目 /
/// 专辑封面）；其余类型只改状态。
pub(crate) async fn apply_candidate(
    cache_dir: &std::path::Path,
    library: &Library,
    row: &lekis_library::EnrichCandidateRow,
) -> Result<()> {
    match row.kind.as_str() {
        "lyrics" => {
            let value: serde_json::Value = serde_json::from_str(&row.payload_json)
                .map_err(|e| LekisError::invalid(format!("候选内容不是合法 JSON：{e}")))?;
            let content = value
                .get("content")
                .and_then(|v| v.as_str())
                .ok_or_else(|| LekisError::invalid("歌词候选缺少 content"))?;
            let format = value
                .get("format")
                .and_then(|v| v.as_str())
                .map(format_from_str)
                .unwrap_or(LyricsFormat::Lrc);
            let Some(track_id) = row.track_id else {
                return Err(LekisError::invalid("歌词候选缺少曲目"));
            };
            library
                .save_selected_lyrics(
                    track_id,
                    Lyrics {
                        format,
                        content: content.to_string(),
                        source: row.source.clone(),
                        offset_ms: 0,
                        confidence: row.score,
                    },
                )
                .await?;
            Ok(())
        }
        "tags" => {
            let overlay: TrackOverlay = serde_json::from_str(&row.payload_json)
                .map_err(|e| LekisError::invalid(format!("覆盖层候选格式不对：{e}")))?;
            let Some(track_id) = row.track_id else {
                return Err(LekisError::invalid("覆盖层候选缺少曲目"));
            };
            library.set_track_overlay(track_id, Some(overlay)).await
        }
        "artwork" => {
            if let Some(id) = row.track_id {
                if plugin_only_track(library, id).await? {
                    return Err(LekisError::unsupported(
                        "在线音源使用网站封面，不应用本地专辑封面候选",
                    ));
                }
            }
            let value: serde_json::Value = serde_json::from_str(&row.payload_json)
                .map_err(|e| LekisError::invalid(format!("候选内容不是合法 JSON：{e}")))?;
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .filter(|u| !u.is_empty())
                .ok_or_else(|| LekisError::invalid("封面候选缺少 url"))?;
            if row.track_id.is_none() && row.album_id.is_none() {
                return Err(LekisError::invalid("封面候选既没有曲目也没有专辑"));
            }
            // 用户亲手确认的：曲目封面总是替换；只针对专辑的候选替换专辑封面，
            // 针对曲目的候选只在专辑还没有封面时顺便补上。
            let target = ArtworkTarget {
                track_id: row.track_id,
                album_id: row.album_id,
                replace_album: row.track_id.is_none(),
            };
            // Accepted artwork is an explicit user choice, protected from automatic replacement.
            store_artwork(cache_dir, library, target, url, "user").await?;
            Ok(())
        }
        _ => Ok(()),
    }
}

/// 不小于 `width` 的最近一档（超过最大档时取最大档）。
pub(crate) fn tier_for(width: u32) -> u32 {
    ARTWORK_TIERS
        .iter()
        .copied()
        .find(|t| *t >= width)
        .unwrap_or(ARTWORK_TIERS[ARTWORK_TIERS.len() - 1])
}

/// 封面在缓存目录里的绝对路径（UI 层拿到后直接读文件显示）。
///
/// 返回不小于 `width` 的最近一档；这一档的文件不存在时（老版本只存了一档），
/// 用缓存里已有的最大那份**就地生成**再返回。一份都没有时仍然返回预期路径，UI 显示占位图。
pub(crate) fn artwork_file_path(config: &CoreConfig, hash: &str, width: u32) -> std::path::PathBuf {
    let tier = tier_for(width);
    let path = config.cache_dir.join(cache_relative_path(hash, tier));
    if path.exists() || !is_hex(hash) {
        return path;
    }
    if let Err(e) = generate_tier(hash, tier, &path) {
        tracing::debug!(target: "lekis_core::enrich", code = %e.code.as_str(), "按需生成缩略图失败");
    }
    path
}

fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 从同一张封面已有的最大一份缓存文件缩放出 `tier` 档，写到 `out`。
fn generate_tier(hash: &str, tier: u32, out: &std::path::Path) -> Result<()> {
    let dir = out
        .parent()
        .ok_or_else(|| LekisError::internal("artwork path has no parent"))?;
    let prefix = format!("{hash}_");
    let mut best: Option<(u32, std::path::PathBuf)> = None;
    for entry in std::fs::read_dir(dir)?.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(w) = name
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix(".webp"))
            .and_then(|w| w.parse::<u32>().ok())
        else {
            continue;
        };
        if best.as_ref().is_none_or(|(bw, _)| w > *bw) {
            best = Some((w, entry.path()));
        }
    }
    let (_, source) = best.ok_or_else(|| LekisError::not_found("no cached artwork to scale"))?;
    let bytes = std::fs::read(source)?;
    let tiers = artwork_ingest::process_tiers(&bytes, &[tier])?;
    let (_, webp) = tiers
        .files
        .into_iter()
        .next()
        .ok_or_else(|| LekisError::internal("no tier produced"))?;
    let tmp = out.with_extension("webp.tmp");
    std::fs::write(&tmp, webp)?;
    std::fs::rename(&tmp, out)?;
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn format_roundtrip() {
        for f in [
            LyricsFormat::Plain,
            LyricsFormat::Lrc,
            LyricsFormat::EnhancedLrc,
            LyricsFormat::Ttml,
        ] {
            assert_eq!(format_from_str(format_to_str(f)), f);
        }
        assert_eq!(format_from_str("unknown"), LyricsFormat::Lrc);
    }

    #[test]
    fn artwork_path_is_inside_cache_dir() {
        let config = CoreConfig::for_tests(std::path::Path::new("C:/tmp/lekis"));
        let path = artwork_file_path(&config, "abcdef0123456789", 1024);
        assert!(path.starts_with(&config.cache_dir));
        assert!(path
            .to_string_lossy()
            .ends_with("abcdef0123456789_1024.webp"));
    }

    #[test]
    fn tiers_round_up_to_nearest_generated_size() {
        assert_eq!(tier_for(1), 128);
        assert_eq!(tier_for(128), 128);
        assert_eq!(tier_for(129), 256);
        assert_eq!(tier_for(320), 512);
        assert_eq!(tier_for(600), 1024);
        assert_eq!(tier_for(4000), 1024);
    }

    fn png(w: u32, h: u32) -> Vec<u8> {
        let mut buf = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            w,
            h,
            image::Rgb([180, 40, 60]),
        ))
        .write_to(&mut buf, image::ImageFormat::Png)
        .expect("encode png");
        buf.into_inner()
    }

    #[test]
    fn missing_tier_is_generated_from_the_largest_cached_file() {
        let root = std::env::temp_dir().join(format!("lekis-core-tier-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let config = CoreConfig::for_tests(&root);
        let hash = "ab12cd34";
        // 只放一份老版本留下的"实际宽度"文件。
        let legacy = config.cache_dir.join(cache_relative_path(hash, 700));
        std::fs::create_dir_all(legacy.parent().expect("parent")).expect("mkdir");
        std::fs::write(&legacy, png(700, 700)).expect("write legacy");

        let path = artwork_file_path(&config, hash, 200);
        assert!(path.to_string_lossy().ends_with("ab12cd34_256.webp"));
        assert!(path.exists(), "256 档应当按需生成");
        let img = image_dims(&path);
        assert_eq!(img, (256, 256));

        // 没有任何缓存文件时返回预期路径但不报错。
        let none = artwork_file_path(&config, "ffff0000", 1024);
        assert!(!none.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    fn image_dims(path: &std::path::Path) -> (u32, u32) {
        let img = image::load_from_memory(&std::fs::read(path).expect("read")).expect("decode");
        (img.width(), img.height())
    }
}

#[cfg(test)]
#[path = "enrich_lyrics_tests.rs"]
mod lyrics_tests;

#[cfg(test)]
#[path = "enrich_artwork_tests.rs"]
mod artwork_tests;
