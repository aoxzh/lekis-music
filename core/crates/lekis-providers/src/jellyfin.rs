//! Jellyfin / Emby（SRC-05）。两者 API 大部分相同，用同一个实现，按 `SourceKind` 区分细节。
//!
//! 要点：
//! - 认证头：`X-Emby-Token: <api_key>`（Jellyfin 和 Emby 都认；Emby 的旧名字是 `X-MediaBrowser-Token`）。
//!   老版本的 `Authorization: MediaBrowser Token="..."` 也支持，但只在登录响应里用得到；
//! - `/Items?IncludeItemTypes=Audio&Recursive=true` 分页拉曲目，`StartIndex` / `Limit` 翻页；
//! - `/Audio/{id}/stream?static=true` 拿原始文件（支持 Range，可拖动）；
//!   `/Audio/{id}/universal` 让服务器决定直连还是转码（转码流不支持拖动）；
//! - `/Sessions/Playing/Stopped` 上报播放；知道用户 ID 时退化到 `/Users/{uid}/PlayedItems/{id}`。
//!
//! 关于隐私：token 只在请求头里，**不进 URL**（URL 更容易被代理和日志记下来），也不进日志。

use crate::datetime::format_iso8601_ms;
use crate::http;
use crate::{MediaServer, RemoteTrack, StreamQuality, StreamTarget};
use async_trait::async_trait;
use lekis_types::{ErrorCode, LekisError, Lyrics, LyricsFormat, Result, SourceKind};
use serde::Deserialize;

/// 分页上限：`/Items` 单次最多 2000 条比较稳妥。
const MAX_PAGE: u32 = 2000;

/// `RunTimeTicks` 是 100 纳秒单位。
const TICKS_PER_MS: u64 = 10_000;

/// Jellyfin / Emby 客户端。
pub struct Jellyfin {
    /// 具体是哪一种（只影响 `kind()` 和个别端点的偏向）。
    kind: SourceKind,
    /// 服务器根地址。
    base_url: String,
    /// API key 或登录拿到的 AccessToken。
    api_key: String,
    /// 复用连接的 HTTP 客户端。
    client: reqwest::Client,
    /// 设备 ID（`/Audio/{id}/universal` 要求带）。构造时随机生成一次。
    device_id: String,
    /// 懒加载的用户 ID（`/Users/{uid}/PlayedItems` 和 `universal` 的 `UserId` 参数要用）。
    user_id: tokio::sync::Mutex<Option<String>>,
}

