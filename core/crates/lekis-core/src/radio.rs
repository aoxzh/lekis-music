//! 网络电台（SRC-11）：Radio Browser 客户端、筛选条件、播放列表解析。
//!
//! 只使用公开的 Radio Browser API，不保存任何凭证。镜像按顺序轮换：
//! 一次请求失败（超时、5xx、JSON 损坏）就换下一个镜像，整轮失败后再重试一轮。
//! 所有请求都带 Lekis 的 User-Agent；分页由 `offset` / `limit` 控制。
//!
//! Radio Browser 返回的电台只是缓存，收藏和自定义电台由
//! [`lekis_library`] 的 `radio_station` 表持久化。

use lekis_types::{
    now_ms, ArtistCredit, ArtistRole, AudioProps, Codec, CoreEvent, ErrorCode, LekisError,
    LibraryScope, RadioStation, RadioStationId, Result, Track, TrackRow, TrackUid,
};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use url::Url;

/// 默认镜像。`all.api.radio-browser.info` 会自动分流，放最后兜底。
const DEFAULT_MIRRORS: [&str; 3] = [
    "https://de1.api.radio-browser.info",
    "https://de2.api.radio-browser.info",
    "https://all.api.radio-browser.info",
];

/// 单次 HTTP 请求超时。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
/// 建立连接超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// 用户代理（部分公共镜像会拒绝空 UA）。
const USER_AGENT: &str = "Lekis/0.1 (network radio; +https://github.com/lekis-music)";
/// 每页最多返回多少条（Radio Browser 也建议不要太大）。
pub const RADIO_PAGE_MAX: u32 = 100;

/// 浏览排序。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RadioSort {
    /// 按点击量（热门）从高到低。
    Popular,
    /// 按名称。
    Name,
}

/// 一次浏览 / 搜索请求。
#[derive(Debug, Clone)]
pub struct RadioQuery {
    /// 名称关键词；空串表示不限。
    pub search: String,
    /// ISO 3166-1 国家代码（`CN`、`US`……）。
    pub country_code: Option<String>,
    /// 语言名（Radio Browser 的 `language` 值）。
    pub language: Option<String>,
    /// 标签 / 流派。
    pub tag: Option<String>,
    /// 排序。
    pub sort: RadioSort,
    /// 分页偏移。
    pub offset: u32,
    /// 本页条数（1..=[`RADIO_PAGE_MAX`]）。
    pub limit: u32,
}

impl Default for RadioQuery {
    fn default() -> Self {
        Self {
            search: String::new(),
            country_code: None,
            language: None,
            tag: None,
            sort: RadioSort::Popular,
            offset: 0,
            limit: 50,
        }
    }
}

/// 一页浏览结果。
#[derive(Debug, Clone)]
pub struct RadioPage {
    /// 电台。
    pub stations: Vec<RadioStation>,
    /// 后面可能还有更多（按 API 是否返回满页判断）。
    pub has_more: bool,
}

/// 一个筛选选项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RadioFilterOption {
    /// 显示名。
    pub name: String,
    /// 传给 [`RadioQuery`] 的值（国家代码 / 语言 / 标签）。
    pub value: String,
    /// 该选项下的电台数。
    pub station_count: u32,
}

/// 国家 / 语言 / 标签筛选选项。
#[derive(Debug, Clone, Default)]
pub struct RadioFilterOptions {
    /// 国家 / 地区。
    pub countries: Vec<RadioFilterOption>,
    /// 语言。
    pub languages: Vec<RadioFilterOption>,
    /// 热门标签 / 流派。
    pub tags: Vec<RadioFilterOption>,
}

/// Radio Browser 客户端。
pub(crate) struct RadioBrowser {
    client: reqwest::Client,
    mirrors: Vec<String>,
    next_mirror: AtomicUsize,
    filters: Mutex<Option<RadioFilterOptions>>,
}

impl RadioBrowser {
    /// 生产客户端。
    pub(crate) fn new() -> Result<Self> {
        Self::with_mirrors(DEFAULT_MIRRORS.iter().map(|m| (*m).to_string()).collect())
    }

