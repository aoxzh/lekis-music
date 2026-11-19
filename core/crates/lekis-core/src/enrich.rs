//! 元数据补全流水线（REQUIREMENTS 3.3，ENR-01~12）。
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
//! （`docs/ARCHITECTURE.md` 第 5 节：数据库只存元数据），然后把 `artwork` 行和
//! 曲目/专辑的 `artwork_id` 一起写好。歌词直接进 `lyrics` 表。
//!
//! 所有网络失败都只记日志，不打断整批补全：一个提供方挂了不能影响另一个。

use crate::config::CoreConfig;
use lekis_enrich::artwork_ingest;
use lekis_enrich::providers::{CoverArtArchive, ITunes, Lrclib};
use lekis_enrich::{
    decide, ArtworkPayload, ArtworkProvider, Candidate, Decision, LyricsPayload, LyricsProvider,
    TrackHint,
};
use lekis_library::{cache_relative_path, Library, NewEnrichCandidate};
use lekis_types::*;

/// 一次补全最多问多少个提供方（防止插件没完没了地加）。
const MAX_PROVIDERS_PER_KIND: usize = 4;

/// 自动应用封面时写入的尺寸档位（ENR-12：正在播放页用 1024）。
const ARTWORK_TARGET_PX: u32 = 1024;

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

/// 补全流水线。持有提供方实例（它们内部有 HTTP 连接池、限速器和缓存）。
pub(crate) struct EnrichPipeline {
    lrclib: Option<Lrclib>,
    cover_art: Option<CoverArtArchive>,
    itunes: Option<ITunes>,
    cache_dir: std::path::PathBuf,
}

impl EnrichPipeline {
    /// 构造流水线。某个提供方构造失败（比如 TLS 初始化不了）时跳过它，不影响其它。
    pub(crate) fn new(config: &CoreConfig) -> Self {
        let build = |what: &str| -> Option<()> {
            tracing::debug!(target: "lekis_core::enrich", "准备提供方 {what}");
            Some(())
        };
        let lrclib = match build("lrclib") {
            Some(()) => Lrclib::new().ok(),
            None => None,
        };
        if lrclib.is_none() {
            tracing::warn!(target: "lekis_core::enrich", "LRCLIB 提供方不可用，跳过歌词补全");
        }
        let cover_art = CoverArtArchive::new().ok();
        let itunes = ITunes::new().ok();
        Self {
            lrclib,
            cover_art,
            itunes,
            cache_dir: config.cache_dir.clone(),
        }
    }

    /// 对一首歌跑一次补全。
    pub(crate) async fn enrich_track(
        &self,
        library: &Library,
        track_id: TrackId,
    ) -> Result<EnrichReport> {
        let track = library.get_track(track_id).await?;
        let hint = hint_for(&track, library).await?;
        let mut report = EnrichReport::default();

        // ---- 歌词（ENR-03）----
        if library.active_lyrics(track_id).await?.is_none() {
            if let Some(provider) = &self.lrclib {
                match provider.find_lyrics(&hint).await {
                    Ok(candidates) => {
                        report.absorb(
                            self.apply_lyrics(library, track_id, &hint, candidates)
                                .await?,
                        );
                    }
                    Err(e) => {
                        tracing::warn!(
                            target: "lekis_core::enrich",
                            code = %e.code.as_str(),
                            "LRCLIB 歌词查询失败"
                        );
                    }
                }
            }
        }

        // ---- 封面（ENR-01）----
        if library.effective_artwork_id(track_id).await?.is_none() {
            let mut artwork_candidates: Vec<Candidate<ArtworkPayload>> = Vec::new();
            if let Some(provider) = &self.cover_art {
                match provider.find_artwork(&hint).await {
                    Ok(list) => artwork_candidates.extend(list),
                    Err(e) => tracing::warn!(
                        target: "lekis_core::enrich",
                        code = %e.code.as_str(),
                        "Cover Art Archive 查询失败"
                    ),
                }
            }
            if let Some(provider) = &self.itunes {
                match provider.find_artwork(&hint).await {
                    Ok(list) => artwork_candidates.extend(list),
                    Err(e) => tracing::warn!(
                        target: "lekis_core::enrich",
                        code = %e.code.as_str(),
                        "iTunes 查询失败"
                    ),
                }
            }
            report.absorb(
                self.apply_artwork(library, &track, &hint, artwork_candidates)
                    .await?,
            );
        }

        Ok(report)
    }

