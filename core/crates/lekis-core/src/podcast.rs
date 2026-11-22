//! 播客（SRC-12）：目录检索、RSS 解析、OPML 导入导出、订阅与播放进度。
//!
//! 数据来源都不需要账号或密钥（和 AntennaPod / Podcini / Kasts 的默认路径一致）：
//!
//! - **Apple Podcasts 目录**：`itunes.apple.com/search?media=podcast` 搜索，
//!   `/lookup?id=` 按目录 ID 取 RSS 地址，`/{国家}/rss/toppodcasts` 取分地区排行榜。
//!   这是覆盖最全、按地区排行（含中国区）最稳定的免费目录。
//! - **RSS / Atom**：节目和单集都直接从节目自己的 RSS 读（enclosure、`itunes:*`、
//!   `podcast:*` 常用字段），目录只用来"找到 RSS 地址"。
//! - **OPML**：和其它播客客户端互相迁移订阅。
//!
//! 单集用 [`PodcastEpisodeId::track_id`] 映射成合成 `TrackId`，播放走普通的 URL 源：
//! 支持 HTTP Range 的服务器可以 seek，播放进度在 [`LekisCore::save_playback_state`]
//! 时顺带写回单集。

use crate::LekisCore;
use lekis_types::{
    now_ms, ArtistCredit, ArtistRole, CoreEvent, ErrorCode, LekisError, LibraryScope, Podcast,
    PodcastEpisode, PodcastEpisodeId, PodcastId, Result, Track, TrackId, TrackRow, TrackUid,
};
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use serde::Deserialize;
use std::time::Duration;
use url::Url;

/// Apple 目录接口根地址。
const ITUNES_BASE: &str = "https://itunes.apple.com";
/// 目录请求超时。
const DIRECTORY_TIMEOUT: Duration = Duration::from_secs(12);
/// RSS 抓取超时（有些节目几千集，文件好几 MB）。
const FEED_TIMEOUT: Duration = Duration::from_secs(30);
/// 建连超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
/// RSS 最大体积。
const MAX_FEED_BYTES: usize = 32 * 1024 * 1024;
/// 简介最多保留多少字符。
const MAX_DESCRIPTION_CHARS: usize = 4000;
/// 用户代理（部分托管平台拒绝空 UA）。
const USER_AGENT: &str = "Lekis/0.1 (podcast; +https://github.com/lekis-music)";
/// 目录一次最多返回多少条。
pub const PODCAST_DIRECTORY_MAX: u32 = 200;
/// 同时刷新多少个节目。
const REFRESH_CONCURRENCY: usize = 4;
/// 打开节目时，最近这么久内刷新过就直接用缓存。
const OPEN_CACHE_MS: i64 = 15 * 60 * 1000;
/// 剩余不到这么久就算听完。
const PLAYED_REMAINING_MS: u64 = 20_000;

// ---------------------------------------------------------------------------
// 公开类型
// ---------------------------------------------------------------------------

/// 目录（搜索 / 排行榜）里的一档节目。还没有抓 RSS，不在本地库里。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DirectoryPodcast {
    /// Apple 目录 ID。
    pub itunes_id: Option<i64>,
    /// 标题。
    pub title: String,
    /// 作者。
    pub author: Option<String>,
    /// 封面地址（尽量取 600px）。
    pub artwork_url: Option<String>,
    /// RSS 地址（排行榜不带，打开时再 lookup）。
    pub feed_url: Option<String>,
    /// 主分类。
    pub genre: Option<String>,
    /// 集数。
    pub episode_count: Option<u32>,
    /// 已经在本地库里时的本机 ID。
    pub local_id: Option<PodcastId>,
    /// 已订阅。
    pub subscribed: bool,
}

/// 解析后的 RSS。
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedFeed {
    /// 节目（`id` 为 0，`feed_url` 为抓取地址）。
    pub podcast: Podcast,
    /// 单集（新的在前，`id` 为 0）。
    pub episodes: Vec<PodcastEpisode>,
}

/// OPML 里的一条订阅。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpmlEntry {
    /// 标题。
    pub title: String,
    /// RSS 地址。
    pub feed_url: String,
}

/// OPML 导入结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpmlImportReport {
    /// OPML 里的有效条目数。
    pub total: u32,
    /// 新订阅的。
    pub added: u32,
    /// 原本就订阅了的。
    pub already_subscribed: u32,
    /// RSS 抓取失败的（仍然订阅，下次刷新再试）。
    pub failed: u32,
}

/// 刷新全部订阅的结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PodcastRefreshReport {
    /// 刷新成功的节目数。
    pub refreshed: u32,
    /// 失败的节目数。
    pub failed: u32,
    /// 新增单集数。
    pub new_episodes: u32,
}

// ---------------------------------------------------------------------------
// HTTP 客户端
// ---------------------------------------------------------------------------

/// 播客网络客户端（目录 + RSS）。
pub(crate) struct PodcastClient {
    client: reqwest::Client,
    itunes_base: String,
}

impl PodcastClient {
    pub(crate) fn new() -> Result<Self> {
        Self::with_base(ITUNES_BASE.to_string())
    }

    /// 指定目录地址（测试注入本地 HTTP 服务）。
    pub(crate) fn with_base(itunes_base: String) -> Result<Self> {
        let client = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .user_agent(USER_AGENT)
            .redirect(reqwest::redirect::Policy::limited(8))
            .build()
            .map_err(|e| {
                LekisError::new(
                    ErrorCode::Network,
                    format!("cannot build podcast client: {e}"),
                )
            })?;
        Ok(Self {
            client,
            itunes_base: itunes_base.trim_end_matches('/').to_string(),
        })
    }

    /// 关键词搜索。
    pub(crate) async fn search(
        &self,
        term: &str,
        country: &str,
        limit: u32,
    ) -> Result<Vec<DirectoryPodcast>> {
        let query = {
            let mut ser = url::form_urlencoded::Serializer::new(String::new());
            ser.append_pair("media", "podcast");
            ser.append_pair("entity", "podcast");
            ser.append_pair("term", term.trim());
            ser.append_pair("limit", &limit.clamp(1, PODCAST_DIRECTORY_MAX).to_string());
            if let Some(country) = clean_country(country) {
                ser.append_pair("country", &country);
            }
            ser.finish()
        };
        let url = format!("{}/search?{query}", self.itunes_base);
        let body = self.get_text(&url, DIRECTORY_TIMEOUT).await?;
        parse_itunes_results(&body)
    }

    /// 分地区排行榜（可按 Apple 分类 ID 过滤）。
    pub(crate) async fn top(
        &self,
        country: &str,
        genre_id: Option<u32>,
        limit: u32,
    ) -> Result<Vec<DirectoryPodcast>> {
        let country = clean_country(country).unwrap_or_else(|| "us".to_string());
        let limit = limit.clamp(1, PODCAST_DIRECTORY_MAX);
        let genre = genre_id.map(|g| format!("/genre={g}")).unwrap_or_default();
        let url = format!(
            "{}/{country}/rss/toppodcasts/limit={limit}{genre}/json",
            self.itunes_base
        );
        let body = self.get_text(&url, DIRECTORY_TIMEOUT).await?;
        parse_itunes_top(&body)
    }

    /// 按目录 ID 取 RSS 地址。
    pub(crate) async fn lookup(&self, itunes_id: i64) -> Result<DirectoryPodcast> {
        let url = format!("{}/lookup?id={itunes_id}&entity=podcast", self.itunes_base);
        let body = self.get_text(&url, DIRECTORY_TIMEOUT).await?;
        parse_itunes_results(&body)?
            .into_iter()
            .find(|p| p.itunes_id == Some(itunes_id) && p.feed_url.is_some())
            .ok_or_else(|| {
                LekisError::not_found(format!(
                    "podcast {itunes_id} has no public RSS feed in the Apple directory"
                ))
            })
    }

    /// 抓取并解析 RSS。
    pub(crate) async fn fetch_feed(&self, feed_url: &str) -> Result<ParsedFeed> {
        let body = self.get_text(feed_url, FEED_TIMEOUT).await?;
        parse_feed(&body, feed_url)
    }