    /// 指定镜像（测试注入本地 HTTP 服务）。
    pub(crate) fn with_mirrors(mirrors: Vec<String>) -> Result<Self> {
        if mirrors.is_empty() {
            return Err(LekisError::invalid(
                "radio browser needs at least one mirror",
            ));
        }
        let client = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .user_agent(USER_AGENT)
            .pool_max_idle_per_host(4)
            .build()
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Network,
                    format!("cannot build radio browser client: {e}"),
                )
            })?;
        Ok(Self {
            client,
            mirrors,
            next_mirror: AtomicUsize::new(0),
            filters: Mutex::new(None),
        })
    }

    /// 拉一页电台；失败时轮换镜像并重试。
    pub(crate) async fn browse(&self, query: &RadioQuery) -> Result<RadioPage> {
        let limit = query.limit.clamp(1, RADIO_PAGE_MAX);
        let path = browse_path(query, limit);
        let raw: Vec<ApiStation> = self.get_json(&path).await?;
        let has_more = raw.len() as u32 >= limit;
        let stations = dedupe(raw.into_iter().filter_map(ApiStation::into_station));
        Ok(RadioPage { stations, has_more })
    }

    /// 国家 / 语言 / 标签筛选选项（进程内缓存）。
    pub(crate) async fn filter_options(&self) -> Result<RadioFilterOptions> {
        if let Ok(cache) = self.filters.lock() {
            if let Some(cached) = cache.as_ref() {
                return Ok(cached.clone());
            }
        }
        let (countries, languages, tags) = tokio::join!(
            self.get_json::<Vec<ApiCountry>>("/json/countries"),
            self.get_json::<Vec<ApiLanguage>>("/json/languages"),
            self.get_json::<Vec<ApiTag>>(
                "/json/tags?limit=200&order=stationcount&reverse=true&hidebroken=true"
            ),
        );
        let mut last_error = None;
        let countries = match countries {
            Ok(v) => country_options(v),
            Err(e) => {
                last_error = Some(e);
                Vec::new()
            }
        };
        let languages = match languages {
            Ok(v) => language_options(v),
            Err(e) => {
                last_error = Some(e);
                Vec::new()
            }
        };
        let tags = match tags {
            Ok(v) => tag_options(v),
            Err(e) => {
                last_error = Some(e);
                Vec::new()
            }
        };
        if countries.is_empty() && languages.is_empty() && tags.is_empty() {
            return Err(last_error.unwrap_or_else(|| {
                LekisError::new(
                    ErrorCode::Network,
                    "radio browser returned no filter options",
                )
            }));
        }
        let options = RadioFilterOptions {
            countries,
            languages,
            tags,
        };
        if let Ok(mut cache) = self.filters.lock() {
            *cache = Some(options.clone());
        }
        Ok(options)
    }

    /// 按镜像顺序请求 JSON；每个镜像失败后换下一个，整轮失败再重试一次。
    async fn get_json<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let total = self.mirrors.len();
        let start = self.next_mirror.load(Ordering::Relaxed) % total;
        let mut last_error = String::from("radio browser request failed");
        for _round in 0..2 {
            for step in 0..total {
                let index = (start + step) % total;
                let base = self.mirrors[index].trim_end_matches('/');
                let url = format!("{base}{path}");
                match self.fetch_json(&url).await {
                    Ok(value) => {
                        self.next_mirror.store(index, Ordering::Relaxed);
                        return Ok(value);
                    }
                    Err(e) => {
                        tracing::debug!(
                            target: "core::radio",
                            mirror = %base,
                            error = %e,
                            "radio browser mirror failed"
                        );
                        last_error = format!("{base}: {}", e.message);
                    }
                }
            }
        }
        Err(LekisError::new(
            ErrorCode::Network,
            format!("all radio browser mirrors failed: {last_error}"),
        ))
    }

    async fn fetch_json<T: DeserializeOwned>(&self, url: &str) -> Result<T> {
        let response = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| {
                LekisError::new(ErrorCode::Network, format!("request {url} failed: {e}"))
            })?;
        let status = response.status();
        if !status.is_success() {
            return Err(LekisError::new(
                if status.as_u16() == 429 {
                    ErrorCode::RateLimited
                } else {
                    ErrorCode::Network
                },
                format!("request {url} returned HTTP {status}"),
            ));
        }
        response.json::<T>().await.map_err(|e| {
            LekisError::new(
                ErrorCode::Network,
                format!("request {url} returned invalid JSON: {e}"),
            )
        })
    }
}

