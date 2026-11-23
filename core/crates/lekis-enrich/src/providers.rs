//! 内置的在线提供方（ENR-01、ENR-03、ENR-05、ENR-09）。
//!
//! | 提供方 | 用途 | 认证 | 速率限制 |
//! |---|---|---|---|
//! | [`Lrclib`] | 歌词（逐行同步 LRC / 纯文本）| 免 Key，但要求可识别的 `User-Agent` | 保守 1 次/秒 |
//! | [`CoverArtArchive`] | 封面（按 Release MBID）| 免 Key | 1 次/秒（跑在 Internet Archive 上）|
//! | [`ITunes`] | 封面（按曲目/专辑检索）| 免 Key | 约 20 次/分钟 → 3 秒/次 |
//! 三个提供方都实现"可注入 `base_url`"，默认值是真实地址；测试和自建镜像都靠它。
//!
//! ## 置信度怎么填
//!
//! ENR-05 的加权模糊匹配写成纯函数 [`crate::scoring::score_match`]，
//! 每个候选的 [`Candidate::provider_confidence`] 就直接用它算出的分数（0..=1），
//! [`Candidate::matched`] 填"提供方自己描述的曲目信息"，UI 的待确认队列可以直接展示这两项。
//!
//! 因此**流水线应当直接拿 `provider_confidence` 和阈值比较**（`decide(candidate.provider_confidence)`）；
//! [`crate::scoring::score`] 会把 `matched` 重新算一遍再乘 `provider_confidence`，
//! 那是给"提供方另行给出可靠性因子"的场景用的，用在内置提供方身上会重复计分。
//!
//! ## 节流、缓存与错误
//!
//! 每个提供方各有一个 [`RateLimiter`]（主动限速）、一个 [`Backoff`]（失败退避）和一个
//! [`TtlCache`]（结果缓存：同一首歌被问两次、同一张专辑的十几首歌共用封面，都能直接命中）。
//! 失败语义（ENR-09）：
//! - 404 → 返回空 `Vec`，让流水线继续问下一个提供方；
//! - 429/403/503 → `ErrorCode::RateLimited`，5xx/连接失败 → `ErrorCode::Network`；
//!   这两种会记一次退避，本进程内先睡一小段（最多 4 秒）再报错，真正的重试由补全队列调度；
//! - 解析失败 → `ErrorCode::Decode`。
//!
//! 日志里只出现提供方名、动作名和状态码，不出现标题/艺人/搜索词（隐私红线）。

use crate::cache::{cache_key, TtlCache};
use crate::http;
use crate::scoring::score_match;
use crate::throttle::{Backoff, RateLimiter};
use crate::{ArtworkPayload, ArtworkProvider, Candidate, LyricsPayload, LyricsProvider, TrackHint};
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, LyricsFormat, Result};
use serde::Deserialize;
use std::time::Duration;

/// 单个提供方一次最多交回多少条候选（候选再多对 UI 也没意义，只会拖慢流水线）。
const MAX_CANDIDATES: usize = 5;

/// 失败退避在本进程内最多睡这么久；更长的等待交给补全队列的重试调度。
const INLINE_BACKOFF_CAP: Duration = Duration::from_secs(4);

/// JSON 解析错误 → [`LekisError`]。
fn decode(e: serde_json::Error) -> LekisError {
    LekisError::new(ErrorCode::Decode, format!("提供方响应解析失败：{e}"))
}

/// 分数转成 `provider_confidence` 需要的精度（内部统一走 f32）。
fn as_confidence(score: f64) -> f32 {
    (score as f32).clamp(0.0, 1.0)
}

