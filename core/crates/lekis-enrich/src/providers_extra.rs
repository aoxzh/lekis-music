//! 扩展免 API Key 在线提供方（歌词 + 专辑封面）。
//!
//! | 提供方 | 类型 | 地址 | 特点 |
//! |---|---|---|---|
//! | [`DeezerArtwork`] | 封面 | `https://api.deezer.com` | 免 Key，1000×1000 高清封面，欧美 / 日韩 / 华语覆盖广 |
//! | [`NetEaseArtwork`] | 封面 | `https://music.163.com` | 免 Key，华语 / 日语 / ACG / 独立音乐专辑封面 |
//! | [`MusicBrainzCoverArt`] | 封面 | `https://musicbrainz.org` + `coverartarchive.org` | 免 Key，无本地 MBID 时自动查 Release 并取 CAA 封面 |
//! | [`NetEaseLyrics`] | 歌词 | `https://music.163.com` | 免 Key，逐行同步 LRC，自动合并原文 + 中文翻译 `tlyric` |
//! | [`KugouLyrics`] | 歌词 | `https://lyrics.kugou.com` | 免 Key，逐行同步 LRC（Base64 解码并清洗头部噪声标签） |
//! | [`LyricsOvh`] | 歌词 | `https://api.lyrics.ovh` | 免 Key，欧美纯文本歌词兜底 |

use crate::cache::{cache_key, TtlCache};
use crate::http;
use crate::providers::clean_acg_query;
use crate::scoring::score_match;
use crate::throttle::{Backoff, RateLimiter};
use crate::{ArtworkPayload, ArtworkProvider, Candidate, LyricsPayload, LyricsProvider, TrackHint};
use async_trait::async_trait;
use base64::Engine;
use lekis_types::{ErrorCode, LekisError, LyricsFormat, Result};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::time::Duration;

const MAX_CANDIDATES: usize = 5;
const INLINE_BACKOFF_CAP: Duration = Duration::from_secs(4);
const NETEASE_HEADERS: &[(&str, &str)] = &[("Referer", "https://music.163.com/")];

fn decode(e: serde_json::Error) -> LekisError {
    LekisError::new(ErrorCode::Decode, format!("提供方响应解析失败：{e}"))
}

fn as_confidence(score: f64) -> f32 {
    (score as f32).clamp(0.0, 1.0)
}

async fn fetch_with_headers(
    client: &reqwest::Client,
    limiter: &RateLimiter,
    backoff: &Backoff,
    url: reqwest::Url,
    headers: &[(&str, &str)],
    what: &str,
) -> Result<Option<String>> {
    limiter.acquire().await;
    match http::get_text_with_headers(client, url, headers, what).await {
        Ok(body) => {
            backoff.reset();
            Ok(body)
        }
        Err(error) => {
            if matches!(error.code, ErrorCode::RateLimited | ErrorCode::Network) {
                let delay = backoff.record_failure().min(INLINE_BACKOFF_CAP);
                tracing::warn!(
                    target: "lekis_enrich::providers_extra",
                    provider = what,
                    failures = backoff.failures(),
                    delay_ms = delay.as_millis() as u64,
                    "提供方请求失败，短暂退避"
                );
                tokio::time::sleep(delay).await;
            }
            Err(error)
        }
    }
}

fn sort_and_filter<T>(mut candidates: Vec<Candidate<T>>, hint: &TrackHint) -> Vec<Candidate<T>> {
    candidates.sort_by(|a, b| b.provider_confidence.total_cmp(&a.provider_confidence));
    if !hint.title.trim().is_empty() {
        candidates.retain(|c| c.provider_confidence >= crate::REVIEW_THRESHOLD);
    }
    candidates.truncate(MAX_CANDIDATES);
    candidates
}

fn first_artist(hint: &TrackHint) -> &str {
    hint.artists
        .iter()
        .map(String::as_str)
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or("")
}

fn to_https(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        url.to_string()
    }
}

// ============================================================================
// Deezer Public API（免 Key，1000x1000 封面）
// ============================================================================