/// 把筛选条件拼成 `/json/stations/search` 的路径和查询串。
pub(crate) fn browse_path(query: &RadioQuery, limit: u32) -> String {
    let mut ser = url::form_urlencoded::Serializer::new(String::new());
    ser.append_pair("hidebroken", "true");
    ser.append_pair("limit", &limit.to_string());
    ser.append_pair("offset", &query.offset.to_string());
    match query.sort {
        RadioSort::Popular => {
            ser.append_pair("order", "clickcount");
            ser.append_pair("reverse", "true");
        }
        RadioSort::Name => {
            ser.append_pair("order", "name");
            ser.append_pair("reverse", "false");
        }
    }
    let search = query.search.trim();
    if !search.is_empty() {
        ser.append_pair("name", search);
    }
    if let Some(code) = query
        .country_code
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        ser.append_pair("countrycode", code);
    }
    if let Some(language) = query
        .language
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        ser.append_pair("language", language);
    }
    if let Some(tag) = query
        .tag
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        ser.append_pair("tag", tag);
        ser.append_pair("tagExact", "true");
    }
    format!("/json/stations/search?{}", ser.finish())
}

/// 从用户输入里解析一个可播放的 http/https 地址。
///
/// 支持直接粘贴地址，也支持 M3U / M3U8 / PLS 文本：M3U 取第一条非注释行，
/// PLS 取编号最小的 `FileN=`。只接受 http 和 https，其余协议直接拒绝。
pub fn parse_stream_address(input: &str) -> Result<String> {
    let text = input.trim().trim_start_matches('\u{feff}');
    if text.is_empty() {
        return Err(LekisError::invalid("stream address must not be empty"));
    }
    let lower = text.to_ascii_lowercase();
    let first_url_line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'));
    let looks_like_playlist = lower.contains("#extm3u")
        || lower.starts_with("#extinf")
        || lower.contains("[playlist]")
        || parse_pls_lines(text).is_some()
        // 没有文件头的纯 URL 列表：多行且第一行就是 http(s) 时也按 M3U 处理。
        || (text.contains('\n')
            && first_url_line.is_some_and(|line| {
                let line = line.to_ascii_lowercase();
                line.starts_with("http://") || line.starts_with("https://")
            }));
    if looks_like_playlist {
        if let Some(url) = parse_m3u(text).or_else(|| parse_pls(text)) {
            return validate_stream_url(&url);
        }
        return Err(LekisError::invalid(
            "playlist does not contain an http(s) stream address",
        ));
    }
    validate_stream_url(text)
}

/// 校验并规范化一个 http/https 地址。
pub fn validate_stream_url(raw: &str) -> Result<String> {
    let raw = raw.trim().trim_matches('"').trim();
    let url =
        Url::parse(raw).map_err(|e| LekisError::invalid(format!("invalid stream address: {e}")))?;
    match url.scheme() {
        "http" | "https" => {}
        scheme => {
            return Err(LekisError::invalid(format!(
                "unsupported stream scheme `{scheme}`; only http and https are allowed"
            )))
        }
    }
    if url.host_str().is_none() {
        return Err(LekisError::invalid("stream address has no host"));
    }
    Ok(url.to_string())
}

/// 校验可选主页：空值忽略，非空只允许 http/https。
pub fn validate_homepage(homepage: Option<&str>) -> Result<Option<String>> {
    match homepage.map(str::trim).filter(|s| !s.is_empty()) {
        Some(value) => Ok(Some(validate_stream_url(value)?)),
        None => Ok(None),
    }
}

fn parse_m3u(text: &str) -> Option<String> {
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.to_ascii_lowercase().starts_with("http://")
            || line.to_ascii_lowercase().starts_with("https://")
        {
            return Some(line.to_string());
        }
    }
    None
}

/// 解析 PLS 的 `FileN=` 行，返回编号最小的地址（自动去掉引号）。
fn parse_pls(text: &str) -> Option<String> {
    let mut entries: Vec<(u32, String)> = text
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            let number = key
                .strip_prefix("File")
                .or_else(|| key.strip_prefix("file"))
                .or_else(|| key.strip_prefix("FILE"))?
                .trim()
                .parse::<u32>()
                .ok()?;
            let value = value.trim().trim_matches('"').trim().to_string();
            if value.is_empty() {
                return None;
            }
            Some((number, value))
        })
        .collect();
    entries.sort_by_key(|(number, _)| *number);
    entries.into_iter().next().map(|(_, value)| value)
}

