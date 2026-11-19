//! 第三方听歌记录上报（DIS-07）。
//!
//! 支持的三个服务（协议细节对照官方文档，见各小节）：
//!
//! | 服务 | 端点 | 认证 | 签名 |
//! |---|---|---|---|
//! | [`ScrobbleService::LastFm`] | `https://ws.audioscrobbler.com/2.0` | `api_key` + `api_secret` + session key | MD5（`api_sig`）|
//! | [`ScrobbleService::LibreFm`] | `https://libre.fm/2.0` | 同上 | 同上（GNU FM 与 Last.fm 同协议）|
//! | [`ScrobbleService::ListenBrainz`] | `https://api.listenbrainz.org` | user token（HTTP 头）| 无 |
//!
//! ## 上报时机
//!
//! [`should_scrobble`] 是三家通用的判定规则（Last.fm 官方规则，ListenBrainz 与 Libre.fm 沿用）：
//! 曲目必须**长于** 30 秒，并且至少听过「一半时长」或「4 分钟」中较短的那个。
//! 播放器在播放进度变化时调用它，为真就把 [`Scrobble`] 丢给上报队列。
//!
//! ## 不能影响播放
//!
//! - 上报失败一律返回 `Err`，不 panic、不 `unwrap`，绝不阻塞播放线程；
//! - 断网时的记录进 [`ScrobbleQueue`]（内存 + JSON 可落盘），联网后 [`ScrobbleClient::flush`] 补报；
//! - 退避只"记账"不睡眠：与 [`crate::providers`] 的在线补全不同（那边是前台任务，可以等），
//!   上报是后台尾巴，等多久都不该占着调用方。真正的重试交给队列调度。
//!
//! ## 隐私红线
//!
//! - `api_secret`、`session_key`、`user_token`、`api_key` 只放 POST body 或 HTTP 头，
//!   **从不进 URL query**（Last.fm 的签名协议本身要求参数进 body，正好合规；
//!   唯一例外是授权网页地址里的 `api_key` 与请求 token —— 那是官方协议规定的、不是机密）；
//! - [`ScrobbleConfig`]、[`ScrobbleClient`]、[`AuthRequest`] 的 `Debug` 一律打 `<redacted>`；
//! - `tracing` 只记服务名、动作名、错误码、批量条数、退避次数，**不记任何凭据**；
//! - 错误信息里只有动作名和状态码（沿用 [`crate::http`] 的规矩：URL 上的内容属于隐私）。
//!
//! ## 协议要点（写在这里省得以后重查）
//!
//! Last.fm / Libre.fm（<https://www.last.fm/api/authspec>、<https://www.last.fm/api/scrobbling>）：
//! - 一律 `POST`，参数放 `application/x-www-form-urlencoded` body；
//! - `api_sig` = 所有参数（`format` 除外）按名字做 ASCII 升序拼成 `k1v1k2v2...`，
//!   末尾接 `api_secret`，取 MD5 小写十六进制；**值不做 URL 编码**；
//! - 批量 scrobble 用数组记法 `artist[i]` / `track[i]` / `timestamp[i]`，一次最多 50 条；
//! - `track.updateNowPlaying` 用非数组参数；`auth.getToken` → `auth.getSession` 换长期 session key。
//!
//! ListenBrainz（<https://listenbrainz.readthedocs.io/en/latest/>）：
//! - `POST /1/submit-listens`，头 `Authorization: Token <user_token>`；
//! - body `{"listen_type":"single"|"import"|"playing_now","payload":[listen...]}`；
//!   `single` 恰好 1 条、`import` 用于补报、`playing_now` 恰好 1 条且**不能带 `listened_at`**；
//! - `additional_info.tracknumber` 是**字符串**，`duration_ms` 是数字。

use crate::http;
use crate::throttle::{Backoff, RateLimiter};
use lekis_types::{ErrorCode, LekisError, Result};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::VecDeque;
use std::fmt;
use std::time::Duration;

/// 待补报队列的容量上限：超出后丢弃最旧的记录（本地磁盘写爆比丢几条旧记录更糟）。
pub const QUEUE_CAPACITY: usize = 5000;

/// 一次请求最多带多少条记录。
///
/// Last.fm 的批量 scrobble 硬性上限是 50 条（`artist[0]`..`artist[49]`）。
/// ListenBrainz 其实能一次收几千条，但统一用 50 能让请求体保持小、失败重传代价低。
pub const MAX_BATCH: usize = 50;

/// 官方规则的下限：**长于** 30 秒的曲目才上报（30 秒整不算）。
pub const MIN_TRACK_MS: u64 = 30_000;

/// 长曲目的封顶阈值：听满 4 分钟就算数，不用等一小时的歌放完。
pub const LONG_TRACK_MS: u64 = 4 * 60 * 1000;

/// 上报客户端标识，写进 ListenBrainz 的 `additional_info.submission_client`。
const SUBMISSION_CLIENT: &str = concat!("LekisMusic/", env!("CARGO_PKG_VERSION"));

/// 表单**键**允许原样出现的字符：除字母数字外保留 `[` `]` `.` `_` `-`。
///
/// Last.fm 的数组参数写作 `artist[0]`，个别服务端在对键做 urldecode 之前就解析下标，
/// 保留方括号最稳妥。**值**一侧走 [`VALUE_SET`]（RFC 3986 的 unreserved 不转义）。
const KEY_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'[')
    .remove(b']')
    .remove(b'.')
    .remove(b'_')
    .remove(b'-');

/// 表单**值**的编码集：`A-Za-z0-9-._~` 原样，其余（含空格）百分号转义。
const VALUE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

// ============================================================================
// 服务
// ============================================================================

/// 支持的上报服务。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScrobbleService {
    /// Last.fm（`ws.audioscrobbler.com`，MD5 签名 + session key）。
    LastFm,
    /// ListenBrainz（JSON + `Authorization: Token`）。
    ListenBrainz,
    /// Libre.fm（GNU FM 实现，协议与 Last.fm 完全一致）。
    LibreFm,
}

impl ScrobbleService {
    /// 人读名字，用于日志、错误信息和 `Debug` 输出。
    pub const fn name(self) -> &'static str {
        match self {
            Self::LastFm => "Last.fm",
            Self::ListenBrainz => "ListenBrainz",
            Self::LibreFm => "Libre.fm",
        }
    }

    /// 默认 API 地址（[`ScrobbleConfig::new`] 用它填 `base_url`）。
    ///
    /// 结尾不带 `/`：拼路径由 [`crate::http::join`] 统一处理。
    pub const fn default_base_url(self) -> &'static str {
        match self {
            Self::LastFm => "https://ws.audioscrobbler.com/2.0",
            Self::ListenBrainz => "https://api.listenbrainz.org",
            Self::LibreFm => "https://libre.fm/2.0",
        }
    }

    /// 授权网页所在的站点根。
    ///
    /// Last.fm 的 API 在 `ws.audioscrobbler.com`，授权页却在 `www.last.fm`，所以不能从
    /// `base_url` 推。自建实例的站点根由 [`ScrobbleClient`] 从 `base_url` 里推，不用这个值。
    const fn auth_page_root(self) -> &'static str {
        match self {
            Self::LastFm => "https://www.last.fm",
            Self::LibreFm => "https://libre.fm",
            // ListenBrainz 没有授权页（用户自己在网站上生成 token）。
            Self::ListenBrainz => "",
        }
    }

    /// 是否走 Last.fm 那套「参数排序 + MD5 签名 + session key」协议。
    pub const fn uses_api_signature(self) -> bool {
        matches!(self, Self::LastFm | Self::LibreFm)
    }

    /// 两次请求之间的默认最小间隔。
    ///
    /// Last.fm 的写接口限制约 5 次/秒，但 scrobble 本来就该批量发，1 秒一次足够；
    /// ListenBrainz 的限流与用户数挂钩，1 秒一次同样很安全。
    pub const fn default_min_interval(self) -> Duration {
        Duration::from_secs(1)
    }
}

impl fmt::Display for ScrobbleService {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

// ============================================================================
// 配置
// ============================================================================

/// 上报配置。
///
/// `Debug` 是手写的：`api_key` / `api_secret` / `session_key` / `user_token` 一律打
/// `<redacted>`，避免任何 `{:?}`（日志宏、错误报告、调试器）把凭据漏出去。
#[derive(Clone, PartialEq, Eq)]
pub struct ScrobbleConfig {
    /// 上报到哪个服务。
    pub service: ScrobbleService,
    /// API 地址；默认取 [`ScrobbleService::default_base_url`]，测试和自建实例可以改。
    pub base_url: String,
    /// Last.fm / Libre.fm 的应用 API key（不是机密，但仍统一脱敏打印）。
    pub api_key: Option<String>,
    /// Last.fm / Libre.fm 的应用 API secret（只参与签名，从不外发）。
    pub api_secret: Option<String>,
    /// 已授权得到的 session key（Last.fm / Libre.fm 的 `sk` 参数）。
    pub session_key: Option<String>,
    /// ListenBrainz 的 user token。
    pub user_token: Option<String>,
}

impl ScrobbleConfig {
    /// 按服务创建配置：`base_url` 取官方地址，凭据留空。
    pub fn new(service: ScrobbleService) -> Self {
        Self {
            service,
            base_url: service.default_base_url().to_string(),
            api_key: None,
            api_secret: None,
            session_key: None,
            user_token: None,
        }
    }

    /// 改 API 地址（测试注入本地假服务、或连自建实例）。
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    /// 填应用级凭据（Last.fm / Libre.fm 的 `api_key` 与 `api_secret`）。
    pub fn with_api_credentials(
        mut self,
        api_key: impl Into<String>,
        api_secret: impl Into<String>,
    ) -> Self {
        self.api_key = Some(api_key.into());
        self.api_secret = Some(api_secret.into());
        self
    }

    /// 填已授权拿到的 session key。
    pub fn with_session_key(mut self, session_key: impl Into<String>) -> Self {
        self.session_key = Some(session_key.into());
        self
    }