/// Deezer 公开检索封面提供方（免 Key）。
pub struct DeezerArtwork {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl DeezerArtwork {
    /// 官方公开 API 地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://api.deezer.com";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建（测试 / 镜像）。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("Deezer 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(500)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl ArtworkProvider for DeezerArtwork {
    fn name(&self) -> &str {
        "deezer"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        let query = format!("{} {}", first_artist(hint), hint.title.trim())
            .trim()
            .to_string();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let mut url = http::join(&self.base_url, "/search")?;
        url.query_pairs_mut()
            .append_pair("q", &query)
            .append_pair("limit", "6");
        let Some(body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            &[],
            "Deezer /search",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let candidates = parse_deezer_artwork(self.name(), hint, &body)?;
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn parse_deezer_artwork(
    source: &str,
    hint: &TrackHint,
    body: &str,
) -> Result<Vec<Candidate<ArtworkPayload>>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        data: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(default)]
        title: String,
        #[serde(default)]
        duration: u64,
        #[serde(default)]
        artist: Option<Artist>,
        #[serde(default)]
        album: Option<Album>,
    }
    #[derive(Deserialize)]
    struct Artist {
        #[serde(default)]
        name: String,
    }
    #[derive(Deserialize)]
    struct Album {
        #[serde(default)]
        title: String,
        #[serde(default)]
        cover_xl: Option<String>,
        #[serde(default)]
        cover_big: Option<String>,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let mut out = Vec::new();
    for item in resp.data {
        let Some(album) = item.album else {
            continue;
        };
        let (raw_url, dim) = if let Some(u) = album.cover_xl.filter(|s| !s.is_empty()) {
            (u, Some(1000))
        } else if let Some(u) = album.cover_big.filter(|s| !s.is_empty()) {
            (u, Some(500))
        } else {
            continue;
        };
        let artist_name = item
            .artist
            .map(|a| a.name)
            .unwrap_or_default();
        let duration_ms = item.duration.saturating_mul(1000);
        let album_opt = (!album.title.trim().is_empty()).then(|| album.title.clone());
        let confidence = as_confidence(score_match(
            hint,
            &item.title,
            &artist_name,
            album_opt.as_deref(),
            duration_ms,
        ));
        let matched = TrackHint {
            title: item.title,
            artists: if artist_name.is_empty() {
                Vec::new()
            } else {
                vec![artist_name]
            },
            album: album_opt,
            duration_ms,
            mbid_recording: None,
            mbid_release: None,
        };
        out.push(Candidate {
            payload: ArtworkPayload {
                url: to_https(&raw_url),
                width: dim,
                height: dim,
            },
            source: source.to_string(),
            matched,
            provider_confidence: confidence,
        });
    }
    Ok(sort_and_filter(out, hint))
}

// ============================================================================
// 网易云音乐专辑封面（免 Key，1000x1000）
// ============================================================================

/// 网易云公开专辑检索封面提供方（免 Key，华语 / 日语 / ACG 极佳）。
pub struct NetEaseArtwork {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl NetEaseArtwork {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://music.163.com";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("网易云地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(800)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl ArtworkProvider for NetEaseArtwork {
    fn name(&self) -> &str {
        "netease"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        let target = hint
            .album
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| hint.title.trim());
        let query = format!("{target} {}", first_artist(hint)).trim().to_string();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&format!("{}/album", self.base_url), hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let mut url = http::join(&self.base_url, "/api/search/get")?;
        url.query_pairs_mut()
            .append_pair("s", &query)
            .append_pair("type", "10")
            .append_pair("limit", "6");
        let Some(body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            NETEASE_HEADERS,
            "NetEase /api/search/get (album)",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let mut candidates = parse_netease_artwork(self.name(), hint, &body)?;
        // ACG / OST 曲目常见带 `(TV Size)`、`[FLAC]`、多 CV 后缀，原串未命中时用清洗后的关键词兜底。
        if candidates.is_empty() {
            let cleaned = clean_acg_query(&query);
            if !cleaned.is_empty() && cleaned != query {
                let mut fallback_url = http::join(&self.base_url, "/api/search/get")?;
                fallback_url
                    .query_pairs_mut()
                    .append_pair("s", &cleaned)
                    .append_pair("type", "10")
                    .append_pair("limit", "6");
                if let Some(fb_body) = fetch_with_headers(
                    &self.client,
                    &self.limiter,
                    &self.backoff,
                    fallback_url,
                    NETEASE_HEADERS,
                    "NetEase /api/search/get (album fallback)",
                )
                .await?
                {
                    candidates = parse_netease_artwork(self.name(), hint, &fb_body)?;
                }
            }
        }
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn parse_netease_artwork(
    source: &str,
    hint: &TrackHint,
    body: &str,
) -> Result<Vec<Candidate<ArtworkPayload>>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        result: Option<Res>,
    }
    #[derive(Deserialize)]
    struct Res {
        #[serde(default)]
        albums: Vec<AlbumItem>,
    }
    #[derive(Deserialize)]
    struct AlbumItem {
        #[serde(default)]
        name: String,
        #[serde(rename = "picUrl", default)]
        pic_url: Option<String>,
        #[serde(default)]
        artist: Option<ArtistItem>,
    }
    #[derive(Deserialize)]
    struct ArtistItem {
        #[serde(default)]
        name: String,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let Some(res) = resp.result else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for item in res.albums {
        let Some(pic) = item.pic_url.filter(|s| !s.trim().is_empty()) else {
            continue;
        };
        let artist_name = item.artist.map(|a| a.name).unwrap_or_default();
        // 专辑检索无曲目名与时长：按专辑名 + 艺人名构造匹配线索。
        let album_hint = TrackHint {
            title: hint
                .album
                .clone()
                .filter(|a| !a.trim().is_empty())
                .unwrap_or_else(|| hint.title.clone()),
            artists: hint.artists.clone(),
            album: hint.album.clone(),
            duration_ms: 0,
            mbid_recording: None,
            mbid_release: None,
        };
        let confidence = as_confidence(score_match(
            &album_hint,
            &item.name,
            &artist_name,
            Some(&item.name),
            0,
        ));
        let full_url = format!("{}?param=1000y1000", to_https(pic.trim()));
        let matched = TrackHint {
            title: hint.title.clone(),
            artists: if artist_name.is_empty() {
                Vec::new()
            } else {
                vec![artist_name]
            },
            album: Some(item.name),
            duration_ms: hint.duration_ms,
            mbid_recording: None,
            mbid_release: None,
        };
        out.push(Candidate {
            payload: ArtworkPayload {
                url: full_url,
                width: Some(1000),
                height: Some(1000),
            },
            source: source.to_string(),
            matched,
            provider_confidence: confidence,
        });
    }
    Ok(sort_and_filter(out, hint))
}

// ============================================================================
// MusicBrainz Search → Cover Art Archive（免 Key，补足无本地 MBID 的曲目）
// ============================================================================

/// MusicBrainz Release 检索 + Cover Art Archive 封面（免 Key，严格 1 req/s）。
pub struct MusicBrainzCoverArt {
    mb_base_url: String,
    caa_base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl MusicBrainzCoverArt {
    /// 官方 MusicBrainz 地址。
    pub const DEFAULT_MB_URL: &'static str = "https://musicbrainz.org";
    /// 官方 Cover Art Archive 地址。
    pub const DEFAULT_CAA_URL: &'static str = "https://coverartarchive.org";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_urls(Self::DEFAULT_MB_URL, Self::DEFAULT_CAA_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_urls(mb_base_url: &str, caa_base_url: &str) -> Result<Self> {
        let mb_base_url = mb_base_url.trim().trim_end_matches('/').to_string();
        let caa_base_url = caa_base_url.trim().trim_end_matches('/').to_string();
        if mb_base_url.is_empty() || caa_base_url.is_empty() {
            return Err(LekisError::invalid("MusicBrainz/CAA 地址为空"));
        }
        Ok(Self {
            mb_base_url,
            caa_base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(1100)),
            backoff: Backoff::new(Duration::from_secs(2), Duration::from_secs(60)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl ArtworkProvider for MusicBrainzCoverArt {
    fn name(&self) -> &str {
        "musicbrainz"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        let album = hint
            .album
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| hint.title.trim());
        let artist = first_artist(hint);
        if album.is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.mb_base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let lucene = if artist.is_empty() {
            format!("release:\"{}\"", escape_lucene(album))
        } else {
            format!(
                "release:\"{}\" AND artist:\"{}\"",
                escape_lucene(album),
                escape_lucene(artist)
            )
        };
        let mut url = http::join(&self.mb_base_url, "/ws/2/release/")?;
        url.query_pairs_mut()
            .append_pair("query", &lucene)
            .append_pair("fmt", "json")
            .append_pair("limit", "3");

        let Some(body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            &[],
            "MusicBrainz /ws/2/release",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let candidates = parse_musicbrainz_releases(self.name(), &self.caa_base_url, hint, &body)?;
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn escape_lucene(input: &str) -> String {
    input.replace('\\', "\\\\").replace('"', "\\\"")
}

fn parse_musicbrainz_releases(
    source: &str,
    caa_base_url: &str,
    hint: &TrackHint,
    body: &str,
) -> Result<Vec<Candidate<ArtworkPayload>>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        releases: Vec<Release>,
    }
    #[derive(Deserialize)]
    struct Release {
        #[serde(default)]
        id: String,
        #[serde(default)]
        title: String,
        #[serde(rename = "artist-credit", default)]
        artist_credit: Vec<Credit>,
    }
    #[derive(Deserialize)]
    struct Credit {
        #[serde(default)]
        name: String,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let album_hint = TrackHint {
        title: hint
            .album
            .clone()
            .filter(|a| !a.trim().is_empty())
            .unwrap_or_else(|| hint.title.clone()),
        artists: hint.artists.clone(),
        album: hint.album.clone(),
        duration_ms: 0,
        mbid_recording: None,
        mbid_release: None,
    };
    let mut out = Vec::new();
    for rel in resp.releases {
        let id = rel.id.trim();
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            continue;
        }
        let artist_name = rel
            .artist_credit
            .into_iter()
            .map(|c| c.name)
            .filter(|n| !n.trim().is_empty())
            .collect::<Vec<_>>()
            .join(" / ");
        let confidence = as_confidence(score_match(
            &album_hint,
            &rel.title,
            &artist_name,
            Some(&rel.title),
            0,
        ));
        let url = format!("{caa_base_url}/release/{id}/front-500");
        out.push(Candidate {
            payload: ArtworkPayload {
                url,
                width: Some(500),
                height: Some(500),
            },
            source: source.to_string(),
            matched: TrackHint {
                title: hint.title.clone(),
                artists: if artist_name.is_empty() {
                    Vec::new()
                } else {
                    vec![artist_name]
                },
                album: Some(rel.title),
                duration_ms: hint.duration_ms,
                mbid_recording: None,
                mbid_release: Some(id.to_string()),
            },
            provider_confidence: confidence,
        });
    }
    Ok(sort_and_filter(out, hint))
}

// ============================================================================
// 网易云音乐歌词（免 Key，逐行同步 + 自动合并双语翻译 tlyric）
// ============================================================================

/// 网易云公开歌词提供方（免 Key，支持原文 + 中文翻译自动按时间轴合并）。
pub struct NetEaseLyrics {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}

impl NetEaseLyrics {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://music.163.com";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("网易云地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(800)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl LyricsProvider for NetEaseLyrics {
    fn name(&self) -> &str {
        "netease"
    }

    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        if hint.title.trim().is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&format!("{}/lyrics", self.base_url), hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let query = format!("{} {}", hint.title.trim(), first_artist(hint))
            .trim()
            .to_string();
        let mut search_url = http::join(&self.base_url, "/api/search/get")?;
        search_url
            .query_pairs_mut()
            .append_pair("s", &query)
            .append_pair("type", "1")
            .append_pair("limit", "5");

        let Some(search_body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            search_url,
            NETEASE_HEADERS,
            "NetEase /api/search/get",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let songs = parse_netease_songs(&search_body)?;
        // 先按元数据打分，挑前 2 首最匹配的去拉歌词，避免浪费请求。
        let mut scored: Vec<(u64, TrackHint, f32)> = songs
            .into_iter()
            .map(|(id, matched)| {
                let conf = as_confidence(score_match(
                    hint,
                    &matched.title,
                    &matched.artists.join(" / "),
                    matched.album.as_deref(),
                    matched.duration_ms,
                ));
                (id, matched, conf)
            })
            .filter(|(_, _, conf)| *conf >= crate::REVIEW_THRESHOLD)
            .collect();
        scored.sort_by(|a, b| b.2.total_cmp(&a.2));
        scored.truncate(2);

        let mut out = Vec::new();
        for (id, matched, confidence) in scored {
            let mut lrc_url = http::join(&self.base_url, "/api/song/lyric")?;
            lrc_url
                .query_pairs_mut()
                .append_pair("id", &id.to_string())
                .append_pair("lv", "1")
                .append_pair("tv", "1");
            let Some(lrc_body) = fetch_with_headers(
                &self.client,
                &self.limiter,
                &self.backoff,
                lrc_url,
                NETEASE_HEADERS,
                "NetEase /api/song/lyric",
            )
            .await?
            else {
                continue;
            };
            if let Some(payload) = parse_netease_lyric_body(&lrc_body)? {
                out.push(Candidate {
                    payload,
                    source: self.name().to_string(),
                    matched,
                    provider_confidence: confidence,
                });
            }
        }

        let candidates = sort_and_filter(out, hint);
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn parse_netease_songs(body: &str) -> Result<Vec<(u64, TrackHint)>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        result: Option<Res>,
    }
    #[derive(Deserialize)]
    struct Res {
        #[serde(default)]
        songs: Vec<Song>,
    }
    #[derive(Deserialize)]
    struct Song {
        id: u64,
        #[serde(default)]
        name: String,
        #[serde(default)]
        duration: u64,
        #[serde(default)]
        artists: Vec<Artist>,
        #[serde(default)]
        album: Option<Album>,
    }
    #[derive(Deserialize)]
    struct Artist {
        #[serde(default)]
        name: String,
    }
    #[derive(Deserialize)]
    struct Album {
        #[serde(default)]
        name: String,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let Some(res) = resp.result else {
        return Ok(Vec::new());
    };
    Ok(res
        .songs
        .into_iter()
        .map(|s| {
            let artists = s
                .artists
                .into_iter()
                .map(|a| a.name)
                .filter(|n| !n.trim().is_empty())
                .collect();
            let album = s
                .album
                .map(|a| a.name)
                .filter(|n| !n.trim().is_empty());
            (
                s.id,
                TrackHint {
                    title: s.name,
                    artists,
                    album,
                    duration_ms: s.duration,
                    mbid_recording: None,
                    mbid_release: None,
                },
            )
        })
        .collect())
}

fn parse_netease_lyric_body(body: &str) -> Result<Option<LyricsPayload>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        lrc: Option<Block>,
        #[serde(default)]
        tlyric: Option<Block>,
    }
    #[derive(Deserialize)]
    struct Block {
        #[serde(default)]
        lyric: Option<String>,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let Some(main_raw) = resp
        .lrc
        .and_then(|b| b.lyric)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    else {
        return Ok(None);
    };
    // 跳过网易云的纯音乐占位文案。
    if main_raw.contains("纯音乐，请欣赏") {
        return Ok(None);
    }
    let trans_raw = resp
        .tlyric
        .and_then(|b| b.lyric)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let synced = looks_like_lrc(&main_raw);
    let content = match (synced, trans_raw) {
        (true, Some(trans)) => merge_netease_bilingual(&main_raw, &trans),
        _ => main_raw,
    };
    Ok(Some(LyricsPayload {
        format: if synced {
            LyricsFormat::Lrc
        } else {
            LyricsFormat::Plain
        },
        content,
    }))
}

fn looks_like_lrc(text: &str) -> bool {
    text.lines().any(|line| {
        let l = line.trim_start();
        l.starts_with('[')
            && l.len() >= 7
            && l.as_bytes()[1].is_ascii_digit()
            && l.as_bytes()[2].is_ascii_digit()
            && l.as_bytes()[3] == b':'
    })
}

/// 将网易云的原文 LRC 与中文翻译 `tlyric` 按时间戳交错合并，
/// 供 Lekis 的双语歌词解析器渲染主句 + 副句译文。
pub(crate) fn merge_netease_bilingual(primary: &str, translation: &str) -> String {
    let mut trans_map: BTreeMap<String, String> = BTreeMap::new();
    for line in translation.lines() {
        if let Some((ts, body)) = split_lrc_timestamp(line) {
            let body = body.trim();
            if !body.is_empty() {
                trans_map.entry(ts).or_insert_with(|| body.to_string());
            }
        }
    }
    if trans_map.is_empty() {
        return primary.to_string();
    }
    let mut out = String::with_capacity(primary.len() + translation.len());
    for line in primary.lines() {
        out.push_str(line);
        out.push('\n');
        if let Some((ts, body)) = split_lrc_timestamp(line) {
            if !body.trim().is_empty() {
                if let Some(t) = trans_map.get(&ts) {
                    out.push('[');
                    out.push_str(&ts);
                    out.push(']');
                    out.push_str(t);
                    out.push('\n');
                }
            }
        }
    }
    out
}

fn split_lrc_timestamp(line: &str) -> Option<(String, &str)> {
    let trimmed = line.trim_start();
    if !trimmed.starts_with('[') {
        return None;
    }
    let close = trimmed.find(']')?;
    let inner = &trimmed[1..close];
    if inner.len() < 5
        || !inner.as_bytes()[0].is_ascii_digit()
        || !inner.as_bytes()[1].is_ascii_digit()
        || inner.as_bytes()[2] != b':'
    {
        return None;
    }
    Some((inner.to_string(), &trimmed[close + 1..]))
}

// ============================================================================
// 酷狗歌词（免 Key，Base64 同步 LRC）
// ============================================================================

/// 酷狗公开歌词提供方（免 Key，华语 / 粤语 / 日语同步 LRC 覆盖率高）。
pub struct KugouLyrics {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}

impl KugouLyrics {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://lyrics.kugou.com";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("酷狗歌词地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(800)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl LyricsProvider for KugouLyrics {
    fn name(&self) -> &str {
        "kugou"
    }

    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        if hint.title.trim().is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let artist = first_artist(hint);
        let keyword = if artist.is_empty() {
            hint.title.trim().to_string()
        } else {
            format!("{artist} - {}", hint.title.trim())
        };
        let mut search_url = http::join(&self.base_url, "/search")?;
        {
            let mut q = search_url.query_pairs_mut();
            q.append_pair("ver", "1")
                .append_pair("man", "yes")
                .append_pair("client", "pc")
                .append_pair("keyword", &keyword);
            if hint.duration_ms > 0 {
                q.append_pair("duration", &hint.duration_ms.to_string());
            }
        }

        let Some(search_body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            search_url,
            &[],
            "KuGou /search",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let items = parse_kugou_search(&search_body)?;
        let mut scored: Vec<(String, String, TrackHint, f32)> = items
            .into_iter()
            .map(|(id, accesskey, matched)| {
                let conf = as_confidence(score_match(
                    hint,
                    &matched.title,
                    &matched.artists.join(" / "),
                    None,
                    matched.duration_ms,
                ));
                (id, accesskey, matched, conf)
            })
            .filter(|(_, _, _, conf)| *conf >= crate::REVIEW_THRESHOLD)
            .collect();
        scored.sort_by(|a, b| b.3.total_cmp(&a.3));
        scored.truncate(2);

        let mut out = Vec::new();
        for (id, accesskey, matched, confidence) in scored {
            let mut dl_url = http::join(&self.base_url, "/download")?;
            dl_url
                .query_pairs_mut()
                .append_pair("ver", "1")
                .append_pair("client", "pc")
                .append_pair("id", &id)
                .append_pair("accesskey", &accesskey)
                .append_pair("fmt", "lrc")
                .append_pair("charset", "utf8");
            let Some(dl_body) = fetch_with_headers(
                &self.client,
                &self.limiter,
                &self.backoff,
                dl_url,
                &[],
                "KuGou /download",
            )
            .await?
            else {
                continue;
            };
            if let Some(lrc) = parse_kugou_download(&dl_body)? {
                let format = if looks_like_lrc(&lrc) {
                    LyricsFormat::Lrc
                } else {
                    LyricsFormat::Plain
                };
                out.push(Candidate {
                    payload: LyricsPayload {
                        format,
                        content: lrc,
                    },
                    source: self.name().to_string(),
                    matched,
                    provider_confidence: confidence,
                });
            }
        }

        let candidates = sort_and_filter(out, hint);
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn parse_kugou_search(body: &str) -> Result<Vec<(String, String, TrackHint)>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        candidates: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(default)]
        id: String,
        #[serde(default)]
        accesskey: String,
        #[serde(default)]
        song: String,
        #[serde(default)]
        singer: String,
        #[serde(default)]
        duration: u64,
    }
    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    Ok(resp
        .candidates
        .into_iter()
        .filter(|i| !i.id.is_empty() && !i.accesskey.is_empty())
        .map(|i| {
            let artists = if i.singer.trim().is_empty() {
                Vec::new()
            } else {
                vec![i.singer]
            };
            (
                i.id,
                i.accesskey,
                TrackHint {
                    title: i.song,
                    artists,
                    album: None,
                    duration_ms: i.duration,
                    mbid_recording: None,
                    mbid_release: None,
                },
            )
        })
        .collect())
}

fn parse_kugou_download(body: &str) -> Result<Option<String>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        content: Option<String>,
    }
    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let Some(b64) = resp.content.filter(|s| !s.trim().is_empty()) else {
        return Ok(None);
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("酷狗歌词 Base64 解码失败：{e}")))?;
    let raw = String::from_utf8_lossy(&bytes);
    let cleaned = clean_kugou_lrc(&raw);
    if cleaned.is_empty() {
        Ok(None)
    } else {
        Ok(Some(cleaned))
    }
}

/// 去掉 UTF-8 BOM 和酷狗自带的 `[id:$...]` / `[hash:...]` / `[sign:...]` / `[qq:...]` 噪声头。
pub(crate) fn clean_kugou_lrc(raw: &str) -> String {
    let trimmed = raw.trim_start_matches('\u{feff}');
    trimmed
        .lines()
        .filter(|line| {
            let l = line.trim();
            !(l.starts_with("[id:")
                || l.starts_with("[hash:")
                || l.starts_with("[sign:")
                || l.starts_with("[qq:")
                || l.starts_with("[total:"))
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

// ============================================================================
// Lyrics.ovh（免 Key，欧美纯文本兜底）
// ============================================================================

/// Lyrics.ovh 公开纯文本歌词提供方（免 Key，作为同步歌词未命中时的兜底）。
pub struct LyricsOvh {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}

impl LyricsOvh {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://api.lyrics.ovh";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("Lyrics.ovh 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl LyricsProvider for LyricsOvh {
    fn name(&self) -> &str {
        "lyrics.ovh"
    }

    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        let title = hint.title.trim();
        let artist = first_artist(hint);
        if title.is_empty() || artist.is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let enc_artist = utf8_percent_encode(artist, NON_ALPHANUMERIC).to_string();
        let enc_title = utf8_percent_encode(title, NON_ALPHANUMERIC).to_string();
        let url = http::join(&self.base_url, &format!("/v1/{enc_artist}/{enc_title}"))?;
        let Some(body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            &[],
            "Lyrics.ovh /v1",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        #[derive(Deserialize)]
        struct Resp {
            #[serde(default)]
            lyrics: Option<String>,
        }
        let resp: Resp = serde_json::from_str(&body).map_err(decode)?;
        let Some(text) = resp
            .lyrics
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
        else {
            return Ok(Vec::new());
        };

        // Lyrics.ovh 是精确路径匹配但不返回时长，保守给 0.85 以允许自动兜底。
        let candidates = vec![Candidate {
            payload: LyricsPayload {
                format: LyricsFormat::Plain,
                content: text,
            },
            source: self.name().to_string(),
            matched: hint.clone(),
            provider_confidence: 0.85,
        }];
        self.cache.insert(key, candidates.clone());
        Ok(candidates)
    }
}

// ============================================================================
// VocaDB Public API（免 Key，Vocaloid / 日语同人 / ACG 独立专辑封面）
// ============================================================================

/// VocaDB 公开专辑封面提供方（免 Key，擅长 Vocaloid / 日语同人 / ACG 作品）。
pub struct VocaDbArtwork {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl VocaDbArtwork {
    /// 官方公开 API 地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://vocadb.net";

    /// 用官方地址创建。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("VocaDB 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_millis(800)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(30)),
            cache: TtlCache::new(),
        })
    }
}

#[async_trait]
impl ArtworkProvider for VocaDbArtwork {
    fn name(&self) -> &str {
        "vocadb"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        let raw_target = hint
            .album
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| hint.title.trim());
        let query = clean_acg_query(raw_target);
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let key = cache_key(&format!("{}/albums", self.base_url), hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let mut url = http::join(&self.base_url, "/api/albums")?;
        url.query_pairs_mut()
            .append_pair("query", &query)
            .append_pair("fields", "MainPicture")
            .append_pair("maxResults", "5")
            .append_pair("nameMatchMode", "Auto");
        let Some(body) = fetch_with_headers(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            &[],
            "VocaDB /api/albums",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let candidates = parse_vocadb_artwork(self.name(), hint, &body)?;
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

fn parse_vocadb_artwork(
    source: &str,
    hint: &TrackHint,
    body: &str,
) -> Result<Vec<Candidate<ArtworkPayload>>> {
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        items: Vec<AlbumItem>,
    }
    #[derive(Deserialize)]
    struct AlbumItem {
        #[serde(default)]
        name: String,
        #[serde(rename = "artistString", default)]
        artist_string: String,
        #[serde(rename = "mainPicture", default)]
        main_picture: Option<Picture>,
    }
    #[derive(Deserialize)]
    struct Picture {
        #[serde(rename = "urlOriginal", default)]
        url_original: Option<String>,
        #[serde(rename = "urlThumb", default)]
        url_thumb: Option<String>,
    }

    let resp: Resp = serde_json::from_str(body).map_err(decode)?;
    let mut out = Vec::new();
    for item in resp.items {
        let Some(pic) = item.main_picture else {
            continue;
        };
        let Some(url) = pic
            .url_original
            .filter(|s| !s.trim().is_empty())
            .or_else(|| pic.url_thumb.filter(|s| !s.trim().is_empty()))
        else {
            continue;
        };
        let album_hint = TrackHint {
            title: hint
                .album
                .clone()
                .filter(|a| !a.trim().is_empty())
                .unwrap_or_else(|| hint.title.clone()),
            artists: hint.artists.clone(),
            album: hint.album.clone(),
            duration_ms: 0,
            mbid_recording: None,
            mbid_release: None,
        };
        let confidence = as_confidence(score_match(
            &album_hint,
            &item.name,
            &item.artist_string,
            Some(&item.name),
            0,
        ));
        let matched = TrackHint {
            title: hint.title.clone(),
            artists: if item.artist_string.is_empty() {
                Vec::new()
            } else {
                vec![item.artist_string]
            },
            album: Some(item.name),
            duration_ms: hint.duration_ms,
            mbid_recording: None,
            mbid_release: None,
        };
        out.push(Candidate {
            payload: ArtworkPayload {
                url: to_https(url.trim()),
                width: None,
                height: None,
            },
            source: source.to_string(),
            matched,
            provider_confidence: confidence,
        });
    }
    Ok(sort_and_filter(out, hint))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn sample_hint() -> TrackHint {
        TrackHint {
            title: "Get Lucky".into(),
            artists: vec!["Daft Punk".into()],
            album: Some("Random Access Memories".into()),
            duration_ms: 248_000,
            mbid_recording: None,
            mbid_release: None,
        }
    }

    #[test]
    fn parses_deezer_artwork_and_upgrades_to_https() {
        let json = r#"{
            "data": [{
                "title": "Get Lucky",
                "duration": 248,
                "artist": {"name": "Daft Punk"},
                "album": {
                    "title": "Random Access Memories",
                    "cover_xl": "http://cdn-images.dzcdn.net/images/cover/abc/1000x1000.jpg"
                }
            }]
        }"#;
        let out = parse_deezer_artwork("deezer", &sample_hint(), json).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].source, "deezer");
        assert!(out[0].payload.url.starts_with("https://"));
        assert_eq!(out[0].payload.width, Some(1000));
        assert!(out[0].provider_confidence >= 0.85);
    }

    #[test]
    fn parses_netease_album_artwork_with_1000px_param() {
        let hint = TrackHint {
            title: "晴天".into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            ..Default::default()
        };
        let json = r#"{
            "result": {
                "albums": [{
                    "name": "叶惠美",
                    "picUrl": "http://p2.music.126.net/abc/123.jpg",
                    "artist": {"name": "周杰伦"}
                }]
            }
        }"#;
        let out = parse_netease_artwork("netease", &hint, json).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0].payload.url,
            "https://p2.music.126.net/abc/123.jpg?param=1000y1000"
        );
    }