fn parse_pls_lines(text: &str) -> Option<()> {
    text.lines().find_map(|line| {
        let (key, _) = line.split_once('=')?;
        let key = key.trim().to_ascii_lowercase();
        if key.starts_with("file") && key[4..].trim().parse::<u32>().is_ok() {
            Some(())
        } else {
            None
        }
    })
}

fn dedupe(stations: impl Iterator<Item = RadioStation>) -> Vec<RadioStation> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for station in stations {
        let key = station
            .station_uuid
            .as_deref()
            .map(|uuid| format!("uuid:{}", uuid.to_ascii_lowercase()))
            .unwrap_or_else(|| format!("url:{}", station.url.to_ascii_lowercase()));
        if seen.insert(key) {
            out.push(station);
        }
    }
    out
}

fn clean(value: String) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn split_tags(value: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    value
        .split(',')
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .filter(|tag| seen.insert(tag.to_ascii_lowercase()))
        .take(20)
        .map(str::to_string)
        .collect()
}

fn country_options(items: Vec<ApiCountry>) -> Vec<RadioFilterOption> {
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<RadioFilterOption> = items
        .into_iter()
        .filter_map(|item| {
            let name = item.name.unwrap_or_default().trim().to_string();
            let value = item
                .iso_3166_1
                .unwrap_or_default()
                .trim()
                .to_ascii_uppercase();
            let count = item.stationcount.unwrap_or(0);
            if name.is_empty() || value.is_empty() || count <= 0 {
                return None;
            }
            if !seen.insert(value.clone()) {
                return None;
            }
            Some(RadioFilterOption {
                name,
                value,
                station_count: count as u32,
            })
        })
        .collect();
    out.sort_by(|a, b| {
        b.station_count
            .cmp(&a.station_count)
            .then(a.name.cmp(&b.name))
    });
    out
}

fn language_options(items: Vec<ApiLanguage>) -> Vec<RadioFilterOption> {
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<RadioFilterOption> = items
        .into_iter()
        .filter_map(|item| {
            let name = item.name.unwrap_or_default().trim().to_string();
            let count = item.stationcount.unwrap_or(0);
            if name.is_empty() || count <= 0 {
                return None;
            }
            if !seen.insert(name.to_ascii_lowercase()) {
                return None;
            }
            Some(RadioFilterOption {
                value: name.clone(),
                name,
                station_count: count as u32,
            })
        })
        .collect();
    out.sort_by(|a, b| {
        b.station_count
            .cmp(&a.station_count)
            .then(a.name.cmp(&b.name))
    });
    out
}

fn tag_options(items: Vec<ApiTag>) -> Vec<RadioFilterOption> {
    let mut seen = std::collections::HashSet::new();
    items
        .into_iter()
        .filter_map(|item| {
            let name = item.name.unwrap_or_default().trim().to_string();
            let count = item.stationcount.unwrap_or(0);
            if name.is_empty() || count <= 0 {
                return None;
            }
            if !seen.insert(name.to_ascii_lowercase()) {
                return None;
            }
            Some(RadioFilterOption {
                value: name.clone(),
                name,
                station_count: count as u32,
            })
        })
        .collect()
}

#[derive(Debug, Default, Deserialize)]
struct ApiStation {
    #[serde(default)]
    stationuuid: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    url_resolved: Option<String>,
    #[serde(default)]
    favicon: Option<String>,
    #[serde(default)]
    country: Option<String>,
    #[serde(default)]
    countrycode: Option<String>,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    tags: Option<String>,
    #[serde(default)]
    codec: Option<String>,
    #[serde(default)]
    bitrate: Option<i64>,
    #[serde(default)]
    homepage: Option<String>,
}

impl ApiStation {
    fn into_station(self) -> Option<RadioStation> {
        let resolved = self.url_resolved.as_deref().unwrap_or_default().trim();
        let raw_url = if resolved.is_empty() {
            self.url.unwrap_or_default()
        } else {
            resolved.to_string()
        };
        let url = validate_stream_url(&raw_url).ok()?;
        let raw_name = self.name.unwrap_or_default();
        let name = if raw_name.trim().is_empty() {
            Url::parse(&url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_string))
                .unwrap_or_else(|| "网络电台".to_string())
        } else {
            raw_name.trim().to_string()
        };
        let favicon = Url::parse(self.favicon.as_deref().unwrap_or_default().trim())
            .ok()
            .filter(|u| matches!(u.scheme(), "http" | "https"))
            .map(|u| u.to_string());
        Some(RadioStation {
            id: RadioStationId(0),
            station_uuid: clean(self.stationuuid.unwrap_or_default()),
            name,
            url,
            favicon,
            country: clean(self.country.unwrap_or_default()),
            country_code: clean(self.countrycode.unwrap_or_default())
                .map(|c| c.to_ascii_uppercase()),
            language: clean(self.language.unwrap_or_default()),
            tags: split_tags(self.tags.as_deref().unwrap_or_default()),
            codec: clean(self.codec.unwrap_or_default()),
            bitrate: self.bitrate.filter(|b| *b > 0).map(|b| b as u32),
            homepage: Url::parse(self.homepage.as_deref().unwrap_or_default().trim())
                .ok()
                .filter(|u| matches!(u.scheme(), "http" | "https"))
                .map(|u| u.to_string()),
            is_custom: false,
            favorite: false,
            last_played_at: None,
        })
    }
}