/// 统一的"取一次文本"：先过限速器，成功后清零退避，受限或网络错误记一次退避。
///
/// 返回 `Ok(None)` 表示提供方明确没有这条数据（404），调用方应当退化或放弃而不是报错。
async fn fetch(
    client: &reqwest::Client,
    limiter: &RateLimiter,
    backoff: &Backoff,
    url: reqwest::Url,
    what: &str,
) -> Result<Option<String>> {
    limiter.acquire().await;
    match http::get_text(client, url, what).await {
        Ok(body) => {
            backoff.reset();
            Ok(body)
        }
        Err(error) => {
            if matches!(error.code, ErrorCode::RateLimited | ErrorCode::Network) {
                let delay = backoff.record_failure().min(INLINE_BACKOFF_CAP);
                tracing::warn!(
                    target: "lekis_enrich::providers",
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

/// 只允许字母数字和 `-`（MusicBrainz 的 MBID 是 UUID），防止把路径拼出花来。
fn validate_mbid(mbid: &str) -> Result<&str> {
    let mbid = mbid.trim();
    if mbid.is_empty() {
        return Err(LekisError::invalid("MBID 为空"));
    }
    if !mbid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(LekisError::invalid("MBID 含有非法字符"));
    }
    Ok(mbid)
}

// ============================================================================
// LRCLIB
// ============================================================================

#[path = "providers/amll.rs"]
mod amll;
#[cfg(test)]
#[path = "providers/lrclib_tests.rs"]
mod lrclib_tests;
pub use amll::AmllLyrics;
#[path = "providers/lyrics_matching.rs"]
mod lyrics_matching;

/// LRCLIB 歌词（ENR-03 来源 ③）。
///
/// 先走 `/api/get` 精确匹配（`track_name` + `artist_name` + 可选 `album_name`/`duration`），
/// 服务器没有这条记录（404）或者拿到的记录没歌词时，退化到 `/api/search?q=` 模糊检索。
/// 带时间轴的 `syncedLyrics` 交给 [`LyricsFormat::Lrc`]，只有纯文本时用 [`LyricsFormat::Plain`]。
pub struct Lrclib {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    /// LRCLIB-only server cooldown; never blocks unrelated providers.
    cooldown: std::sync::Mutex<Option<std::time::Instant>>,
    /// 结果缓存（ENR-09）：同一首歌在一次扫描里可能被问两次（取封面时也会顺带问歌词）。
    cache: TtlCache<Vec<Candidate<LyricsPayload>>>,
}

impl Lrclib {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://lrclib.net";

    /// 用官方地址创建。
    ///
    /// # Errors
    /// HTTP 客户端构建失败时返回错误（基本只会在系统根证书缺失时发生）。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建（自建镜像、单元测试）。
    ///
    /// # Errors
    /// 地址为空或 HTTP 客户端构建失败时报错。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("LRCLIB 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(60)),
            cooldown: std::sync::Mutex::new(None),
            cache: TtlCache::new(),
        })
    }

    /// 当前使用的地址。
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 清空结果缓存。
    pub fn clear_cache(&self) {
        self.cache.clear();
    }

    async fn fetch_lyrics(&self, url: reqwest::Url, what: &str) -> Result<Option<String>> {
        self.limiter.acquire().await;
        if self
            .cooldown
            .lock()
            .map_err(|_| LekisError::new(ErrorCode::Internal, "LRCLIB cooldown lock"))?
            .is_some_and(|until| until > std::time::Instant::now())
        {
            return Err(LekisError::new(
                ErrorCode::RateLimited,
                "LRCLIB：服务器冷却中",
            ));
        }
        let response = self.client.get(url).send().await.map_err(http::network)?;
        let code = response.status().as_u16();
        if (200..300).contains(&code) {
            self.backoff.reset();
            return response.text().await.map(Some).map_err(http::network);
        }
        if code == 404 {
            return Ok(None);
        }
        if code == 429 || code == 503 {
            let delay = response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| {
                    value
                        .parse::<u64>()
                        .ok()
                        .map(Duration::from_secs)
                        .or_else(|| {
                            httpdate::parse_http_date(value).ok().map(|date| {
                                date.duration_since(std::time::SystemTime::now())
                                    .unwrap_or_default()
                            })
                        })
                })
                .unwrap_or_else(|| self.backoff.record_failure());
            // No sleep: callers get a typed error while subsequent requests short-circuit.
            *self
                .cooldown
                .lock()
                .map_err(|_| LekisError::new(ErrorCode::Internal, "LRCLIB cooldown lock"))? =
                std::time::Instant::now().checked_add(delay);
        }
        Err(http::status(code, what))
    }

    /// `/api/get` 的地址（精确匹配）。
    ///
    /// 参数用 `query_pairs_mut` 构造，天然做了百分号编码（中文标题也不需要额外处理）。
    /// `duration` 按 LRCLIB 的约定传整秒；时长未知就不传（少一个条件，命中率反而高）。
    fn exact_url(&self, hint: &TrackHint) -> Result<reqwest::Url> {
        let mut url = http::join(&self.base_url, "/api/get")?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("track_name", hint.title.trim());
            if let Some(artist) = hint
                .artists
                .iter()
                .map(|a| a.trim())
                .find(|a| !a.is_empty())
            {
                query.append_pair("artist_name", artist);
            }
            if let Some(album) = hint
                .album
                .as_deref()
                .map(str::trim)
                .filter(|a| !a.is_empty())
            {
                query.append_pair("album_name", album);
            }
            let seconds = hint.duration_ms.saturating_add(500) / 1000;
            if (1..=3600).contains(&seconds) {
                query.append_pair("duration", &seconds.to_string());
            }
        }
        Ok(url)
    }

    /// Structured fields avoid matching a title solely in an unrelated album name.
    fn search_url(&self, title: &str, artist: Option<&str>) -> Result<reqwest::Url> {
        let mut url = http::join(&self.base_url, "/api/search")?;
        url.query_pairs_mut().append_pair("track_name", title);
        if let Some(artist) = artist.filter(|a| !a.trim().is_empty()) {
            url.query_pairs_mut().append_pair("artist_name", artist);
        }
        Ok(url)
    }
}

#[async_trait]
impl LyricsProvider for Lrclib {
    fn name(&self) -> &str {
        "lrclib"
    }

    async fn find_lyrics(&self, hint: &TrackHint) -> Result<Vec<Candidate<LyricsPayload>>> {
        if hint.title.trim().is_empty() {
            // 没有标题就没法检索，直接交白卷，别浪费配额。
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            tracing::debug!(
                target: "lekis_enrich::providers",
                provider = "lrclib",
                "命中结果缓存"
            );
            return Ok(cached);
        }

        let mut candidates = Vec::new();
        let mut first_error = None;
        // /api/get requires an artist; a missing tag should fall back to search,
        // rather than sending an invalid request and stopping at HTTP 400.
        if hint.artists.iter().any(|artist| !artist.trim().is_empty()) {
            let exact = self.exact_url(hint)?;
            if let Some(body) = self.fetch_lyrics(exact, "LRCLIB /api/get").await? {
                if let Some(entry) = parse_lrclib_record(&body)? {
                    candidates = lyrics_candidates(self.name(), hint, &[entry]);
                    if lyrics_matching::has_synced_hit(&candidates) {
                        self.cache.insert(key, candidates.clone());
                        return Ok(candidates);
                    }
                }
            }
        }

        // A plain exact result remains usable while we look for a synced edition.
        // Requests are sequential and bounded, and every returned record is still
        // checked against the original identity, including artist and version.
        for (title, artist) in lyrics_matching::search_variants(hint) {
            let search = self.search_url(&title, artist.as_deref())?;
            match self.fetch_lyrics(search, "LRCLIB /api/search").await {
                Ok(Some(body)) => {
                    let entries = match parse_lrclib_search(&body) {
                        Ok(entries) => entries,
                        Err(error) => {
                            first_error = Some(error);
                            break;
                        }
                    };
                    candidates.extend(lyrics_candidates(self.name(), hint, &entries));
                    lyrics_matching::sort(&mut candidates);
                    if lyrics_matching::has_synced_hit(&candidates) {
                        break;
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    first_error = Some(error);
                    break;
                }
            }
        }
        lyrics_matching::sort(&mut candidates);
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
            return Ok(candidates);
        }
        if let Some(error) = first_error {
            return Err(error);
        }
        Ok(candidates)
    }
}

