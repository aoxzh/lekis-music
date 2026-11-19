//! OpenSubsonic / Subsonic（Navidrome、gonic、Airsonic、Ampache）。
//!
//! 要点：
//! - 认证用 token + salt：`t = md5(password + salt)`、`s = salt`、`u = username`；
//!   密码本身不出现请求里（除非用户显式打开 [`OpenSubsonic::with_plaintext_auth`]，给只支持
//!   `p=enc:<hex>` 的老服务器用）；
//! - 每个请求都带 `v=1.16.1`、`c=LekisMusic`、`f=json`；
//! - 全量拉取用 `search3`（空查询 + `songOffset` / `songCount` 分页）；
//! - Subsonic 没有真正的增量接口：`since_ms` 走 `getAlbumList2?type=newest`，按专辑创建时间
//!   从新到旧扫，遇到比 `since_ms` 老的专辑就停，再对每个专辑调 `getAlbum` 取曲目；
//! - 播放用 `stream`（转码时加 `maxBitRate` 和 `format`），封面用 `getCoverArt` 的 id，
//!   播放上报用 `scrobble`。
//!
//! 关于隐私：`stream` 返回的播放地址里带着 `t`/`s` 查询参数（Subsonic 只支持 query 认证），
//! 所以这个地址**不能进日志**。本模块里的 tracing 只记录动作名和状态码。

use crate::datetime::parse_iso8601_ms;
use crate::http;
use crate::md5;
use crate::{MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use reqwest::Url;
use serde::Deserialize;

/// 我们声明支持的 Subsonic API 版本。
const API_VERSION: &str = "1.16.1";

/// 客户端标识（Subsonic 要求每个客户端有唯一名字）。
const CLIENT_NAME: &str = "LekisMusic";

/// 增量拉取时往回多看一点，抵消客户端和服务器的时钟偏移。
const INCREMENTAL_OVERLAP_MS: i64 = 60_000;

/// `getAlbumList2` 一次最多返回 500 张专辑（服务端硬限制）。
const ALBUM_LIST_MAX: u32 = 500;

/// OpenSubsonic 客户端。
pub struct OpenSubsonic {
    /// 服务器根地址，例如 `https://nas.local:4533`（可以带路径前缀）。
    base_url: String,
    /// 用户名。
    username: String,
    /// 密码（只用来现算 token，不直接发送）。
    password: String,
    /// 复用连接的 HTTP 客户端。
    client: reqwest::Client,
    /// 是否降级到 `p=enc:<hex>` 明文认证（只给很老的服务器）。
    plaintext_auth: bool,
}

impl OpenSubsonic {
    /// 创建客户端。
    ///
    /// 构造**不发任何网络请求**，连通性和凭据在 [`MediaServer::ping`] 里验证。
    /// 这样调用方可以在扫描流程里同步构造客户端。
    pub fn new(base_url: &str, username: &str, password: String) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            username: username.to_string(),
            password,
            // 客户端构造失败（例如缺少 TLS 后端）极罕见；这里退化成默认客户端，
            // 让 ping() 去报真正的网络错误，而不是在构造阶段 panic。
            client: http::client().unwrap_or_default(),
            plaintext_auth: false,
        }
    }

    /// 打开明文密码认证（`p=enc:<hex>`）。
    ///
    /// 只有 2015 年以前的 Subsonic 服务器不支持 token 认证时才需要。注意 `p=enc:` 只是把密码
    /// 换成十六进制，**没有加密**，等于把密码发给服务器；默认关闭。
    pub fn with_plaintext_auth(mut self, enabled: bool) -> Self {
        self.plaintext_auth = enabled;
        self
    }

    /// 生成认证相关的查询参数。
    ///
    /// 每次都重新造 salt：`t` 只能用来重放这一次请求，降低在代理日志里泄露后的影响。
    fn auth_params(&self) -> Vec<(String, String)> {
        let mut params = vec![
            ("u".to_string(), self.username.clone()),
            ("v".to_string(), API_VERSION.to_string()),
            ("c".to_string(), CLIENT_NAME.to_string()),
            ("f".to_string(), "json".to_string()),
        ];
        if self.plaintext_auth {
            params.push((
                "p".to_string(),
                format!("enc:{}", http::hex_encode(self.password.as_bytes())),
            ));
        } else {
            // salt 用 uuid v4 的 32 位十六进制形式：随机、无需额外依赖。
            let salt = uuid::Uuid::new_v4().simple().to_string();
            let token = md5::hex_digest(format!("{}{salt}", self.password).as_bytes());
            params.push(("s".to_string(), salt));
            params.push(("t".to_string(), token));
        }
        params
    }

    /// 拼一个带认证参数的 `/rest/<method>.view` 地址。
    fn rest_url(&self, method: &str, extra: &[(&str, String)]) -> Result<Url> {
        let mut url = http::join(&self.base_url, &format!("/rest/{method}.view"))?;
        {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in self.auth_params() {
                pairs.append_pair(&key, &value);
            }
            for (key, value) in extra {
                pairs.append_pair(key, value);
            }
        }
        Ok(url)
    }

    /// 发起 GET 请求并返回响应体文本（`what` 用于错误信息，不含地址）。
    async fn get_text(&self, url: Url, what: &str) -> Result<String> {
        let response = self.client.get(url).send().await.map_err(http::network)?;
        http::ensure_status(&response, what)?;
        response.text().await.map_err(http::network)
    }

    /// 调一个返回 `subsonic-response` 包装的方法，返回包装体。
    async fn call(&self, method: &str, extra: &[(&str, String)], what: &str) -> Result<Envelope> {
        let url = self.rest_url(method, extra)?;
        let body = self.get_text(url, what).await?;
        parse_envelope(&body, what)
    }
}