#[derive(Debug, Default, Deserialize)]
struct ApiCountry {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    iso_3166_1: Option<String>,
    #[serde(default)]
    stationcount: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
struct ApiLanguage {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    iso_639: Option<String>,
    #[serde(default)]
    stationcount: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
struct ApiTag {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    stationcount: Option<i64>,
}

/// 电台在「正在播放 / 播放队列」里的合成曲目。
pub(crate) fn station_track(station: &RadioStation) -> Track {
    let mut subtitle = Vec::new();
    if let Some(country) = station.country.as_deref().filter(|s| !s.is_empty()) {
        subtitle.push(country.to_string());
    } else if let Some(language) = station.language.as_deref().filter(|s| !s.is_empty()) {
        subtitle.push(language.to_string());
    }
    let artist = if subtitle.is_empty() {
        "网络电台".to_string()
    } else {
        format!("网络电台 · {}", subtitle.join(" / "))
    };
    Track {
        id: station.id.track_id(),
        uid: TrackUid(format!("radio:{}", station.id.0)),
        title: station.name.clone(),
        sort_title: None,
        artists: vec![ArtistCredit {
            artist_id: None,
            name: artist,
            role: ArtistRole::Main,
        }],
        album_id: None,
        album_title: None,
        track_no: None,
        disc_no: None,
        year: None,
        duration_ms: 0,
        genres: station.tags.clone(),
        mbid_recording: None,
        audio: station.codec.as_ref().map(|codec| AudioProps {
            codec: Codec::Other(codec.clone()),
            sample_rate: 0,
            bit_depth: None,
            channels: 2,
            bitrate_kbps: station.bitrate,
        }),
        replaygain: Default::default(),
        artwork_id: None,
        overlay: None,
        is_local: false,
    }
}

/// 电台在播放队列里的列表行。
pub(crate) fn station_track_row(station: &RadioStation) -> TrackRow {
    let mut bits = Vec::new();
    if let Some(country) = station.country.as_deref().filter(|s| !s.is_empty()) {
        bits.push(country.to_string());
    } else if let Some(language) = station.language.as_deref().filter(|s| !s.is_empty()) {
        bits.push(language.to_string());
    }
    let quality_badge = match (station.codec.as_deref(), station.bitrate) {
        (Some(codec), Some(bitrate)) => Some(format!("{codec} {bitrate}")),
        (Some(codec), None) => Some(codec.to_string()),
        (None, Some(bitrate)) => Some(format!("{bitrate} kbps")),
        (None, None) => None,
    };
    TrackRow {
        id: station.id.track_id(),
        title: station.name.clone(),
        artist_line: if bits.is_empty() {
            "网络电台".to_string()
        } else {
            bits.join(" / ")
        },
        album_title: None,
        duration_ms: 0,
        artwork_id: None,
        quality_badge,
        loved: station.favorite,
        is_local: false,
    }
}

/// 收藏 / 取消收藏时发一个用户状态事件，电台页和正在播放页都能刷新。
pub(crate) fn favorite_event() -> CoreEvent {
    CoreEvent::LibraryChanged {
        scope: LibraryScope::UserState,
    }
}

/// 最近播放时间（Unix 毫秒）。
pub(crate) fn played_at_now() -> i64 {
    now_ms()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn accepts_http_and_https_only() {
        assert_eq!(
            parse_stream_address(" https://example.com/live.mp3 ").unwrap(),
            "https://example.com/live.mp3"
        );
        assert!(parse_stream_address("ftp://example.com/live.mp3").is_err());
        assert!(parse_stream_address("file:///etc/passwd").is_err());
        assert!(parse_stream_address("not a url").is_err());
    }

    #[test]
    fn parses_m3u_playlist() {
        let text = "#EXTM3U\n#EXTINF:-1,Test Radio\nhttp://example.com:8000/live\nhttp://example.com/other";
        assert_eq!(
            parse_stream_address(text).unwrap(),
            "http://example.com:8000/live"
        );
    }

    #[test]
    fn parses_pls_playlist_in_file_order() {
        let text = "[playlist]\nFile2=https://example.com/2\nFile1=\"https://example.com/1\"\nNumberOfEntries=2";
        assert_eq!(parse_stream_address(text).unwrap(), "https://example.com/1");
    }

    #[test]
    fn rejects_playlist_without_http_url() {
        assert!(parse_stream_address("#EXTM3U\n#EXTINF:-1,Test\n/relative/live.mp3").is_err());
    }

    #[test]
    fn dedupes_by_uuid_then_url() {
        let a = ApiStation {
            stationuuid: Some("ABC".into()),
            name: Some("One".into()),
            url_resolved: Some("https://example.com/a".into()),
            ..Default::default()
        };
        let b = ApiStation {
            stationuuid: Some("abc".into()),
            name: Some("Two".into()),
            url_resolved: Some("https://example.com/b".into()),
            ..Default::default()
        };
        let c = ApiStation {
            stationuuid: Some(String::new()),
            name: Some("Three".into()),
            url_resolved: Some("https://example.com/a".into()),
            ..Default::default()
        };
        let out = dedupe(
            [
                a.into_station().unwrap(),
                b.into_station().unwrap(),
                c.into_station().unwrap(),
            ]
            .into_iter(),
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].name, "One");
        assert_eq!(out[1].name, "Three");
    }