    /// 填 ListenBrainz 的 user token。
    pub fn with_user_token(mut self, user_token: impl Into<String>) -> Self {
        self.user_token = Some(user_token.into());
        self
    }
}

impl fmt::Debug for ScrobbleConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScrobbleConfig")
            .field("service", &self.service)
            .field("base_url", &self.base_url)
            .field("api_key", &redacted(self.api_key.as_deref()))
            .field("api_secret", &redacted(self.api_secret.as_deref()))
            .field("session_key", &redacted(self.session_key.as_deref()))
            .field("user_token", &redacted(self.user_token.as_deref()))
            .finish()
    }
}

/// `Debug` 里对凭据的统一表示：有值就 `<redacted>`，没值就 `None`。
fn redacted(value: Option<&str>) -> Option<&'static str> {
    value.map(|_| "<redacted>")
}

// ============================================================================
// 记录
// ============================================================================

/// 一条待上报的播放记录。
///
/// `played_at_ms` 是**开始播放**的时刻（Last.fm 的 `timestamp` 就是这个语义），
/// 不是"听完的时刻"。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scrobble {
    /// 艺人名（必填）。
    pub artist: String,
    /// 曲目标题（必填）。
    pub title: String,
    /// 专辑名。
    pub album: Option<String>,
    /// 时长（毫秒）；不知道就填 0，请求里会省略。
    pub duration_ms: u64,
    /// 开始播放的 Unix 时间戳（毫秒）。
    pub played_at_ms: i64,
    /// MusicBrainz 录音 ID（三家都认）。
    pub mbid_recording: Option<String>,
    /// 专辑内曲序（从 1 开始）。
    pub track_number: Option<u32>,
}

impl Scrobble {
    /// 创建一条记录（其余字段用 `with_*` 补）。
    pub fn new(artist: impl Into<String>, title: impl Into<String>, played_at_ms: i64) -> Self {
        Self {
            artist: artist.into(),
            title: title.into(),
            album: None,
            duration_ms: 0,
            played_at_ms,
            mbid_recording: None,
            track_number: None,
        }
    }

    /// 补专辑名。
    pub fn with_album(mut self, album: impl Into<String>) -> Self {
        self.album = Some(album.into());
        self
    }

    /// 补时长（毫秒）。
    pub fn with_duration_ms(mut self, duration_ms: u64) -> Self {
        self.duration_ms = duration_ms;
        self
    }

    /// 补录音 MBID。
    pub fn with_mbid_recording(mut self, mbid: impl Into<String>) -> Self {
        self.mbid_recording = Some(mbid.into());
        self
    }

    /// 补曲序。
    pub fn with_track_number(mut self, track_number: u32) -> Self {
        self.track_number = Some(track_number);
        self
    }

    /// 协议里要的 Unix 秒（毫秒向下取整）。
    fn played_at_secs(&self) -> i64 {
        self.played_at_ms.div_euclid(1000)
    }

    /// Last.fm 的 `duration` 参数：整秒，0 表示未知（请求里省略）。
    fn duration_secs(&self) -> u64 {
        self.duration_ms / 1000
    }

    /// 上报前的必填校验。
    fn validate(&self) -> Result<()> {
        if self.artist.trim().is_empty() {
            return Err(LekisError::invalid("上报记录缺少艺人名"));
        }
        if self.title.trim().is_empty() {
            return Err(LekisError::invalid("上报记录缺少曲目标题"));
        }
        Ok(())
    }
}

/// "正在播放"的借用视图：字段和 [`Scrobble`] 一样，只是没有 `played_at`。
///
/// 播放器手里通常就是一条 [`Scrobble`]，[`ScrobbleClient::now_playing`] 会自动转换；
/// 只有手上没有完整记录时才需要自己拼这个结构。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NowPlaying<'a> {
    /// 艺人名。
    pub artist: &'a str,
    /// 曲目标题。
    pub title: &'a str,
    /// 专辑名。
    pub album: Option<&'a str>,
    /// 时长（毫秒）。
    pub duration_ms: u64,
    /// MusicBrainz 录音 ID。
    pub mbid_recording: Option<&'a str>,
    /// 专辑内曲序。
    pub track_number: Option<u32>,
}

impl<'a> NowPlaying<'a> {
    /// 从一条完整记录里取出"正在播放"需要的字段。
    pub fn from_scrobble(scrobble: &'a Scrobble) -> Self {
        Self {
            artist: &scrobble.artist,
            title: &scrobble.title,
            album: scrobble.album.as_deref(),
            duration_ms: scrobble.duration_ms,
            mbid_recording: scrobble.mbid_recording.as_deref(),
            track_number: scrobble.track_number,
        }
    }

    /// 必填校验。
    fn validate(&self) -> Result<()> {
        if self.artist.trim().is_empty() {
            return Err(LekisError::invalid("正在播放缺少艺人名"));
        }
        if self.title.trim().is_empty() {
            return Err(LekisError::invalid("正在播放缺少曲目标题"));
        }
        Ok(())
    }
}

/// Last.fm / Libre.fm 授权流程第一步的结果。
///
/// 调用方要做的是：把 `url` 打开给用户点"同意"，然后拿 `token` 回调
/// [`ScrobbleClient::complete_auth`] 换长期 session key。
#[derive(Clone, PartialEq, Eq)]
pub struct AuthRequest {
    /// 请求 token（一次性，换完 session key 就作废）。
    pub token: String,
    /// 让用户去点授权的网页地址（带 `api_key` 与 token，**不含 secret**）。
    pub url: String,
}

impl AuthRequest {
    /// 请求 token。
    pub fn token(&self) -> &str {
        &self.token
    }

    /// 授权网页地址。
    pub fn url(&self) -> &str {
        &self.url
    }
}

impl fmt::Debug for AuthRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthRequest")
            .field("token", &"<redacted>")
            .field("url", &self.url)
            .finish()
    }
}

// ============================================================================
// 上报客户端
// ============================================================================

/// 上报客户端。
///
/// 复用本 crate 的 [`crate::http`]（UA / 超时 / 连接池 / 错误映射）与
/// [`crate::throttle`]（主动限速 + 失败退避），不另造一套 HTTP 设施。
pub struct ScrobbleClient {
    config: ScrobbleConfig,
    client: reqwest::Client,
    limiter: RateLimiter,
    backoff: Backoff,
}

impl ScrobbleClient {
    /// 用默认限速创建。
    ///
    /// # Errors
    /// - `base_url` 为空或无法解析 → `InvalidArgument`；
    /// - Last.fm / Libre.fm 缺 `api_key` 或 `api_secret` → `Auth`（应用级凭据，缺失就是配置错误）；
    /// - HTTP 客户端构建失败 → `Internal`。
    pub fn new(config: ScrobbleConfig) -> Result<Self> {
        let client = http::client()?;
        let min_interval = config.service.default_min_interval();
        Self::build(config, client, min_interval)
    }

    /// 用一个现成的 [`reqwest::Client`] 创建（复用连接池；测试里用它注入 `no_proxy` 客户端）。
    ///
    /// # Errors
    /// 同 [`Self::new`]。
    pub fn with_client(config: ScrobbleConfig, client: reqwest::Client) -> Result<Self> {
        let min_interval = config.service.default_min_interval();
        Self::build(config, client, min_interval)
    }

    /// 真正的构造：额外允许指定限速间隔（测试用 `Duration::ZERO`）。
    fn build(
        config: ScrobbleConfig,
        client: reqwest::Client,
        min_interval: Duration,
    ) -> Result<Self> {
        // 提前把地址校验掉，别等播放到一半才发现配错。
        http::join(&config.base_url, "")?;
        if config.service.uses_api_signature() {
            require(&config.api_key, config.service, "api_key")?;
            require(&config.api_secret, config.service, "api_secret")?;
        }
        Ok(Self {
            config,
            client,
            limiter: RateLimiter::new(min_interval),
            backoff: Backoff::new(Duration::from_secs(5), Duration::from_secs(300)),
        })
    }

    /// 配置（`Debug` 已脱敏）。
    pub fn config(&self) -> &ScrobbleConfig {
        &self.config
    }

    /// 上报到哪个服务。
    pub fn service(&self) -> ScrobbleService {
        self.config.service
    }

    /// API 地址。
    pub fn base_url(&self) -> &str {
        &self.config.base_url
    }

    /// 当前连续失败次数（队列调度据此决定要不要推迟下一轮）。
    pub fn failures(&self) -> u32 {
        self.backoff.failures()
    }

    /// 清空失败计数（例如用户手动点了"重试"）。
    pub fn reset_backoff(&self) {
        self.backoff.reset();
    }

    /// 上报"正在播放"。
    ///
    /// Last.fm 的 `track.updateNowPlaying` 没有逐条时间戳；ListenBrainz 用
    /// `listen_type = playing_now`（按规范**不能**带 `listened_at`）。
    ///
    /// # Errors
    /// 缺凭据 → `Auth`；401/403 → `Auth`；429 → `RateLimited`；
    /// 其余 4xx → `InvalidArgument`；5xx / 连接失败 → `Network`。
    pub async fn now_playing(&self, track: &Scrobble) -> Result<()> {
        self.update_now_playing(&NowPlaying::from_scrobble(track))
            .await
    }

    /// 同 [`Self::now_playing`]，但接受借用视图。
    ///
    /// # Errors
    /// 同 [`Self::now_playing`]。
    pub async fn update_now_playing(&self, track: &NowPlaying<'_>) -> Result<()> {
        track.validate()?;
        match self.config.service {
            ScrobbleService::ListenBrainz => {
                let token = require(&self.config.user_token, self.config.service, "user_token")?;
                let body = json!({
                    "listen_type": "playing_now",
                    "payload": [listenbrainz_listen(*track, None)],
                });
                self.post_json("/1/submit-listens", token, &body, "上报正在播放")
                    .await?;
            }
            _ => {
                let session_key =
                    require(&self.config.session_key, self.config.service, "session_key")?;
                let mut params = vec![("method".to_string(), "track.updateNowPlaying".to_string())];
                if let Some(album) = non_empty(track.album) {
                    params.push(("album".to_string(), album.to_string()));
                }
                params.push(("artist".to_string(), track.artist.to_string()));
                if let Some(duration) = nonzero(track.duration_ms / 1000) {
                    params.push(("duration".to_string(), duration.to_string()));
                }
                if let Some(mbid) = non_empty(track.mbid_recording) {
                    params.push(("mbid".to_string(), mbid.to_string()));
                }
                params.push(("sk".to_string(), session_key.to_string()));
                params.push(("track".to_string(), track.title.to_string()));
                if let Some(number) = track.track_number.filter(|n| *n > 0) {
                    params.push(("trackNumber".to_string(), number.to_string()));
                }
                self.post_signed(params, "上报正在播放").await?;
            }
        }
        tracing::debug!(
            target: "lekis_enrich::scrobble",
            service = self.config.service.name(),
            "已上报正在播放",
        );
        Ok(())
    }