    async fn get_text(&self, url: &str, timeout: Duration) -> Result<String> {
        let mut response = self
            .client
            .get(url)
            .timeout(timeout)
            .send()
            .await
            .map_err(|e| {
                LekisError::new(ErrorCode::Network, format!("request {url} failed: {e}"))
            })?;
        let status = response.status();
        if !status.is_success() {
            return Err(LekisError::new(
                match status.as_u16() {
                    429 => ErrorCode::RateLimited,
                    404 | 410 => ErrorCode::NotFound,
                    _ => ErrorCode::Network,
                },
                format!("request {url} returned HTTP {status}"),
            ));
        }
        if response
            .content_length()
            .is_some_and(|len| len as usize > MAX_FEED_BYTES)
        {
            return Err(LekisError::invalid(format!("{url} is too large")));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| LekisError::new(ErrorCode::Network, format!("read {url} failed: {e}")))?
        {
            if body.len() + chunk.len() > MAX_FEED_BYTES {
                return Err(LekisError::invalid(format!("{url} is too large")));
            }
            body.extend_from_slice(&chunk);
        }
        Ok(String::from_utf8_lossy(&body).into_owned())
    }
}

fn clean_country(country: &str) -> Option<String> {
    let c = country.trim().to_ascii_lowercase();
    (c.len() == 2 && c.chars().all(|ch| ch.is_ascii_alphabetic())).then_some(c)
}

// ---------------------------------------------------------------------------
// Apple 目录 JSON
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct ItunesResults {
    #[serde(default)]
    results: Vec<ItunesItem>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItunesItem {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    collection_id: Option<i64>,
    #[serde(default)]
    track_id: Option<i64>,
    #[serde(default)]
    collection_name: Option<String>,
    #[serde(default)]
    track_name: Option<String>,
    #[serde(default)]
    artist_name: Option<String>,
    #[serde(default)]
    feed_url: Option<String>,
    #[serde(default)]
    artwork_url600: Option<String>,
    #[serde(default)]
    artwork_url100: Option<String>,
    #[serde(default)]
    primary_genre_name: Option<String>,
    #[serde(default)]
    track_count: Option<i64>,
}

/// 解析 `/search` 和 `/lookup` 的 JSON。
pub fn parse_itunes_results(json: &str) -> Result<Vec<DirectoryPodcast>> {
    let parsed: ItunesResults = serde_json::from_str(json)
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("invalid iTunes JSON: {e}")))?;
    let mut seen = std::collections::HashSet::new();
    Ok(parsed
        .results
        .into_iter()
        .filter(|item| item.kind.as_deref().is_none_or(|k| k == "podcast"))
        .filter_map(|item| {
            let title = nonempty(item.collection_name.or(item.track_name))?;
            let itunes_id = item.collection_id.or(item.track_id);
            let feed_url = item.feed_url.and_then(|u| validate_http_url(&u).ok());
            let key = itunes_id
                .map(|id| format!("id:{id}"))
                .or_else(|| feed_url.clone())
                .unwrap_or_else(|| title.clone());
            if !seen.insert(key) {
                return None;
            }
            Some(DirectoryPodcast {
                itunes_id,
                title,
                author: nonempty(item.artist_name),
                artwork_url: nonempty(item.artwork_url600.or(item.artwork_url100))
                    .and_then(|u| validate_http_url(&u).ok()),
                feed_url,
                genre: nonempty(item.primary_genre_name),
                episode_count: item.track_count.filter(|c| *c > 0).map(|c| c as u32),
                local_id: None,
                subscribed: false,
            })
        })
        .collect())
}

/// 解析旧版 iTunes RSS 排行榜 JSON（`/{cc}/rss/toppodcasts/.../json`）。
///
/// 结构是 Atom 转出来的：`feed.entry[]`，值都包在 `{"label": ...}` 里；
/// 只有一条时 `entry` 是对象而不是数组。
pub fn parse_itunes_top(json: &str) -> Result<Vec<DirectoryPodcast>> {
    let root: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("invalid iTunes JSON: {e}")))?;
    let entries = match root.pointer("/feed/entry") {
        Some(serde_json::Value::Array(items)) => items.clone(),
        Some(item @ serde_json::Value::Object(_)) => vec![item.clone()],
        _ => Vec::new(),
    };
    let label = |v: &serde_json::Value, path: &str| -> Option<String> {
        v.pointer(path)
            .and_then(|l| l.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    Ok(entries
        .iter()
        .filter_map(|entry| {
            let title = label(entry, "/im:name/label")?;
            let itunes_id = label(entry, "/id/attributes/im:id").and_then(|s| s.parse().ok());
            let artwork = entry
                .pointer("/im:image")
                .and_then(|v| v.as_array())
                .and_then(|images| images.last())
                .and_then(|img| img.pointer("/label"))
                .and_then(|l| l.as_str())
                .map(upscale_artwork)
                .and_then(|u| validate_http_url(&u).ok());
            Some(DirectoryPodcast {
                itunes_id,
                title,
                author: label(entry, "/im:artist/label"),
                artwork_url: artwork,
                feed_url: None,
                genre: label(entry, "/category/attributes/label"),
                episode_count: None,
                local_id: None,
                subscribed: false,
            })
        })
        .collect())
}

/// Apple 的缩略图地址里带尺寸（`.../170x170bb.png`），换成 600px。
fn upscale_artwork(url: &str) -> String {
    if let Some((head, tail)) = url.rsplit_once('/') {
        if let Some((size, ext)) = tail.split_once("bb.") {
            if size.contains('x') && size.split('x').all(|n| n.parse::<u32>().is_ok()) {
                return format!("{head}/600x600bb.{ext}");
            }
        }
    }
    url.to_string()
}

// ---------------------------------------------------------------------------
// 极简 XML 树
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Clone)]
struct Node {
    /// 带前缀的名字（`itunes:image`）。
    name: String,
    attrs: Vec<(String, String)>,
    text: String,
    children: Vec<Node>,
}

impl Node {
    fn local(&self) -> &str {
        self.name.rsplit_once(':').map_or(&self.name, |(_, l)| l)
    }

    fn prefix(&self) -> Option<&str> {
        self.name.split_once(':').map(|(p, _)| p)
    }

    fn attr(&self, key: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.as_str())
            .map(str::trim)
            .filter(|v| !v.is_empty())
    }

    /// 精确匹配带前缀的名字（`itunes:duration`；无前缀写 `title`）。
    fn child(&self, name: &str) -> Option<&Node> {
        self.children
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
    }

    fn children<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Node> + 'a {
        self.children
            .iter()
            .filter(move |c| c.name.eq_ignore_ascii_case(name))
    }

    /// 匹配本地名（忽略前缀）。
    fn child_local(&self, local: &str) -> Option<&Node> {
        self.children
            .iter()
            .find(|c| c.local().eq_ignore_ascii_case(local))
    }

    fn text_of(&self, name: &str) -> Option<String> {
        self.child(name)
            .and_then(|n| nonempty(Some(n.text.clone())))
    }
}