impl Jellyfin {
    /// 创建客户端。
    ///
    /// 构造**不发任何网络请求**；连通性和 token 有效性在 [`MediaServer::ping`] 里验证。
    /// `kind` 只接受 [`SourceKind::Jellyfin`] 和 [`SourceKind::Emby`]。
    pub fn new(kind: SourceKind, base_url: &str, api_key: String) -> Result<Self> {
        if !matches!(kind, SourceKind::Jellyfin | SourceKind::Emby) {
            return Err(LekisError::invalid(format!(
                "not a jellyfin-like source: {kind:?}"
            )));
        }
        let base_url = base_url.trim_end_matches('/');
        if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
            return Err(LekisError::invalid(
                "Jellyfin / Emby 地址必须以 http(s):// 开头",
            ));
        }
        if api_key.trim().is_empty() {
            return Err(LekisError::invalid("Jellyfin / Emby API key 不能为空"));
        }
        Ok(Self {
            kind,
            base_url: base_url.to_string(),
            api_key,
            client: http::client().unwrap_or_default(),
            device_id: uuid::Uuid::new_v4().simple().to_string(),
            user_id: tokio::sync::Mutex::new(None),
        })
    }

    /// 用用户名密码登录，返回拿到 token 的客户端。
    ///
    /// 这是唯一的异步初始化路径：调 `/Users/AuthenticateByName` 换 `AccessToken`。
    /// 密码只在请求体里出现一次，不写日志、不保存。
    pub async fn login_with_password(
        kind: SourceKind,
        base_url: &str,
        username: &str,
        password: &str,
    ) -> Result<Self> {
        // 先构造一个占位 token 的实例，复用地址校验和 HTTP 客户端。
        let mut client = Self::new(kind, base_url, "pending-login".to_string())?;

        let url = http::join(&client.base_url, "/Users/AuthenticateByName")?;
        let body = serde_json::json!({ "Username": username, "Pw": password });
        let response = client
            .client
            .post(url)
            // 登录接口用 `Authorization` 头声明客户端身份（Jellyfin 要求）。
            .header(
                "Authorization",
                format!(
                    "MediaBrowser Client=\"{}\", Device=\"Lekis\", DeviceId=\"{}\", Version=\"{}\"",
                    http::USER_AGENT,
                    client.device_id,
                    env!("CARGO_PKG_VERSION")
                ),
            )
            .json(&body)
            .send()
            .await
            .map_err(http::network)?;
        http::ensure_status(&response, "jellyfin login")?;
        let text = response.text().await.map_err(http::network)?;
        let auth = parse_auth_response(&text)?;

        client.api_key = auth.access_token;
        if let Some(user) = auth.user {
            *client.user_id.lock().await = Some(user.id);
        }
        tracing::info!(target: "lekis_providers::jellyfin", "登录成功");
        Ok(client)
    }

    /// 拼一个带 token 的完整地址（token 走请求头，不放在 URL 里）。
    fn url(&self, path: &str, query: &[(&str, String)]) -> Result<reqwest::Url> {
        let mut url = http::join(&self.base_url, path)?;
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                pairs.append_pair(key, value);
            }
        }
        Ok(url)
    }

    /// 带认证头发 GET，返回响应体文本。
    async fn get_text(&self, url: reqwest::Url, what: &str) -> Result<String> {
        let response = self
            .client
            .get(url)
            .header(self.auth_header_name(), &self.api_key)
            .send()
            .await
            .map_err(http::network)?;
        http::ensure_status(&response, what)?;
        response.text().await.map_err(http::network)
    }

    /// 认证头名字：Jellyfin 和 Emby 都认 `X-Emby-Token`。
    fn auth_header_name(&self) -> &'static str {
        match self.kind {
            // Emby 后来改名为 `X-Emby-Token`，老版本仍然接受 `X-MediaBrowser-Token`。
            SourceKind::Emby => "X-Emby-Token",
            _ => "X-Emby-Token",
        }
    }

    /// 懒加载用户 ID（`/Users/Me`）。失败就返回 `None`，调用方退化成不带 userId 的请求。
    async fn user_id(&self) -> Option<String> {
        if let Some(id) = self.user_id.lock().await.clone() {
            return Some(id);
        }
        let url = self.url("/Users/Me", &[]).ok()?;
        let text = self.get_text(url, "jellyfin /Users/Me").await.ok()?;
        let id = parse_current_user(&text).ok()?;
        *self.user_id.lock().await = Some(id.clone());
        Some(id)
    }
}