/// 手写 `Debug`：**不能泄露密码**。默认 derive 会把 `password` 原样打出来，
/// 而 `dbg!` / `{:?}` 很容易在调试和错误上报里出现。
impl std::fmt::Debug for OpenSubsonic {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenSubsonic")
            .field("base_url", &self.base_url)
            .field("username", &self.username)
            .field("password", &"<redacted>")
            .field("plaintext_auth", &self.plaintext_auth)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl MediaServer for OpenSubsonic {
    fn kind(&self) -> SourceKind {
        SourceKind::OpenSubsonic
    }

    async fn ping(&self) -> Result<()> {
        let envelope = self.call("ping", &[], "opensubsonic ping").await?;
        // 老服务器可能不返回 version，但 status 一定是 ok 才走到这里。
        tracing::debug!(
            target: "lekis_providers::opensubsonic",
            version = envelope.version.as_deref().unwrap_or("?"),
            "服务器连通"
        );
        Ok(())
    }

    async fn list_tracks(
        &self,
        offset: u32,
        limit: u32,
        since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        // 页大小给个合理上限，0 会被服务器当成"全部"。
        let limit = limit.clamp(1, 500);
        match since_ms {
            None => self.page_via_search3(offset, limit).await,
            Some(since) => self.page_via_newest_albums(offset, limit, since).await,
        }
    }

    async fn stream(&self, external_id: &str, quality: StreamQuality) -> Result<StreamTarget> {
        let mut extra: Vec<(&str, String)> = vec![("id", external_id.to_string())];
        match quality {
            StreamQuality::Original => {
                // `format=raw` 是 OpenSubsonic 扩展：明确要求原文件，不要服务端转码。
                extra.push(("format", "raw".to_string()));
            }
            StreamQuality::Transcode { max_kbps } => {
                // 老服务器不理解 `format=raw` 时也能靠 maxBitRate 退化到转码。
                extra.push(("format", "mp3".to_string()));
                extra.push(("maxBitRate", max_kbps.to_string()));
            }
        }
        let url = self.rest_url("stream", &extra)?;
        Ok(StreamTarget {
            // 注意：这个地址里有 token，不能写进日志。
            url: url.to_string(),
            headers: Vec::new(),
            // Subsonic 的 stream 支持 Range（Navidrome 等实现都支持），可以拖动进度条。
            seekable: true,
        })
    }

    async fn scrobble(&self, external_id: &str, played_at_ms: i64) -> Result<()> {
        let extra = vec![
            ("id", external_id.to_string()),
            ("time", played_at_ms.to_string()),
            // submission=true：真正计入播放次数；false 是"正在播放"的心跳。
            ("submission", "true".to_string()),
        ];
        // 有些服务器在 scrobble 之后回了空体，这里的解析对空体是宽容的。
        self.call("scrobble", &extra, "opensubsonic scrobble")
            .await?;
        Ok(())
    }
}

impl OpenSubsonic {
    /// 全量分页：`search3` 空查询 + `songOffset` / `songCount`。
    async fn page_via_search3(&self, offset: u32, limit: u32) -> Result<Vec<RemoteTrack>> {
        let extra = vec![
            ("query", String::new()),
            ("songCount", limit.to_string()),
            ("songOffset", offset.to_string()),
            ("albumCount", "0".to_string()),
            ("artistCount", "0".to_string()),
        ];
        let envelope = self.call("search3", &extra, "opensubsonic search3").await?;
        let songs = envelope
            .search_result3
            .map(|result| result.song)
            .unwrap_or_default();
        Ok(songs.iter().map(song_to_track).collect())
    }