fn parse_xml(xml: &str) -> Result<Node> {
    let mut reader = Reader::from_str(xml.trim_start_matches('\u{feff}'));
    reader.config_mut().trim_text(false);
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    loop {
        let event = reader
            .read_event()
            .map_err(|e| LekisError::invalid(format!("XML parse failed: {e}")))?;
        match event {
            Event::Start(start) => stack.push(node_from_tag(&start)),
            Event::Empty(empty) => {
                let node = node_from_tag(&empty);
                attach(&mut stack, &mut root, node);
            }
            Event::End(_) => {
                if let Some(node) = stack.pop() {
                    attach(&mut stack, &mut root, node);
                }
            }
            Event::Text(text) => {
                if let Some(top) = stack.last_mut() {
                    let raw = text.into_inner();
                    let decoded = quick_xml::escape::unescape(&raw)
                        .map(|c| c.into_owned())
                        .unwrap_or_else(|_| raw.into_owned());
                    top.text.push_str(&decoded);
                }
            }
            Event::CData(cdata) => {
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(&cdata.into_inner());
                }
            }
            Event::GeneralRef(reference) => {
                if let Some(top) = stack.last_mut() {
                    let raw = format!("&{};", reference.as_ref());
                    match quick_xml::escape::unescape(&raw) {
                        Ok(value) => top.text.push_str(&value),
                        Err(_) => top.text.push_str(&raw),
                    }
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    // 不平衡的尾巴（截断的 RSS）：尽量把已经读到的部分挂回去。
    while let Some(node) = stack.pop() {
        attach(&mut stack, &mut root, node);
    }
    root.ok_or_else(|| LekisError::invalid("document has no root element"))
}

fn node_from_tag(tag: &BytesStart<'_>) -> Node {
    let mut node = Node {
        name: tag.name().as_ref().to_string(),
        ..Node::default()
    };
    for attr in tag.attributes().with_checks(false).flatten() {
        let key = attr.key.as_ref().to_string();
        let value = attr
            .normalized_value(XmlVersion::Implicit1_0)
            .map(|v| v.into_owned())
            .unwrap_or_default();
        node.attrs.push((key, value));
    }
    node
}

fn attach(stack: &mut [Node], root: &mut Option<Node>, node: Node) {
    match stack.last_mut() {
        Some(parent) => parent.children.push(node),
        None => {
            if root.is_none() {
                *root = Some(node);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// RSS / Atom
// ---------------------------------------------------------------------------

/// 解析 RSS 2.0（含 `itunes:*` / `podcast:*` / `content:encoded`）或 Atom。
///
/// 没有音频 enclosure 的条目会被跳过；相对地址按 `feed_url` 解析。
pub fn parse_feed(xml: &str, feed_url: &str) -> Result<ParsedFeed> {
    let feed_url = validate_http_url(feed_url)?;
    let base = Url::parse(&feed_url).ok();
    let root = parse_xml(xml).map_err(|e| {
        LekisError::invalid(format!(
            "{feed_url} is not a valid podcast feed: {}",
            e.message
        ))
    })?;
    let mut parsed = match root.local().to_ascii_lowercase().as_str() {
        "rss" | "rdf" => {
            let channel = root
                .child_local("channel")
                .ok_or_else(|| LekisError::invalid("RSS feed has no <channel>"))?;
            parse_rss_channel(channel, &feed_url, base.as_ref())
        }
        "feed" => parse_atom(&root, &feed_url, base.as_ref()),
        "html" => {
            return Err(LekisError::invalid(format!(
                "{feed_url} is a web page, not a podcast RSS feed"
            )))
        }
        other => {
            return Err(LekisError::invalid(format!(
                "{feed_url} is not a podcast feed (root element <{other}>)"
            )))
        }
    };
    // 新的在前；没有日期的保持原顺序排在后面。
    parsed
        .episodes
        .sort_by_key(|e| std::cmp::Reverse(e.published_at.unwrap_or(i64::MIN)));
    // 同一个 guid 出现多次时只留第一条（有的源会重复发布）。
    let mut seen = std::collections::HashSet::new();
    parsed.episodes.retain(|e| seen.insert(e.guid.clone()));
    parsed.podcast.episode_count = parsed.episodes.len() as u32;
    parsed.podcast.unplayed_count = parsed.episodes.len() as u32;
    parsed.podcast.latest_published_at =
        parsed.episodes.iter().filter_map(|e| e.published_at).max();
    Ok(parsed)
}

fn empty_podcast(feed_url: &str) -> Podcast {
    Podcast {
        id: PodcastId(0),
        feed_url: feed_url.to_string(),
        itunes_id: None,
        title: String::new(),
        author: None,
        description: None,
        artwork_url: None,
        link: None,
        language: None,
        categories: Vec::new(),
        subscribed: false,
        subscribed_at: None,
        last_refreshed_at: None,
        last_error: None,
        episode_count: 0,
        unplayed_count: 0,
        latest_published_at: None,
    }
}

fn empty_episode() -> PodcastEpisode {
    PodcastEpisode {
        id: PodcastEpisodeId(0),
        podcast_id: PodcastId(0),
        podcast_title: String::new(),
        guid: String::new(),
        title: String::new(),
        description: None,
        audio_url: String::new(),
        mime_type: None,
        size_bytes: None,
        duration_ms: 0,
        published_at: None,
        artwork_url: None,
        episode_no: None,
        season_no: None,
        link: None,
        position_ms: 0,
        played: false,
        last_played_at: None,
    }
}

fn parse_rss_channel(channel: &Node, feed_url: &str, base: Option<&Url>) -> ParsedFeed {
    let mut podcast = empty_podcast(feed_url);
    podcast.title = channel
        .text_of("title")
        .or_else(|| channel.text_of("itunes:title"))
        .map(|t| html_to_text(&t))
        .unwrap_or_else(|| host_of(feed_url));
    podcast.author = channel
        .text_of("itunes:author")
        .or_else(|| {
            channel
                .child("itunes:owner")
                .and_then(|o| o.text_of("itunes:name"))
        })
        .or_else(|| channel.text_of("author"))
        .or_else(|| channel.text_of("managingEditor"));
    podcast.description = channel
        .text_of("description")
        .or_else(|| channel.text_of("itunes:summary"))
        .or_else(|| channel.text_of("itunes:subtitle"))
        .map(|d| truncate(html_to_text(&d)));
    podcast.artwork_url = channel
        .child("itunes:image")
        .and_then(|i| i.attr("href"))
        .map(str::to_string)
        .or_else(|| channel.child("image").and_then(|i| i.text_of("url")))
        .and_then(|u| resolve_url(base, &u));
    podcast.link = channel
        .children("link")
        .find_map(|l| nonempty(Some(l.text.clone())))
        .and_then(|u| resolve_url(base, &u));
    podcast.language = channel.text_of("language");
    let mut categories = Vec::new();
    collect_categories(channel, &mut categories);
    podcast.categories = categories;

    let episodes = channel
        .children("item")
        .filter_map(|item| parse_rss_item(item, base))
        .collect();
    ParsedFeed { podcast, episodes }
}

fn collect_categories(node: &Node, out: &mut Vec<String>) {
    for cat in node.children("itunes:category") {
        if let Some(text) = cat.attr("text") {
            let text = html_to_text(text);
            if !text.is_empty()
                && !out.iter().any(|c| c.eq_ignore_ascii_case(&text))
                && out.len() < 8
            {
                out.push(text);
            }
        }
        collect_categories(cat, out);
    }
}

fn parse_rss_item(item: &Node, base: Option<&Url>) -> Option<PodcastEpisode> {
    let enclosure = item
        .children("enclosure")
        .find(|e| e.attr("url").is_some() && is_audio_or_video(e.attr("type")))
        .or_else(|| item.child("enclosure"));
    let (audio_url, mime_type, size_bytes) = match enclosure.and_then(|e| e.attr("url")) {
        Some(url) => {
            let e = enclosure?;
            (
                url.to_string(),
                e.attr("type").map(str::to_string),
                e.attr("length")
                    .and_then(|l| l.parse::<u64>().ok())
                    .filter(|l| *l > 0),
            )
        }
        None => {
            // 没有 enclosure 时退回 Media RSS。
            let media = item
                .children("media:content")
                .find(|m| m.attr("url").is_some() && is_audio_or_video(m.attr("type")))?;
            (
                media.attr("url")?.to_string(),
                media.attr("type").map(str::to_string),
                media.attr("fileSize").and_then(|l| l.parse::<u64>().ok()),
            )
        }
    };
    let audio_url = resolve_url(base, &audio_url)?;

    let mut episode = empty_episode();
    episode.title = item
        .text_of("title")
        .or_else(|| item.text_of("itunes:title"))
        .map(|t| html_to_text(&t))
        .unwrap_or_default();
    episode.guid = item
        .text_of("guid")
        .map(|g| g.trim().to_string())
        .unwrap_or_else(|| audio_url.clone());
    episode.description = item
        .text_of("description")
        .or_else(|| item.text_of("content:encoded"))
        .or_else(|| item.text_of("itunes:summary"))
        .or_else(|| item.text_of("itunes:subtitle"))
        .map(|d| truncate(html_to_text(&d)))
        .filter(|d| !d.is_empty());
    episode.audio_url = audio_url;
    episode.mime_type = mime_type;
    episode.size_bytes = size_bytes;
    episode.duration_ms = item
        .text_of("itunes:duration")
        .and_then(|d| parse_duration_ms(&d))
        .unwrap_or(0);
    episode.published_at = item
        .text_of("pubDate")
        .or_else(|| item.text_of("dc:date"))
        .and_then(|d| parse_date_ms(&d));
    episode.artwork_url = item
        .child("itunes:image")
        .and_then(|i| i.attr("href"))
        .and_then(|u| resolve_url(base, u));
    episode.episode_no = item
        .text_of("itunes:episode")
        .or_else(|| item.text_of("podcast:episode"))
        .and_then(|n| n.trim().parse::<f64>().ok())
        .filter(|n| *n >= 0.0)
        .map(|n| n as u32);
    episode.season_no = item
        .text_of("itunes:season")
        .or_else(|| item.text_of("podcast:season"))
        .and_then(|n| n.trim().parse().ok());
    episode.link = item.text_of("link").and_then(|u| resolve_url(base, &u));
    if episode.title.is_empty() {
        episode.title = episode
            .published_at
            .map(format_date)
            .unwrap_or_else(|| "未命名单集".to_string());
    }
    Some(episode)
}

fn parse_atom(feed: &Node, feed_url: &str, base: Option<&Url>) -> ParsedFeed {
    let mut podcast = empty_podcast(feed_url);
    podcast.title = feed
        .child_local("title")
        .and_then(|t| nonempty(Some(html_to_text(&t.text))))
        .unwrap_or_else(|| host_of(feed_url));
    podcast.author = feed
        .child_local("author")
        .and_then(|a| a.child_local("name"))
        .and_then(|n| nonempty(Some(n.text.clone())))
        .or_else(|| feed.text_of("itunes:author"));
    podcast.description = feed
        .child_local("subtitle")
        .and_then(|s| nonempty(Some(truncate(html_to_text(&s.text)))));
    podcast.artwork_url = feed
        .child("itunes:image")
        .and_then(|i| i.attr("href").map(str::to_string))
        .or_else(|| feed.child_local("logo").map(|l| l.text.clone()))
        .or_else(|| feed.child_local("icon").map(|l| l.text.clone()))
        .and_then(|u| resolve_url(base, &u));
    podcast.link = feed
        .children
        .iter()
        .filter(|c| c.local() == "link")
        .find(|l| l.attr("rel").is_none_or(|r| r == "alternate"))
        .and_then(|l| l.attr("href"))
        .and_then(|u| resolve_url(base, u));
    podcast.language = feed.attr("xml:lang").map(str::to_string);

    let episodes = feed
        .children
        .iter()
        .filter(|c| c.local() == "entry" && c.prefix().is_none_or(|p| p == "atom"))
        .filter_map(|entry| {
            let link = entry
                .children
                .iter()
                .filter(|c| c.local() == "link")
                .find(|l| l.attr("rel") == Some("enclosure"))?;
            let audio_url = resolve_url(base, link.attr("href")?)?;
            let mut episode = empty_episode();
            episode.title = entry
                .child_local("title")
                .map(|t| html_to_text(&t.text))
                .unwrap_or_default();
            episode.guid = entry
                .child_local("id")
                .and_then(|i| nonempty(Some(i.text.clone())))
                .unwrap_or_else(|| audio_url.clone());
            episode.description = entry
                .child_local("summary")
                .or_else(|| entry.child_local("content"))
                .map(|s| truncate(html_to_text(&s.text)))
                .filter(|s| !s.is_empty());
            episode.mime_type = link.attr("type").map(str::to_string);
            episode.size_bytes = link.attr("length").and_then(|l| l.parse().ok());
            episode.audio_url = audio_url;
            episode.published_at = entry
                .child_local("published")
                .or_else(|| entry.child_local("updated"))
                .and_then(|d| parse_date_ms(&d.text));
            episode.duration_ms = entry
                .text_of("itunes:duration")
                .and_then(|d| parse_duration_ms(&d))
                .unwrap_or(0);
            episode.link = entry
                .children
                .iter()
                .filter(|c| c.local() == "link")
                .find(|l| l.attr("rel").is_none_or(|r| r == "alternate"))
                .and_then(|l| l.attr("href"))
                .and_then(|u| resolve_url(base, u));
            if episode.title.is_empty() {
                episode.title = "未命名单集".to_string();
            }
            Some(episode)
        })
        .collect();
    ParsedFeed { podcast, episodes }
}

fn is_audio_or_video(mime: Option<&str>) -> bool {
    match mime {
        None => true,
        Some(m) => {
            let m = m.trim().to_ascii_lowercase();
            m.is_empty()
                || m.starts_with("audio/")
                || m.starts_with("video/")
                || m == "application/octet-stream"
                || m == "application/ogg"
                || m == "application/x-mpegurl"
        }
    }
}

// ---------------------------------------------------------------------------
// 小工具：时长、日期、HTML、URL
// ---------------------------------------------------------------------------

/// `itunes:duration`：`HH:MM:SS`、`MM:SS`、纯秒数（可带小数）。
pub fn parse_duration_ms(raw: &str) -> Option<u64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let parts: Vec<&str> = raw.split(':').collect();
    if parts.len() > 3 {
        return None;
    }
    let mut total = 0f64;
    for part in &parts {
        let value: f64 = part.trim().parse().ok()?;
        if value.is_nan() || value < 0.0 {
            return None;
        }
        total = total * 60.0 + value;
    }
    Some((total * 1000.0).round() as u64)
}

/// RSS `pubDate`（RFC 822 / 2822，宽松）或 ISO 8601 / RFC 3339。返回 Unix 毫秒。
pub fn parse_date_ms(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if raw.as_bytes()[0].is_ascii_digit() && raw.len() >= 10 && raw.as_bytes()[4] == b'-' {
        return parse_iso8601(raw);
    }
    parse_rfc2822(raw)
}

fn parse_rfc2822(raw: &str) -> Option<i64> {
    // 去掉可选的星期：`Tue, 10 Jun 2003 04:00:00 GMT`。
    let s = raw.split_once(',').map_or(raw, |(_, rest)| rest).trim();
    let mut it = s.split_whitespace();
    let day: u32 = it.next()?.parse().ok()?;
    let month = month_index(it.next()?)?;
    let mut year: i64 = it.next()?.parse().ok()?;
    if year < 100 {
        year += if year < 50 { 2000 } else { 1900 };
    }
    let time = it.next().unwrap_or("00:00:00");
    let mut t = time.split(':');
    let hour: u32 = t.next()?.parse().ok()?;
    let minute: u32 = t.next().unwrap_or("0").parse().ok()?;
    let second: u32 = t.next().unwrap_or("0").split('.').next()?.parse().ok()?;
    let offset_min = it.next().map(zone_offset_minutes).unwrap_or(Some(0))?;
    to_unix_ms(year, month, day, hour, minute, second, offset_min)
}

fn parse_iso8601(raw: &str) -> Option<i64> {
    let year: i64 = raw.get(0..4)?.parse().ok()?;
    let month: u32 = raw.get(5..7)?.parse().ok()?;
    let day: u32 = raw.get(8..10)?.parse().ok()?;
    let rest = raw.get(10..).unwrap_or("");
    if rest.is_empty() {
        return to_unix_ms(year, month, day, 0, 0, 0, 0);
    }
    let rest = rest.trim_start_matches(['T', 't', ' ']);
    let hour: u32 = rest.get(0..2)?.parse().ok()?;
    let minute: u32 = rest.get(3..5)?.parse().ok()?;
    let mut idx = 5;
    let mut second = 0;
    if rest.as_bytes().get(5) == Some(&b':') {
        second = rest.get(6..8)?.parse().ok()?;
        idx = 8;
    }
    let mut tail = &rest[idx..];
    if tail.starts_with('.') {
        let frac_len = tail[1..].chars().take_while(char::is_ascii_digit).count();
        tail = &tail[1 + frac_len..];
    }
    let offset = match tail {
        "" | "Z" | "z" => 0,
        tz => zone_offset_minutes(tz)?,
    };
    to_unix_ms(year, month, day, hour, minute, second, offset)
}

fn month_index(name: &str) -> Option<u32> {
    const MONTHS: [&str; 12] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    let lower = name.to_ascii_lowercase();
    MONTHS
        .iter()
        .position(|m| lower.starts_with(m))
        .map(|i| i as u32 + 1)
}

fn zone_offset_minutes(zone: &str) -> Option<i32> {
    let zone = zone.trim();
    match zone.to_ascii_uppercase().as_str() {
        "GMT" | "UT" | "UTC" | "Z" => return Some(0),
        "EST" => return Some(-5 * 60),
        "EDT" => return Some(-4 * 60),
        "CST" => return Some(-6 * 60),
        "CDT" => return Some(-5 * 60),
        "MST" => return Some(-7 * 60),
        "MDT" => return Some(-6 * 60),
        "PST" => return Some(-8 * 60),
        "PDT" => return Some(-7 * 60),
        _ => {}
    }
    let (sign, digits) = match zone.as_bytes().first()? {
        b'+' => (1, &zone[1..]),
        b'-' => (-1, &zone[1..]),
        // 不认识的时区缩写按 UTC 处理，总比整条丢掉强。
        _ => return Some(0),
    };
    let digits: String = digits.chars().filter(char::is_ascii_digit).collect();
    if digits.len() != 4 {
        return Some(0);
    }
    let hours: i32 = digits[0..2].parse().ok()?;
    let minutes: i32 = digits[2..4].parse().ok()?;
    Some(sign * (hours * 60 + minutes))
}

fn to_unix_ms(
    year: i64,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    offset_min: i32,
) -> Option<i64> {
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 24
        || minute > 59
        || second > 60
    {
        return None;
    }
    // Howard Hinnant 的 days_from_civil。
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = month as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64
        - offset_min as i64 * 60;
    Some(secs * 1000)
}

/// 毫秒时间戳 → `YYYY-MM-DD`（UTC）。
fn format_date(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    // civil_from_days
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}")
}

/// 简介里的 HTML → 纯文本：块级标签换行，其余标签去掉，常见实体解码，空白折叠。
pub fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut chars = html.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '<' {
            let mut tag = String::new();
            for t in chars.by_ref() {
                if t == '>' {
                    break;
                }
                tag.push(t);
            }
            let name = tag
                .trim_start_matches('/')
                .split(|ch: char| ch.is_whitespace() || ch == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if matches!(
                name.as_str(),
                "br" | "p" | "div" | "li" | "ul" | "ol" | "h1" | "h2" | "h3" | "h4" | "tr"
            ) {
                out.push('\n');
            }
            continue;
        }
        if c == '&' {
            let mut entity = String::new();
            while let Some(&n) = chars.peek() {
                if n == ';' || entity.len() > 10 || n.is_whitespace() || n == '&' {
                    break;
                }
                entity.push(n);
                chars.next();
            }
            if chars.peek() == Some(&';') {
                chars.next();
                if let Some(decoded) = decode_entity(&entity) {
                    out.push(decoded);
                    continue;
                }
                out.push('&');
                out.push_str(&entity);
                out.push(';');
            } else {
                out.push('&');
                out.push_str(&entity);
            }
            continue;
        }
        out.push(c);
    }
    // 折叠空白：行内多个空格并成一个，连续空行最多保留一个。
    let mut result = String::with_capacity(out.len());
    let mut blank_run = 0;
    for line in out.lines() {
        let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if line.is_empty() {
            blank_run += 1;
            if blank_run > 1 || result.is_empty() {
                continue;
            }
        } else {
            blank_run = 0;
        }
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&line);
    }
    result.trim().to_string()
}

fn decode_entity(entity: &str) -> Option<char> {
    if let Some(num) = entity.strip_prefix('#') {
        let code = if let Some(hex) = num.strip_prefix(['x', 'X']) {
            u32::from_str_radix(hex, 16).ok()?
        } else {
            num.parse().ok()?
        };
        return char::from_u32(code);
    }
    Some(match entity {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => ' ',
        "hellip" => '…',
        "mdash" => '—',
        "ndash" => '–',
        "ldquo" => '“',
        "rdquo" => '”',
        "lsquo" => '‘',
        "rsquo" => '’',
        "middot" => '·',
        "copy" => '©',
        _ => return None,
    })
}

fn truncate(text: String) -> String {
    if text.chars().count() <= MAX_DESCRIPTION_CHARS {
        return text;
    }
    let mut cut: String = text.chars().take(MAX_DESCRIPTION_CHARS).collect();
    cut.push('…');
    cut
}

fn nonempty(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn host_of(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_string))
        .unwrap_or_else(|| "播客".to_string())
}

/// 校验 http/https 地址并规范化。
pub fn validate_http_url(raw: &str) -> Result<String> {
    let raw = raw.trim();
    let url = Url::parse(raw).map_err(|e| LekisError::invalid(format!("invalid address: {e}")))?;
    match url.scheme() {
        "http" | "https" => {}
        scheme => {
            return Err(LekisError::invalid(format!(
                "unsupported scheme `{scheme}`; only http and https are allowed"
            )))
        }
    }
    if url.host_str().is_none() {
        return Err(LekisError::invalid("address has no host"));
    }
    Ok(url.to_string())
}

/// 用户输入的订阅地址：支持 `feed://`、`itpc://`、`pcast://` 和省略协议。
pub fn normalize_feed_input(raw: &str) -> Result<String> {
    let raw = raw.trim();
    let lower = raw.to_ascii_lowercase();
    for prefix in ["feed://", "itpc://", "pcast://", "podcast://"] {
        if lower.starts_with(prefix) {
            return validate_http_url(&format!("https://{}", &raw[prefix.len()..]));
        }
    }
    if lower.starts_with("feed:http") {
        return validate_http_url(&raw[5..]);
    }
    if !lower.contains("://") {
        return validate_http_url(&format!("https://{raw}"));
    }
    validate_http_url(raw)
}

/// 从 Apple Podcasts 网页地址里取目录 ID（`.../id1234567890`）。
pub fn apple_podcast_id(raw: &str) -> Option<i64> {
    let url = Url::parse(raw.trim()).ok()?;
    let host = url.host_str()?;
    if !(host.ends_with("podcasts.apple.com") || host.ends_with("itunes.apple.com")) {
        return None;
    }
    url.path_segments()?
        .filter_map(|seg| seg.strip_prefix("id"))
        .find_map(|id| id.parse().ok())
}

fn resolve_url(base: Option<&Url>, raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let joined = match base {
        Some(base) => base.join(raw).ok()?,
        None => Url::parse(raw).ok()?,
    };
    matches!(joined.scheme(), "http" | "https").then(|| joined.to_string())
}

// ---------------------------------------------------------------------------
// OPML
// ---------------------------------------------------------------------------

/// 解析 OPML：递归收集所有带 `xmlUrl` 的 `<outline>`（文件夹会被展开）。
pub fn parse_opml(text: &str) -> Result<Vec<OpmlEntry>> {
    let root = parse_xml(text)?;
    if !root.local().eq_ignore_ascii_case("opml") {
        return Err(LekisError::invalid("not an OPML document"));
    }
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    fn walk(node: &Node, out: &mut Vec<OpmlEntry>, seen: &mut std::collections::HashSet<String>) {
        for child in &node.children {
            if child.local().eq_ignore_ascii_case("outline") {
                if let Some(feed) = child
                    .attr("xmlUrl")
                    .or_else(|| child.attr("url"))
                    .and_then(|u| normalize_feed_input(u).ok())
                {
                    if seen.insert(feed.clone()) {
                        let title = child
                            .attr("text")
                            .or_else(|| child.attr("title"))
                            .map(str::to_string)
                            .unwrap_or_else(|| host_of(&feed));
                        out.push(OpmlEntry {
                            title,
                            feed_url: feed,
                        });
                    }
                }
            }
            walk(child, out, seen);
        }
    }
    walk(&root, &mut out, &mut seen);
    Ok(out)
}

/// 导出 OPML 2.0。
pub fn export_opml(podcasts: &[Podcast]) -> String {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head>\n    <title>Lekis Podcasts</title>\n  </head>\n  <body>\n",
    );
    for p in podcasts {
        out.push_str(&format!(
            "    <outline type=\"rss\" text=\"{t}\" title=\"{t}\" xmlUrl=\"{u}\"",
            t = xml_escape(&p.title),
            u = xml_escape(&p.feed_url)
        ));
        if let Some(link) = &p.link {
            out.push_str(&format!(" htmlUrl=\"{}\"", xml_escape(link)));
        }
        out.push_str(" />\n");
    }
    out.push_str("  </body>\n</opml>\n");
    out
}

fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if (c as u32) < 0x20 && c != '\t' && c != '\n' && c != '\r' => {}
            c => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// 合成曲目（播放队列 / 正在播放）
// ---------------------------------------------------------------------------

/// 单集在「正在播放」里的合成曲目。
pub(crate) fn episode_track(episode: &PodcastEpisode) -> Track {
    Track {
        id: episode.id.track_id(),
        uid: TrackUid(format!("podcast:{}", episode.guid)),
        title: episode.title.clone(),
        sort_title: None,
        artists: vec![ArtistCredit {
            artist_id: None,
            name: episode.podcast_title.clone(),
            role: ArtistRole::Main,
        }],
        album_id: None,
        album_title: Some(episode.podcast_title.clone()),
        track_no: episode.episode_no,
        disc_no: episode.season_no,
        year: None,
        duration_ms: episode.duration_ms,
        genres: vec!["Podcast".to_string()],
        mbid_recording: None,
        audio: None,
        replaygain: Default::default(),
        artwork_id: None,
        overlay: None,
        is_local: false,
    }
}

/// 单集在播放队列里的列表行。
pub(crate) fn episode_track_row(episode: &PodcastEpisode) -> TrackRow {
    TrackRow {
        id: episode.id.track_id(),
        title: episode.title.clone(),
        artist_line: episode.podcast_title.clone(),
        album_title: Some(episode.podcast_title.clone()),
        duration_ms: episode.duration_ms,
        artwork_id: None,
        quality_badge: None,
        loved: false,
        is_local: false,
    }
}

/// 根据当前进度判断是否算「听完」。
pub(crate) fn is_finished(position_ms: u64, duration_ms: u64) -> bool {
    duration_ms > 0
        && (position_ms + PLAYED_REMAINING_MS >= duration_ms
            || position_ms * 100 >= duration_ms * 97)
}

// ---------------------------------------------------------------------------
// LekisCore 门面
// ---------------------------------------------------------------------------

fn user_state_event() -> CoreEvent {
    CoreEvent::LibraryChanged {
        scope: LibraryScope::UserState,
    }
}

impl LekisCore {
    /// 在 Apple 目录里搜索节目。`country` 是 ISO 3166-1 二位代码（决定用哪个区的目录）。
    pub async fn podcast_search(
        &self,
        term: String,
        country: String,
        limit: u32,
    ) -> Result<Vec<DirectoryPodcast>> {
        let term = term.trim().to_string();
        if term.is_empty() {
            return Ok(Vec::new());
        }
        let s = self.services.clone();
        self.run(async move {
            // 直接粘贴 RSS / Apple 链接时不走搜索。
            if let Some(id) = apple_podcast_id(&term) {
                let found = s.podcast.lookup(id).await?;
                return annotate(&s.library, vec![found]).await;
            }
            let found = s.podcast.search(&term, &country, limit).await?;
            annotate(&s.library, found).await
        })
        .await
    }

    /// 分地区排行榜。`genre_id` 是 Apple 的播客分类 ID（例如 1318 = 科技）。
    pub async fn podcast_top(
        &self,
        country: String,
        genre_id: Option<u32>,
        limit: u32,
    ) -> Result<Vec<DirectoryPodcast>> {
        let s = self.services.clone();
        self.run(async move {
            let found = s.podcast.top(&country, genre_id, limit).await?;
            annotate(&s.library, found).await
        })
        .await
    }

    /// 打开目录里的一档节目：必要时 lookup RSS 地址，抓取并缓存到本地（不自动订阅）。
    pub async fn podcast_open_directory(
        &self,
        itunes_id: Option<i64>,
        feed_url: Option<String>,
    ) -> Result<Podcast> {
        let s = self.services.clone();
        self.run(async move {
            // 本地已有、刚刷新过：直接用缓存。
            let existing = match (itunes_id, feed_url.as_deref()) {
                (_, Some(url)) => s.library.podcast_by_feed_url(url).await?,
                (Some(id), None) => s.library.podcast_by_itunes_id(id).await?,
                (None, None) => {
                    return Err(LekisError::invalid("need an iTunes id or a feed url"));
                }
            };
            if let Some(p) = &existing {
                if p.last_refreshed_at
                    .is_some_and(|t| now_ms() - t < OPEN_CACHE_MS)
                {
                    return Ok(p.clone());
                }
            }
            let feed_url = match (feed_url, existing.as_ref()) {
                (Some(url), _) => validate_http_url(&url)?,
                (None, Some(p)) => p.feed_url.clone(),
                (None, None) => {
                    let id = itunes_id.unwrap_or_default();
                    s.podcast
                        .lookup(id)
                        .await?
                        .feed_url
                        .ok_or_else(|| LekisError::not_found("podcast has no RSS feed"))?
                }
            };
            fetch_and_store(&s, &feed_url, itunes_id).await
        })
        .await
    }

    /// 按 RSS 地址（或 Apple Podcasts 网页地址）添加节目：抓取并缓存，不自动订阅。
    pub async fn podcast_open_feed(&self, address: String) -> Result<Podcast> {
        if let Some(id) = apple_podcast_id(&address) {
            return self.podcast_open_directory(Some(id), None).await;
        }
        let feed_url = normalize_feed_input(&address)?;
        let s = self.services.clone();
        self.run(async move { fetch_and_store(&s, &feed_url, None).await })
            .await
    }

    /// 重新抓取一个节目的 RSS。
    pub async fn podcast_refresh(&self, id: PodcastId) -> Result<Podcast> {
        let s = self.services.clone();
        self.run(async move {
            let podcast = s.library.podcast(id).await?;
            fetch_and_store(&s, &podcast.feed_url, None).await
        })
        .await
    }

    /// 刷新所有订阅（并发 [`REFRESH_CONCURRENCY`] 个）。
    pub async fn podcast_refresh_all(&self) -> Result<PodcastRefreshReport> {
        let s = self.services.clone();
        let report = self
            .run(async move {
                let subs = s.library.podcast_subscriptions().await?;
                refresh_many(&s, subs).await
            })
            .await?;
        self.services.events.emit(user_state_event());
        Ok(report)
    }

    /// 订阅 / 取消订阅。
    pub async fn podcast_set_subscribed(&self, id: PodcastId, subscribed: bool) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_set_subscribed(id, subscribed).await })
            .await?;
        self.services.events.emit(user_state_event());
        Ok(())
    }

    /// 已订阅的节目。
    pub async fn podcast_subscriptions(&self) -> Result<Vec<Podcast>> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_subscriptions().await })
            .await
    }

    /// 本地缓存的节目。
    pub async fn podcast_get(&self, id: PodcastId) -> Result<Podcast> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast(id).await }).await
    }

    /// 节目的单集（新的在前）。
    pub async fn podcast_episodes(
        &self,
        id: PodcastId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<PodcastEpisode>> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_episodes(id, offset, limit).await })
            .await
    }

    /// 订阅里最新的单集。
    pub async fn podcast_latest_episodes(&self, limit: u32) -> Result<Vec<PodcastEpisode>> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_latest_episodes(limit).await })
            .await
    }

    /// 听到一半的单集。
    pub async fn podcast_in_progress(&self, limit: u32) -> Result<Vec<PodcastEpisode>> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_in_progress(limit).await })
            .await
    }

    /// 标记单集已播放 / 未播放。
    pub async fn podcast_set_played(&self, id: PodcastEpisodeId, played: bool) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_set_played(id, played).await })
            .await?;
        self.services.events.emit(user_state_event());
        Ok(())
    }

    /// 把节目的所有单集标记为已播放。
    pub async fn podcast_mark_all_played(&self, id: PodcastId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.podcast_mark_all_played(id).await })
            .await?;
        self.services.events.emit(user_state_event());
        Ok(())
    }

    /// 用一组单集替换播放队列，从 `start` 开始播放；有保存的进度时从那里接着放。
    pub async fn podcast_play(&self, episodes: Vec<PodcastEpisodeId>, start: u32) -> Result<u32> {
        if episodes.is_empty() {
            return Err(LekisError::invalid("podcast queue must not be empty"));
        }
        let s = self.services.clone();
        let (tracks, start, resume_ms) = self
            .run(async move {
                let start = (start as usize).min(episodes.len() - 1);
                let first = s.library.podcast_episode(episodes[start]).await?;
                let resume = if first.played { 0 } else { first.position_ms };
                s.library
                    .podcast_update_progress(first.id, resume, None, now_ms())
                    .await?;
                let tracks: Vec<TrackId> = episodes.iter().map(|id| id.track_id()).collect();
                Ok((tracks, start, resume))
            })
            .await?;
        let len = tracks.len() as u32;
        let engine = &self.services.engine;
        engine.send(lekis_playback::EngineCommand::SetQueue { tracks, start })?;
        if resume_ms > 5_000 {
            // 回退几秒，方便接上上下文。
            engine.send(lekis_playback::EngineCommand::Seek(resume_ms - 3_000))?;
        }
        self.services.events.emit(user_state_event());
        Ok(len)
    }

    /// 导入 OPML：全部订阅，然后并发抓取 RSS。
    pub async fn podcast_import_opml(&self, text: String) -> Result<OpmlImportReport> {
        let entries = parse_opml(&text)?;
        let s = self.services.clone();
        let report = self
            .run(async move {
                let mut report = OpmlImportReport {
                    total: entries.len() as u32,
                    ..Default::default()
                };
                let mut to_fetch = Vec::new();
                for entry in entries {
                    let podcast = s
                        .library
                        .podcast_ensure(&entry.feed_url, &entry.title, None)
                        .await?;
                    if podcast.subscribed {
                        report.already_subscribed += 1;
                        continue;
                    }
                    s.library.podcast_set_subscribed(podcast.id, true).await?;
                    report.added += 1;
                    to_fetch.push(podcast);
                }
                let refreshed = refresh_many(&s, to_fetch).await?;
                report.failed = refreshed.failed;
                Ok(report)
            })
            .await?;
        self.services.events.emit(user_state_event());
        Ok(report)
    }

    /// 导出所有订阅为 OPML 2.0 文本。
    pub async fn podcast_export_opml(&self) -> Result<String> {
        let subs = self.podcast_subscriptions().await?;
        Ok(export_opml(&subs))
    }

    /// 保存播放会话时顺带写回播客进度（由 `save_playback_state` 调用）。
    pub(crate) async fn podcast_save_progress(&self, snap: &crate::PlaybackSnapshot) -> Result<()> {
        let Some(episode_id) = snap.track_id.and_then(PodcastEpisodeId::from_track_id) else {
            return Ok(());
        };
        let position = snap.position_ms;
        let ended = snap.state == lekis_types::PlaybackState::Ended;
        let duration = snap.duration_ms;
        let s = self.services.clone();
        let finished = self
            .run(async move {
                let episode = s.library.podcast_episode(episode_id).await?;
                let duration = if duration > 0 {
                    duration
                } else {
                    episode.duration_ms
                };
                let finished = ended || is_finished(position, duration);
                if finished {
                    s.library
                        .podcast_update_progress(episode_id, 0, Some(true), now_ms())
                        .await?;
                } else if position > 0 {
                    s.library
                        .podcast_update_progress(episode_id, position, None, now_ms())
                        .await?;
                }
                Ok(finished && !episode.played)
            })
            .await?;
        if finished {
            self.services.events.emit(user_state_event());
        }
        Ok(())
    }
}