    /// 校验配置与网络连通性，**不会**产生任何 scrobble / now-playing 记录。
    ///
    /// - ListenBrainz：`GET /1/validate-token`（只验证 token，不写任何数据）；
    /// - Last.fm / Libre.fm：签名调用 `user.getInfo`（只读，需要用户名）。
    ///
    /// # Errors
    /// 缺凭据 / 用户名 → `Auth`；网络失败 → `Network`；其余同 [`Self::now_playing`]。
    pub async fn test_connection(&self, username: Option<&str>) -> Result<()> {
        match self.config.service {
            ScrobbleService::ListenBrainz => {
                let token = require(&self.config.user_token, self.config.service, "user_token")?;
                let url = http::join(&self.config.base_url, "/1/validate-token")?;
                let request = self.client.get(url).header(
                    reqwest::header::AUTHORIZATION,
                    format!("Token {}", token.trim()),
                );
                self.execute(request, "校验 ListenBrainz 连接").await?;
            }
            _ => {
                let user = username
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                    .ok_or_else(|| {
                        LekisError::new(
                            ErrorCode::Auth,
                            format!("{} 需要填写用户名才能测试连接", self.config.service.name()),
                        )
                    })?;
                // user.getInfo 是只读接口，不需要 session key，也不会写用户资料。
                let params = vec![
                    ("method".to_string(), "user.getInfo".to_string()),
                    ("user".to_string(), user.to_string()),
                ];
                self.post_signed(params, "校验连接").await?;
            }
        }
        tracing::debug!(
            target: "lekis_enrich::scrobble",
            service = self.config.service.name(),
            "连接测试通过",
        );
        Ok(())
    }

    /// 批量上报听歌记录。
    ///
    /// 空切片直接返回 `Ok(())`（不发请求）。超过 [`MAX_BATCH`] 条会自动分包；
    /// 任意一包失败就立刻返回错误，**之前成功的包不会回滚** —— 调用方据此把这一批
    /// 记回队列即可（重复的 scrobble 在服务端会被去重，丢记录比重复更糟）。
    ///
    /// # Errors
    /// 记录缺艺人/标题 → `InvalidArgument`；缺凭据 → `Auth`；其余同 [`Self::now_playing`]。
    pub async fn scrobble(&self, tracks: &[Scrobble]) -> Result<()> {
        if tracks.is_empty() {
            return Ok(());
        }
        for track in tracks {
            track.validate()?;
        }
        for batch in tracks.chunks(MAX_BATCH) {
            self.scrobble_batch(batch).await?;
            tracing::debug!(
                target: "lekis_enrich::scrobble",
                service = self.config.service.name(),
                count = batch.len(),
                "已上报一批听歌记录",
            );
        }
        Ok(())
    }

    /// 上报一包（不超过 [`MAX_BATCH`] 条）。
    async fn scrobble_batch(&self, batch: &[Scrobble]) -> Result<()> {
        match self.config.service {
            ScrobbleService::ListenBrainz => {
                let token = require(&self.config.user_token, self.config.service, "user_token")?;
                // 单条用 `single`，多条用 `import`：后者正是为补报/批量场景定义的。
                let listen_type = if batch.len() == 1 { "single" } else { "import" };
                let payload: Vec<Value> = batch
                    .iter()
                    .map(|track| listenbrainz_listen(NowPlaying::from_scrobble(track), Some(track)))
                    .collect();
                let body = json!({ "listen_type": listen_type, "payload": payload });
                self.post_json("/1/submit-listens", token, &body, "上报听歌记录")
                    .await?;
            }
            _ => {
                let session_key =
                    require(&self.config.session_key, self.config.service, "session_key")?;
                let mut params = vec![("method".to_string(), "track.scrobble".to_string())];
                for (index, track) in batch.iter().enumerate() {
                    let timestamp = track.played_at_secs().to_string();
                    params.push((format!("artist[{index}]"), track.artist.clone()));
                    params.push((format!("track[{index}]"), track.title.clone()));
                    params.push((format!("timestamp[{index}]"), timestamp));
                    if let Some(album) = non_empty(track.album.as_deref()) {
                        params.push((format!("album[{index}]"), album.to_string()));
                    }
                    if let Some(duration) = nonzero(track.duration_secs()) {
                        params.push((format!("duration[{index}]"), duration.to_string()));
                    }
                    if let Some(mbid) = non_empty(track.mbid_recording.as_deref()) {
                        params.push((format!("mbid[{index}]"), mbid.to_string()));
                    }
                    if let Some(number) = track.track_number.filter(|n| *n > 0) {
                        params.push((format!("trackNumber[{index}]"), number.to_string()));
                    }
                }
                params.push(("sk".to_string(), session_key.to_string()));
                self.post_signed(params, "上报听歌记录").await?;
            }
        }
        Ok(())
    }

    /// 把队列里的记录尽力补报出去，返回成功上报的条数。
    ///
    /// 成功的出队；**第一批失败就停**，剩下的一次原样放回队头并返回错误，
    /// 这样下一轮只重传失败的部分。
    ///
    /// # Errors
    /// 任何一批失败就返回该错误；注意此时**已经成功的那部分保持出队状态**，
    /// 所以中途出错不等于"整批都没发出去"。
    pub async fn flush(&self, queue: &mut ScrobbleQueue) -> Result<usize> {
        let mut sent = 0usize;
        while !queue.is_empty() {
            let batch = queue.drain(MAX_BATCH);
            if batch.is_empty() {
                break;
            }
            if let Err(error) = self.scrobble(&batch).await {
                let count = batch.len();
                queue.requeue(batch);
                tracing::warn!(
                    target: "lekis_enrich::scrobble",
                    service = self.config.service.name(),
                    count,
                    sent,
                    "补报失败，记录留在队列里",
                );
                return Err(error);
            }
            sent += batch.len();
        }
        Ok(sent)
    }

    // ---- 授权流程（只有 Last.fm / Libre.fm 有）----------------------------

    /// 授权第一步：拿一个请求 token，并给出让用户点"同意"的网页地址。
    ///
    /// # Errors
    /// ListenBrainz → `Unsupported`（它没有这套流程，用户自己去网站复制 token）；
    /// 缺 `api_key` / `api_secret` → `Auth`；服务端拒绝 → 同 [`Self::now_playing`]。
    pub async fn begin_auth(&self) -> Result<AuthRequest> {
        if !self.config.service.uses_api_signature() {
            return Err(LekisError::unsupported(format!(
                "{} 不支持 token 授权流程，请在网站上生成 user token 后填入配置",
                self.config.service.name()
            )));
        }
        let api_key = require(&self.config.api_key, self.config.service, "api_key")?.to_string();
        let params = vec![("method".to_string(), "auth.getToken".to_string())];
        let body = self.post_signed(params, "获取授权 token").await?;
        let wire: TokenWire = serde_json::from_str(&body).map_err(decode)?;
        let token = wire.token.trim().to_string();
        if token.is_empty() {
            return Err(LekisError::new(
                ErrorCode::Decode,
                format!("{} 返回了空的授权 token", self.config.service.name()),
            ));
        }
        let url = self.auth_url(&api_key, &token);
        Ok(AuthRequest { token, url })
    }

    /// 授权第二步：用请求 token 换长期 session key。
    ///
    /// 返回的 session key 应当存进 [`ScrobbleConfig::session_key`] 并持久化。
    ///
    /// # Errors
    /// ListenBrainz → `Unsupported`；token 被拒 → `Auth`（Last.fm 会回错误码 4/14/15）。
    pub async fn complete_auth(&self, token: &str) -> Result<String> {
        if !self.config.service.uses_api_signature() {
            return Err(LekisError::unsupported(format!(
                "{} 不支持 token 授权流程",
                self.config.service.name()
            )));
        }
        let token = token.trim();
        if token.is_empty() {
            return Err(LekisError::invalid("授权 token 为空"));
        }
        let params = vec![
            ("method".to_string(), "auth.getSession".to_string()),
            ("token".to_string(), token.to_string()),
        ];
        let body = self.post_signed(params, "换取 session key").await?;
        let wire: SessionWire = serde_json::from_str(&body).map_err(decode)?;
        let key = wire.session.key.trim().to_string();
        if key.is_empty() {
            return Err(LekisError::new(
                ErrorCode::Decode,
                format!("{} 返回了空的 session key", self.config.service.name()),
            ));
        }
        Ok(key)
    }

    /// 拼授权网页地址。
    ///
    /// 官方的 API 域名和网页域名不一样（`ws.audioscrobbler.com` vs `www.last.fm`），
    /// 所以默认地址走服务自带的站点根；`base_url` 被改过（自建实例）时，
    /// 从它去掉 `/2.0` 后缀得到站点根。URL 里只放 `api_key` 和请求 token，
    /// **永远不放 `api_secret`**。
    fn auth_url(&self, api_key: &str, token: &str) -> String {
        let base = self.config.base_url.trim_end_matches('/');
        let root = if base == self.config.service.default_base_url() {
            self.config.service.auth_page_root().to_string()
        } else {
            base.strip_suffix("/2.0").unwrap_or(base).to_string()
        };
        format!(
            "{root}/api/auth/?api_key={}&token={}",
            encode(api_key),
            encode(token)
        )
    }