/// LRCLIB 的一条歌词记录（`/api/get` 的对象，或 `/api/search` 数组里的一项）。
#[derive(Debug, Clone, Default, Deserialize)]
struct LrcEntry {
    /// 曲目名（`/api/get` 也会给 `name`，两者等价）。
    #[serde(rename = "trackName", default)]
    track_name: Option<String>,
    /// 旧字段名的曲目名。
    #[serde(rename = "name", default)]
    name: Option<String>,
    /// 艺人。
    #[serde(rename = "artistName", default)]
    artist_name: Option<String>,
    /// 专辑。
    #[serde(rename = "albumName", default)]
    album_name: Option<String>,
    /// 时长（秒，可能是小数）。
    #[serde(default)]
    duration: Option<f64>,
    /// 纯音乐。
    #[serde(default)]
    instrumental: Option<bool>,
    /// 纯文本歌词。
    #[serde(rename = "plainLyrics", default)]
    plain_lyrics: Option<String>,
    /// 带时间轴的歌词。
    #[serde(rename = "syncedLyrics", default)]
    synced_lyrics: Option<String>,
}

impl LrcEntry {
    /// 把记录转成"提供方自己描述的曲目信息"，交给打分函数比对。
    fn to_hint(&self) -> TrackHint {
        let title = self
            .track_name
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .or_else(|| {
                self.name
                    .as_deref()
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
            })
            .unwrap_or_default()
            .to_string();
        TrackHint {
            title,
            artists: self
                .artist_name
                .as_deref()
                .map(split_artist_names)
                .unwrap_or_default(),
            album: self
                .album_name
                .as_deref()
                .map(str::trim)
                .filter(|a| !a.is_empty())
                .map(str::to_string),
            duration_ms: self.duration.map(seconds_to_ms).unwrap_or(0),
            mbid_recording: None,
            mbid_release: None,
        }
    }
}

/// 秒（可能是小数）→ 毫秒；越界或非法值退回 0（"时长未知"）。
fn seconds_to_ms(seconds: f64) -> u64 {
    if !seconds.is_finite() || seconds <= 0.0 {
        return 0;
    }
    let ms = (seconds * 1000.0).round();
    if ms > u64::MAX as f64 {
        0
    } else {
        ms as u64
    }
}

/// 把 "A, B & C" 这类艺人串拆成多个（曲目名和艺人名都可能出现多艺人写法）。
fn split_artist_names(value: &str) -> Vec<String> {
    value
        .split([',', '/', '&', ';', '、'])
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(str::to_string)
        .collect()
}

/// 解析 `/api/get` 的响应：正常是一个对象；不是对象就当没找到。
fn parse_lrclib_record(body: &str) -> Result<Option<LrcEntry>> {
    let value: serde_json::Value = serde_json::from_str(body).map_err(decode)?;
    if !value.is_object() {
        return Ok(None);
    }
    serde_json::from_value(value).map(Some).map_err(decode)
}

/// 解析 `/api/search` 的响应（数组）。
fn parse_lrclib_search(body: &str) -> Result<Vec<LrcEntry>> {
    let value: serde_json::Value = serde_json::from_str(body).map_err(decode)?;
    match value {
        serde_json::Value::Array(_) => serde_json::from_value(value).map_err(decode),
        // 有些镜像会用 `{"data": [...]}` 包装。
        serde_json::Value::Object(map) => {
            let inner = map
                .get("data")
                .cloned()
                .ok_or_else(|| LekisError::new(ErrorCode::Decode, "LRCLIB 检索响应缺少 results"))?;
            serde_json::from_value(inner).map_err(decode)
        }
        _ => Err(LekisError::new(
            ErrorCode::Decode,
            "LRCLIB 检索响应不是数组",
        )),
    }
}

// A metadata tag or arbitrary nonempty string is not synchronized lyrics.
fn has_lyric_timestamp(value: &str) -> bool {
    value.split('[').skip(1).any(|part| {
        let Some((stamp, text)) = part.split_once(']') else {
            return false;
        };
        let Some((minutes, seconds)) = stamp.split_once(':') else {
            return false;
        };
        !minutes.is_empty()
            && minutes.bytes().all(|b| b.is_ascii_digit())
            && seconds
                .parse::<f64>()
                .is_ok_and(|v| v.is_finite() && (0.0..60.0).contains(&v))
            && !text.trim().is_empty()
    })
}

/// 把 LRCLIB 记录变成候选：有 `syncedLyrics` 优先给 LRC，否则用 `plainLyrics`。
fn lyrics_candidates(
    source: &str,
    hint: &TrackHint,
    entries: &[LrcEntry],
) -> Vec<Candidate<LyricsPayload>> {
    let mut out = Vec::new();
    for entry in entries {
        // 纯音乐没有歌词可挂，直接跳过（有些记录仍会带一个 "[Instrumental]" 占位文本）。
        if entry.instrumental == Some(true) {
            continue;
        }
        let (format, content) = match (
            entry
                .synced_lyrics
                .as_deref()
                .map(str::trim)
                .filter(|s| has_lyric_timestamp(s)),
            entry
                .plain_lyrics
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty()),
        ) {
            (Some(synced), _) => (LyricsFormat::Lrc, synced.to_string()),
            (None, Some(plain)) => (LyricsFormat::Plain, plain.to_string()),
            // 纯音乐，或者这条记录根本没歌词：跳过。
            (None, None) => continue,
        };

        let matched = entry.to_hint();
        let Some(confidence) = lyrics_matching::confidence(hint, &matched) else {
            continue;
        };
        out.push(Candidate {
            payload: LyricsPayload { format, content },
            source: source.to_string(),
            matched,
            provider_confidence: confidence,
        });
    }

    out.retain(|candidate| candidate.provider_confidence >= crate::REVIEW_THRESHOLD);
    lyrics_matching::sort(&mut out);
    out
}

/// 按置信度降序，截断到 [`MAX_CANDIDATES`]，并丢掉低于待确认阈值的候选。
///
/// 线索里连标题都没有时不裁（否则分数全被压到阈值以下，等于什么都查不到）。
fn sort_and_filter<T>(mut candidates: Vec<Candidate<T>>, hint: &TrackHint) -> Vec<Candidate<T>> {
    candidates.sort_by(|a, b| b.provider_confidence.total_cmp(&a.provider_confidence));
    if !hint.title.trim().is_empty() {
        candidates.retain(|c| c.provider_confidence >= crate::REVIEW_THRESHOLD);
    }
    candidates.truncate(MAX_CANDIDATES);
    candidates
}

// ============================================================================
// Cover Art Archive
// ============================================================================