    /// 逐条处理歌词候选。
    async fn apply_lyrics(
        &self,
        library: &Library,
        track_id: TrackId,
        hint: &TrackHint,
        candidates: Vec<Candidate<LyricsPayload>>,
    ) -> Result<EnrichReport> {
        let mut report = EnrichReport::default();
        let mut queued: Vec<NewEnrichCandidate> = Vec::new();
        let mut applied = false;

        for candidate in candidates.into_iter().take(MAX_PROVIDERS_PER_KIND) {
            let score = lekis_enrich::scoring::score(hint, &candidate);
            match decide(score) {
                Decision::AutoApply if !applied => {
                    let lyrics = Lyrics {
                        format: candidate.payload.format,
                        content: candidate.payload.content,
                        source: candidate.source.clone(),
                        offset_ms: 0,
                        confidence: score,
                    };
                    library.save_lyrics(track_id, lyrics).await?;
                    report.auto_applied += 1;
                    applied = true;
                }
                Decision::AutoApply | Decision::Review => {
                    queued.push(NewEnrichCandidate {
                        track_id: Some(track_id),
                        album_id: None,
                        kind: "lyrics".into(),
                        payload_json: serde_json::json!({
                            "format": format_to_str(candidate.payload.format),
                            "content": candidate.payload.content,
                        })
                        .to_string(),
                        source: candidate.source,
                        score,
                    });
                }
                Decision::Discard => report.discarded += 1,
            }
        }

        report.queued = library.insert_enrich_candidates(queued).await? as u32;
        Ok(report)
    }

    /// 逐条处理封面候选。
    async fn apply_artwork(
        &self,
        library: &Library,
        track: &Track,
        hint: &TrackHint,
        candidates: Vec<Candidate<ArtworkPayload>>,
    ) -> Result<EnrichReport> {
        let mut report = EnrichReport::default();
        let mut queued: Vec<NewEnrichCandidate> = Vec::new();
        let mut applied = false;

        for candidate in candidates.into_iter().take(MAX_PROVIDERS_PER_KIND) {
            let score = lekis_enrich::scoring::score(hint, &candidate);
            let payload_json = serde_json::json!({
                "url": candidate.payload.url,
                "width": candidate.payload.width,
                "height": candidate.payload.height,
            })
            .to_string();

            match decide(score) {
                Decision::AutoApply if !applied => match self
                    .store_artwork(library, track, &candidate.payload, &candidate.source)
                    .await
                {
                    Ok(()) => {
                        report.auto_applied += 1;
                        applied = true;
                    }
                    Err(e) => {
                        // 下载失败（网络抖动、图太大）时降级进待确认队列，
                        // 用户手动确认时还能再试一次。
                        tracing::warn!(
                            target: "lekis_core::enrich",
                            code = %e.code.as_str(),
                            "封面下载/处理失败，转入待确认"
                        );
                        queued.push(NewEnrichCandidate {
                            track_id: Some(track.id),
                            album_id: track.album_id,
                            kind: "artwork".into(),
                            payload_json,
                            source: candidate.source,
                            score,
                        });
                    }
                },
                Decision::AutoApply | Decision::Review => queued.push(NewEnrichCandidate {
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

    /// 下载 + 处理 + 落盘 + 入库一张封面。
    async fn store_artwork(
        &self,
        library: &Library,
        track: &Track,
        payload: &ArtworkPayload,
        source: &str,
    ) -> Result<()> {
        let raw = artwork_ingest::fetch_image(&payload.url).await?;
        let processed = tokio::task::spawn_blocking(move || {
            artwork_ingest::process_image(&raw, ARTWORK_TARGET_PX)
        })
        .await
        .map_err(|e| LekisError::internal(format!("封面处理任务失败：{e}")))??;

        // 已有同哈希的封面就复用，省一次写盘和一行数据。
        let relative = cache_relative_path(&processed.hash, processed.width);
        let path = self.cache_dir.join(&relative);
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        if !path.exists() {
            tokio::fs::write(&path, &processed.bytes).await?;
        }

        let artwork_id = library
            .upsert_artwork(
                processed.hash,
                source.to_string(),
                Some(processed.width),
                Some(processed.height),
                Some(processed.palette),
            )
            .await?;

        // 曲目级优先；同时给专辑打上，让别的曲目也能用（ENR-01）。
        library
            .set_track_artwork(track.id, Some(artwork_id))
            .await?;
        if let Some(album_id) = track.album_id {
            if library.get_album(album_id).await?.artwork_id.is_none() {
                library
                    .set_album_artwork(album_id, Some(artwork_id))
                    .await?;
            }
        }
        Ok(())
    }
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
/// 目前支持 `lyrics`（直接入库）和 `tags`（写覆盖层）；其余类型只改状态。
pub(crate) async fn apply_candidate(
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
                .save_lyrics(
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
        _ => Ok(()),
    }
}

/// 封面在缓存目录里的绝对路径（UI 层拼好后直接读文件显示）。
pub(crate) fn artwork_file_path(config: &CoreConfig, hash: &str, width: u32) -> std::path::PathBuf {
    config.cache_dir.join(cache_relative_path(hash, width))
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
}
