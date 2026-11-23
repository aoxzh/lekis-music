//! Plex（SRC-06，P1）。
//!
//! 认证：`X-Plex-Token` 请求头（token 由 plex.tv 的 PIN 授权流程拿到，用户不在 App 里输密码）。
//! token **不放在 URL 里**：URL 会进日志、进代理缓存、进浏览历史，请求头不会。
//!
//! 端点：
//! - `GET /`（或 `/identity`）：连通性检查，返回 `MediaContainer`；
//! - `GET /library/sections`：发现音乐库。Plex 的库是"多 section"的，这里选第一个
//!   `type="artist"` 的 section 并缓存（音乐库的 section 类型叫 `artist`，不是 `music`）；
//! - `GET /library/sections/{id}/all?type=10`：拉曲目（`type=10` 是 track）；
//! - `GET /library/metadata/{ratingKey}`：拿 `Media` / `Part`，`Part.key` 才是真正的文件路径；
//! - `GET /:/scrobble?key={ratingKey}&identifier=com.plexapp.plugins.library`：播放上报。
//!
//! Plex 只给 XML（`Accept: application/xml`），解析用 `crate::xml` 里的小树。

use crate::xml::{self, XmlElement};
use crate::{http, MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, Lyrics, LyricsFormat, Result, SourceKind};
use reqwest::Url;

/// Plex 音乐库的 section 类型。注意是 `artist` 而不是 `music`：
/// Plex 把音乐库的 section 标成 `artist`（里面装的是艺人），曲目在 `type=10`。
const MUSIC_SECTION_TYPE: &str = "artist";

/// Plex 的 track 类型编号。
const TRACK_TYPE: &str = "10";

/// 分页上限（服务端对 `/all` 的最大值没有硬性文档，1000 是社区实践经验）。
const MAX_PAGE: u32 = 1000;

/// Plex 客户端的唯一标识，转码会话要用；构造时随机生成一次。
const CLIENT_IDENTIFIER_HEADER: &str = "X-Plex-Client-Identifier";

/// Plex 客户端。
pub struct Plex {
    /// 服务器根地址，例如 `http://192.168.1.10:32400`。
    base_url: String,
    /// plex.tv 授权拿到的 token。
    token: String,
    /// 复用连接的 HTTP 客户端。
    client: reqwest::Client,
    /// 本机客户端标识（Plex 的转码会话要求同一客户端复用同一个 ID）。
    client_id: String,
    /// 缓存的音乐 section ID（第一次 `list_tracks` 时发现）。
    section_id: tokio::sync::Mutex<Option<String>>,
}