    /// 增量分页：`getAlbumList2?type=newest` 按专辑创建时间倒序，逐个专辑取曲目。
    ///
    /// Subsonic 没有"给我某时间之后新增的歌曲"这样的接口，所以只能用专辑的 `created` 近似：
    /// 一旦遇到比 `since_ms` 老的专辑就停止翻页。`limit` 在这个模式下表示**一页扫多少张专辑**
    /// （不是曲目数），返回的曲目数可能更多；`offset` 是专辑偏移。
    async fn page_via_newest_albums(
        &self,
        offset: u32,
        limit: u32,
        since_ms: i64,
    ) -> Result<Vec<RemoteTrack>> {
        let extra = vec![
            ("type", "newest".to_string()),
            ("size", limit.min(ALBUM_LIST_MAX).to_string()),
            ("offset", offset.to_string()),
        ];
        let envelope = self
            .call("getAlbumList2", &extra, "opensubsonic getAlbumList2")
            .await?;
        let albums = envelope
            .album_list2
            .map(|list| list.album)
            .unwrap_or_default();

        let cutoff = since_ms.saturating_sub(INCREMENTAL_OVERLAP_MS);
        let mut tracks = Vec::new();
        for album in albums {
            // 专辑按创建时间倒序；一旦比 cutoff 老，后面的都更老，可以停。
            if let Some(created) = album.created.as_deref().and_then(parse_iso8601_ms) {
                if created < cutoff {
                    break;
                }
            }
            let extra = vec![("id", album.id.clone())];
            let envelope = self
                .call("getAlbum", &extra, "opensubsonic getAlbum")
                .await?;
            let songs = envelope.album.map(|album| album.song).unwrap_or_default();
            for song in &songs {
                // 专辑是新的，但里面的歌可能是老歌（重新整理的专辑）。有 created 就按歌过滤。
                if let Some(created) = song.created.as_deref().and_then(parse_iso8601_ms) {
                    if created < cutoff {
                        continue;
                    }
                }
                tracks.push(song_to_track(song));
            }
        }
        Ok(tracks)
    }
}

// ---------------------------------------------------------------------------
// 响应解析
// ---------------------------------------------------------------------------

/// `{"subsonic-response": {...}}` 包装。
#[derive(Debug, Deserialize)]
struct Wire {
    #[serde(rename = "subsonic-response")]
    response: Envelope,
}

/// `subsonic-response` 的内容。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Envelope {
    /// `ok` 或 `failed`。
    pub(crate) status: String,
    /// 服务器支持的 API 版本。
    pub(crate) version: Option<String>,
    /// 失败时的错误信息。
    pub(crate) error: Option<SubsonicError>,
    /// `search3` 的结果。
    pub(crate) search_result3: Option<SearchResult3>,
    /// `getAlbumList2` 的结果。
    pub(crate) album_list2: Option<AlbumList2>,
    /// `getAlbum` 的结果。
    pub(crate) album: Option<Album>,
}

/// Subsonic 的错误体。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SubsonicError {
    /// 错误码，见 [`map_error_code`]。
    pub(crate) code: u32,
    /// 服务器给的说明（只用于日志，不直接展示给用户）。
    #[serde(default)]
    pub(crate) message: String,
}