/// 标注目录结果是否已经在本地 / 已订阅。
async fn annotate(
    library: &lekis_library::Library,
    mut items: Vec<DirectoryPodcast>,
) -> Result<Vec<DirectoryPodcast>> {
    for item in &mut items {
        let local = match (&item.feed_url, item.itunes_id) {
            (Some(url), _) => library.podcast_by_feed_url(url).await?,
            (None, Some(id)) => library.podcast_by_itunes_id(id).await?,
            _ => None,
        };
        let local = match (local, item.itunes_id) {
            (None, Some(id)) if item.feed_url.is_some() => library.podcast_by_itunes_id(id).await?,
            (local, _) => local,
        };
        if let Some(p) = local {
            item.local_id = Some(p.id);
            item.subscribed = p.subscribed;
        }
    }
    Ok(items)
}

async fn fetch_and_store(
    s: &std::sync::Arc<crate::Services>,
    feed_url: &str,
    itunes_id: Option<i64>,
) -> Result<Podcast> {
    match s.podcast.fetch_feed(feed_url).await {
        Ok(mut parsed) => {
            parsed.podcast.itunes_id = itunes_id;
            s.library
                .podcast_store_feed(parsed.podcast, parsed.episodes)
                .await
        }
        Err(e) => {
            if let Some(p) = s.library.podcast_by_feed_url(feed_url).await? {
                s.library
                    .podcast_set_error(p.id, Some(e.message.clone()))
                    .await?;
            }
            Err(e)
        }
    }
}