impl Plex {
    /// 创建客户端。
    ///
    /// 构造**不发任何网络请求**；section 发现推迟到第一次 [`MediaServer::list_tracks`]。
    pub fn new(base_url: &str, token: String) -> Result<Self> {
        let base_url = base_url.trim_end_matches('/');
        if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
            return Err(LekisError::invalid("Plex 地址必须以 http(s):// 开头"));
        }
        if token.trim().is_empty() {
            return Err(LekisError::invalid("Plex token 不能为空"));
        }
        Ok(Self {
            base_url: base_url.to_string(),
            token,
            client: http::client().unwrap_or_default(),
            client_id: uuid::Uuid::new_v4().simple().to_string(),
            section_id: tokio::sync::Mutex::new(None),
        })
    }

    /// Plex 要求的公共请求头。
    ///
    /// 注意 token 在这里以请求头的形式带上，URL 里没有凭据。
    fn headers(&self) -> Vec<(&'static str, String)> {
        vec![
            ("X-Plex-Token", self.token.clone()),
            ("Accept", "application/xml".to_string()),
            // 让服务器删掉 Plex Web 专属的 `X-Plex-...` 前缀差异；Plex 会照常返回 XML。
            ("X-Plex-Product", "LekisMusic".to_string()),
            ("X-Plex-Version", env!("CARGO_PKG_VERSION").to_string()),
            (CLIENT_IDENTIFIER_HEADER, self.client_id.clone()),
        ]
    }

    /// 拼地址（`path` 以 `/` 开头；不覆盖 base 里的路径前缀）。
    fn url(&self, path: &str, query: &[(&str, String)]) -> Result<Url> {
        let mut url = http::join(&self.base_url, path)?;
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }
        Ok(url)
    }

    /// 带 Plex 头发 GET，返回响应体文本。
    async fn get_text(&self, url: Url, what: &str) -> Result<String> {
        let mut request = self.client.get(url);
        for (name, value) in self.headers() {
            request = request.header(name, value);
        }
        let response = request.send().await.map_err(http::network)?;
        http::ensure_status(&response, what)?;
        response.text().await.map_err(http::network)
    }

    async fn lyrics_get(&self, client: &reqwest::Client, url: Url, limit: usize) -> Result<Option<Vec<u8>>> {
        let mut request = client.get(url);
        for (name, value) in self.headers() { request = request.header(name, value); }
        let mut response = request.send().await.map_err(http::network)?;
        if response.status() == reqwest::StatusCode::NOT_FOUND { return Ok(None); }
        http::ensure_status(&response, "plex lyrics")?;
        if response.content_length().is_some_and(|n| n > limit as u64) { return Err(LekisError::invalid("Plex lyrics response too large")); }
        let mut data = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http::network)? {
            if data.len() + chunk.len() > limit { return Err(LekisError::invalid("Plex lyrics response too large")); }
            data.extend_from_slice(&chunk);
        }
        Ok(Some(data))
    }

    /// 取 `MediaContainer` 根元素。
    async fn container(
        &self,
        path: &str,
        query: &[(&str, String)],
        what: &str,
    ) -> Result<XmlElement> {
        let url = self.url(path, query)?;
        let body = self.get_text(url, what).await?;
        let root = xml::parse(&body)?;
        if !root.local_name().eq_ignore_ascii_case("MediaContainer") {
            return Err(LekisError::new(
                ErrorCode::Internal,
                format!(
                    "{what}：期望 MediaContainer，实际是 <{}>",
                    root.local_name()
                ),
            ));
        }
        Ok(root)
    }

    /// 发现并缓存音乐 section 的 ID。
    ///
    /// 选第一个 `type="artist"` 的 section；如果一个都没有，再退让选 `type="music"`
    /// （极老的服务器和第三方实现会用 `music`）。
    async fn section_id(&self) -> Result<String> {
        if let Some(id) = self.section_id.lock().await.clone() {
            return Ok(id);
        }

        let root = self
            .container("/library/sections", &[], "plex /library/sections")
            .await?;
        let id = select_music_section(&root)?;
        *self.section_id.lock().await = Some(id.clone());
        Ok(id)
    }
}