    // ---- 请求发送 ---------------------------------------------------------

    /// 发一个带签名的表单请求（Last.fm / Libre.fm）。
    ///
    /// `params` 里不含 `api_key` / `api_sig` / `format`，由本函数补上：
    /// `format=json` 参与请求体但**不参与签名**（协议规定），`api_sig` 最后加。
    async fn post_signed(&self, params: Vec<(String, String)>, what: &str) -> Result<String> {
        let api_key = require(&self.config.api_key, self.config.service, "api_key")?;
        let api_secret = require(&self.config.api_secret, self.config.service, "api_secret")?;
        let mut params = params;
        params.push(("api_key".to_string(), api_key.to_string()));
        params.push(("format".to_string(), "json".to_string()));
        let signature = api_signature(&params, api_secret);
        params.push(("api_sig".to_string(), signature));

        let url = http::join(&self.config.base_url, "")?;
        let request = self
            .client
            .post(url)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(encode_pairs(&params));
        self.execute(request, what).await
    }

    /// 发一个 JSON 请求（ListenBrainz）。token 只放在 `Authorization` 头里。
    async fn post_json(&self, path: &str, token: &str, body: &Value, what: &str) -> Result<String> {
        let url = http::join(&self.config.base_url, path)?;
        let request = self
            .client
            .post(url)
            .header(
                reqwest::header::AUTHORIZATION,
                format!("Token {}", token.trim()),
            )
            .json(body);
        self.execute(request, what).await
    }

    /// 发请求、判状态、识别服务端错误体、更新退避计数。
    ///
    /// 注意：**不睡眠**。等待时长交给队列调度（见模块文档）。
    async fn execute(&self, request: reqwest::RequestBuilder, what: &str) -> Result<String> {
        self.limiter.acquire().await;
        let response = match request.send().await {
            Ok(response) => response,
            Err(error) => return Err(self.note_failure(http::network(error), what)),
        };
        let status = response.status().as_u16();
        let body = match response.text().await {
            Ok(body) => body,
            Err(error) => return Err(self.note_failure(http::network(error), what)),
        };
        // Last.fm 即使返回 200 也会在 body 里带 `{"error":N}`，两种情况都要看。
        if let Some(error) = self.api_error(&body) {
            return Err(self.note_failure(error, what));
        }
        if !(200..=299).contains(&status) {
            return Err(self.note_failure(status_error(status, what), what));
        }
        self.backoff.reset();
        Ok(body)
    }

    /// 从响应体里认出 Last.fm 的 `{"error":N,"message":...}`。
    ///
    /// ListenBrainz 没有这种错误体，直接返回 `None`；成功响应里也不会带 `error` 字段。
    fn api_error(&self, body: &str) -> Option<LekisError> {
        if !self.config.service.uses_api_signature() {
            return None;
        }
        let wire: ErrorWire = serde_json::from_str(body).ok()?;
        Some(LekisError::new(
            map_api_error(wire.error),
            format!(
                "{} 上报失败：{}（错误码 {}）",
                self.config.service.name(),
                wire.message.trim(),
                wire.error
            ),
        ))
    }

    /// 记一次失败并原样返回错误。
    fn note_failure(&self, error: LekisError, what: &str) -> LekisError {
        if matches!(error.code, ErrorCode::RateLimited | ErrorCode::Network) {
            let delay = self.backoff.record_failure();
            tracing::warn!(
                target: "lekis_enrich::scrobble",
                service = self.config.service.name(),
                code = error.code.as_str(),
                failures = self.backoff.failures(),
                retry_after_ms = delay.as_millis() as u64,
                "{what} 失败，稍后重试",
            );
        } else {
            // 凭据/参数类错误重试也没用，不记退避。
            tracing::warn!(
                target: "lekis_enrich::scrobble",
                service = self.config.service.name(),
                code = error.code.as_str(),
                "{what} 失败",
            );
        }
        error
    }
}

impl fmt::Debug for ScrobbleClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScrobbleClient")
            .field("config", &self.config)
            .field("failures", &self.backoff.failures())
            .finish_non_exhaustive()
    }
}

// ============================================================================
// 待补报队列
// ============================================================================

/// 待补报队列（内存），可 JSON 落盘。
///
/// 语义：
/// - [`enqueue`](Self::enqueue) 追加到队尾；超过 [`QUEUE_CAPACITY`] 丢**最旧**的记录；
/// - [`drain`](Self::drain) 从队头取走至多 N 条 —— 取走即视为"正在发送"，
///   发失败就 [`requeue`](Self::requeue) 放回队头（顺序不变），发成功就别再管；
/// - [`to_json`](Self::to_json) / [`from_json`](Self::from_json) 用来跨进程保存，
///   文件路径和写入时机由上层决定（本 crate 不碰文件系统）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrobbleQueue {
    /// 队头最旧。
    items: VecDeque<Scrobble>,
}

impl ScrobbleQueue {
    /// 空队列。
    pub fn new() -> Self {
        Self::default()
    }

    /// 追加一条记录；队列满了就丢最旧的那条。
    pub fn enqueue(&mut self, scrobble: Scrobble) {
        self.items.push_back(scrobble);
        self.trim();
    }

    /// 从队头取走至多 `max` 条（取走即出队；发送失败请用 [`Self::requeue`] 放回去）。
    pub fn drain(&mut self, max: usize) -> Vec<Scrobble> {
        let count = max.min(self.items.len());
        self.items.drain(..count).collect()
    }

    /// 把一批记录按原顺序放回队头（补报失败时用）。
    ///
    /// 如果这期间队列又满了，仍然按"丢最旧"的规则裁剪 —— 恢复的旧记录会被刚进来的
    /// 新记录挤掉，理由见 [`QUEUE_CAPACITY`]。
    pub fn requeue(&mut self, scrobbles: Vec<Scrobble>) {
        for scrobble in scrobbles.into_iter().rev() {
            self.items.push_front(scrobble);
        }
        self.trim();
    }

    /// 当前条数。
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// 是否为空。
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// 清空（用户关掉某个服务的上报时用）。
    pub fn clear(&mut self) {
        self.items.clear();
    }

    /// 序列化成 JSON（落盘用）。
    ///
    /// # Errors
    /// 理论上只有内存不足会失败，仍然转成 `Internal` 而不是 `unwrap`。
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self)
            .map_err(|e| LekisError::new(ErrorCode::Internal, format!("待补报队列序列化失败：{e}")))
    }

    /// 从 JSON 还原。
    ///
    /// # Errors
    /// JSON 结构不对 → `Decode`（损坏的队列文件不该让播放器起不来，调用方丢弃重建即可）。
    pub fn from_json(json: &str) -> Result<Self> {
        let mut queue: Self = serde_json::from_str(json)
            .map_err(|e| LekisError::new(ErrorCode::Decode, format!("待补报队列解析失败：{e}")))?;
        queue.trim();
        Ok(queue)
    }

    /// 超容量时丢最旧的。
    fn trim(&mut self) {
        while self.items.len() > QUEUE_CAPACITY {
            self.items.pop_front();
        }
    }
}

// ============================================================================
// 纯函数
// ============================================================================

/// 官方规则：这条播放该不该算一次 scrobble。
///
/// Last.fm 的原文是「曲目必须长于 30 秒，并且至少听过一半或 4 分钟（取较短者）」，
/// ListenBrainz 与 Libre.fm 沿用同一规则：
///
/// - `duration_ms <= 30_000` → `false`（29 秒、30 秒都不算，31 秒起才有资格）；
/// - 否则看 `played_ms` 是否达到 `min(duration_ms / 2, 4 分钟)`。
///
/// 边界取"够到就算"：5 分钟的歌听满 150 秒算；10 分钟的歌听满 240 秒算（不是 300 秒）。
pub fn should_scrobble(duration_ms: u64, played_ms: u64) -> bool {
    if duration_ms <= MIN_TRACK_MS {
        return false;
    }
    let threshold = (duration_ms / 2).min(LONG_TRACK_MS);
    played_ms >= threshold
}

/// 计算 Last.fm / Libre.fm 的 `api_sig`。
///
/// 官方协议（<https://www.last.fm/api/authspec>，GNU FM 实现完全相同）：
/// 1. 把所有请求参数（**`format` 除外**）按参数名做 ASCII 升序排列；
/// 2. 依次把 `名字` 和 `值` 直接拼起来（`k1v1k2v2...`），值**不做 URL 编码**、保持 UTF-8 原文；
/// 3. 末尾拼上 `api_secret`，对整串做 MD5，取小写十六进制。
///
/// 数组参数按"带下标的完整名字"排序，于是 `artist[10]` 排在 `artist[1]` 前面
/// （`'0' < ']'`）—— 这是协议本身的行为，服务端也这么算。
pub fn api_signature(params: &[(String, String)], api_secret: &str) -> String {
    let mut sorted: Vec<&(String, String)> =
        params.iter().filter(|(key, _)| key != "format").collect();
    sorted.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut joined = String::new();
    for (key, value) in sorted {
        joined.push_str(key);
        joined.push_str(value);
    }
    joined.push_str(api_secret);
    crate::md5::hex_digest(joined.as_bytes())
}

/// Last.fm 的数值错误码 → 错误码。
///
/// 对照 <https://www.last.fm/api/errorcodes>：
/// - `4/9/10/13/14/15/26`：凭据问题（session key 失效、API key 无效、签名错误、
///   key 被停用、授权 token 被拒）——只能让用户重新授权 → `Auth`；
/// - `8/11/16`：服务端临时故障（Operation failed / Service Offline / 临时错误），
///   过一会儿重试就好 → `RateLimited`（与 29 同类，队列会按退避重试）；
/// - `29`：限流 → `RateLimited`；
/// - `2/3/5/6/7`：请求本身不合法 → `InvalidArgument`。
fn map_api_error(code: i64) -> ErrorCode {
    match code {
        4 | 9 | 10 | 13 | 14 | 15 | 26 => ErrorCode::Auth,
        8 | 11 | 16 | 29 => ErrorCode::RateLimited,
        2 | 3 | 5 | 6 | 7 => ErrorCode::InvalidArgument,
        _ => ErrorCode::Internal,
    }
}