/// Cover Art Archive 封面（ENR-01 来源 ③）：按 Release MBID 精确取图。
///
/// 需要线索里有 `mbid_release`（本地标签或 MusicBrainz 查询得来），没有就直接返回空，
/// 让流水线去问下一个提供方。取 `front: true` 的那张，优先用 `thumbnails.large`。
pub struct CoverArtArchive {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    /// 结果缓存（ENR-09）：同一张专辑下十几首歌共用同一个 Release MBID，命中率很高。
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl CoverArtArchive {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://coverartarchive.org";

    /// 用官方地址创建。
    ///
    /// # Errors
    /// HTTP 客户端构建失败时报错。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    ///
    /// # Errors
    /// 地址为空或 HTTP 客户端构建失败时报错。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("Cover Art Archive 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            limiter: RateLimiter::new(Duration::from_secs(1)),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(60)),
            cache: TtlCache::new(),
        })
    }

    /// 当前使用的地址。
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 清空结果缓存。
    pub fn clear_cache(&self) {
        self.cache.clear();
    }
}

#[async_trait]
impl ArtworkProvider for CoverArtArchive {
    fn name(&self) -> &str {
        "coverartarchive"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        let Some(mbid) = hint.mbid_release.as_deref() else {
            // 没有 Release MBID 就查不了，这是正常情况（ENR-01 的 ③ 只对 MusicBrainz 有数据的曲目有效）。
            return Ok(Vec::new());
        };
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }

        let mbid = validate_mbid(mbid)?;
        let url = http::join(&self.base_url, &format!("/release/{mbid}"))?;
        let Some(body) = fetch(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            "Cover Art Archive /release",
        )
        .await?
        else {
            return Ok(Vec::new());
        };

        let images = parse_coverart_archive(&body)?;
        let candidates = artwork_candidates(self.name(), hint, images);
        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

/// CAA 响应里的一张图。
#[derive(Debug, Clone, Default, Deserialize)]
struct CaaImage {
    /// 是否是封面（最可靠的正反面标记）。
    #[serde(default)]
    front: Option<bool>,
    /// 是否是封底。
    #[serde(default)]
    back: Option<bool>,
    /// 图片类型，例如 `["Front", "Cover"]`。
    #[serde(default)]
    types: Vec<String>,
    /// 原图地址。
    #[serde(default)]
    image: Option<String>,
    /// 缩略图，键名有 `small`/`large`/`1200` 等。
    #[serde(default)]
    thumbnails: std::collections::BTreeMap<String, String>,
}

impl CaaImage {
    /// 这张图是不是正面封面。
    fn is_front(&self) -> bool {
        self.front == Some(true) || self.types.iter().any(|t| t.eq_ignore_ascii_case("front"))
    }

    /// 拿最大可用尺寸：`thumbnails.large` 覆盖 500px 左右，比原图快得多；
    /// 没有缩略图才退回 `image`。
    fn best_url(&self) -> Option<&str> {
        self.thumbnails
            .get("large")
            .map(String::as_str)
            .filter(|u| !u.is_empty())
            .or_else(|| self.thumbnails.get("1200").map(String::as_str))
            .or(self.image.as_deref())
            .filter(|u| !u.is_empty())
    }
}

/// 解析 CAA 的 `/release/{mbid}` 响应。
///
/// 只保留 `image/` 域名下的 http(s) 地址，并把正面封面排在最前面。
fn parse_coverart_archive(body: &str) -> Result<Vec<ArtworkPayload>> {
    #[derive(Deserialize)]
    struct Response {
        #[serde(default)]
        images: Vec<CaaImage>,
    }
    let response: Response = serde_json::from_str(body).map_err(decode)?;

    let mut fronts = Vec::new();
    let mut others = Vec::new();
    for image in &response.images {
        let Some(url) = image.best_url() else {
            continue;
        };
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            // 防御：CAA 只会给绝对地址，别把奇怪的东西塞进封面缓存。
            continue;
        }
        let payload = ArtworkPayload {
            url: url.to_string(),
            // CAA 的缩略图是等比缩放，实际像素取决于上传的原图，这里不瞎猜。
            width: None,
            height: None,
        };
        if image.is_front() {
            fronts.push(payload);
        } else if image.back != Some(true) {
            others.push(payload);
        }
    }
    fronts.extend(others);
    Ok(fronts)
}

/// 把图片包成候选。CAA 是按 Release MBID 精确查的，不提供曲目级信息，
/// 所以 `matched` 就是线索本身（打分自然是满分，除非线索本身自相矛盾）。
fn artwork_candidates(
    source: &str,
    hint: &TrackHint,
    images: Vec<ArtworkPayload>,
) -> Vec<Candidate<ArtworkPayload>> {
    let confidence = as_confidence(score_match(
        hint,
        &hint.title,
        &hint.artists.join(" / "),
        hint.album.as_deref(),
        hint.duration_ms,
    ));
    images
        .into_iter()
        .take(MAX_CANDIDATES)
        .map(|payload| Candidate {
            payload,
            source: source.to_string(),
            matched: hint.clone(),
            provider_confidence: confidence,
        })
        .collect()
}

// ============================================================================
// iTunes Search API
// ============================================================================

/// iTunes Search API 封面（ENR-01 来源 ④）。
///
/// 先用 `entity=song` 按"标题 + 艺人"检索；没有结果时退化到 `entity=album` 按"艺人 + 专辑"检索。
/// `artworkUrl100` 里的 `100x100bb` 换成 `600x600bb` 就得到 600px 大图（Apple 的图片服务按 URL 里的
/// 尺寸参数缩放，同一张原图能取多个尺寸）。
pub struct ITunes {
    base_url: String,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
    /// 结果缓存（ENR-09）：iTunes 是三个提供方里配额最紧的（20 次/分钟），缓存最值钱。
    cache: TtlCache<Vec<Candidate<ArtworkPayload>>>,
}

impl ITunes {
    /// 官方地址。
    pub const DEFAULT_BASE_URL: &'static str = "https://itunes.apple.com";

    /// 用官方地址创建。
    ///
    /// # Errors
    /// HTTP 客户端构建失败时报错。
    pub fn new() -> Result<Self> {
        Self::with_base_url(Self::DEFAULT_BASE_URL)
    }