/// 手写 `Debug`：**不能泄露 token**。
impl std::fmt::Debug for Plex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Plex")
            .field("base_url", &self.base_url)
            .field("token", &"<redacted>")
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl MediaServer for Plex {
    fn kind(&self) -> SourceKind {
        SourceKind::Plex
    }

    async fn ping(&self) -> Result<()> {
        // `/identity` 不需要选库，是最轻的连通性检查。
        // 老版本没有 `/identity` 时退化到 `/`。
        match self.container("/identity", &[], "plex ping").await {
            Ok(root) => {
                tracing::debug!(
                    target: "lekis_providers::plex",
                    machine = root.attr("machineIdentifier").unwrap_or("?"),
                    version = root.attr("version").unwrap_or("?"),
                    "服务器连通"
                );
                Ok(())
            }
            Err(error) if error.code == ErrorCode::NotFound => {
                self.container("/", &[], "plex ping").await.map(|_| ())
            }
            Err(error) => Err(error),
        }
    }

    async fn list_tracks(
        &self,
        offset: u32,
        limit: u32,
        since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        let limit = limit.clamp(1, MAX_PAGE);
        let section = self.section_id().await?;

        let mut query: Vec<(&str, String)> = vec![
            ("type", TRACK_TYPE.to_string()),
            ("X-Plex-Container-Start", offset.to_string()),
            ("X-Plex-Container-Size", limit.to_string()),
        ];
        if since_ms.is_some() {
            // 增量：按加入时间倒序，遇到比 since 老的就停（Plex 没有"某时间之后"的过滤参数）。
            query.push(("sort", "addedAt:desc".to_string()));
        }
        let root = self
            .container(
                &format!("/library/sections/{section}/all"),
                &query,
                "plex /library/sections/{section}/all",
            )
            .await?;

        let cutoff = since_ms.map(|ms| ms.div_euclid(1000));
        let mut tracks = Vec::new();
        for track in root.children_named("Track") {
            if let Some(cutoff) = cutoff {
                // `addedAt` 是 Unix 秒；解析不出来就当它是新的（宁多拉不少拉）。
                if let Some(added) = track.attr_parse::<i64>("addedAt") {
                    if added < cutoff {
                        break;
                    }
                }
            }
            tracks.push(track_to_remote(track));
        }
        Ok(tracks)
    }

    async fn stream(&self, external_id: &str, quality: StreamQuality) -> Result<StreamTarget> {
        // 先查这个曲目，拿 Media/Part 的 key —— 那才是文件路径（曲目的 key 是元数据 URL）。
        let part = self.part_key(external_id).await?;
        let headers: Vec<(String, String)> = self
            .headers()
            .into_iter()
            .filter(|(name, _)| *name != "Accept")
            .map(|(name, value)| (name.to_string(), value))
            .collect();

        match quality {
            StreamQuality::Original => {
                // `Part.key` 已经是 `/library/parts/...` 形式的绝对路径。
                let url = http::join(&self.base_url, &part)?;
                Ok(StreamTarget {
                    url: url.to_string(),
                    headers,
                    // Plex 的直连文件支持 Range。
                    seekable: true,
                })
            }
            StreamQuality::Transcode { max_kbps } => {
                // Plex 的通用转码器：返回音频流的 HTTP 响应（不是 HLS）。
                // 注意：部分 Plex 版本要求额外的 `X-Plex-Client-Profile-*` 参数才肯输出纯音频；
                // 真机上如果失败，说明这条路径需要客户端 profile，留给后续在真服务器上联调。
                let query = vec![
                    ("path", part),
                    ("maxAudioBitrate", (max_kbps * 1000).to_string()),
                    ("directPlay", "0".to_string()),
                    ("directStream", "0".to_string()),
                    ("protocol", "http".to_string()),
                    ("mediaIndex", "0".to_string()),
                    ("partIndex", "0".to_string()),
                    ("session", uuid::Uuid::new_v4().simple().to_string()),
                ];
                let url = self.url("/music/:/transcode/universal/start", &query)?;
                Ok(StreamTarget {
                    url: url.to_string(),
                    headers,
                    // 转码流不支持 Range。
                    seekable: false,
                })
            }
        }
    }

    async fn lyrics(&self, external_id: &str) -> Result<Option<Lyrics>> {
        // Never forward the Plex token through a server-provided redirect.
        let client = reqwest::Client::builder()
            .user_agent(http::USER_AGENT).timeout(http::TIMEOUT)
            .connect_timeout(http::CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build().map_err(|e| LekisError::internal(format!("Plex client: {e}")))?;
        let url = self.url(&format!("/library/metadata/{}", encode_path_segment(external_id)), &[])?;
        let Some(metadata) = self.lyrics_get(&client, url, 2 * 1024 * 1024).await? else { return Ok(None) };
        let root = xml::parse(&String::from_utf8_lossy(&metadata))?;
        let key = root.children_named("Track")
            .flat_map(|track| track.children_named("Media"))
            .flat_map(|media| media.children_named("Part"))
            .flat_map(|part| part.children_named("Stream"))
            .find(|stream| stream.attr("streamType") == Some("4") && stream.attr("format").is_some_and(|f| f.eq_ignore_ascii_case("lrc")))
            .and_then(|stream| stream.attr("key"));
        let Some(key) = key else { return Ok(None) };
        if key.is_empty() || key.starts_with("//") || key.contains('\\') || key.contains("://") || key.chars().any(char::is_control) {
            return Err(LekisError::invalid("Plex lyric stream key is not a relative path"));
        }
        let path = if key.starts_with('/') { key.to_owned() } else { format!("/{key}") };
        let url = self.url(&path, &[])?;
        let base = Url::parse(&self.base_url).map_err(|_| LekisError::invalid("invalid Plex server URL"))?;
        if url.origin() != base.origin() { return Err(LekisError::invalid("Plex lyric stream is not same-origin")); }
        let Some(data) = self.lyrics_get(&client, url, 1024 * 1024).await? else { return Ok(None) };
        let content = String::from_utf8(data).map_err(|_| LekisError::invalid("Plex lyrics are not UTF-8"))?;
        if content.trim().is_empty() { return Ok(None); }
        Ok(Some(Lyrics { format: LyricsFormat::Lrc, content, source: "server:plex".into(), offset_ms: 0, confidence: 1.0 }))
    }

    async fn scrobble(&self, external_id: &str, played_at_ms: i64) -> Result<()> {
        // Plex 的 scrobble 用 ratingKey；时间由服务器自己记，我们只需要触发一次。
        let _ = played_at_ms;
        let url = self.url(
            "/:/scrobble",
            &[
                ("key", external_id.to_string()),
                ("identifier", "com.plexapp.plugins.library".to_string()),
            ],
        )?;
        let mut request = self.client.get(url);
        for (name, value) in self.headers() {
            request = request.header(name, value);
        }
        let response = request.send().await.map_err(http::network)?;
        http::ensure_status(&response, "plex scrobble")
    }
}

impl Plex {
    /// 取曲目的 `Part.key`（真正的文件路径）。
    async fn part_key(&self, external_id: &str) -> Result<String> {
        let root = self
            .container(
                &format!("/library/metadata/{}", encode_path_segment(external_id)),
                &[],
                "plex /library/metadata",
            )
            .await?;
        // 响应里是 `<MediaContainer><Track ...><Media><Part key="..."/></Media></Track>`。
        let track = root
            .children
            .iter()
            .find(|child| matches_local(child, "Track"))
            .or_else(|| root.child("Track"))
            .ok_or_else(|| {
                LekisError::new(
                    ErrorCode::NotFound,
                    format!("plex：曲目 {external_id} 不在资料库里"),
                )
            })?;
        let part = track
            .child("Media")
            .and_then(|media| media.child("Part"))
            .ok_or_else(|| {
                LekisError::new(
                    ErrorCode::NotFound,
                    format!("plex：曲目 {external_id} 没有可播放的 Part"),
                )
            })?;
        let key = part.attr("key").ok_or_else(|| {
            LekisError::new(
                ErrorCode::Internal,
                format!("plex：曲目 {external_id} 的 Part 没有 key"),
            )
        })?;
        if key.is_empty() {
            return Err(LekisError::new(
                ErrorCode::Internal,
                format!("plex：曲目 {external_id} 的 Part key 为空"),
            ));
        }
        Ok(key.to_string())
    }
}

fn matches_local(element: &XmlElement, name: &str) -> bool {
    element.local_name().eq_ignore_ascii_case(name)
}

/// 从 `/library/sections` 的结果里挑音乐库。
fn select_music_section(root: &XmlElement) -> Result<String> {
    let directories: Vec<&XmlElement> = root.children_named("Directory").collect();
    let pick = directories
        .iter()
        .find(|dir| {
            dir.attr("type")
                .is_some_and(|kind| kind.eq_ignore_ascii_case(MUSIC_SECTION_TYPE))
        })
        .or_else(|| {
            // 极老的服务器 / 第三方实现可能用 `music`。
            directories.iter().find(|dir| {
                dir.attr("type")
                    .is_some_and(|kind| kind.eq_ignore_ascii_case("music"))
            })
        });

    match pick {
        Some(dir) => dir
            .attr("key")
            .map(|key| key.to_string())
            .ok_or_else(|| LekisError::new(ErrorCode::Internal, "plex：音乐库 section 没有 key")),
        None => Err(LekisError::new(
            ErrorCode::NotFound,
            "plex：服务器上找不到音乐库（type=artist 的 section）",
        )),
    }
}

/// `Track` 元素 → [`RemoteTrack`]。
fn track_to_remote(track: &XmlElement) -> RemoteTrack {
    // Plex 把专辑和艺人放在 `parentTitle` / `grandparentTitle` 里；
    // 新版本也可能带 `<ParentTitle>` 这样的子元素，两种都认。
    let album = track
        .attr("parentTitle")
        .map(str::to_string)
        .or_else(|| track.child("parentTitle").map(|e| e.text.clone()))
        .filter(|album| !album.is_empty());
    let artist = track
        .attr("grandparentTitle")
        .or_else(|| track.attr("originalTitle"))
        .unwrap_or("")
        .trim()
        .to_string();

    let mbid = track
        .attributes
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("guid"))
        .map(|(_, value)| value.trim().to_string())
        .and_then(|guid| guid.strip_prefix("mbid://").map(str::to_string))
        .or_else(|| {
            // 新版本给 `<Guid id="mbid://..."/>` 子元素。
            track
                .children_named("Guid")
                .filter_map(|guid| guid.attr("id"))
                .find_map(|id| id.strip_prefix("mbid://").map(str::to_string))
        });

    RemoteTrack {
            external_album_id: None, album_artists: vec![], disc_no: None, track_no: None,
        external_id: track.attr("ratingKey").unwrap_or_default().to_string(),
        title: track.attr("title").unwrap_or_default().to_string(),
        artists: if artist.is_empty() {
            Vec::new()
        } else {
            vec![artist]
        },
        album,
        // Plex 的 duration 是毫秒，和我们的单位一致。
        duration_ms: track.attr_parse("duration").unwrap_or(0),
        mbid_recording: mbid,
        // Plex 的封面用 thumb 路径（`/library/metadata/{id}/thumb/...`），
        // 这里把 ratingKey 当封面 ID，取图时再拼 thumb 路径。
        cover_id: track
            .attr("parentRatingKey")
            .or_else(|| track.attr("ratingKey"))
            .map(str::to_string),
    }
}