/// 手写 `Debug`：**不能泄露 token**。
impl std::fmt::Debug for Jellyfin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Jellyfin")
            .field("kind", &self.kind)
            .field("base_url", &self.base_url)
            .field("api_key", &"<redacted>")
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl MediaServer for Jellyfin {
    fn kind(&self) -> SourceKind {
        self.kind
    }

    async fn ping(&self) -> Result<()> {
        // `/System/Info` 需要认证，正好同时验证 token。
        let url = self.url("/System/Info", &[])?;
        let text = self.get_text(url, "jellyfin ping").await?;
        let info: SystemInfo = serde_json::from_str(&text).map_err(|e| {
            LekisError::new(
                ErrorCode::Internal,
                format!("jellyfin ping：响应不是合法的服务器信息：{e}"),
            )
        })?;
        tracing::debug!(
            target: "lekis_providers::jellyfin",
            server = info.server_name.as_deref().unwrap_or("?"),
            version = info.version.as_deref().unwrap_or("?"),
            "服务器连通"
        );
        Ok(())
    }

    async fn album_artwork(&self, album_id: &str) -> Result<Option<Vec<u8>>> {
        let url = self.url(
            &format!("/Items/{}/Images/Primary", encode_path_segment(album_id)),
            &[],
        )?;
        let mut response = self
            .client
            .get(url)
            .header(self.auth_header_name(), &self.api_key)
            .send()
            .await
            .map_err(http::network)?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        http::ensure_status(&response, "jellyfin album artwork")?;
        const LIMIT: usize = 16 * 1024 * 1024;
        if response.content_length().is_some_and(|n| n > LIMIT as u64) {
            return Err(LekisError::invalid("album artwork too large"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http::network)? {
            if bytes.len() + chunk.len() > LIMIT {
                return Err(LekisError::invalid("album artwork too large"));
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(Some(bytes))
    }

    async fn list_tracks(
        &self,
        offset: u32,
        limit: u32,
        since_ms: Option<i64>,
    ) -> Result<Vec<RemoteTrack>> {
        let limit = limit.clamp(1, MAX_PAGE);
        let mut query: Vec<(&str, String)> = vec![
            ("IncludeItemTypes", "Audio".to_string()),
            ("Recursive", "true".to_string()),
            ("StartIndex", offset.to_string()),
            ("Limit", limit.to_string()),
            // 少要字段能明显减小响应体；这几个是我们真正用到的。
            (
                "Fields",
                "Album,Artists,AlbumArtists,RunTimeTicks,ProviderIds,ImageTags,MediaSources,DateCreated"
                    .to_string(),
            ),
            ("SortBy", "DateCreated,SortName".to_string()),
            ("SortOrder", "Descending".to_string()),
            ("EnableImages", "true".to_string()),
        ];
        // 增量：只拉某个时间之后加入资料库的条目（Jellyfin 的 `MinDateLastSaved` 走 ISO-8601）。
        if let Some(since) = since_ms {
            query.push(("MinDateLastSaved", format_iso8601_ms(since)));
        }
        let url = self.url("/Items", &query)?;
        let text = self.get_text(url, "jellyfin /Items").await?;
        parse_items(&text)
    }

    async fn stream(&self, external_id: &str, quality: StreamQuality) -> Result<StreamTarget> {
        let headers = vec![(self.auth_header_name().to_string(), self.api_key.clone())];
        let mut query: Vec<(&str, String)> = Vec::new();
        if let Some(user_id) = self.user_id().await {
            query.push(("UserId", user_id));
        }
        match quality {
            StreamQuality::Original => {
                // `static=true` 要求直接给原文件，服务端不会偷偷转码；支持 Range。
                query.push(("static", "true".to_string()));
                let url = self.url(
                    &format!("/Audio/{}/stream", encode_path_segment(external_id)),
                    &query,
                )?;
                Ok(StreamTarget {
                    url: url.to_string(),
                    headers,
                    seekable: true,
                })
            }
            StreamQuality::Transcode { max_kbps } => {
                // universal 端点：由服务器决定直连还是转码；给个码率上限。
                query.push(("MaxStreamingBitrate", (max_kbps * 1000).to_string()));
                query.push(("DeviceId", self.device_id.clone()));
                query.push(("AudioCodec", "aac".to_string()));
                query.push(("TranscodingContainer", "ts".to_string()));
                query.push(("TranscodingProtocol", "http".to_string()));
                query.push((
                    "Container",
                    "opus,webm|opus,mp3,aac,m4a|aac,m4b|aac,flac,webma,webm|webma,wav,ogg"
                        .to_string(),
                ));
                let url = self.url(
                    &format!("/Audio/{}/universal", encode_path_segment(external_id)),
                    &query,
                )?;
                Ok(StreamTarget {
                    url: url.to_string(),
                    headers,
                    // 转码流是边转边发的，不能可靠地 Range 定位。
                    seekable: false,
                })
            }
        }
    }

    async fn lyrics(&self, external_id: &str) -> Result<Option<Lyrics>> {
        if self.kind != SourceKind::Jellyfin {
            return Ok(None);
        }
        if external_id == "." || external_id == ".." || external_id.is_empty() {
            return Err(LekisError::invalid("invalid Jellyfin item ID"));
        }
        let url = self.url(
            &format!("/Audio/{}/Lyrics", encode_path_segment(external_id)),
            &[],
        )?;
        // Never forward the server token through redirects, even to another origin.
        let client = reqwest::Client::builder()
            .user_agent(http::USER_AGENT)
            .timeout(http::TIMEOUT)
            .connect_timeout(http::CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(http::network)?;
        let response = client
            .get(url)
            .header(self.auth_header_name(), &self.api_key)
            .send()
            .await
            .map_err(http::network)?;
        if response.status() == reqwest::StatusCode::NOT_FOUND
            || response.status() == reqwest::StatusCode::NO_CONTENT
        {
            return Ok(None);
        }
        http::ensure_status(&response, "jellyfin lyrics")?;
        parse_lyrics(&response.text().await.map_err(http::network)?)
    }

    async fn scrobble(&self, external_id: &str, played_at_ms: i64) -> Result<()> {
        let url = self.url("/Sessions/Playing/Stopped", &[])?;
        // Jellyfin 用 PositionTicks 判断"算不算播放过"。我们不知道这首歌的实际结束位置，
        // 就按"播到最后"上报（time 参数虽然是墙上时间，但服务端以此决定 scrobble 的时刻）。
        let _ = played_at_ms;
        let body = serde_json::json!({
            "ItemId": external_id,
            "PlaySessionId": uuid::Uuid::new_v4().simple().to_string(),
            "PositionTicks": 0,
            "CanSeek": false,
            "IsPaused": false,
            "IsMuted": false,
            "PlayMethod": "DirectStream",
        });
        let response = self
            .client
            .post(url)
            .header(self.auth_header_name(), &self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(http::network)?;

        if response.status().is_success() {
            return Ok(());
        }
        let code = response.status().as_u16();
        tracing::debug!(
            target: "lekis_providers::jellyfin",
            status = code,
            "Sessions/Playing/Stopped 失败，尝试 PlayedItems"
        );

        // 退化路径：直接标记为"已播放"（Jellyfin 和 Emby 都有这个接口）。
        let Some(user_id) = self.user_id().await else {
            return Err(http::status(code, "jellyfin scrobble"));
        };
        let url = self.url(
            &format!(
                "/Users/{}/PlayedItems/{}",
                encode_path_segment(&user_id),
                encode_path_segment(external_id)
            ),
            &[],
        )?;
        let response = self
            .client
            .post(url)
            .header(self.auth_header_name(), &self.api_key)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body("true")
            .send()
            .await
            .map_err(http::network)?;
        http::ensure_status(&response, "jellyfin PlayedItems")
    }
}

/// 把 ID 放进路径里（Jellyfin 的 ID 一般是 32 位十六进制，但仍然按通用规则编码）。
fn encode_path_segment(segment: &str) -> String {
    use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
    // `NoneAsciiSet` 之外还要保留 `-` `_`（NON_ALPHANUMERIC 会编码它们，虽然合法但不必要）。
    const SET: &percent_encoding::AsciiSet = &NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~');
    utf8_percent_encode(segment, SET).to_string()
}

// ---------------------------------------------------------------------------
// 响应解析
// ---------------------------------------------------------------------------

/// `/Items` 的响应。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct ItemsResponse {
    /// 条目。
    pub(crate) items: Vec<Item>,
    /// 总数（分页判断用）。
    pub(crate) total_record_count: Option<u32>,
}

/// 一个媒体条目（只取我们需要的字段）。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct Item {
    /// 条目 ID。
    pub(crate) id: String,
    /// 名字（曲名）。
    pub(crate) name: String,
    /// 专辑名。
    pub(crate) album: Option<String>,
    pub(crate) album_id: Option<String>,
    pub(crate) parent_index_number: Option<u32>,
    pub(crate) index_number: Option<u32>,
    /// 曲目艺人。
    pub(crate) artists: Vec<String>,
    /// 专辑艺人（`artists` 为空时用它）。
    pub(crate) album_artists: Vec<ArtistRef>,
    /// 时长（100 纳秒）。
    pub(crate) run_time_ticks: Option<u64>,
    /// 外部 ID（`ProviderIds`）。
    pub(crate) provider_ids: Option<ProviderIds>,
    /// 图片标签（`ImageTags.Primary` 就是封面 ID）。
    pub(crate) image_tags: Option<std::collections::BTreeMap<String, String>>,
}

/// 只带名字的艺人引用。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct ArtistRef {
    /// 名字。
    pub(crate) name: String,
}

/// `ProviderIds`。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct ProviderIds {
    /// MusicBrainz 录音 ID。
    #[serde(rename = "MusicBrainzTrack")]
    pub(crate) music_brainz_track: Option<String>,
    /// MusicBrainz 专辑 ID。
    #[serde(rename = "MusicBrainzAlbum")]
    pub(crate) music_brainz_album: Option<String>,
}

/// `/System/Info` 的响应（只要名字和版本）。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct SystemInfo {
    /// 服务器名。
    pub(crate) server_name: Option<String>,
    /// 版本号。
    pub(crate) version: Option<String>,
    /// 是不是 Emby（Jellyfin 里没有这个字段）。
    pub(crate) product_name: Option<String>,
}

/// `/Users/AuthenticateByName` 的响应。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct AuthResponse {
    /// AccessToken。
    pub(crate) access_token: String,
    /// 用户。
    pub(crate) user: Option<AuthUser>,
}