    /// 用自定义地址创建。
    ///
    /// # Errors
    /// 地址为空或 HTTP 客户端构建失败时报错。
    pub fn with_base_url(base_url: &str) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            return Err(LekisError::invalid("iTunes 地址为空"));
        }
        Ok(Self {
            base_url,
            client: http::client()?,
            // 20 次/分钟 → 平均 3 秒一次。
            limiter: RateLimiter::new(Duration::from_secs(3)),
            backoff: Backoff::new(Duration::from_secs(2), Duration::from_secs(60)),
            cache: TtlCache::new(),
        })
    }

    /// 当前使用的地址。
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 清空结果缓存。
    pub fn clear_cache(&self) {
        self.cache.clear();
    }

    /// 检索地址（默认商店区，测试与兜底复用）。
    #[cfg(test)]
    fn search_url(&self, term: &str, entity: &str) -> Result<reqwest::Url> {
        self.search_url_in_country(term, entity, None)
    }

    /// 按指定商店区检索（如 `Some("jp")` 覆盖日区动漫 OST / Vocaloid / ACG 专辑）。
    fn search_url_in_country(
        &self,
        term: &str,
        entity: &str,
        country: Option<&str>,
    ) -> Result<reqwest::Url> {
        let mut url = http::join(&self.base_url, "/search")?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("term", term);
            query.append_pair("entity", entity);
            query.append_pair("media", "music");
            query.append_pair("limit", "5");
            if let Some(code) = country {
                query.append_pair("country", code);
                if code.eq_ignore_ascii_case("jp") {
                    query.append_pair("lang", "ja_jp");
                }
            }
        }
        Ok(url)
    }

    /// 检索一次并解析。
    async fn search(
        &self,
        term: &str,
        entity: &str,
        country: Option<&str>,
    ) -> Result<Vec<ITunesItem>> {
        let url = self.search_url_in_country(term, entity, country)?;
        let Some(body) = fetch(
            &self.client,
            &self.limiter,
            &self.backoff,
            url,
            "iTunes /search",
        )
        .await?
        else {
            return Ok(Vec::new());
        };
        parse_itunes_search(&body)
    }
}

/// 文本是否包含中日韩表意文字或日文假名（用于优先走日区商店与 ACG 清洗逻辑）。
pub(crate) fn contains_cjk_or_kana(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(
            c as u32,
            0x3040..=0x30FF // Hiragana + Katakana
                | 0x31F0..=0x31FF
                | 0x4E00..=0x9FFF // CJK Unified Ideographs
                | 0x3400..=0x4DBF
                | 0xF900..=0xFAFF
        )
    })
}