/// 路径段编码（ratingKey 一般是整数，但仍按通用规则处理）。
fn encode_path_segment(segment: &str) -> String {
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    const SET: &percent_encoding::AsciiSet = &NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~');
    utf8_percent_encode(segment, SET).to_string()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// 真实的 `/library/sections` 响应形状（两个库：一个电影，一个音乐）。
    const SECTIONS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="2" allowSync="1" title1="Lekis">
  <Directory allowSync="1" art="/:/resources/movie-fanart.jpg" key="1" librarySectionID="1"
             librarySectionTitle="Movies" librarySectionUUID="uuid-1" type="movie" title="Movies" />
  <Directory allowSync="1" art="/:/resources/artist-fanart.jpg" key="3" librarySectionID="3"
             librarySectionTitle="Music" librarySectionUUID="uuid-3" type="artist" title="音乐" />
</MediaContainer>"#;

    /// `/library/sections/3/all?type=10` 的响应形状。
    const TRACKS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="2" totalSize="2" offset="0">
  <Track ratingKey="1001" key="track-key-1001" guid="plex://track/5d07bca3"
         type="track" title="Bohemian Rhapsody" grandparentTitle="Queen"
         parentTitle="A Night at the Opera" parentRatingKey="900" duration="354000"
         addedAt="1714600000" index="11" parentIndex="1">
    <Media id="2001" duration="354000" bitrate="1411" audioChannels="2" audioCodec="flac" container="flac">
      <Part id="3001" key="part-key-3001" duration="354000" size="62500000" />
    </Media>
  </Track>
  <Track ratingKey="1002" key="track-key-1002" guid="mbid://b1a9c0f4-1c1e-4f5a-9a4e-000000000001"
         type="track" title="Love of My Life" grandparentTitle="Queen"
         parentTitle="A Night at the Opera" parentRatingKey="900" duration="219000"
         addedAt="1714500000" index="9" parentIndex="1">
    <Media id="2002" duration="219000" audioChannels="2" audioCodec="mp3" container="mp3">
      <Part id="3002" key="part-key-3002" duration="219000" />
    </Media>
  </Track>
</MediaContainer>"#;

    #[test]
    fn selects_first_music_section() {
        let root = xml::parse(SECTIONS).unwrap();
        assert_eq!(select_music_section(&root).unwrap(), "3");
    }

    #[test]
    fn falls_back_to_music_type_and_reports_missing_section() {
        let music = r#"<MediaContainer>
            <Directory key="7" type="music" title="Music" />
        </MediaContainer>"#;
        assert_eq!(
            select_music_section(&xml::parse(music).unwrap()).unwrap(),
            "7"
        );

        let none =
            r#"<MediaContainer><Directory key="1" type="movie" title="Movies" /></MediaContainer>"#;
        let error = select_music_section(&xml::parse(none).unwrap()).unwrap_err();
        assert_eq!(error.code, ErrorCode::NotFound);
    }

    #[test]
    fn parses_track_list() {
        let root = xml::parse(TRACKS).unwrap();
        let tracks: Vec<RemoteTrack> = root.children_named("Track").map(track_to_remote).collect();
        assert_eq!(tracks.len(), 2);

        assert_eq!(tracks[0].external_id, "1001");
        assert_eq!(tracks[0].title, "Bohemian Rhapsody");
        assert_eq!(tracks[0].artists, vec!["Queen".to_string()]);
        assert_eq!(tracks[0].album.as_deref(), Some("A Night at the Opera"));
        assert_eq!(tracks[0].duration_ms, 354_000);
        // ratingKey 本身就是封面 ID 的来源（父专辑优先）。
        assert_eq!(tracks[0].cover_id.as_deref(), Some("900"));
        assert_eq!(tracks[0].mbid_recording, None);

        // `<Track>` 上的 `mbid://` guid 直接当 MusicBrainz 录音 ID。
        assert_eq!(
            tracks[1].mbid_recording.as_deref(),
            Some("b1a9c0f4-1c1e-4f5a-9a4e-000000000001")
        );
        assert_eq!(tracks[1].duration_ms, 219_000);
    }

    #[test]
    fn mbid_from_guid_child_element() {
        let xml_text = r#"<MediaContainer><Track ratingKey="5" title="X" duration="1000">
            <Guid id="mbid://11111111-2222-3333-4444-555555555555" />
        </Track></MediaContainer>"#;
        let root = xml::parse(xml_text).unwrap();
        let track = track_to_remote(root.child("Track").unwrap());
        assert_eq!(
            track.mbid_recording.as_deref(),
            Some("11111111-2222-3333-4444-555555555555")
        );
    }

    #[test]
    fn incremental_cutoff_breaks_on_older_tracks() {
        // 模拟 list_tracks 的过滤逻辑：addedAt 倒序，遇到比 cutoff 老的就停。
        let root = xml::parse(TRACKS).unwrap();
        let cutoff_seconds = 1714600000i64; // 第一首歌加入的时间
        let mut kept = Vec::new();
        for track in root.children_named("Track") {
            if let Some(added) = track.attr_parse::<i64>("addedAt") {
                if added < cutoff_seconds {
                    break;
                }
            }
            kept.push(track_to_remote(track));
        }
        assert_eq!(kept.len(), 1, "只应保留 addedAt >= cutoff 的曲目");
        assert_eq!(kept[0].external_id, "1001");
    }

    #[test]
    fn extracts_part_key_for_streaming() {
        let root = xml::parse(TRACKS).unwrap();
        // 复刻 part_key() 的取法。
        let track = root
            .children
            .iter()
            .find(|child| matches_local(child, "Track"))
            .unwrap();
        let part = track
            .child("Media")
            .and_then(|media| media.child("Part"))
            .unwrap();
        assert_eq!(part.attr("key"), Some("part-key-3001"));
    }

    #[test]
    fn constructor_rejects_bad_arguments() {
        assert_eq!(
            Plex::new("192.168.1.10:32400", "t".into())
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            Plex::new("http://x:32400", "  ".into()).unwrap_err().code,
            ErrorCode::InvalidArgument
        );
        let plex = Plex::new("http://x:32400/", "abc".into()).unwrap();
        assert_eq!(plex.base_url, "http://x:32400");
        assert_eq!(plex.kind(), SourceKind::Plex);
    }

    #[test]
    fn token_stays_in_headers_not_url() {
        let plex = Plex::new("http://x:32400", "super-secret-token".into()).unwrap();
        let url = plex
            .url("/library/sections/3/all", &[("type", "10".to_string())])
            .unwrap();
        assert!(
            !url.as_str().contains("super-secret-token"),
            "token 不能出现在 URL 里：{url}"
        );
        let headers = plex.headers();
        assert!(headers
            .iter()
            .any(|(name, value)| *name == "X-Plex-Token" && value == "super-secret-token"));
        assert!(headers.iter().any(|(name, _)| *name == "Accept"));
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod server_lyrics_tests {
    use super::*;
    use std::io::{Read, Write};

    #[tokio::test]
    async fn lrc_stream_uses_plex_auth_and_rejects_external_key() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let task = std::thread::spawn(move || {
            for (expected, body) in [
                ("/library/metadata/42", "<MediaContainer><Track><Media><Part><Stream streamType=\"4\" format=\"lrc\" key=\"/library/parts/4/lyrics\"/></Part></Media></Track></MediaContainer>"),
                ("/library/parts/4/lyrics", "[00:01.00]Hello"),
                ("/library/metadata/43", "<MediaContainer><Track><Media><Part><Stream streamType=\"4\" format=\"lrc\" key=\"https://evil.invalid/lyrics\"/></Part></Media></Track></MediaContainer>"),
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buf = [0; 4096]; let count = stream.read(&mut buf).unwrap();
                let request = String::from_utf8_lossy(&buf[..count]).to_ascii_lowercase();
                assert!(request.starts_with(&format!("get {expected} ")));
                assert!(request.contains("x-plex-token: secret"));
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        let plex = Plex::new(&format!("http://{addr}"), "secret".into()).unwrap();
        let lyric = plex.lyrics("42").await.unwrap().unwrap();
        assert_eq!(lyric.format, LyricsFormat::Lrc);
        assert_eq!(lyric.content, "[00:01.00]Hello");
        assert!(plex.lyrics("43").await.is_err());
        task.join().unwrap();
    }

    #[tokio::test]
    async fn does_not_forward_plex_token_on_redirect() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let task = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0; 4096]; let _ = stream.read(&mut buf).unwrap();
            stream.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
        });
        let plex = Plex::new(&format!("http://{addr}"), "secret".into()).unwrap();
        assert!(plex.lyrics("42").await.is_err());
        task.join().unwrap();
    }
}