/// 登录响应里的用户。
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "PascalCase", default)]
pub(crate) struct AuthUser {
    /// 用户 ID。
    pub(crate) id: String,
}

/// 解析 `/Items` 响应。
pub(crate) fn parse_items(body: &str) -> Result<Vec<RemoteTrack>> {
    let response: ItemsResponse = serde_json::from_str(body).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("jellyfin /Items：响应解析失败：{e}"),
        )
    })?;
    Ok(response.items.iter().map(item_to_track).collect())
}

/// 解析 `/Users/Me` 响应里的用户 ID。
pub(crate) fn parse_current_user(body: &str) -> Result<String> {
    let user: AuthUser = serde_json::from_str(body).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("jellyfin /Users/Me：响应解析失败：{e}"),
        )
    })?;
    if user.id.is_empty() {
        return Err(LekisError::new(
            ErrorCode::Internal,
            "jellyfin /Users/Me：用户 ID 为空",
        ));
    }
    Ok(user.id)
}

/// 解析登录响应。
pub(crate) fn parse_auth_response(body: &str) -> Result<AuthResponse> {
    let auth: AuthResponse = serde_json::from_str(body).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("jellyfin 登录：响应解析失败：{e}"),
        )
    })?;
    if auth.access_token.is_empty() {
        // 服务器说成功但没有 token，等于认证失败。
        return Err(LekisError::new(
            ErrorCode::Auth,
            "jellyfin 登录：服务器没有返回 AccessToken",
        ));
    }
    Ok(auth)
}