/// HTTP 状态码 → 错误码。
///
/// 专门用于上报场景，**不能**复用 [`crate::http::map_status`]：那个是给免 Key 的
/// 公开读接口定的（403 一律当限流），而上报是带认证的写操作，403 就是凭据不对。
fn map_status(code: u16) -> ErrorCode {
    match code {
        401 | 403 => ErrorCode::Auth,
        404 => ErrorCode::NotFound,
        429 => ErrorCode::RateLimited,
        400..=499 => ErrorCode::InvalidArgument,
        500..=599 => ErrorCode::Network,
        _ => ErrorCode::Internal,
    }
}

/// 状态码 → [`LekisError`]。
fn status_error(code: u16, what: &str) -> LekisError {
    LekisError::new(map_status(code), format!("{what}：HTTP {code}"))
}

/// JSON 解析错误 → [`LekisError`]。
fn decode(e: serde_json::Error) -> LekisError {
    LekisError::new(ErrorCode::Decode, format!("上报服务响应解析失败：{e}"))
}

/// 取一个非空的配置项，缺失时按"尚未授权"报错。
fn require<'a>(value: &'a Option<String>, service: ScrobbleService, name: &str) -> Result<&'a str> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .ok_or_else(|| {
            LekisError::new(
                ErrorCode::Auth,
                format!("{} 尚未配置 {name}，需要先完成授权", service.name()),
            )
        })
}

/// `Option<&str>` 里筛出非空值。
fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|text| !text.is_empty())
}

/// 0 当作"未知"处理。
fn nonzero(value: u64) -> Option<u64> {
    if value == 0 {
        None
    } else {
        Some(value)
    }
}

/// 表单值编码：`A-Za-z0-9-._~` 原样，其余百分号转义（空格 → `%20`）。
fn encode(value: &str) -> String {
    utf8_percent_encode(value, VALUE_SET).to_string()
}

/// 表单键编码：额外保留 `[` `]`（见 [`KEY_SET`]）。
fn encode_key(value: &str) -> String {
    utf8_percent_encode(value, KEY_SET).to_string()
}

/// 拼 `application/x-www-form-urlencoded` 请求体。
fn encode_pairs(params: &[(String, String)]) -> String {
    let mut body = String::new();
    for (index, (key, value)) in params.iter().enumerate() {
        if index > 0 {
            body.push('&');
        }
        body.push_str(&encode_key(key));
        body.push('=');
        body.push_str(&encode(value));
    }
    body
}

/// 拼一条 ListenBrainz 的 listen 对象。
///
/// 结构见 <https://listenbrainz.readthedocs.io/en/latest/>：
/// `track_metadata.artist_name` 与 `track_metadata.track_name` 必填；
/// `additional_info.tracknumber` 是**字符串**（不是数字）；
/// `playing_now` 类型按规范不能带 `listened_at`，所以由 `source` 是否存在控制。
fn listenbrainz_listen(track: NowPlaying<'_>, source: Option<&Scrobble>) -> Value {
    let mut additional = Map::new();
    additional.insert("duration_ms".to_string(), json!(track.duration_ms));
    additional.insert("submission_client".to_string(), json!(SUBMISSION_CLIENT));
    if let Some(mbid) = non_empty(track.mbid_recording) {
        additional.insert("recording_mbid".to_string(), json!(mbid));
    }
    if let Some(number) = track.track_number.filter(|n| *n > 0) {
        additional.insert("tracknumber".to_string(), json!(number.to_string()));
    }

    let mut metadata = Map::new();
    metadata.insert("artist_name".to_string(), json!(track.artist));
    metadata.insert("track_name".to_string(), json!(track.title));
    if let Some(album) = non_empty(track.album) {
        metadata.insert("release_name".to_string(), json!(album));
    }
    metadata.insert("additional_info".to_string(), Value::Object(additional));

    let mut listen = Map::new();
    if let Some(source) = source {
        listen.insert("listened_at".to_string(), json!(source.played_at_secs()));
    }
    listen.insert("track_metadata".to_string(), Value::Object(metadata));
    Value::Object(listen)
}

/// `auth.getToken` 的响应。
#[derive(Deserialize)]
struct TokenWire {
    /// 请求 token。
    token: String,
}

/// `auth.getSession` 的响应。
#[derive(Deserialize)]
struct SessionWire {
    /// 会话信息。
    session: SessionBody,
}

/// `auth.getSession` 里的 session 对象。
#[derive(Deserialize)]
struct SessionBody {
    /// 长期 session key。
    key: String,
}

/// 错误响应体 `{"error":N,"message":"..."}`。
#[derive(Deserialize)]
struct ErrorWire {
    /// Last.fm 错误码。
    error: i64,
    /// 人类可读的说明。
    #[serde(default)]
    message: String,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use percent_encoding::percent_decode_str;
    use std::io::{Read as _, Write as _};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    // 固定测试凭据（编出来的字符串，和任何真实账号无关）。
    const API_KEY: &str = "lekis-test-api-key-000000000000";
    const API_SECRET: &str = "lekis-test-api-secret-111111111";
    const SESSION_KEY: &str = "00112233445566778899aabbccddeeff";
    const USER_TOKEN: &str = "listenbrainz-user-token-42";

    // ---- 假 HTTP 服务 -----------------------------------------------------

    /// 记录下来的一个请求。
    #[derive(Clone, Debug)]
    struct Recorded {
        method: String,
        path: String,
        headers: Vec<(String, String)>,
        body: String,
    }