async fn refresh_many(
    s: &std::sync::Arc<crate::Services>,
    podcasts: Vec<Podcast>,
) -> Result<PodcastRefreshReport> {
    let mut report = PodcastRefreshReport::default();
    for chunk in podcasts.chunks(REFRESH_CONCURRENCY) {
        let mut set = tokio::task::JoinSet::new();
        for p in chunk {
            let s = s.clone();
            let p = p.clone();
            set.spawn(async move {
                let before = p.episode_count;
                fetch_and_store(&s, &p.feed_url, None)
                    .await
                    .map(|after| after.episode_count.saturating_sub(before))
            });
        }
        while let Some(result) = set.join_next().await {
            match result {
                Ok(Ok(new)) => {
                    report.refreshed += 1;
                    report.new_episodes += new;
                }
                Ok(Err(e)) => {
                    tracing::debug!(target: "core::podcast", error = %e.message, "feed refresh failed");
                    report.failed += 1;
                }
                Err(e) => {
                    tracing::warn!(target: "core::podcast", error = %e, "feed refresh task failed");
                    report.failed += 1;
                }
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    const RSS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:atom="http://www.w3.org/2005/Atom"
     xmlns:podcast="https://podcastindex.org/namespace/1.0">
  <channel>
    <title>测试播客 &amp; 朋友</title>
    <atom:link href="https://example.com/feed.xml" rel="self" type="application/rss+xml"/>
    <link>https://example.com/</link>
    <language>zh-cn</language>
    <itunes:author>某某电台</itunes:author>
    <description><![CDATA[<p>一档<b>关于</b>技术的节目。</p><p>第二段</p>]]></description>
    <itunes:image href="https://example.com/cover.jpg"/>
    <itunes:category text="Technology"><itunes:category text="Tech News"/></itunes:category>
    <item>
      <title>第 1 期：开始</title>
      <guid isPermaLink="false">ep-1</guid>
      <pubDate>Tue, 10 Jun 2025 04:00:00 +0800</pubDate>
      <enclosure url="https://cdn.example.com/1.mp3" length="12345" type="audio/mpeg"/>
      <itunes:duration>01:02:03</itunes:duration>
      <itunes:episode>1</itunes:episode>
      <description>简介 &lt;b&gt;粗体&lt;/b&gt; &#x4F60;好</description>
    </item>
    <item>
      <title>第 2 期</title>
      <pubDate>Wed, 11 Jun 2025 04:00:00 GMT</pubDate>
      <enclosure url="/media/2.m4a" type="audio/x-m4a"/>
      <itunes:duration>754</itunes:duration>
      <itunes:image href="https://example.com/2.jpg"/>
      <content:encoded><![CDATA[<p>只有 content</p>]]></content:encoded>
    </item>
    <item>
      <title>没有音频的公告</title>
      <guid>notice</guid>
    </item>
  </channel>
</rss>"#;

    #[test]
    fn parses_rss_with_itunes_tags() {
        let feed = parse_feed(RSS, "https://example.com/feed.xml").unwrap();
        let p = &feed.podcast;
        assert_eq!(p.title, "测试播客 & 朋友");
        assert_eq!(p.author.as_deref(), Some("某某电台"));
        assert_eq!(
            p.description.as_deref(),
            Some("一档关于技术的节目。\n\n第二段")
        );
        assert_eq!(
            p.artwork_url.as_deref(),
            Some("https://example.com/cover.jpg")
        );
        assert_eq!(p.link.as_deref(), Some("https://example.com/"));
        assert_eq!(p.categories, vec!["Technology", "Tech News"]);
        assert_eq!(p.language.as_deref(), Some("zh-cn"));
        assert_eq!(feed.episodes.len(), 2);

        // 新的在前。
        let e2 = &feed.episodes[0];
        assert_eq!(e2.title, "第 2 期");
        assert_eq!(e2.audio_url, "https://example.com/media/2.m4a");
        assert_eq!(e2.guid, "https://example.com/media/2.m4a");
        assert_eq!(e2.duration_ms, 754_000);
        assert_eq!(e2.artwork_url.as_deref(), Some("https://example.com/2.jpg"));
        assert_eq!(e2.description.as_deref(), Some("只有 content"));
        assert_eq!(e2.published_at, Some(1_749_614_400_000));

        let e1 = &feed.episodes[1];
        assert_eq!(e1.guid, "ep-1");
        assert_eq!(e1.size_bytes, Some(12345));
        assert_eq!(e1.mime_type.as_deref(), Some("audio/mpeg"));
        assert_eq!(e1.duration_ms, 3_723_000);
        assert_eq!(e1.episode_no, Some(1));
        assert_eq!(e1.description.as_deref(), Some("简介 粗体 你好"));
        // 2025-06-10 04:00 +08:00 = 2025-06-09 20:00 UTC
        assert_eq!(e1.published_at, Some(1_749_499_200_000));
        assert_eq!(p.latest_published_at, Some(1_749_614_400_000));
    }

    #[test]
    fn parses_atom_enclosures() {
        let atom = r#"<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en">
          <title>Atom Cast</title>
          <author><name>Alice</name></author>
          <logo>https://example.org/logo.png</logo>
          <entry>
            <id>urn:1</id><title>Hello</title>
            <published>2024-01-02T03:04:05Z</published>
            <link rel="alternate" href="https://example.org/1"/>
            <link rel="enclosure" href="https://example.org/1.ogg" type="audio/ogg" length="10"/>
            <summary>Sum</summary>
          </entry>
          <entry><id>urn:2</id><title>No audio</title></entry>
        </feed>"#;
        let feed = parse_feed(atom, "https://example.org/atom").unwrap();
        assert_eq!(feed.podcast.title, "Atom Cast");
        assert_eq!(feed.podcast.author.as_deref(), Some("Alice"));
        assert_eq!(feed.episodes.len(), 1);
        assert_eq!(feed.episodes[0].audio_url, "https://example.org/1.ogg");
        assert_eq!(feed.episodes[0].published_at, Some(1_704_164_645_000));
        assert_eq!(
            feed.episodes[0].link.as_deref(),
            Some("https://example.org/1")
        );
    }

    #[test]
    fn rejects_html_and_garbage() {
        assert!(parse_feed("<html><body>hi</body></html>", "https://e.com/").is_err());
        assert!(parse_feed("not xml at all", "https://e.com/").is_err());
        assert!(parse_feed(RSS, "file:///etc/passwd").is_err());
    }

    #[test]
    fn parses_itunes_search_json() {
        let json = r#"{"resultCount":3,"results":[
          {"wrapperType":"track","kind":"podcast","collectionId":1166949390,"trackId":1166949390,
           "artistName":"日谈公园","collectionName":"日谈公园",
           "feedUrl":"http://www.ximalaya.com/album/5574153.xml",
           "artworkUrl100":"https://is1-ssl.mzstatic.com/a/100x100bb.jpg",
           "artworkUrl600":"https://is1-ssl.mzstatic.com/a/600x600bb.jpg",
           "primaryGenreName":"表演艺术","trackCount":870},
          {"kind":"podcast","collectionId":1166949390,"collectionName":"dup"},
          {"kind":"podcast","collectionId":2,"collectionName":"  ","feedUrl":"https://x"}
        ]}"#;
        let items = parse_itunes_results(json).unwrap();
        assert_eq!(items.len(), 1);
        let p = &items[0];
        assert_eq!(p.itunes_id, Some(1166949390));
        assert_eq!(p.title, "日谈公园");
        assert_eq!(
            p.feed_url.as_deref(),
            Some("http://www.ximalaya.com/album/5574153.xml")
        );
        assert_eq!(
            p.artwork_url.as_deref(),
            Some("https://is1-ssl.mzstatic.com/a/600x600bb.jpg")
        );
        assert_eq!(p.genre.as_deref(), Some("表演艺术"));
        assert_eq!(p.episode_count, Some(870));
        assert!(parse_itunes_results("<html>").is_err());
    }

    #[test]
    fn parses_itunes_top_chart_json() {
        let json = r#"{"feed":{"entry":[
          {"im:name":{"label":"声动早咖啡"},
           "im:image":[{"label":"https://is1-ssl.mzstatic.com/x/55x55bb.png"},
                       {"label":"https://is1-ssl.mzstatic.com/x/170x170bb.png"}],
           "id":{"label":"https://podcasts.apple.com/cn/podcast/id1573189055?uo=2",
                 "attributes":{"im:id":"1573189055"}},
           "im:artist":{"label":"声动活泼"},
           "category":{"attributes":{"im:id":"1493","label":"创业"}}}
        ]}}"#;
        let items = parse_itunes_top(json).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].itunes_id, Some(1573189055));
        assert_eq!(items[0].title, "声动早咖啡");
        assert_eq!(items[0].author.as_deref(), Some("声动活泼"));
        assert_eq!(items[0].genre.as_deref(), Some("创业"));
        assert_eq!(
            items[0].artwork_url.as_deref(),
            Some("https://is1-ssl.mzstatic.com/x/600x600bb.png")
        );
        // 单条时 entry 是对象。
        let single =
            r#"{"feed":{"entry":{"im:name":{"label":"One"},"id":{"attributes":{"im:id":"5"}}}}}"#;
        assert_eq!(parse_itunes_top(single).unwrap()[0].itunes_id, Some(5));
        assert!(parse_itunes_top(r#"{"feed":{}}"#).unwrap().is_empty());
    }

    #[test]
    fn opml_roundtrip() {
        let opml = r#"<?xml version="1.0"?>
          <opml version="1.0"><head><title>x</title></head><body>
            <outline text="Folder">
              <outline type="rss" text="A &amp; B" xmlUrl="https://a.example/feed"/>
              <outline type="rss" title="C" xmlUrl="feed://c.example/rss"/>
            </outline>
            <outline type="rss" text="dup" xmlUrl="https://a.example/feed"/>
            <outline type="rss" text="bad" xmlUrl="javascript:alert(1)"/>
          </body></opml>"#;
        let entries = parse_opml(opml).unwrap();
        assert_eq!(
            entries,
            vec![
                OpmlEntry {
                    title: "A & B".into(),
                    feed_url: "https://a.example/feed".into()
                },
                OpmlEntry {
                    title: "C".into(),
                    feed_url: "https://c.example/rss".into()
                },
            ]
        );
        let mut p = empty_podcast("https://a.example/feed?x=1&y=2");
        p.title = "A & \"B\"".into();
        let out = export_opml(&[p]);
        let back = parse_opml(&out).unwrap();
        assert_eq!(back[0].title, "A & \"B\"");
        assert_eq!(back[0].feed_url, "https://a.example/feed?x=1&y=2");
        assert!(parse_opml("<rss/>").is_err());
    }

    #[test]
    fn durations_and_dates() {
        assert_eq!(parse_duration_ms("1:02:03"), Some(3_723_000));
        assert_eq!(parse_duration_ms("62:03"), Some(3_723_000));
        assert_eq!(parse_duration_ms("3723"), Some(3_723_000));
        assert_eq!(parse_duration_ms("12.5"), Some(12_500));
        assert_eq!(parse_duration_ms("abc"), None);
        assert_eq!(parse_date_ms("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
        assert_eq!(parse_date_ms("1 Jan 1970 01:00:00 +0100"), Some(0));
        assert_eq!(
            parse_date_ms("Thu, 1 Jan 1970 00:00 EST"),
            Some(5 * 3600 * 1000)
        );
        assert_eq!(parse_date_ms("1970-01-01T08:00:00+08:00"), Some(0));
        assert_eq!(parse_date_ms("1970-01-02"), Some(86_400_000));
        assert_eq!(parse_date_ms("garbage"), None);
        assert_eq!(format_date(1_749_614_400_000), "2025-06-11");
    }

    #[test]
    fn feed_input_and_apple_links() {
        assert_eq!(
            normalize_feed_input("feed://example.com/rss").unwrap(),
            "https://example.com/rss"
        );
        assert_eq!(
            normalize_feed_input("example.com/rss").unwrap(),
            "https://example.com/rss"
        );
        assert!(normalize_feed_input("ftp://example.com/rss").is_err());
        assert_eq!(
            apple_podcast_id("https://podcasts.apple.com/cn/podcast/%E6%97%A5/id1166949390?uo=4"),
            Some(1166949390)
        );
        assert_eq!(apple_podcast_id("https://example.com/id123"), None);
    }

    #[test]
    fn finished_threshold() {
        assert!(!is_finished(0, 0));
        assert!(!is_finished(60_000, 3_600_000));
        assert!(is_finished(3_590_000, 3_600_000));
        assert!(is_finished(99_000, 100_000));
    }

    #[test]
    fn synthetic_ids_route_to_episode() {
        let mut e = empty_episode();
        e.id = PodcastEpisodeId(3);
        e.title = "T".into();
        e.podcast_title = "P".into();
        let t = episode_track(&e);
        assert_eq!(
            PodcastEpisodeId::from_track_id(t.id),
            Some(PodcastEpisodeId(3))
        );
        assert_eq!(episode_track_row(&e).artist_line, "P");
    }

    /// 手动验证真实 RSS：`LEKIS_PODCAST_FEED_FILE=feed.xml cargo test -p lekis-core real_feed_file -- --ignored --nocapture`。
    #[test]
    #[ignore]
    fn real_feed_file() {
        let path = std::env::var("LEKIS_PODCAST_FEED_FILE").expect("LEKIS_PODCAST_FEED_FILE");
        let xml = std::fs::read_to_string(path).unwrap();
        let started = std::time::Instant::now();
        let feed = parse_feed(&xml, "https://example.com/feed.xml").unwrap();
        println!(
            "{} by {:?}: {} episodes in {:?}",
            feed.podcast.title,
            feed.podcast.author,
            feed.episodes.len(),
            started.elapsed()
        );
        for e in feed.episodes.iter().take(3) {
            println!(
                "  {} | {:?} | {} ms | {}",
                e.title,
                e.published_at.map(format_date),
                e.duration_ms,
                e.audio_url
            );
        }
        assert!(!feed.episodes.is_empty());
    }

    #[tokio::test]
    async fn client_parses_mock_directory_and_feed() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 4096];
                let n = stream.read(&mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let body = if req.starts_with("GET /search") {
                    assert!(req.contains("media=podcast"));
                    assert!(req.contains("country=cn"));
                    format!(
                        r#"{{"results":[{{"kind":"podcast","collectionId":9,"collectionName":"Mock","feedUrl":"http://{addr}/feed.xml"}}]}}"#
                    )
                } else {
                    RSS.to_string()
                };
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(resp.as_bytes()).await.unwrap();
                let _ = stream.shutdown().await;
            }
        });
        let client = PodcastClient::with_base(format!("http://{addr}")).unwrap();
        let found = client.search("mock", "CN", 10).await.unwrap();
        assert_eq!(found.len(), 1);
        let feed = client
            .fetch_feed(found[0].feed_url.as_deref().unwrap())
            .await
            .unwrap();
        assert_eq!(feed.episodes.len(), 2);
    }
}