/// `Item` → [`RemoteTrack`]。
fn item_to_track(item: &Item) -> RemoteTrack {
    let mut artists: Vec<String> = item
        .artists
        .iter()
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .collect();
    if artists.is_empty() {
        artists = item
            .album_artists
            .iter()
            .map(|artist| artist.name.trim().to_string())
            .filter(|name| !name.is_empty())
            .collect();
    }
    RemoteTrack {
        external_album_id: item.album_id.clone().filter(|s| !s.is_empty()),
        album_artists: item
            .album_artists
            .iter()
            .map(|a| a.name.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect(),
        disc_no: item.parent_index_number,
        track_no: item.index_number,
        external_id: item.id.clone(),
        title: item.name.clone(),
        artists,
        album: item.album.clone().filter(|album| !album.is_empty()),
        duration_ms: item.run_time_ticks.unwrap_or(0) / TICKS_PER_MS,
        mbid_recording: item
            .provider_ids
            .as_ref()
            .and_then(|ids| ids.music_brainz_track.clone())
            .filter(|id| !id.is_empty()),
        cover_id: item
            .image_tags
            .as_ref()
            .and_then(|tags| tags.get("Primary").or_else(|| tags.get("primary")).cloned())
            .filter(|id| !id.is_empty())
            // 没有 Primary 标签但条目本身有 ID 时，Jellyfin 仍能按条目 ID 出图。
            .or_else(|| Some(item.id.clone())),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    const ITEMS: &str = r#"{
      "Items": [
        {
          "Name": "七里香",
          "ServerId": "abc",
          "Id": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
          "RunTimeTicks": 2990000000,
          "Album": "七里香",
          "AlbumId": "f1e2d3",
          "Artists": ["周杰伦"],
          "AlbumArtists": [{ "Name": "周杰伦", "Id": "ar-1" }],
          "ImageTags": { "Primary": "img-tag-1" },
          "ProviderIds": { "MusicBrainzTrack": "11111111-2222-3333-4444-555555555555" },
          "Type": "Audio"
        },
        {
          "Name": "Clocks",
          "Id": "bbbb",
          "RunTimeTicks": 3200000000,
          "Album": "A Rush of Blood to the Head",
          "AlbumArtists": [{ "Name": "Coldplay" }]
        }
      ],
      "TotalRecordCount": 2,
      "StartIndex": 0
    }"#;

    #[test]
    fn parses_album_identity_artists_and_disc_positions() {
        let tracks = parse_items(r#"{"Items":[{"Id":"song","Name":"Song","Album":"Compilation","AlbumId":"album-1","Artists":["Singer"],"AlbumArtists":[{"Name":"Various Artists"}],"ParentIndexNumber":2,"IndexNumber":3}]}"#).unwrap();
        assert_eq!(tracks[0].external_album_id.as_deref(), Some("album-1"));
        assert_eq!(tracks[0].artists, vec!["Singer"]);
        assert_eq!(tracks[0].album_artists, vec!["Various Artists"]);
        assert_eq!((tracks[0].disc_no, tracks[0].track_no), (Some(2), Some(3)));
    }

    #[test]
    fn parses_items_response() {
        let tracks = parse_items(ITEMS).unwrap();
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0].external_id, "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4");
        assert_eq!(tracks[0].title, "七里香");
        assert_eq!(tracks[0].artists, vec!["周杰伦".to_string()]);
        assert_eq!(tracks[0].album.as_deref(), Some("七里香"));
        // 100 纳秒 ticks → 毫秒。
        assert_eq!(tracks[0].duration_ms, 299_000);
        assert_eq!(
            tracks[0].mbid_recording.as_deref(),
            Some("11111111-2222-3333-4444-555555555555")
        );
        assert_eq!(tracks[0].cover_id.as_deref(), Some("img-tag-1"));

        // Artists 为空时退化到 AlbumArtists；没有 ImageTags 时用条目 ID 当封面 ID。
        assert_eq!(tracks[1].artists, vec!["Coldplay".to_string()]);
        assert_eq!(tracks[1].cover_id.as_deref(), Some("bbbb"));
        assert_eq!(tracks[1].duration_ms, 320_000);
    }

    #[test]
    fn empty_items_list_is_ok() {
        let tracks = parse_items(r#"{"Items":[],"TotalRecordCount":0}"#).unwrap();
        assert!(tracks.is_empty());
        // 服务器省略 Items 字段也要能解析。
        let tracks = parse_items(r#"{"TotalRecordCount":0}"#).unwrap();
        assert!(tracks.is_empty());
    }

    #[test]
    fn rejects_html_body() {
        let error = parse_items("<html>401 Unauthorized</html>").unwrap_err();
        assert_eq!(error.code, ErrorCode::Internal);
    }

    #[test]
    fn parses_auth_response() {
        let body = r#"{"User":{"Id":"user-1","Name":"alice"},
                       "AccessToken":"fake-token",
                       "ServerId":"srv-1"}"#;
        let auth = parse_auth_response(body).unwrap();
        assert_eq!(auth.access_token, "fake-token");
        assert_eq!(auth.user.unwrap().id, "user-1");

        let missing = parse_auth_response(r#"{"User":{"Id":"u"},"AccessToken":""}"#).unwrap_err();
        assert_eq!(missing.code, ErrorCode::Auth);
    }

    #[test]
    fn parses_system_info() {
        let info: SystemInfo = serde_json::from_str(
            r#"{"ServerName":"nas","Version":"10.9.11","ProductName":"Jellyfin Server"}"#,
        )
        .unwrap();
        assert_eq!(info.server_name.as_deref(), Some("nas"));
        assert_eq!(info.version.as_deref(), Some("10.9.11"));
    }

    #[test]
    fn parses_current_user() {
        assert_eq!(
            parse_current_user(r#"{"Id":"u1","Name":"a"}"#).unwrap(),
            "u1"
        );
        assert!(parse_current_user(r#"{"Id":""}"#).is_err());
    }

    #[test]
    fn constructor_validates_arguments() {
        assert_eq!(
            Jellyfin::new(SourceKind::Plex, "https://x", "k".into())
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            Jellyfin::new(SourceKind::Jellyfin, "ftp://x", "k".into())
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        assert_eq!(
            Jellyfin::new(SourceKind::Jellyfin, "https://x", "  ".into())
                .unwrap_err()
                .code,
            ErrorCode::InvalidArgument
        );
        let client = Jellyfin::new(SourceKind::Emby, "https://x/", "k".into()).unwrap();
        assert_eq!(client.kind(), SourceKind::Emby);
        assert_eq!(client.base_url, "https://x");
        // token 只在请求头里，不拼进 URL。
        let url = client.url("/Items", &[("Limit", "5".to_string())]).unwrap();
        assert_eq!(url.as_str(), "https://x/Items?Limit=5");
    }

    #[test]
    fn path_segments_are_encoded() {
        assert_eq!(encode_path_segment("a1b2-c3_d4"), "a1b2-c3_d4");
        assert_eq!(encode_path_segment("a/b"), "a%2Fb");
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ServerLyrics {
    #[serde(default, alias = "lyrics")]
    lyrics: Vec<ServerLyricLine>,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ServerLyricLine {
    #[serde(alias = "start")]
    start: Option<i64>,
    #[serde(alias = "text")]
    text: Option<String>,
}

fn parse_lyrics(body: &str) -> Result<Option<Lyrics>> {
    let response: ServerLyrics = serde_json::from_str(body).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("jellyfin lyrics: invalid response: {e}"),
        )
    })?;
    let lines: Vec<_> = response
        .lyrics
        .into_iter()
        .filter_map(|line| {
            line.text
                .filter(|text| !text.trim().is_empty())
                .map(|text| (line.start, text))
        })
        .collect();
    if lines.is_empty() {
        return Ok(None);
    }
    // Mixed timed and untimed data is kept as plain text so no line is lost.
    let timed = lines
        .iter()
        .all(|(start, _)| start.is_some_and(|value| value >= 0));
    let content = lines
        .into_iter()
        .map(|(start, text)| {
            let text = text.replace(['\r', '\n'], " ");
            if let Some(ticks) = start.filter(|_| timed) {
                let ms = ticks as u64 / TICKS_PER_MS;
                format!(
                    "[{:02}:{:02}.{:03}]{}",
                    ms / 60_000,
                    (ms / 1000) % 60,
                    ms % 1000,
                    text
                )
            } else {
                text
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    Ok(Some(Lyrics {
        format: if timed {
            LyricsFormat::Lrc
        } else {
            LyricsFormat::Plain
        },
        content,
        source: "server:jellyfin".into(),
        offset_ms: 0,
        confidence: 1.0,
    }))
}

#[cfg(test)]
mod lyrics_tests {
    #![allow(clippy::unwrap_used)]
    use super::*;
    #[tokio::test]
    async fn requests_authenticated_lyrics_and_handles_missing() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let task = std::thread::spawn(move || {
            for status in ["200 OK", "404 Not Found"] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buf = [0; 4096];
                let n = stream.read(&mut buf).unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_ascii_lowercase();
                assert!(request.starts_with("get /audio/item/lyrics "));
                assert!(request.contains("x-emby-token: test-token"));
                let body = if status.starts_with("200") {
                    r#"{"Lyrics":[{"Start":10000000,"Text":"hello"}]}"#
                } else {
                    ""
                };
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = Jellyfin::new(
            SourceKind::Jellyfin,
            &format!("http://{address}"),
            "test-token".into(),
        )
        .unwrap();
        assert_eq!(
            client.lyrics("item").await.unwrap().unwrap().content,
            "[00:01.000]hello"
        );
        assert!(client.lyrics("item").await.unwrap().is_none());
        task.join().unwrap();
    }

    #[test]
    fn converts_ticks_and_keeps_untimed_lines() {
        let timed = parse_lyrics(
            r#"{"Lyrics":[{"Start":12345670,"Text":"first"},{"Start":610000000,"Text":"second"}]}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(timed.format, LyricsFormat::Lrc);
        assert_eq!(timed.content, "[00:01.234]first\n[01:01.000]second");
        let plain = parse_lyrics(r#"{"Lyrics":[{"Start":0,"Text":"first"},{"Text":"second"}]}"#)
            .unwrap()
            .unwrap();
        assert_eq!(plain.format, LyricsFormat::Plain);
        assert_eq!(plain.content, "first\nsecond");
        assert!(parse_lyrics(r#"{"Lyrics":[]}"#).unwrap().is_none());
    }
}

#[cfg(test)]
mod album_artwork_tests {
    #![allow(clippy::unwrap_used)]
    use super::*;
    #[tokio::test]
    async fn requests_authenticated_album_artwork_and_handles_missing() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let task = std::thread::spawn(move || {
            for status in ["200 OK", "404 Not Found"] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buf = [0; 4096];
                let n = stream.read(&mut buf).unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_ascii_lowercase();
                assert!(request.starts_with("get /items/album%2fid/images/primary "));
                assert!(request.contains("x-emby-token: test-token"));
                let body = if status.starts_with("200") {
                    "image"
                } else {
                    ""
                };
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = Jellyfin::new(
            SourceKind::Emby,
            &format!("http://{address}"),
            "test-token".into(),
        )
        .unwrap();
        assert_eq!(
            client.album_artwork("album/id").await.unwrap(),
            Some(b"image".to_vec())
        );
        assert_eq!(client.album_artwork("album/id").await.unwrap(), None);
        task.join().unwrap();
    }
}