    #[test]
    fn build_query_includes_filters_and_paging() {
        let path = browse_path(
            &RadioQuery {
                search: "jazz fm".into(),
                country_code: Some("CN".into()),
                language: Some("chinese".into()),
                tag: Some("jazz".into()),
                sort: RadioSort::Name,
                offset: 100,
                limit: 25,
            },
            25,
        );
        assert!(path.starts_with("/json/stations/search?"));
        assert!(path.contains("name=jazz+fm"));
        assert!(path.contains("countrycode=CN"));
        assert!(path.contains("language=chinese"));
        assert!(path.contains("tag=jazz"));
        assert!(path.contains("tagExact=true"));
        assert!(path.contains("offset=100"));
        assert!(path.contains("limit=25"));
        assert!(path.contains("order=name"));
    }

    #[tokio::test]
    async fn rotates_to_next_mirror_on_server_error() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        async fn serve_once(status: &'static str, body: &'static str) -> String {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buffer = [0u8; 2048];
                let _ = stream.read(&mut buffer).await;
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
            format!("http://{addr}")
        }

        let bad = serve_once("503 Service Unavailable", "").await;
        let good = serve_once(
            "200 OK",
            r#"[{"stationuuid":"u1","name":"Mock FM","url_resolved":"http://example.com/live","country":"China","countrycode":"CN","language":"chinese","tags":"pop,jazz","codec":"MP3","bitrate":128,"homepage":"https://example.com"}]"#,
        )
        .await;
        let browser = RadioBrowser::with_mirrors(vec![bad, good]).unwrap();
        let page = browser
            .browse(&RadioQuery {
                limit: 5,
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(page.stations.len(), 1);
        assert_eq!(page.stations[0].name, "Mock FM");
        assert_eq!(page.stations[0].tags, vec!["pop", "jazz"]);
        assert_eq!(page.stations[0].bitrate, Some(128));
        assert!(!page.has_more);
    }

    #[test]
    fn empty_optional_fields_are_none() {
        let station = ApiStation {
            name: Some("  ".into()),
            url_resolved: Some("https://example.com/live".into()),
            favicon: Some(" ".into()),
            country: Some(" ".into()),
            countrycode: Some(" ".into()),
            language: Some(" ".into()),
            codec: Some(" ".into()),
            bitrate: Some(0),
            homepage: Some(" ".into()),
            ..Default::default()
        }
        .into_station()
        .unwrap();
        assert_eq!(station.name, "example.com");
        assert!(station.favicon.is_none());
        assert!(station.country.is_none());
        assert!(station.codec.is_none());
        assert!(station.bitrate.is_none());
        assert!(station.homepage.is_none());
    }
}