/// 清洗日系 / ACG 曲名与专辑名里常见的版本后缀噪声：
/// 如 `(TV Size)`、`(Game Ver.)`、`(Instrumental)`、`(CV. xxx)`、`[Hi-Res]`、全角波浪号等。
pub(crate) fn clean_acg_query(text: &str) -> String {
    let mut s = text.replace(['\u{3000}', '～', '~'], " ");
    for (open, close) in [
        ('(', ')'),
        ('（', '）'),
        ('[', ']'),
        ('【', '】'),
        ('「', '」'),
    ] {
        while let Some(start) = s.find(open) {
            if let Some(rel_end) = s[start + open.len_utf8()..].find(close) {
                let end = start + open.len_utf8() + rel_end + close.len_utf8();
                let inner = &s[start + open.len_utf8()..start + open.len_utf8() + rel_end];
                let lower = inner.to_ascii_lowercase();
                let is_noise = lower.contains("tv")
                    || lower.contains("size")
                    || lower.contains("ver")
                    || lower.contains("edit")
                    || lower.contains("inst")
                    || lower.contains("off vocal")
                    || lower.contains("karaoke")
                    || lower.contains("cv.")
                    || lower.contains("cv:")
                    || lower.contains("feat")
                    || lower.contains("flac")
                    || lower.contains("hi-res")
                    || lower.contains("remaster")
                    || lower.contains("ost")
                    || lower.contains("op")
                    || lower.contains("ed");
                if is_noise {
                    s.replace_range(start..end, " ");
                    continue;
                }
            }
            break;
        }
    }
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[async_trait]
impl ArtworkProvider for ITunes {
    fn name(&self) -> &str {
        "itunes"
    }

    async fn find_artwork(&self, hint: &TrackHint) -> Result<Vec<Candidate<ArtworkPayload>>> {
        if hint.title.trim().is_empty() && hint.album.is_none() {
            return Ok(Vec::new());
        }
        let key = cache_key(&self.base_url, hint);
        if let Some(cached) = self.cache.get(&key) {
            tracing::debug!(
                target: "lekis_enrich::providers",
                provider = "itunes",
                "命中结果缓存"
            );
            return Ok(cached);
        }

        let artist = hint
            .artists
            .first()
            .map(String::as_str)
            .unwrap_or("")
            .trim();
        let is_cjk = contains_cjk_or_kana(&hint.title)
            || contains_cjk_or_kana(artist)
            || hint.album.as_deref().is_some_and(contains_cjk_or_kana);
        // CJK / 日语曲目优先查日区商店（日区覆盖大量动漫 OST / Vocaloid / 角色歌），
        // 未命中再回落到全局商店。
        let primary_country = is_cjk.then_some("jp");

        let song_term = format!("{} {}", hint.title.trim(), artist)
            .trim()
            .to_string();
        let mut candidates = if song_term.is_empty() {
            Vec::new()
        } else {
            let items = self.search(&song_term, "song", primary_country).await?;
            item_candidates(self.name(), hint, &items)
        };

        if candidates.is_empty() {
            let cleaned_title = clean_acg_query(&hint.title);
            let cleaned_artist = clean_acg_query(artist);
            let cleaned_song = format!("{cleaned_title} {cleaned_artist}")
                .trim()
                .to_string();
            if !cleaned_song.is_empty() && cleaned_song != song_term {
                let items = self.search(&cleaned_song, "song", primary_country).await?;
                candidates = item_candidates(self.name(), hint, &items);
            }
        }

        if candidates.is_empty() {
            if let Some(album) = hint
                .album
                .as_deref()
                .map(str::trim)
                .filter(|a| !a.is_empty())
            {
                let album_term = format!("{album} {artist}").trim().to_string();
                let items = self.search(&album_term, "album", primary_country).await?;
                candidates = item_candidates(self.name(), hint, &items);
                if candidates.is_empty() {
                    let cleaned_album = clean_acg_query(album);
                    if !cleaned_album.is_empty() && cleaned_album != album {
                        let items = self
                            .search(&cleaned_album, "album", primary_country)
                            .await?;
                        candidates = item_candidates(self.name(), hint, &items);
                    }
                }
            }
        }

        // 日区没查到时，再退回默认全局区试一次（部分海外发行的双语/华语专辑不在 JP 区）。
        if candidates.is_empty() && primary_country.is_some() && !song_term.is_empty() {
            let items = self.search(&song_term, "song", None).await?;
            candidates = item_candidates(self.name(), hint, &items);
        }

        if !candidates.is_empty() {
            self.cache.insert(key, candidates.clone());
        }
        Ok(candidates)
    }
}

/// iTunes 检索结果里的一项（`songs` 和 `albums` 两种 entity 共用）。
#[derive(Debug, Clone, Default, Deserialize)]
struct ITunesItem {
    /// 曲目名（`entity=song` 时才有）。
    #[serde(rename = "trackName", default)]
    track_name: Option<String>,
    /// 专辑/合集名。
    #[serde(rename = "collectionName", default)]
    collection_name: Option<String>,
    /// 艺人。
    #[serde(rename = "artistName", default)]
    artist_name: Option<String>,
    /// 时长（毫秒）。
    #[serde(rename = "trackTimeMillis", default)]
    track_time_ms: Option<u64>,
    /// 100px 封面地址。
    #[serde(rename = "artworkUrl100", default)]
    artwork_url_100: Option<String>,
}

impl ITunesItem {
    /// 取 600px 封面地址（把 URL 里的尺寸参数换掉）。
    fn big_artwork(&self) -> Option<String> {
        let url = self.artwork_url_100.as_deref()?.trim();
        if url.is_empty() {
            return None;
        }
        Some(upgrade_artwork_size(url))
    }
}

/// 把 Apple 图片地址里的 `100x100bb` 换成 `600x600bb`；换不到就原样返回。
fn upgrade_artwork_size(url: &str) -> String {
    if url.contains("100x100bb") {
        return url.replace("100x100bb", "600x600bb");
    }
    if url.contains("100x100") {
        return url.replace("100x100", "600x600");
    }
    url.to_string()
}

/// 解析 `/search` 响应（`resultCount` + `results[]`）。
fn parse_itunes_search(body: &str) -> Result<Vec<ITunesItem>> {
    #[derive(Deserialize)]
    struct Wire {
        /// Apple 会把结果条数放在这里；我们直接用 `results` 的长度，字段留着做类型校验。
        #[serde(default)]
        #[allow(dead_code)]
        result_count: Option<u32>,
        #[serde(default)]
        results: Vec<ITunesItem>,
    }
    let wire: Wire = serde_json::from_str(body).map_err(decode)?;
    Ok(wire.results)
}

/// 把检索结果包成候选。标题/艺人/专辑/时长都用来打分；
/// `entity=album` 的结果没有曲目名，标题项会自然掉分（专辑封面本来就只对应专辑，
/// 落在待确认区是正确行为）。
fn item_candidates(
    source: &str,
    hint: &TrackHint,
    items: &[ITunesItem],
) -> Vec<Candidate<ArtworkPayload>> {
    let mut out = Vec::new();
    for item in items {
        let Some(url) = item.big_artwork() else {
            continue;
        };
        let title = item
            .track_name
            .as_deref()
            .or(item.collection_name.as_deref())
            .unwrap_or_default()
            .trim()
            .to_string();
        let artists = item
            .artist_name
            .as_deref()
            .map(split_artist_names)
            .unwrap_or_default();
        let matched = TrackHint {
            title,
            artists,
            album: item
                .collection_name
                .as_deref()
                .map(str::trim)
                .filter(|a| !a.is_empty())
                .map(str::to_string),
            duration_ms: item.track_time_ms.unwrap_or(0),
            mbid_recording: None,
            mbid_release: None,
        };
        let confidence = as_confidence(score_match(
            hint,
            &matched.title,
            &matched.artists.join(" / "),
            matched.album.as_deref(),
            matched.duration_ms,
        ));
        out.push(Candidate {
            payload: ArtworkPayload {
                url,
                // 600x600 是请求的尺寸，Apple 实际返回的不会更小（除非原图更小）。
                width: Some(600),
                height: Some(600),
            },
            source: source.to_string(),
            matched,
            provider_confidence: confidence,
        });
    }
    sort_and_filter(out, hint)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn hint(title: &str, artist: &str, album: Option<&str>, duration_ms: u64) -> TrackHint {
        TrackHint {
            title: title.into(),
            artists: vec![artist.into()],
            album: album.map(str::to_string),
            duration_ms,
            ..Default::default()
        }
    }

    // ---------- LRCLIB ----------

    const LRCLIB_GET: &str = r#"{
        "id": 3396226,
        "name": "晴天",
        "trackName": "晴天",
        "artistName": "周杰伦",
        "albumName": "叶惠美",
        "duration": 269.0,
        "instrumental": false,
        "plainLyrics": "故事的小黄花\n从出生那年就飘着",
        "syncedLyrics": "[00:00.00] 晴天\n[00:02.00] 周杰伦"
    }"#;

    #[test]
    fn parses_lrclib_get_response() {
        let entry = parse_lrclib_record(LRCLIB_GET).unwrap().unwrap();
        assert_eq!(entry.track_name.as_deref(), Some("晴天"));
        assert_eq!(entry.duration, Some(269.0));
        assert_eq!(entry.to_hint().duration_ms, 269_000);
        assert_eq!(entry.to_hint().artists, vec!["周杰伦".to_string()]);
    }

    /// 有 `syncedLyrics` 时给 Lrc，并且能打到自动应用阈值。
    #[test]
    fn lrclib_prefers_synced_lyrics() {
        let entry = parse_lrclib_record(LRCLIB_GET).unwrap().unwrap();
        let me = hint("晴天", "周杰伦", Some("叶惠美"), 269_000);
        let candidates = lyrics_candidates("lrclib", &me, &[entry]);
        assert_eq!(candidates.len(), 1);
        let candidate = &candidates[0];
        assert_eq!(candidate.payload.format, LyricsFormat::Lrc);
        assert!(candidate.payload.content.starts_with("[00:00.00]"));
        assert!(
            candidate.provider_confidence >= crate::AUTO_APPLY_THRESHOLD,
            "confidence = {}",
            candidate.provider_confidence
        );
        assert_eq!(candidate.source, "lrclib");
        assert_eq!(candidate.matched.album.as_deref(), Some("叶惠美"));
    }

    /// 只有 `plainLyrics` 时给 Plain，不会因为缺时间轴就丢掉。
    #[test]
    fn lrclib_falls_back_to_plain_lyrics() {
        let body = r#"{"trackName":"Yesterday","artistName":"The Beatles",
                       "albumName":"Help!","duration":125.0,
                       "plainLyrics":"Yesterday, all my troubles seemed so far away",
                       "syncedLyrics":null}"#;
        let entry = parse_lrclib_record(body).unwrap().unwrap();
        let me = hint("Yesterday", "The Beatles", Some("Help!"), 125_000);
        let candidates = lyrics_candidates("lrclib", &me, &[entry]);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].payload.format, LyricsFormat::Plain);
        assert!(candidates[0].payload.content.contains("Yesterday"));
        assert!(candidates[0].provider_confidence >= crate::AUTO_APPLY_THRESHOLD);
    }

    /// 纯音乐 / 没歌词的记录直接跳过，不产生空歌词候选。
    #[test]
    fn lrclib_skips_instrumental_and_empty() {
        let body = r#"{"trackName":"Clair de Lune","artistName":"Debussy","instrumental":true,
                       "plainLyrics":null,"syncedLyrics":null}"#;
        let entry = parse_lrclib_record(body).unwrap().unwrap();
        let me = hint("Clair de Lune", "Debussy", None, 300_000);
        assert!(lyrics_candidates("lrclib", &me, &[entry]).is_empty());
    }

    /// `/api/get` 返回数组或空对象时当"没找到"，不报错。
    #[test]
    fn lrclib_get_tolerates_unexpected_shapes() {
        assert!(parse_lrclib_record("[]").unwrap().is_none());
        assert!(parse_lrclib_record("\"oops\"").unwrap().is_none());
        assert!(parse_lrclib_record("{}").unwrap().is_some());
        assert!(parse_lrclib_record("not json").is_err());
    }

    /// 检索结果按置信度排序，无关候选被阈值丢掉。
    #[test]
    fn lrclib_search_sorts_and_filters() {
        let body = r#"[
            {"trackName":"Symphony No. 9","artistName":"Berliner Philharmoniker","duration":4000.0,
             "plainLyrics":"da da da","syncedLyrics":null},
            {"trackName":"晴天","artistName":"周杰伦","albumName":"叶惠美","duration":269.0,
             "plainLyrics":"故事的小黄花","syncedLyrics":"[00:00.00] 晴天"}
        ]"#;
        let entries = parse_lrclib_search(body).unwrap();
        assert_eq!(entries.len(), 2);
        let me = hint("晴天", "周杰伦", Some("叶惠美"), 269_000);
        let candidates = lyrics_candidates("lrclib", &me, &entries);
        assert_eq!(candidates.len(), 1, "无关候选应被丢弃：{candidates:?}");
        assert_eq!(candidates[0].payload.format, LyricsFormat::Lrc);
        assert!(candidates[0].provider_confidence >= 0.99);
    }

    /// 检索响应被镜像包在 `{"data": [...]}` 里也能解析。
    #[test]
    fn lrclib_search_tolerates_wrapped_object() {
        let body = r#"{"data":[{"trackName":"A","artistName":"B","plainLyrics":"x"}]}"#;
        assert_eq!(parse_lrclib_search(body).unwrap().len(), 1);
        assert!(parse_lrclib_search("{}").is_err());
        assert!(parse_lrclib_search("42").is_err());
    }

    /// 精确匹配的地址里中文要百分号编码，且时长按秒传。
    #[test]
    fn lrclib_exact_url_encodes_query() {
        let provider = Lrclib::with_base_url("https://lrclib.net/").unwrap();
        let me = hint("晴天", "周杰伦", Some("叶惠美"), 269_000);
        let url = provider.exact_url(&me).unwrap();
        assert!(url.as_str().starts_with("https://lrclib.net/api/get?"));
        assert!(url.as_str().contains("track_name=%E6%99%B4%E5%A4%A9"));
        assert!(url
            .as_str()
            .contains("album_name=%E5%8F%B6%E6%83%A0%E7%BE%8E"));
        assert_eq!(provider.base_url(), "https://lrclib.net");
        assert!(Lrclib::with_base_url("  ").is_err());
    }

    // ---------- Cover Art Archive ----------

    const CAA_RESPONSE: &str = r#"{
        "release": "https://musicbrainz.org/release/9c1f7c1e-1111-4a2b-8888-000000000001",
        "images": [
            {
                "front": false,
                "back": true,
                "types": ["Back"],
                "image": "https://coverartarchive.org/release/x/back.jpg",
                "thumbnails": {"large": "https://coverartarchive.org/release/x/back-500.jpg"}
            },
            {
                "front": true,
                "types": ["Front", "Cover"],
                "image": "https://coverartarchive.org/release/x/front.jpg",
                "thumbnails": {"small": "https://coverartarchive.org/release/x/front-250.jpg",
                               "large": "https://coverartarchive.org/release/x/front-500.jpg"}
            }
        ]
    }"#;

    /// 取正面封面，并优先用 `thumbnails.large`。
    ///
    /// 封底（`back: true`）会被过滤掉：补全只要正面封面，封面缓存不该被封底占位。
    #[test]
    fn parses_coverart_archive_front_image() {
        let images = parse_coverart_archive(CAA_RESPONSE).unwrap();
        assert_eq!(images.len(), 1, "只保留正面封面");
        assert_eq!(
            images[0].url,
            "https://coverartarchive.org/release/x/front-500.jpg"
        );
        assert_eq!(images[0].width, None);
    }

    /// `front` 缺失但 `types` 里有 "Front" 也算正面。
    #[test]
    fn coverart_archive_accepts_types_marker() {
        let body = r#"{"images":[{"types":["Front"],"image":"https://coverartarchive.org/release/y/a.jpg"}]}"#;
        let images = parse_coverart_archive(body).unwrap();
        assert_eq!(images.len(), 1);
        // 没有缩略图时退回原图。
        assert_eq!(images[0].url, "https://coverartarchive.org/release/y/a.jpg");
    }

    /// 非 http(s) 地址要过滤掉（防御性检查）。
    #[test]
    fn coverart_archive_rejects_non_http_urls() {
        let body = r#"{"images":[{"front":true,"image":"file:///etc/passwd"}]}"#;
        assert!(parse_coverart_archive(body).unwrap().is_empty());
        assert!(parse_coverart_archive("{}").unwrap().is_empty());
        assert!(parse_coverart_archive("nope").is_err());
    }

    /// CAA 候选按 MBID 精确查，置信度等价于满分。
    #[test]
    fn coverart_candidates_are_confident() {
        let me = TrackHint {
            title: "晴天".into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            mbid_recording: None,
            mbid_release: Some("9c1f7c1e-1111-4a2b-8888-000000000001".into()),
        };
        let images = parse_coverart_archive(CAA_RESPONSE).unwrap();
        let candidates = artwork_candidates("coverartarchive", &me, images);
        assert!(candidates.len() <= MAX_CANDIDATES);
        assert!(candidates[0].provider_confidence >= 0.99);
        assert_eq!(
            candidates[0].matched.mbid_release.as_deref(),
            me.mbid_release.as_deref()
        );
    }

    // ---------- iTunes ----------

    const ITUNES_RESPONSE: &str = r#"{
        "resultCount": 2,
        "results": [
            {
                "wrapperType": "track",
                "kind": "song",
                "trackName": "晴天",
                "artistName": "周杰伦",
                "collectionName": "叶惠美",
                "trackTimeMillis": 269000,
                "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/abc/100x100bb.jpg"
            },
            {
                "wrapperType": "track",
                "kind": "song",
                "trackName": "Symphony No. 9",
                "artistName": "Berliner Philharmoniker",
                "collectionName": "Beethoven: Symphony No. 9",
                "trackTimeMillis": 4000000,
                "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/def/100x100bb.jpg"
            }
        ]
    }"#;

    /// `100x100bb` 要换成 `600x600bb`，无关结果要被丢掉。
    #[test]
    fn parses_itunes_search_and_upgrades_artwork() {
        let items = parse_itunes_search(ITUNES_RESPONSE).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0].big_artwork().unwrap(),
            "https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg"
        );
        assert_eq!(upgrade_artwork_size("https://x/y.jpg"), "https://x/y.jpg");

        let me = hint("晴天", "周杰伦", Some("叶惠美"), 269_000);
        let candidates = item_candidates("itunes", &me, &items);
        assert_eq!(candidates.len(), 1, "无关结果应被丢弃");
        assert_eq!(candidates[0].payload.width, Some(600));
        assert!(candidates[0].payload.url.contains("600x600bb"));
        assert!(candidates[0].provider_confidence >= crate::AUTO_APPLY_THRESHOLD);
        assert_eq!(candidates[0].matched.duration_ms, 269_000);
    }

    /// 空结果、缺字段都不能炸。
    #[test]
    fn parses_itunes_empty_response() {
        assert!(parse_itunes_search(r#"{"resultCount":0,"results":[]}"#)
            .unwrap()
            .is_empty());
        assert!(
            parse_itunes_search(r#"{"resultCount":1,"results":[{"kind":"song"}]}"#).unwrap()[0]
                .big_artwork()
                .is_none()
        );
        assert!(parse_itunes_search("oops").is_err());
    }

    /// 专辑检索的候选因为标题项掉分而落在待确认区（而不是自动应用）。
    #[test]
    fn itunes_album_candidate_lands_in_review() {
        let body = r#"{"resultCount":1,"results":[{
            "collectionName":"叶惠美","artistName":"周杰伦",
            "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/ghj/100x100bb.jpg"}]}"#;
        let items = parse_itunes_search(body).unwrap();
        let me = hint("晴天", "周杰伦", Some("叶惠美"), 269_000);
        let candidates = item_candidates("itunes", &me, &items);
        assert_eq!(candidates.len(), 1);
        let confidence = candidates[0].provider_confidence;
        assert!(
            (crate::REVIEW_THRESHOLD..crate::AUTO_APPLY_THRESHOLD).contains(&confidence),
            "专辑封面应落在待确认区：{confidence}"
        );
    }

    /// 检索地址要带上 entity 和 limit。
    #[test]
    fn itunes_search_url_has_expected_params() {
        let provider = ITunes::with_base_url("https://itunes.apple.com").unwrap();
        let url = provider.search_url("晴天 周杰伦", "song").unwrap();
        let text = url.as_str();
        assert!(text.starts_with("https://itunes.apple.com/search?"));
        assert!(text.contains("entity=song"));
        assert!(text.contains("limit=5"));
        assert!(text.contains("media=music"));
        assert_eq!(provider.limiter.min_interval(), Duration::from_secs(3));
    }

    // ---------- 通用 ----------

    /// MBID 只允许 UUID 字符，别把路径拼出花来。
    #[test]
    fn mbid_validation_blocks_path_tricks() {
        assert!(validate_mbid("9c1f7c1e-1111-4a2b-8888-000000000001").is_ok());
        assert!(validate_mbid("  ").is_err());
        assert!(validate_mbid("../../etc/passwd").is_err());
        assert!(validate_mbid("abc?x=1").is_err());
    }

    /// 提供方在没线索时应当直接交白卷，一个网络请求都不发。
    #[tokio::test]
    async fn empty_hint_short_circuits() {
        let me = TrackHint::default();
        let lrclib = Lrclib::new().unwrap();
        assert!(lrclib.find_lyrics(&me).await.unwrap().is_empty());
        let itunes = ITunes::new().unwrap();
        assert!(itunes.find_artwork(&me).await.unwrap().is_empty());
        let caa = CoverArtArchive::new().unwrap();
        assert!(caa.find_artwork(&me).await.unwrap().is_empty());
    }
}