    impl Recorded {
        /// 取一个头（名字必须小写）。
        fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.as_str())
        }
    }

    /// 本地假 HTTP 服务：按顺序回放预设响应，记录每个请求。
    struct FakeServer {
        addr: SocketAddr,
        log: Arc<Mutex<Vec<Recorded>>>,
        stop: Arc<AtomicBool>,
        join: Option<std::thread::JoinHandle<()>>,
    }

    impl FakeServer {
        /// 用一串 `(状态码, 响应体)` 启动；请求数超出后一直重复最后一个。
        fn start(replies: Vec<(u16, String)>) -> Self {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind fake server");
            let addr = listener.local_addr().expect("local addr");
            let log = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let thread_log = log.clone();
            let thread_stop = stop.clone();
            let join = std::thread::spawn(move || {
                for incoming in listener.incoming() {
                    if thread_stop.load(Ordering::Acquire) {
                        return;
                    }
                    let Ok(mut stream) = incoming else { continue };
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                    let _ = handle_connection(&mut stream, &replies, &thread_log);
                }
            });
            Self {
                addr,
                log,
                stop,
                join: Some(join),
            }
        }

        /// 所有请求都回同一个状态码 + 响应体。
        fn fixed(status: u16, body: &str) -> Self {
            Self::start(vec![(status, body.to_string())])
        }

        /// 站点根地址（`http://127.0.0.1:PORT`）。
        fn root(&self) -> String {
            format!("http://{}", self.addr)
        }

        /// Last.fm 风格的 API 地址（`http://127.0.0.1:PORT/2.0`）。
        fn api_url(&self) -> String {
            format!("http://{}/2.0", self.addr)
        }

        /// 记录下来的请求。
        fn recorded(&self) -> Vec<Recorded> {
            self.log.lock().expect("log mutex").clone()
        }
    }

    impl Drop for FakeServer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Release);
            // 唤醒阻塞在 accept 上的线程。
            let _ = TcpStream::connect(self.addr);
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
        }
    }

    /// 读一个请求、按预设回响应。
    fn handle_connection(
        stream: &mut TcpStream,
        replies: &[(u16, String)],
        log: &Mutex<Vec<Recorded>>,
    ) -> std::io::Result<()> {
        let mut raw = Vec::new();
        let mut buf = [0u8; 2048];
        let head_end = loop {
            let n = stream.read(&mut buf)?;
            if n == 0 {
                return Ok(());
            }
            raw.extend_from_slice(&buf[..n]);
            if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos;
            }
            if raw.len() > 64 * 1024 {
                return Ok(());
            }
        };
        let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
        let mut lines = head.split("\r\n");
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default().to_ascii_uppercase();
        let path = parts.next().unwrap_or_default().to_string();
        let headers: Vec<(String, String)> = lines
            .filter_map(|line| {
                line.split_once(':').map(|(name, value)| {
                    (name.trim().to_ascii_lowercase(), value.trim().to_string())
                })
            })
            .collect();
        let length = headers
            .iter()
            .find(|(name, _)| name == "content-length")
            .and_then(|(_, value)| value.parse::<usize>().ok())
            .unwrap_or(0);
        let mut body_raw = raw[head_end + 4..].to_vec();
        while body_raw.len() < length {
            let n = stream.read(&mut buf)?;
            if n == 0 {
                break;
            }
            body_raw.extend_from_slice(&buf[..n]);
        }
        let body_text =
            String::from_utf8_lossy(&body_raw[..body_raw.len().min(length)]).to_string();

        let index = {
            let mut guard = log.lock().expect("log mutex");
            let index = guard.len();
            guard.push(Recorded {
                method,
                path,
                headers,
                body: body_text,
            });
            index
        };
        let (status, body) = replies
            .get(index)
            .or_else(|| replies.last())
            .cloned()
            .unwrap_or((200, String::from("{}")));
        let reason = if (200..300).contains(&status) {
            "OK"
        } else {
            "Error"
        };
        write!(
            stream,
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )?;
        stream.write_all(body.as_bytes())?;
        Ok(())
    }

    /// 测试客户端：`no_proxy` 保证回环请求不被环境里的代理拦走，
    /// `user_agent` 与 [`crate::http::client`] 保持一致（上报服务也要求可识别的 UA）。
    fn test_client() -> reqwest::Client {
        reqwest::Client::builder()
            .no_proxy()
            .user_agent(http::USER_AGENT)
            .timeout(Duration::from_secs(10))
            .build()
            .expect("build test client")
    }

    /// 造一个指向假服务的客户端（限速间隔设 0，测试不用等）。
    fn client_for(service: ScrobbleService, base_url: &str) -> ScrobbleClient {
        let config = ScrobbleConfig::new(service)
            .with_base_url(base_url)
            .with_api_credentials(API_KEY, API_SECRET)
            .with_session_key(SESSION_KEY)
            .with_user_token(USER_TOKEN);
        ScrobbleClient::build(config, test_client(), Duration::ZERO).expect("build client")
    }

    /// 表单里取一个**原始编码**的值。
    fn form_value(body: &str, key: &str) -> Option<String> {
        body.split('&').find_map(|pair| {
            let (name, value) = pair.split_once('=')?;
            if name == key {
                Some(value.to_string())
            } else {
                None
            }
        })
    }

    /// 表单解码成参数表（签名用原始值，所以要先解百分号编码）。
    fn form_params(body: &str) -> Vec<(String, String)> {
        body.split('&')
            .filter_map(|pair| {
                let (name, value) = pair.split_once('=')?;
                Some((
                    percent_decode_str(name).decode_utf8_lossy().to_string(),
                    percent_decode_str(value).decode_utf8_lossy().to_string(),
                ))
            })
            .collect()
    }

    /// 断言请求体里的 `api_sig` 确实是对"其余参数 + secret"算出来的签名。
    fn assert_body_is_signed(body: &str) {
        let params = form_params(body);
        let signature = params
            .iter()
            .find(|(key, _)| key == "api_sig")
            .map(|(_, value)| value.clone())
            .expect("请求体里必须有 api_sig");
        assert_eq!(signature.len(), 32, "签名是 32 位十六进制");
        assert!(
            signature
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "签名必须是**小写**十六进制：{signature}"
        );
        let signed: Vec<(String, String)> = params
            .into_iter()
            .filter(|(key, _)| key != "api_sig")
            .collect();
        assert_eq!(
            api_signature(&signed, API_SECRET),
            signature,
            "签名和请求体里的其余参数对不上"
        );
    }

    /// 一条时长 250 秒、在 2023-11-14T22:13:20Z 开始播放的记录。
    fn paranoid_android() -> Scrobble {
        Scrobble::new("Radiohead", "Paranoid Android", 1_700_000_000_000)
            .with_album("OK Computer")
            .with_duration_ms(250_000)
    }

    // ---- should_scrobble --------------------------------------------------

    #[test]
    fn should_scrobble_requires_more_than_thirty_seconds() {
        // 29 秒、30 秒都不够（官方规则是 "longer than 30 seconds"）。
        assert!(!should_scrobble(29_000, 29_000));
        assert!(!should_scrobble(30_000, 30_000));
        // 31 秒起才有资格，而且必须真的听够一半。
        assert!(!should_scrobble(31_000, 15_000));
        assert!(should_scrobble(31_000, 16_000));
        // 时长未知（0）一律不上报。
        assert!(!should_scrobble(0, 1_000));
    }

    #[test]
    fn should_scrobble_accepts_half_or_four_minutes() {
        // 5 分钟的歌：一半是 150 秒。
        assert!(!should_scrobble(300_000, 149_999));
        assert!(should_scrobble(300_000, 150_000));
        // 49% / 50% 的边界。
        assert!(!should_scrobble(200_000, 99_999));
        assert!(should_scrobble(200_000, 100_000));
        // 10 分钟的歌：一半是 300 秒，但 4 分钟封顶，听满 240 秒就算。
        assert!(!should_scrobble(600_000, 239_999));
        assert!(should_scrobble(600_000, 240_000));
        // 听完当然算。
        assert!(should_scrobble(180_000, 180_000));
    }

    // ---- 签名 ------------------------------------------------------------

    /// Last.fm 文档 <https://www.last.fm/api/authspec> 里公布的两组已知签名。
    #[test]
    fn api_signature_matches_lastfm_documented_vectors() {
        let get_session = vec![
            ("api_key".to_string(), "YOUR_API_KEY".to_string()),
            ("method".to_string(), "auth.getSession".to_string()),
            ("token".to_string(), "YOUR_REQUESTED_TOKEN".to_string()),
        ];
        assert_eq!(
            api_signature(&get_session, "YOUR_SECRET"),
            "94539006de89b3c6b3c030bb1e52b9c4"
        );

        let love = vec![
            ("api_key".to_string(), "YOUR_API_KEY".to_string()),
            ("artist".to_string(), "KITANO REM".to_string()),
            ("method".to_string(), "track.love".to_string()),
            ("sk".to_string(), "YOUR_SESSION_KEY".to_string()),
            ("track".to_string(), "RAINSICK".to_string()),
        ];
        assert_eq!(
            api_signature(&love, "YOUR_SECRET"),
            "800b8884b00c9343d1d425ed271e0f42"
        );
    }

    /// 排序规则：ASCII 升序、`format` 不参与、`artist[10]` 排在 `artist[1]` 之前。
    #[test]
    fn api_signature_sorts_keys_and_skips_format() {
        let scrambled = vec![
            ("track".to_string(), "B".to_string()),
            ("format".to_string(), "json".to_string()),
            ("artist".to_string(), "A".to_string()),
        ];
        // format 被排除，排序后是 artistA + trackB + secret。
        assert_eq!(
            api_signature(&scrambled, "S"),
            crate::md5::hex_digest(b"artistAtrackBS")
        );

        let indexed = vec![
            ("artist[1]".to_string(), "one".to_string()),
            ("artist[10]".to_string(), "ten".to_string()),
            ("artist[2]".to_string(), "two".to_string()),
        ];
        // '0' < ']'，所以 artist[10] 排最前，随后 artist[1]、artist[2]。
        assert_eq!(
            api_signature(&indexed, "S"),
            crate::md5::hex_digest(b"artist[10]tenartist[1]oneartist[2]twoS")
        );
        // 值里的空格和中文按 UTF-8 原文参与，不做 URL 编码。
        let unicode = vec![("artist".to_string(), "晴天 周杰伦".to_string())];
        assert_eq!(
            api_signature(&unicode, "S"),
            crate::md5::hex_digest("artist晴天 周杰伦S".as_bytes())
        );
    }

    // ---- 队列 ------------------------------------------------------------

    #[test]
    fn queue_roundtrips_through_json() {
        let mut queue = ScrobbleQueue::new();
        assert!(queue.is_empty());
        queue.enqueue(paranoid_android());
        queue.enqueue(Scrobble::new("叶惠美", "晴天", 1_700_000_100_000).with_duration_ms(269_000));
        assert_eq!(queue.len(), 2);

        let json = queue.to_json().expect("serialize queue");
        let restored = ScrobbleQueue::from_json(&json).expect("deserialize queue");
        assert_eq!(restored, queue);
        assert_eq!(restored.len(), 2);
        // 落盘内容里不该出现任何凭据。
        assert!(!json.contains(API_SECRET));
        assert!(!json.contains(SESSION_KEY));
    }

    #[test]
    fn queue_drops_oldest_beyond_capacity() {
        let mut queue = ScrobbleQueue::new();
        for index in 0..(QUEUE_CAPACITY + 3) {
            queue.enqueue(Scrobble::new("artist", format!("track-{index}"), 0));
        }
        assert_eq!(queue.len(), QUEUE_CAPACITY);
        let drained = queue.drain(1);
        assert_eq!(drained[0].title, "track-3", "最旧的 3 条应该被丢掉");
    }

    #[test]
    fn queue_drain_and_requeue_keep_order() {
        let mut queue = ScrobbleQueue::new();
        for index in 0..5u32 {
            queue.enqueue(Scrobble::new("artist", format!("track-{index}"), 0));
        }
        let batch = queue.drain(2);
        assert_eq!(batch.len(), 2);
        assert_eq!(batch[0].title, "track-0");
        assert_eq!(queue.len(), 3);
        // 发送失败 → 原样放回队头，顺序不变。
        queue.requeue(batch);
        assert_eq!(queue.len(), 5);
        let all = queue.drain(10);
        let titles: Vec<&str> = all.iter().map(|item| item.title.as_str()).collect();
        assert_eq!(
            titles,
            ["track-0", "track-1", "track-2", "track-3", "track-4"]
        );
        // 再取就是空的。
        assert!(queue.drain(5).is_empty());
        assert_eq!(queue.drain(0).len(), 0);
    }

    #[test]
    fn queue_rejects_broken_json() {
        let error = ScrobbleQueue::from_json("{not json}").expect_err("坏 JSON 应该报错");
        assert_eq!(error.code, ErrorCode::Decode);
        // 空数组是合法的空队列。
        assert!(ScrobbleQueue::from_json(r#"{"items":[]}"#)
            .expect("empty queue")
            .is_empty());
    }

    // ---- 配置与脱敏 ------------------------------------------------------

    #[test]
    fn config_defaults_and_debug_redaction() {
        let config = ScrobbleConfig::new(ScrobbleService::LastFm)
            .with_api_credentials(API_KEY, API_SECRET)
            .with_session_key(SESSION_KEY)
            .with_user_token(USER_TOKEN);
        assert_eq!(config.base_url, "https://ws.audioscrobbler.com/2.0");
        assert_eq!(
            ScrobbleConfig::new(ScrobbleService::ListenBrainz).base_url,
            "https://api.listenbrainz.org"
        );
        assert_eq!(
            ScrobbleConfig::new(ScrobbleService::LibreFm).base_url,
            "https://libre.fm/2.0"
        );
        assert_eq!(ScrobbleService::LastFm.name(), "Last.fm");
        assert_eq!(ScrobbleService::ListenBrainz.to_string(), "ListenBrainz");
        assert!(ScrobbleService::LibreFm.uses_api_signature());
        assert!(!ScrobbleService::ListenBrainz.uses_api_signature());

        let printed = format!("{config:?}");
        for secret in [API_KEY, API_SECRET, SESSION_KEY, USER_TOKEN] {
            assert!(!printed.contains(secret), "Debug 泄漏了凭据：{printed}");
        }
        assert!(printed.contains("<redacted>"));
        // 没配的凭据显示成 None，而不是一个假的 <redacted>。
        let empty = format!("{:?}", ScrobbleConfig::new(ScrobbleService::ListenBrainz));
        assert!(empty.contains("api_secret: None"));
    }

    #[test]
    fn client_and_auth_request_redact_secrets() {
        let client = client_for(ScrobbleService::LastFm, "https://ws.audioscrobbler.com/2.0");
        let printed = format!("{client:?}");
        for secret in [API_KEY, API_SECRET, SESSION_KEY] {
            assert!(
                !printed.contains(secret),
                "client Debug 泄漏了凭据：{printed}"
            );
        }

        let request = AuthRequest {
            token: "REQUEST_TOKEN_MUST_NOT_LEAK".to_string(),
            url: "https://www.last.fm/api/auth/?api_key=k&token=t".to_string(),
        };
        let printed = format!("{request:?}");
        assert!(!printed.contains("REQUEST_TOKEN_MUST_NOT_LEAK"));
        assert!(printed.contains("<redacted>"));
        assert_eq!(request.token(), "REQUEST_TOKEN_MUST_NOT_LEAK");
        assert!(request.url().starts_with("https://www.last.fm/api/auth/"));
    }

    #[test]
    fn missing_base_url_and_credentials_are_rejected() {
        let error = ScrobbleClient::build(
            ScrobbleConfig::new(ScrobbleService::LastFm).with_base_url(""),
            test_client(),
            Duration::ZERO,
        )
        .expect_err("空地址应该报错");
        assert_eq!(error.code, ErrorCode::InvalidArgument);

        let error = ScrobbleClient::build(
            ScrobbleConfig::new(ScrobbleService::LastFm)
                .with_base_url("https://example.invalid/2.0"),
            test_client(),
            Duration::ZERO,
        )
        .expect_err("缺 api_key 应该报错");
        assert_eq!(error.code, ErrorCode::Auth);

        // ListenBrainz 只需要 token；构造时不校验（用户可能稍后才授权）。
        let client = ScrobbleClient::build(
            ScrobbleConfig::new(ScrobbleService::ListenBrainz),
            test_client(),
            Duration::ZERO,
        )
        .expect("ListenBrainz 可以没有 token");
        assert_eq!(client.service(), ScrobbleService::ListenBrainz);
        assert_eq!(client.base_url(), "https://api.listenbrainz.org");
    }

    // ---- Last.fm 请求 ----------------------------------------------------

    #[tokio::test]
    async fn lastfm_now_playing_is_signed_and_posts_to_body() {
        let server = FakeServer::fixed(200, r#"{"nowplaying":{}}"#);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let track = Scrobble::new(
            "Radiohead",
            "Everything In Its Right Place",
            1_700_000_000_000,
        )
        .with_duration_ms(293_000)
        .with_track_number(3);
        client
            .now_playing(&track)
            .await
            .expect("now playing 应该成功");

        let requests = server.recorded();
        assert_eq!(requests.len(), 1);
        let request = &requests[0];
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/2.0", "凭据不能出现在 URL query 里");
        assert_eq!(
            request.header("content-type"),
            Some("application/x-www-form-urlencoded")
        );
        assert!(request
            .header("user-agent")
            .unwrap_or_default()
            .starts_with("LekisMusic/"));
        assert_eq!(
            form_value(&request.body, "method").as_deref(),
            Some("track.updateNowPlaying")
        );
        assert_eq!(
            form_value(&request.body, "track").as_deref(),
            Some("Everything%20In%20Its%20Right%20Place")
        );
        assert_eq!(
            form_value(&request.body, "duration").as_deref(),
            Some("293")
        );
        assert_eq!(
            form_value(&request.body, "trackNumber").as_deref(),
            Some("3")
        );
        assert_eq!(
            form_value(&request.body, "artist").as_deref(),
            Some("Radiohead")
        );
        assert_eq!(
            form_value(&request.body, "sk").as_deref(),
            Some(SESSION_KEY)
        );
        assert_eq!(
            form_value(&request.body, "api_key").as_deref(),
            Some(API_KEY)
        );
        assert_eq!(form_value(&request.body, "format").as_deref(), Some("json"));
        // secret 只在签名里体现，绝不能出现在请求体或 URL 上。
        assert!(!request.body.contains(API_SECRET));
        assert!(!request.path.contains(API_KEY));
        assert_body_is_signed(&request.body);
    }

    #[tokio::test]
    async fn lastfm_scrobble_signs_and_batches() {
        let server = FakeServer::fixed(200, r#"{"scrobbles":{"@attr":{"accepted":2}}}"#);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let tracks = vec![
            paranoid_android(),
            Scrobble::new("Radiohead", "Karma Police", 1_700_000_300_000).with_duration_ms(264_000),
        ];
        client.scrobble(&tracks).await.expect("scrobble 应该成功");

        let requests = server.recorded();
        assert_eq!(requests.len(), 1, "两条记录应该打进同一个请求");
        let request = &requests[0];
        assert_eq!(request.path, "/2.0");
        let body = &request.body;
        assert_eq!(
            form_value(body, "method").as_deref(),
            Some("track.scrobble")
        );
        assert_eq!(form_value(body, "artist[0]").as_deref(), Some("Radiohead"));
        assert_eq!(
            form_value(body, "track[1]").as_deref(),
            Some("Karma%20Police")
        );
        // 时间戳是 Unix 秒，不是毫秒。
        assert_eq!(
            form_value(body, "timestamp[0]").as_deref(),
            Some("1700000000")
        );
        assert_eq!(
            form_value(body, "timestamp[1]").as_deref(),
            Some("1700000300")
        );
        // 没填的字段就不发。
        assert!(form_value(body, "mbid[0]").is_none());
        assert!(form_value(body, "trackNumber[0]").is_none());
        // 签名覆盖数组参数在内的全部参数。
        assert_body_is_signed(body);
    }

    #[tokio::test]
    async fn lastfm_scrobble_chunks_over_fifty_tracks() {
        let server = FakeServer::fixed(200, "{}");
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let tracks: Vec<Scrobble> = (0..(MAX_BATCH + 2))
            .map(|index| Scrobble::new("artist", format!("track-{index}"), 1_700_000_000_000))
            .collect();
        client.scrobble(&tracks).await.expect("分包上报应该成功");
        assert_eq!(server.recorded().len(), 2, "53 条应该拆成 2 个请求");
    }

    #[tokio::test]
    async fn lastfm_error_body_maps_to_auth_and_rate_limit() {
        let server = FakeServer::fixed(200, r#"{"error":9,"message":"Invalid session key"}"#);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let error = client
            .scrobble(&[paranoid_android()])
            .await
            .expect_err("错误体应该报错");
        assert_eq!(error.code, ErrorCode::Auth);
        assert!(error.message.contains("Invalid session key"));
        // 凭据错误重试无用，不计退避。
        assert_eq!(client.failures(), 0);

        for code in [8, 11, 16, 29] {
            let server =
                FakeServer::fixed(200, &format!(r#"{{"error":{code},"message":"later"}}"#));
            let client = client_for(ScrobbleService::LastFm, &server.api_url());
            let error = client
                .scrobble(&[paranoid_android()])
                .await
                .expect_err("可重试错误应该报错");
            assert_eq!(error.code, ErrorCode::RateLimited, "错误码 {code}");
            assert_eq!(client.failures(), 1);
            client.reset_backoff();
            assert_eq!(client.failures(), 0);
        }
    }

    #[tokio::test]
    async fn http_statuses_map_to_expected_error_codes() {
        assert_eq!(map_status(400), ErrorCode::InvalidArgument);
        assert_eq!(map_status(401), ErrorCode::Auth);
        assert_eq!(map_status(403), ErrorCode::Auth);
        assert_eq!(map_status(404), ErrorCode::NotFound);
        assert_eq!(map_status(422), ErrorCode::InvalidArgument);
        assert_eq!(map_status(429), ErrorCode::RateLimited);
        assert_eq!(map_status(500), ErrorCode::Network);
        assert_eq!(map_status(503), ErrorCode::Network);

        let server = FakeServer::fixed(500, "{}");
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let error = client
            .scrobble(&[paranoid_android()])
            .await
            .expect_err("5xx 应该报错");
        assert_eq!(error.code, ErrorCode::Network);
        assert_eq!(client.failures(), 1);

        let server = FakeServer::fixed(429, "{}");
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let error = client
            .scrobble(&[paranoid_android()])
            .await
            .expect_err("429 应该报错");
        assert_eq!(error.code, ErrorCode::RateLimited);
    }

    #[tokio::test]
    async fn scrobble_rejects_incomplete_tracks_without_sending() {
        let server = FakeServer::fixed(200, "{}");
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let error = client
            .scrobble(&[Scrobble::new("   ", "title", 0)])
            .await
            .expect_err("空艺人应该报错");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        let error = client
            .scrobble(&[Scrobble::new("artist", "", 0)])
            .await
            .expect_err("空标题应该报错");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        assert!(server.recorded().is_empty(), "校验失败不该发出请求");
        // 空切片是合法的空操作。
        client.scrobble(&[]).await.expect("空批量应该直接成功");
        assert!(server.recorded().is_empty());
    }

    #[tokio::test]
    async fn missing_session_key_reports_auth_without_sending() {
        let server = FakeServer::fixed(200, "{}");
        let config = ScrobbleConfig::new(ScrobbleService::LastFm)
            .with_base_url(server.api_url())
            .with_api_credentials(API_KEY, API_SECRET);
        let client =
            ScrobbleClient::build(config, test_client(), Duration::ZERO).expect("build client");
        let error = client
            .scrobble(&[paranoid_android()])
            .await
            .expect_err("缺 session key 应该报错");
        assert_eq!(error.code, ErrorCode::Auth);
        assert!(server.recorded().is_empty());
    }

    // ---- 授权流程 --------------------------------------------------------

    #[tokio::test]
    async fn auth_flow_gets_token_then_session_key() {
        let server = FakeServer::start(vec![
            (200, r#"{"token":"request-token-abc"}"#.to_string()),
            (
                200,
                r#"{"session":{"name":"dj","key":"new-session-key","subscriber":0}}"#.to_string(),
            ),
        ]);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());

        let request = client.begin_auth().await.expect("auth.getToken 应该成功");
        assert_eq!(request.token(), "request-token-abc");
        // 自建/注入的 base_url：站点根去掉 `/2.0`，token 也带进授权页。
        assert_eq!(
            request.url(),
            format!(
                "{}/api/auth/?api_key={API_KEY}&token=request-token-abc",
                server.root()
            )
        );
        // URL 里绝对不能出现 secret。
        assert!(!request.url().contains(API_SECRET));

        let session_key = client
            .complete_auth(request.token())
            .await
            .expect("auth.getSession 应该成功");
        assert_eq!(session_key, "new-session-key");

        let requests = server.recorded();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].path, "/2.0");
        assert_eq!(
            form_value(&requests[0].body, "method").as_deref(),
            Some("auth.getToken")
        );
        assert_eq!(
            form_value(&requests[1].body, "method").as_deref(),
            Some("auth.getSession")
        );
        assert_eq!(
            form_value(&requests[1].body, "token").as_deref(),
            Some("request-token-abc")
        );
        // 两次请求都带签名，且 body 里都没有 secret。
        for recorded in &requests {
            assert!(!recorded.body.contains(API_SECRET));
            assert_body_is_signed(&recorded.body);
        }
    }

    #[test]
    fn auth_url_follows_custom_base_url() {
        // 自建实例：站点根从 base_url 去掉 /2.0 得到。
        let client = client_for(ScrobbleService::LibreFm, "https://libre.example/2.0");
        assert_eq!(
            client.auth_url("key", "tok"),
            "https://libre.example/api/auth/?api_key=key&token=tok"
        );
        // 官方 Last.fm：API 域名和网页域名不同，走服务自带的站点根。
        let client = client_for(ScrobbleService::LastFm, "https://ws.audioscrobbler.com/2.0");
        assert_eq!(
            client.auth_url("key", "tok"),
            "https://www.last.fm/api/auth/?api_key=key&token=tok"
        );
        // 官方 Libre.fm 同理。
        let client = client_for(ScrobbleService::LibreFm, "https://libre.fm/2.0");
        assert_eq!(
            client.auth_url("key", "tok"),
            "https://libre.fm/api/auth/?api_key=key&token=tok"
        );
    }

    #[tokio::test]
    async fn auth_rejects_empty_token_and_unexpected_bodies() {
        let server = FakeServer::fixed(200, r#"{"unexpected":true}"#);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        assert_eq!(
            client
                .complete_auth("   ")
                .await
                .expect_err("空 token")
                .code,
            ErrorCode::InvalidArgument
        );
        // 响应里没有 session 对象 → Decode，而不是 panic。
        let error = client
            .complete_auth("token")
            .await
            .expect_err("缺少 session 字段应该报错");
        assert_eq!(error.code, ErrorCode::Decode);

        let server = FakeServer::fixed(200, r#"{"token":""}"#);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        assert_eq!(
            client
                .begin_auth()
                .await
                .expect_err("空 token 应该报错")
                .code,
            ErrorCode::Decode
        );
    }

    #[tokio::test]
    async fn listenbrainz_has_no_token_auth_flow() {
        let client = client_for(
            ScrobbleService::ListenBrainz,
            "https://api.listenbrainz.org",
        );
        assert_eq!(
            client.begin_auth().await.expect_err("不该支持").code,
            ErrorCode::Unsupported
        );
        assert_eq!(
            client
                .complete_auth("token")
                .await
                .expect_err("不该支持")
                .code,
            ErrorCode::Unsupported
        );
    }

    // ---- ListenBrainz ----------------------------------------------------

    #[tokio::test]
    async fn listenbrainz_submits_single_listen_with_token_header() {
        let server = FakeServer::fixed(200, r#"{"status":"ok"}"#);
        let client = client_for(ScrobbleService::ListenBrainz, &server.root());

        client
            .scrobble(&[paranoid_android()])
            .await
            .expect("ListenBrainz 上报应该成功");
        let requests = server.recorded();
        assert_eq!(requests.len(), 1);
        let request = &requests[0];
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/1/submit-listens");
        let expected_auth = format!("Token {USER_TOKEN}");
        assert_eq!(
            request.header("authorization"),
            Some(expected_auth.as_str())
        );
        assert_eq!(request.header("content-type"), Some("application/json"));

        let body: Value = serde_json::from_str(&request.body).expect("body 是 JSON");
        assert_eq!(body["listen_type"], "single");
        let payload = body["payload"].as_array().expect("payload 是数组");
        assert_eq!(payload.len(), 1);
        assert_eq!(payload[0]["listened_at"], 1_700_000_000_i64);
        assert_eq!(payload[0]["track_metadata"]["artist_name"], "Radiohead");
        assert_eq!(
            payload[0]["track_metadata"]["track_name"],
            "Paranoid Android"
        );
        assert_eq!(payload[0]["track_metadata"]["release_name"], "OK Computer");
        assert_eq!(
            payload[0]["track_metadata"]["additional_info"]["duration_ms"],
            250_000_u64
        );
        // 没填曲序就不该出现 tracknumber 字段。
        assert!(payload[0]["track_metadata"]["additional_info"]["tracknumber"].is_null());
        assert!(
            payload[0]["track_metadata"]["additional_info"]["submission_client"]
                .as_str()
                .unwrap_or_default()
                .starts_with("LekisMusic/")
        );
        // token 只在头里，不进 URL 也不进 body。
        assert!(!request.path.contains(USER_TOKEN));
        assert!(!request.body.contains(USER_TOKEN));
    }

    #[tokio::test]
    async fn listenbrainz_playing_now_omits_listened_at() {
        let server = FakeServer::fixed(200, r#"{"status":"ok"}"#);
        let client = client_for(ScrobbleService::ListenBrainz, &server.root());
        client
            .now_playing(&paranoid_android())
            .await
            .expect("playing_now 应该成功");
        let requests = server.recorded();
        let body: Value = serde_json::from_str(&requests[0].body).expect("body 是 JSON");
        assert_eq!(body["listen_type"], "playing_now");
        let listen = &body["payload"][0];
        assert!(
            listen.get("listened_at").is_none(),
            "playing_now 按规范不能带 listened_at"
        );
        assert_eq!(listen["track_metadata"]["track_name"], "Paranoid Android");
    }

    #[tokio::test]
    async fn listenbrainz_multiple_listens_use_import_and_tracknumber_is_string() {
        let server = FakeServer::fixed(200, "{}");
        let client = client_for(ScrobbleService::ListenBrainz, &server.root());
        let tracks = vec![
            paranoid_android().with_track_number(10),
            Scrobble::new("Radiohead", "Let Down", 1_700_000_300_000).with_duration_ms(299_000),
        ];
        client.scrobble(&tracks).await.expect("批量上报应该成功");
        let body: Value = serde_json::from_str(&server.recorded()[0].body).expect("body 是 JSON");
        assert_eq!(body["listen_type"], "import");
        assert_eq!(body["payload"].as_array().map(Vec::len), Some(2));
        // 规范要求 tracknumber 是字符串，duration_ms 是数字。
        assert_eq!(
            body["payload"][0]["track_metadata"]["additional_info"]["tracknumber"],
            "10"
        );
        assert_eq!(
            body["payload"][1]["track_metadata"]["additional_info"]["duration_ms"],
            299_000_u64
        );
    }

    #[tokio::test]
    async fn listenbrainz_unauthorized_token_maps_to_auth() {
        let server =
            FakeServer::fixed(401, r#"{"code":401,"error":"Invalid authorization token"}"#);
        let client = client_for(ScrobbleService::ListenBrainz, &server.root());
        let error = client
            .scrobble(&[paranoid_android()])
            .await
            .expect_err("401 应该报错");
        assert_eq!(error.code, ErrorCode::Auth);
        // 凭据类错误不该拉长退避（重试也没用）。
        assert_eq!(client.failures(), 0);
    }

    #[tokio::test]
    async fn listenbrainz_without_token_reports_auth() {
        let server = FakeServer::fixed(200, "{}");
        let config =
            ScrobbleConfig::new(ScrobbleService::ListenBrainz).with_base_url(server.root());
        let client =
            ScrobbleClient::build(config, test_client(), Duration::ZERO).expect("build client");
        assert_eq!(
            client
                .scrobble(&[paranoid_android()])
                .await
                .expect_err("缺 token")
                .code,
            ErrorCode::Auth
        );
        assert!(server.recorded().is_empty(), "没 token 就不该发请求");
    }

    // ---- 补报 ------------------------------------------------------------

    #[tokio::test]
    async fn flush_sends_queue_and_keeps_failed_items() {
        let server = FakeServer::start(vec![(200, "{}".to_string()), (500, "{}".to_string())]);
        let client = client_for(ScrobbleService::LastFm, &server.api_url());
        let mut queue = ScrobbleQueue::new();
        queue.enqueue(paranoid_android());

        assert_eq!(client.flush(&mut queue).await.expect("第一轮应该成功"), 1);
        assert!(queue.is_empty());

        // 第二轮：服务端开始 500，记录必须留在队列里。
        queue.enqueue(paranoid_android());
        let error = client.flush(&mut queue).await.expect_err("第二轮应该失败");
        assert_eq!(error.code, ErrorCode::Network);
        assert_eq!(queue.len(), 1, "失败的记录不能被丢掉");
        assert_eq!(client.failures(), 1);
    }

    #[tokio::test]
    async fn libre_fm_uses_lastfm_protocol() {
        let server = FakeServer::fixed(200, "{}");
        let client = client_for(ScrobbleService::LibreFm, &server.api_url());
        client
            .scrobble(&[paranoid_android()])
            .await
            .expect("应该成功");
        let request = &server.recorded()[0];
        assert_eq!(request.path, "/2.0");
        assert_eq!(
            form_value(&request.body, "method").as_deref(),
            Some("track.scrobble")
        );
        // 同一套签名算法，签名覆盖参数表里全部字段。
        assert_body_is_signed(&request.body);
    }
}