    #[test]
    fn parses_musicbrainz_release_into_caa_url() {
        let json = r#"{
            "releases": [{
                "id": "8ecfafd1-89a8-423a-968f-3fff47f0b0f9",
                "title": "Random Access Memories",
                "artist-credit": [{"name": "Daft Punk"}]
            }]
        }"#;
        let out = parse_musicbrainz_releases(
            "musicbrainz",
            "https://coverartarchive.org",
            &sample_hint(),
            json,
        )
        .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0].payload.url,
            "https://coverartarchive.org/release/8ecfafd1-89a8-423a-968f-3fff47f0b0f9/front-500"
        );
    }

    #[test]
    fn merges_netease_bilingual_lyrics_by_timestamp() {
        let main = "[00:05.00]鼓動は胸を焦がしてる\n[00:10.00]忘れられた明日\n";
        let trans = "[00:05.00]躁动仿佛将心灼伤\n[00:10.00]已经遗忘了的明天\n";
        let merged = merge_netease_bilingual(main, trans);
        assert!(merged.contains("[00:05.00]鼓動は胸を焦がしてる\n[00:05.00]躁动仿佛将心灼伤\n"));
        assert!(merged.contains("[00:10.00]忘れられた明日\n[00:10.00]已经遗忘了的明天\n"));
    }

    #[test]
    fn cleans_kugou_bom_and_noise_headers() {
        let raw = "\u{feff}[id:$00000000]\n[hash:abc]\n[ar:周杰伦]\n[00:01.00]故事的小黄花\n";
        let cleaned = clean_kugou_lrc(raw);
        assert!(!cleaned.contains("[id:"));
        assert!(!cleaned.contains("[hash:"));
        assert!(cleaned.contains("[00:01.00]故事的小黄花"));
    }

    #[test]
    fn cleans_acg_version_noise_and_parses_vocadb() {
        assert_eq!(
            clean_acg_query("青春コンプレックス (TV Size) [FLAC]"),
            "青春コンプレックス"
        );
        assert_eq!(
            clean_acg_query("メルト (feat. 初音ミク)"),
            "メルト"
        );
        let hint = TrackHint {
            title: "メルト".into(),
            artists: vec!["ryo".into()],
            album: Some("supercell".into()),
            duration_ms: 258_000,
            ..Default::default()
        };
        let json = r#"{
            "items": [{
                "name": "supercell",
                "artistString": "ryo feat. 初音ミク",
                "mainPicture": {
                    "urlOriginal": "https://static.vocadb.net/img/album/mainOrig/123.jpg"
                }
            }]
        }"#;
        let out = parse_vocadb_artwork("vocadb", &hint, json).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0].payload.url,
            "https://static.vocadb.net/img/album/mainOrig/123.jpg"
        );
    }
}