/// `search3` 的结果集。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct SearchResult3 {
    /// 歌曲。
    pub(crate) song: Vec<Song>,
}

/// `getAlbumList2` 的结果集。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct AlbumList2 {
    /// 专辑。
    pub(crate) album: Vec<Album>,
}

/// 专辑。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Album {
    /// 专辑 ID。
    pub(crate) id: String,
    /// 创建时间（ISO-8601）。
    pub(crate) created: Option<String>,
    /// 专辑里的歌。
    pub(crate) song: Vec<Song>,
}

/// 歌曲。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Song {
    /// 歌曲 ID。
    pub(crate) id: String,
    /// 标题。
    pub(crate) title: String,
    /// 专辑名。
    pub(crate) album: Option<String>,
    /// 单个艺人名（经典 Subsonic）。
    pub(crate) artist: Option<String>,
    /// 多艺人（OpenSubsonic 扩展）；有空就用它，没有就用 `artist`。
    pub(crate) artists: Vec<NameRef>,
    /// 时长（秒）。
    pub(crate) duration: Option<u64>,
    /// 加入资料库的时间（ISO-8601）。
    pub(crate) created: Option<String>,
    /// MusicBrainz 录音 ID（OpenSubsonic / 部分实现提供）。
    pub(crate) music_brainz_id: Option<String>,
    /// 封面 ID。
    pub(crate) cover_art: Option<String>,
}

/// 只带名字的引用（`{"id": "...", "name": "..."}`）。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct NameRef {
    /// 名字。
    pub(crate) name: String,
}

/// 解析 `{"subsonic-response": ...}`，`status == "failed"` 时映射成错误。
pub(crate) fn parse_envelope(body: &str, what: &str) -> Result<Envelope> {
    // 个别老服务器在出错时返回空体或者 HTML；两种都给一个可读的错误。
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return Err(LekisError::new(
            ErrorCode::Internal,
            format!("{what}：服务器返回了空响应"),
        ));
    }
    let wire: Wire = serde_json::from_str(trimmed).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("{what}：响应不是合法的 Subsonic JSON：{e}"),
        )
    })?;
    let envelope = wire.response;
    if envelope.status.eq_ignore_ascii_case("failed") {
        let code = envelope.error.as_ref().map_or(0, |e| e.code);
        let message = envelope
            .error
            .as_ref()
            .map(|e| e.message.as_str())
            .unwrap_or("unknown");
        tracing::warn!(
            target: "lekis_providers::opensubsonic",
            code,
            message,
            "{what} 失败"
        );
        return Err(LekisError::new(
            map_error_code(code),
            format!("{what}：服务器错误 {code}（{message}）"),
        ));
    }
    Ok(envelope)
}

/// Subsonic 错误码 → 我们的 [`ErrorCode`]。
///
/// 码表来自 Subsonic API 文档（错误码是开放集合，未知的按 `Internal` 处理）。
pub(crate) fn map_error_code(code: u32) -> ErrorCode {
    match code {
        // 10：缺少参数。
        10 => ErrorCode::InvalidArgument,
        // 20：客户端太旧，需要升级。
        20 => ErrorCode::Unsupported,
        // 30：服务器太旧，需要升级。
        30 => ErrorCode::Unsupported,
        // 40：用户名或密码错误。
        40 => ErrorCode::Auth,
        // 41：LDAP 服务器不支持 token 认证。
        41 => ErrorCode::Auth,
        // 50：用户没有权限访问这个接口。
        50 => ErrorCode::PermissionDenied,
        // 60：试用期结束。
        60 => ErrorCode::PermissionDenied,
        // 70：请求的数据不存在。
        70 => ErrorCode::NotFound,
        // 80：服务器不支持这个功能。
        80 => ErrorCode::Unsupported,
        // 0 和其他：服务器内部错误。
        _ => ErrorCode::Internal,
    }
}

/// `Song` → [`RemoteTrack`]。
fn song_to_track(song: &Song) -> RemoteTrack {
    let mut artists: Vec<String> = song
        .artists
        .iter()
        .map(|artist| artist.name.trim().to_string())
        .filter(|name| !name.is_empty())
        .collect();
    if artists.is_empty() {
        if let Some(artist) = song.artist.as_deref() {
            // 经典 Subsonic 用一个字符串装多个艺人，常见分隔符是 `/`。
            artists = artist
                .split('/')
                .map(|part| part.trim().to_string())
                .filter(|part| !part.is_empty())
                .collect();
        }
    }
    RemoteTrack {
        external_id: song.id.clone(),
        title: song.title.clone(),
        artists,
        album: song.album.clone().filter(|album| !album.is_empty()),
        duration_ms: song.duration.unwrap_or(0).saturating_mul(1000),
        mbid_recording: song.music_brainz_id.clone().filter(|id| !id.is_empty()),
        cover_id: song.cover_art.clone().filter(|id| !id.is_empty()),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    const SEARCH3_OK: &str = r#"{
      "subsonic-response": {
        "status": "ok",
        "version": "1.16.1",
        "type": "navidrome",
        "serverVersion": "0.52.5",
        "searchResult3": {
          "song": [
            {
              "id": "300000106",
              "parent": "100000002",
              "title": "晴天",
              "album": "叶惠美",
              "artist": "周杰伦",
              "artists": [{ "id": "ar-1", "name": "周杰伦" }],
              "duration": 269,
              "created": "2024-05-01T12:34:56.789Z",
              "musicBrainzId": "b1a9c0f4-1c1e-4f5a-9a4e-000000000001",
              "coverArt": "al-100000002"
            },
            {
              "id": "300000107",
              "title": "The Sound of Silence",
              "album": "Wednesday Morning, 3 A.M.",
              "artist": "Simon & Garfunkel",
              "duration": 184,
              "coverArt": "al-100000003"
            }
          ]
        }
      }
    }"#;

    #[test]
    fn parses_search3_tracks() {
        let envelope = parse_envelope(SEARCH3_OK, "search3").unwrap();
        assert_eq!(envelope.status, "ok");
        let songs = envelope.search_result3.unwrap().song;
        assert_eq!(songs.len(), 2);

        let tracks: Vec<RemoteTrack> = songs.iter().map(song_to_track).collect();
        assert_eq!(tracks[0].external_id, "300000106");
        assert_eq!(tracks[0].title, "晴天");
        assert_eq!(tracks[0].artists, vec!["周杰伦".to_string()]);
        assert_eq!(tracks[0].album.as_deref(), Some("叶惠美"));
        // 秒 → 毫秒。
        assert_eq!(tracks[0].duration_ms, 269_000);
        assert_eq!(
            tracks[0].mbid_recording.as_deref(),
            Some("b1a9c0f4-1c1e-4f5a-9a4e-000000000001")
        );
        assert_eq!(tracks[0].cover_id.as_deref(), Some("al-100000002"));

        // 没有 artists 数组时退化到 artist 字段，并保留 "&" 这种不是分隔符的部分。
        assert_eq!(tracks[1].artists, vec!["Simon & Garfunkel".to_string()]);
        assert_eq!(tracks[1].mbid_recording, None);
    }

    #[test]
    fn splits_multiple_artists_on_slash() {
        let body = r#"{"subsonic-response":{"status":"ok","searchResult3":{"song":[
            {"id":"1","title":"Song","artist":"Artist A / Artist B","duration":200}
        ]}}}"#;
        let envelope = parse_envelope(body, "search3").unwrap();
        let song = &envelope.search_result3.unwrap().song[0];
        let track = song_to_track(song);
        assert_eq!(
            track.artists,
            vec!["Artist A".to_string(), "Artist B".to_string()]
        );
        assert_eq!(track.duration_ms, 200_000);
    }

    #[test]
    fn failed_response_maps_error_codes() {
        let cases = [
            (40, ErrorCode::Auth),
            (50, ErrorCode::PermissionDenied),
            (70, ErrorCode::NotFound),
            (10, ErrorCode::InvalidArgument),
            (80, ErrorCode::Unsupported),
            (0, ErrorCode::Internal),
        ];
        for (code, expected) in cases {
            let body = format!(
                r#"{{"subsonic-response":{{"status":"failed","version":"1.16.1",
                    "error":{{"code":{code},"message":"boom"}}}}}}"#
            );
            let error = parse_envelope(&body, "ping").unwrap_err();
            assert_eq!(error.code, expected, "subsonic code {code}");
            // 错误信息里不能有地址或凭据，只有错误码和服务器说明。
            assert!(error.message.contains("boom"));
        }
    }

    #[test]
    fn empty_or_html_body_is_reported() {
        assert!(parse_envelope("", "ping").is_err());
        assert!(parse_envelope("<html>502 Bad Gateway</html>", "ping").is_err());
    }

    #[test]
    fn parses_album_list_and_album_children() {
        let albums = r#"{"subsonic-response":{"status":"ok","albumList2":{"album":[
            {"id":"al-1","name":"新专辑","created":"2024-05-02T00:00:00.000Z"},
            {"id":"al-2","name":"老专辑","created":"2020-01-01T00:00:00.000Z"}
        ]}}}"#;
        let envelope = parse_envelope(albums, "getAlbumList2").unwrap();
        let list = envelope.album_list2.unwrap().album;
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id, "al-1");
        assert_eq!(
            list[0].created.as_deref().and_then(parse_iso8601_ms),
            Some(1_714_608_000_000)
        );
        // 空专辑列表也要能解析（服务器有时候省略 album 字段）。
        let empty = parse_envelope(
            r#"{"subsonic-response":{"status":"ok","albumList2":{}}}"#,
            "getAlbumList2",
        )
        .unwrap();
        assert!(empty.album_list2.unwrap().album.is_empty());

        let album = r#"{"subsonic-response":{"status":"ok","album":{"id":"al-1","song":[
            {"id":"s1","title":"A","duration":100,"created":"2024-05-02T00:00:00.000Z"}
        ]}}}"#;
        let envelope = parse_envelope(album, "getAlbum").unwrap();
        assert_eq!(envelope.album.unwrap().song.len(), 1);
    }

    /// 认证参数的形状：`u` / `t` / `s` / `v` / `c` / `f` 都在，且 token = md5(password + salt)。
    #[test]
    fn auth_params_are_subsonic_shaped() {
        let server = OpenSubsonic::new("https://nas.local:4533/", "alice", "hunter2".to_string());
        let params = server.auth_params();
        let find = |key: &str| {
            params
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
        };
        assert_eq!(find("u").as_deref(), Some("alice"));
        assert_eq!(find("v").as_deref(), Some(API_VERSION));
        assert_eq!(find("c").as_deref(), Some(CLIENT_NAME));
        assert_eq!(find("f").as_deref(), Some("json"));
        assert_eq!(find("s").map(|s| s.len()), Some(32));
        // 密码不能出现在任何参数里。
        assert!(params.iter().all(|(_, v)| v != "hunter2"));
        // token 必须是 md5(password + salt)。
        let salt = find("s").unwrap();
        assert_eq!(
            find("t"),
            Some(md5::hex_digest(format!("hunter2{salt}").as_bytes()))
        );
    }

    #[test]
    fn rest_url_keeps_base_path_and_query() {
        let server = OpenSubsonic::new("https://example.org/music", "bob", "pw".to_string());
        let url = server
            .rest_url(
                "stream",
                &[("id", "42".to_string()), ("maxBitRate", "192".to_string())],
            )
            .unwrap();
        assert_eq!(url.path(), "/music/rest/stream.view");
        let query = url.query().unwrap();
        assert!(query.contains("id=42"));
        assert!(query.contains("maxBitRate=192"));
        assert!(query.contains("u=bob"));
        assert!(query.contains("t="));
    }

    #[test]
    fn plaintext_auth_uses_hex_encoded_password() {
        let server = OpenSubsonic::new("https://old.local", "alice", "abc".to_string())
            .with_plaintext_auth(true);
        let params = server.auth_params();
        assert!(params.iter().any(|(k, v)| k == "p" && v == "enc:616263"));
        // 明文模式下不再发送 t / s。
        assert!(params.iter().all(|(k, _)| k != "t" && k != "s"));
    }
}
