//! 第三方听歌记录上报（DIS-07）的核心服务。
//!
//! [`lekis_enrich::scrobble`] 只提供协议客户端、队列和纯判定函数；本模块负责：
//! - 把设置（启用 / 服务 / 用户名 / now-playing）存进 `kv`，凭据存进平台钥匙串；
//! - 监听播放快照，按**实际播放时长**判定是否达到 Last.fm 规则；
//! - 达到阈值时入队，由后台任务补报（断网时保留在 JSON 队列里）；
//! - 给桥接层提供设置 / 状态 / 连接测试。
//!
//! 隐私约定：日志里只有服务名、动作、错误码、队列条数；API key / secret /
//! session key / user token 一律不打印，且只从平台凭据存储读取。

use crate::platform::CredentialStore;
use lekis_enrich::scrobble::{
    should_scrobble, Scrobble, ScrobbleClient, ScrobbleConfig, ScrobbleQueue, ScrobbleService,
    MAX_BATCH,
};
use lekis_library::Library;
use lekis_playback::PlaybackSnapshot;
use lekis_types::{now_ms, PlaybackState, Result, TrackId};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::{watch, Notify};

/// 是否启用上报（`"true"` / `"false"`，默认关）。
pub const ENABLED_KEY: &str = "scrobble.enabled";
/// 服务：`lastfm`（默认）/ `listenbrainz` / `librefm`。
pub const SERVICE_KEY: &str = "scrobble.service";
/// 用户名（Last.fm / Libre.fm 的 `user.getInfo` 连接测试需要；上报本身不强制）。
pub const USERNAME_KEY: &str = "scrobble.username";
/// 是否发送 now-playing（默认开，取决于各服务的行为）。
pub const NOW_PLAYING_KEY: &str = "scrobble.now_playing";

/// 队列文件名（放在核心数据目录）。
const QUEUE_FILE: &str = "scrobble_queue.json";

/// 后台补报的兜底轮询间隔（没有新记录时也会定期重试断网期间积压的队列）。
const RETRY_INTERVAL: Duration = Duration::from_secs(60);

/// 单次快照最多记多少播放时长。设备休眠 / 应用被挂起后恢复时，两个 tick 之间
/// 可能隔很久；按真实墙钟累加会把没播的时间也算进去。
const MAX_TICK_MS: u64 = 2_000;

/// 上报设置（给 UI 的安全视图：只有"是否已保存"，没有明文凭据）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbleSettings {
    /// 是否启用。
    pub enabled: bool,
    /// 服务标识（`lastfm` / `listenbrainz` / `librefm`）。
    pub service: String,
    /// 用户名。
    pub username: Option<String>,
    /// 是否发送 now-playing。
    pub now_playing: bool,
    /// 是否已经保存 API key。
    pub has_api_key: bool,
    /// 是否已经保存 API secret。
    pub has_api_secret: bool,
    /// 是否已经保存 session key（Last.fm / Libre.fm）。
    pub has_session_key: bool,
    /// 是否已经保存 user token（ListenBrainz）。
    pub has_user_token: bool,
}

impl ScrobbleSettings {
    fn empty() -> Self {
        Self {
            enabled: false,
            service: "lastfm".to_string(),
            username: None,
            now_playing: true,
            has_api_key: false,
            has_api_secret: false,
            has_session_key: false,
            has_user_token: false,
        }
    }

    /// 当前服务的凭据是否齐全。UI 可以据此显示"已就绪 / 缺少凭据"。
    pub fn configured(&self) -> bool {
        match parse_service(&self.service) {
            ScrobbleService::ListenBrainz => self.has_user_token,
            _ => self.has_api_key && self.has_api_secret && self.has_session_key,
        }
    }
}

/// 修改设置。凭据字段是 `Option<String>`：`None` 保留原值，`Some("")` 删除，
/// `Some(secret)` 覆盖。这样 UI 不需要把已保存的密钥读回 Dart。
#[derive(Debug, Clone, Default)]
pub struct ScrobbleSettingsInput {
    /// 是否启用。
    pub enabled: bool,
    /// 服务标识。
    pub service: String,
    /// 用户名（空字符串清除）。
    pub username: String,
    /// 是否发送 now-playing。
    pub now_playing: bool,
    /// Last.fm / Libre.fm 的应用 API key。
    pub api_key: Option<String>,
    /// Last.fm / Libre.fm 的应用 API secret。
    pub api_secret: Option<String>,
    /// Last.fm / Libre.fm 的长期 session key。
    pub session_key: Option<String>,
    /// ListenBrainz 的 user token。
    pub user_token: Option<String>,
}

/// 上报状态（设置页显示队列与最近错误）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrobbleStatus {
    /// 客户端是否已经配置完整（启用且凭据齐全）。
    pub configured: bool,
    /// 用户是否打开开关。
    pub enabled: bool,
    /// 服务标识。
    pub service: String,
    /// 待补报条数。
    pub queued: u32,
    /// 最近一次失败的错误文本（不含凭据；成功时清空）。
    pub last_error: Option<String>,
    /// 最近一次成功上报 / 连接测试的 Unix 毫秒。
    pub last_success_at_ms: Option<i64>,
}

impl ScrobbleStatus {
    fn from(inner: &Inner, queued: u32) -> Self {
        Self {
            configured: inner.client.is_some(),
            enabled: inner.settings.enabled,
            service: inner.settings.service.clone(),
            queued,
            last_error: inner.last_error.clone(),
            last_success_at_ms: inner.last_success_at_ms,
        }
    }
}

struct Inner {
    settings: ScrobbleSettings,
    client: Option<Arc<ScrobbleClient>>,
    last_error: Option<String>,
    last_success_at_ms: Option<i64>,
}

/// 核心里的上报服务。线程安全，可被播放监听、桥接和后台补报任务共享。
pub struct Scrobbler {
    library: Library,
    credentials: Arc<dyn CredentialStore>,
    queue_path: PathBuf,
    queue: Mutex<ScrobbleQueue>,
    flush_lock: tokio::sync::Mutex<()>,
    inner: RwLock<Inner>,
    wake: Notify,
    load_lock: tokio::sync::Mutex<()>,
    loaded: AtomicBool,
}

impl Scrobbler {
    /// 创建（设置和队列在 [`Self::load`] 里异步读入）。
    pub fn new(library: Library, credentials: Arc<dyn CredentialStore>, data_dir: &Path) -> Self {
        Self {
            library,
            credentials,
            queue_path: data_dir.join(QUEUE_FILE),
            queue: Mutex::new(ScrobbleQueue::new()),
            flush_lock: tokio::sync::Mutex::new(()),
            inner: RwLock::new(Inner {
                settings: ScrobbleSettings::empty(),
                client: None,
                last_error: None,
                last_success_at_ms: None,
            }),
            wake: Notify::new(),
            load_lock: tokio::sync::Mutex::new(()),
            loaded: AtomicBool::new(false),
        }
    }

    /// 从 `kv` 和平台凭据存储恢复设置，并读回落盘的待补报队列。
    pub async fn load(&self) {
        let _guard = self.load_lock.lock().await;
        if self.loaded.load(Ordering::Acquire) {
            return;
        }
        let settings = self.read_settings().await;
        let (client, error) = self.build_client(&settings);
        if let Ok(mut inner) = self.inner.write() {
            inner.settings = settings;
            inner.client = client;
            inner.last_error = error;
        }
        self.load_queue();
        self.loaded.store(true, Ordering::Release);
        if self.queue_len() > 0 {
            // 上次退出时还有积压：启动后尽快补报，不用等 60 秒兜底轮询。
            self.wake.notify_one();
        }
        tracing::debug!(
            target: "lekis_core::scrobble",
            service = %self.settings().service,
            enabled = self.settings().enabled,
            queued = self.queue_len(),
            "scrobble settings loaded",
        );
    }

    /// 当前设置（不含明文凭据）。
    pub fn settings(&self) -> ScrobbleSettings {
        self.inner
            .read()
            .map(|inner| inner.settings.clone())
            .unwrap_or_else(|_| ScrobbleSettings::empty())
    }

    /// 当前状态。
    pub fn status(&self) -> ScrobbleStatus {
        let queued = self.queue_len() as u32;
        self.inner
            .read()
            .map(|inner| ScrobbleStatus::from(&inner, queued))
            .unwrap_or(ScrobbleStatus {
                configured: false,
                enabled: false,
                service: "lastfm".to_string(),
                queued,
                last_error: Some("scrobble state is unavailable".to_string()),
                last_success_at_ms: None,
            })
    }

    /// 保存设置（非机密字段进 `kv`，机密字段进平台凭据存储）。
    pub async fn update(&self, input: ScrobbleSettingsInput) -> Result<ScrobbleSettings> {
        // 避免启动时的异步 load 在用户保存之后又把旧值写回内存。
        self.load().await;
        let previous_service = self.settings().service;
        let service = parse_service(&input.service);
        let service_id = service_id(service);
        self.library
            .set_setting(ENABLED_KEY, if input.enabled { "true" } else { "false" })
            .await?;
        self.library.set_setting(SERVICE_KEY, service_id).await?;
        self.library
            .set_setting(
                NOW_PLAYING_KEY,
                if input.now_playing { "true" } else { "false" },
            )
            .await?;
        let username = input.username.trim();
        if username.is_empty() {
            self.library.delete_setting(USERNAME_KEY).await?;
        } else {
            self.library.set_setting(USERNAME_KEY, username).await?;
        }

        self.apply_secret(service, "api_key", input.api_key)?;
        self.apply_secret(service, "api_secret", input.api_secret)?;
        self.apply_secret(service, "session_key", input.session_key)?;
        self.apply_secret(service, "user_token", input.user_token)?;

        let settings = self.read_settings().await;
        let (client, error) = self.build_client(&settings);
        if let Ok(mut inner) = self.inner.write() {
            inner.settings = settings.clone();
            inner.client = client;
            inner.last_error = error;
            inner.last_success_at_ms = None;
        }
        if previous_service != service_id {
            // 待补报记录没有记录目标服务；换服务时不能把 Last.fm 的记录发给
            // ListenBrainz（反之亦然），直接丢弃旧队列。
            if let Ok(mut queue) = self.queue.lock() {
                if !queue.is_empty() {
                    tracing::info!(
                        target: "lekis_core::scrobble",
                        dropped = queue.len(),
                        "scrobble service changed; discarding the old pending queue"
                    );
                    queue.clear();
                }
            }
            self.save_queue();
        }
        tracing::info!(
            target: "lekis_core::scrobble",
            service = service_id,
            enabled = settings.enabled,
            configured = settings.configured(),
            "scrobble settings updated",
        );
        if settings.enabled {
            self.wake.notify_one();
        }
        Ok(settings)
    }

    /// 测试当前配置（只读接口，不产生 scrobble / now-playing）。
    pub async fn test(&self) -> Result<()> {
        self.load().await;
        let (client, username) = {
            let inner = self
                .inner
                .read()
                .map_err(|_| lekis_types::LekisError::internal("scrobble state is unavailable"))?;
            let client = inner.client.clone().ok_or_else(|| {
                lekis_types::LekisError::new(
                    lekis_types::ErrorCode::Auth,
                    "scrobble is not configured (enable it and fill in the credentials first)",
                )
            })?;
            (client, inner.settings.username.clone())
        };
        match client.test_connection(username.as_deref()).await {
            Ok(()) => {
                self.note_success();
                Ok(())
            }
            Err(e) => {
                self.note_error(&e);
                Err(e)
            }
        }
    }

    /// 入队并唤醒补报任务。未启用 / 未配置时直接丢弃（不产生任何网络请求）。
    fn enqueue(&self, scrobble: Scrobble) {
        let inner = match self.inner.read() {
            Ok(inner) => inner,
            Err(_) => return,
        };
        if !inner.settings.enabled || inner.client.is_none() {
            return;
        }
        drop(inner);
        if let Ok(mut queue) = self.queue.lock() {
            queue.enqueue(scrobble);
        }
        self.save_queue();
        self.wake.notify_one();
    }

    /// 尽力补报当前队列，返回成功条数。
    pub async fn flush_once(&self) -> Result<usize> {
        let client = match self.inner.read() {
            Ok(inner) if inner.settings.enabled => inner.client.clone(),
            _ => None,
        };
        let Some(client) = client else {
            return Ok(0);
        };
        // 同一时间只跑一轮补报，避免两个任务重复取走同一批。
        let _guard = self.flush_lock.lock().await;
        let mut sent = 0usize;
        loop {
            let batch = match self.queue.lock() {
                Ok(mut queue) => queue.drain(MAX_BATCH),
                Err(_) => return Ok(sent),
            };
            if batch.is_empty() {
                break;
            }
            match client.scrobble(&batch).await {
                Ok(()) => {
                    sent += batch.len();
                    self.save_queue();
                    self.note_success();
                }
                Err(e) => {
                    if let Ok(mut queue) = self.queue.lock() {
                        queue.requeue(batch);
                    }
                    self.save_queue();
                    self.note_error(&e);
                    return Err(e);
                }
            }
        }
        Ok(sent)
    }

    /// 后台补报循环：新记录立即尝试，失败后最多每分钟重试一次。
    pub async fn run_worker(self: Arc<Self>) {
        loop {
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(RETRY_INTERVAL) => {}
            }
            if let Err(e) = self.flush_once().await {
                tracing::debug!(
                    target: "lekis_core::scrobble",
                    code = e.code.as_str(),
                    queued = self.queue_len(),
                    "scrobble flush failed; records stay queued"
                );
            }
        }
    }

    fn queue_len(&self) -> usize {
        self.queue.lock().map(|q| q.len()).unwrap_or(0)
    }

    fn note_success(&self) {
        if let Ok(mut inner) = self.inner.write() {
            inner.last_error = None;
            inner.last_success_at_ms = Some(now_ms());
        }
    }

    fn note_error(&self, error: &lekis_types::LekisError) {
        if let Ok(mut inner) = self.inner.write() {
            // 错误文本由 enrich 层生成，只有服务名 / 状态码，不含 URL 或凭据。
            inner.last_error = Some(error.message.clone());
        }
    }

    fn apply_secret(
        &self,
        service: ScrobbleService,
        name: &str,
        value: Option<String>,
    ) -> Result<()> {
        let Some(value) = value else {
            return Ok(());
        };
        let key = credential_ref(service, name);
        let value = value.trim();
        if value.is_empty() {
            self.credentials.delete(&key)
        } else {
            self.credentials.set(&key, value)
        }
    }

    async fn read_settings(&self) -> ScrobbleSettings {
        let enabled = self
            .library
            .get_setting(ENABLED_KEY)
            .await
            .ok()
            .flatten()
            .map(|value| value != "false")
            .unwrap_or(false);
        let service_value = self
            .library
            .get_setting(SERVICE_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| "lastfm".to_string());
        let service = parse_service(&service_value);
        let username = self
            .library
            .get_setting(USERNAME_KEY)
            .await
            .ok()
            .flatten()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let now_playing = self
            .library
            .get_setting(NOW_PLAYING_KEY)
            .await
            .ok()
            .flatten()
            .map(|value| value != "false")
            .unwrap_or(true);
        ScrobbleSettings {
            enabled,
            service: service_id(service).to_string(),
            username,
            now_playing,
            has_api_key: self.has_secret(service, "api_key"),
            has_api_secret: self.has_secret(service, "api_secret"),
            has_session_key: self.has_secret(service, "session_key"),
            has_user_token: self.has_secret(service, "user_token"),
        }
    }

    fn has_secret(&self, service: ScrobbleService, name: &str) -> bool {
        self.credentials
            .get(&credential_ref(service, name))
            .is_some_and(|value| !value.trim().is_empty())
    }

    fn build_client(
        &self,
        settings: &ScrobbleSettings,
    ) -> (Option<Arc<ScrobbleClient>>, Option<String>) {
        if !settings.enabled {
            return (None, None);
        }
        let service = parse_service(&settings.service);
        let mut config = ScrobbleConfig::new(service);
        if service.uses_api_signature() {
            let api_key = self.credentials.get(&credential_ref(service, "api_key"));
            let api_secret = self.credentials.get(&credential_ref(service, "api_secret"));
            let session_key = self
                .credentials
                .get(&credential_ref(service, "session_key"));
            let (Some(api_key), Some(api_secret), Some(session_key)) =
                (api_key, api_secret, session_key)
            else {
                return (
                    None,
                    Some(format!(
                        "{} 还缺 API key / API secret / session key",
                        service.name()
                    )),
                );
            };
            config = config
                .with_api_credentials(api_key, api_secret)
                .with_session_key(session_key);
        } else {
            let Some(user_token) = self.credentials.get(&credential_ref(service, "user_token"))
            else {
                return (None, Some(format!("{} 还缺 user token", service.name())));
            };
            config = config.with_user_token(user_token);
        }
        match ScrobbleClient::new(config) {
            Ok(client) => (Some(Arc::new(client)), None),
            Err(e) => (None, Some(e.message)),
        }
    }

    fn load_queue(&self) {
        let Ok(text) = std::fs::read_to_string(&self.queue_path) else {
            return;
        };
        match ScrobbleQueue::from_json(&text) {
            Ok(queue) => {
                let count = queue.len();
                if let Ok(mut current) = self.queue.lock() {
                    *current = queue;
                }
                if count > 0 {
                    tracing::info!(
                        target: "lekis_core::scrobble",
                        count,
                        "restored pending scrobbles from disk"
                    );
                }
            }
            Err(e) => {
                tracing::warn!(
                    target: "lekis_core::scrobble",
                    code = e.code.as_str(),
                    "scrobble queue file is corrupt; starting with an empty queue"
                );
            }
        }
    }

    fn save_queue(&self) {
        let queue = match self.queue.lock() {
            Ok(queue) => queue.clone(),
            Err(_) => return,
        };
        let json = match queue.to_json() {
            Ok(json) => json,
            Err(e) => {
                tracing::warn!(
                    target: "lekis_core::scrobble",
                    code = e.code.as_str(),
                    "cannot serialize scrobble queue"
                );
                return;
            }
        };
        let tmp = self.queue_path.with_extension("json.tmp");
        if let Some(dir) = self.queue_path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Err(e) = std::fs::write(&tmp, json) {
            tracing::warn!(
                target: "lekis_core::scrobble",
                error = %e,
                "cannot write scrobble queue"
            );
            return;
        }
        if let Err(e) = std::fs::rename(&tmp, &self.queue_path) {
            tracing::warn!(
                target: "lekis_core::scrobble",
                error = %e,
                "cannot replace scrobble queue"
            );
        }
    }
}

/// 播放监听：累计**真实播放时长**（暂停、缓冲不算），达到阈值后只提交一次。
///
/// 不按进度条位置计算，所以用户拖到 99% 不会立刻产生 scrobble；seek 只影响
/// 当前曲目的后续累计，不会把跳过的部分算成听过。
pub(crate) async fn track_playback(
    mut snapshots: watch::Receiver<PlaybackSnapshot>,
    scrobbler: Arc<Scrobbler>,
    library: Library,
) {
    let mut last = snapshots.borrow().clone();
    let mut last_instant = Instant::now();
    let mut run: Option<TrackRun> = None;

    loop {
        if snapshots.changed().await.is_err() {
            break;
        }
        let snap = snapshots.borrow_and_update().clone();
        let now = Instant::now();
        let elapsed_ms = (now.duration_since(last_instant).as_millis() as u64).min(MAX_TICK_MS);
        last_instant = now;

        let track_changed = run
            .as_ref()
            .is_some_and(|current| Some(current.track_id) != snap.track_id);
        if track_changed {
            if let Some(mut previous) = run.take() {
                if last.state == PlaybackState::Playing {
                    previous.played_ms = previous.played_ms.saturating_add(elapsed_ms);
                }
                previous.finalize(&scrobbler);
            }
        }

        let mut started_new = false;
        if run.is_none() {
            if let Some(track_id) = snap.track_id {
                let metadata = match library.get_track(track_id).await {
                    Ok(track) => Some(track),
                    Err(e) => {
                        tracing::debug!(
                            target: "lekis_core::scrobble",
                            %track_id,
                            code = e.code.as_str(),
                            "cannot load track metadata; scrobbling is disabled for this track"
                        );
                        None
                    }
                };
                run = Some(TrackRun::new(track_id, metadata));
                started_new = true;
            }
        }

        if let Some(current) = run.as_mut() {
            if !started_new && !track_changed && last.state == PlaybackState::Playing {
                current.played_ms = current.played_ms.saturating_add(elapsed_ms);
            }
            current.duration_ms = current.duration_ms.max(snap.duration_ms);
            if snap.state == PlaybackState::Playing {
                current.start_if_needed();
                current.announce_now_playing(&scrobbler);
                current.maybe_submit(&scrobbler);
            } else if last.state == PlaybackState::Playing && !started_new && !track_changed {
                // 暂停 / 结束：把最后一个 tick 到停止之间的时长也算进去。
                current.finalize(&scrobbler);
            }
        }

        last = snap;
    }

    if let Some(mut current) = run.take() {
        current.finalize(&scrobbler);
    }
}

/// 一首曲目的播放账本。
struct TrackRun {
    track_id: TrackId,
    track: Option<lekis_types::Track>,
    duration_ms: u64,
    played_ms: u64,
    started_at_ms: Option<i64>,
    submitted: bool,
    now_playing_sent: bool,
}

impl TrackRun {
    fn new(track_id: TrackId, track: Option<lekis_types::Track>) -> Self {
        let duration_ms = track.as_ref().map(|track| track.duration_ms).unwrap_or(0);
        Self {
            track_id,
            track,
            duration_ms,
            played_ms: 0,
            started_at_ms: None,
            submitted: false,
            now_playing_sent: false,
        }
    }

    fn start_if_needed(&mut self) {
        if self.started_at_ms.is_none() {
            self.started_at_ms = Some(now_ms());
        }
    }

    fn duration_ms(&self) -> u64 {
        self.duration_ms
    }

    fn scrobble(&self, duration_ms: u64) -> Option<Scrobble> {
        let track = self.track.as_ref()?;
        let artist = track
            .artists
            .first()
            .map(|credit| credit.name.trim())
            .filter(|name| !name.is_empty())?;
        let title = track.title.trim();
        if title.is_empty() {
            return None;
        }
        let mut scrobble = Scrobble::new(artist, title, self.started_at_ms.unwrap_or_else(now_ms))
            .with_duration_ms(duration_ms.max(track.duration_ms));
        if let Some(album) = track
            .album_title
            .as_deref()
            .map(str::trim)
            .filter(|album| !album.is_empty())
        {
            scrobble = scrobble.with_album(album);
        }
        if let Some(mbid) = track
            .mbid_recording
            .as_deref()
            .map(str::trim)
            .filter(|mbid| !mbid.is_empty())
        {
            scrobble = scrobble.with_mbid_recording(mbid);
        }
        if let Some(track_no) = track.track_no.filter(|number| *number > 0) {
            scrobble = scrobble.with_track_number(track_no);
        }
        Some(scrobble)
    }

    fn announce_now_playing(&mut self, scrobbler: &Scrobbler) {
        if self.now_playing_sent {
            return;
        }
        let settings = scrobbler.settings();
        if !settings.enabled || !settings.now_playing {
            return;
        }
        let Some(track) = self.scrobble(self.duration_ms()) else {
            return;
        };
        let client = match scrobbler.inner.read() {
            Ok(inner) => inner.client.clone(),
            Err(_) => None,
        };
        let Some(client) = client else {
            return;
        };
        self.now_playing_sent = true;
        // 网络请求绝不阻塞播放快照循环。
        tokio::spawn(async move {
            if let Err(e) = client.now_playing(&track).await {
                tracing::debug!(
                    target: "lekis_core::scrobble",
                    code = e.code.as_str(),
                    service = client.service().name(),
                    "now-playing failed"
                );
            }
        });
    }

    fn maybe_submit(&mut self, scrobbler: &Scrobbler) {
        if self.submitted {
            return;
        }
        let duration = self.duration_ms();
        if !should_scrobble(duration, self.played_ms) {
            return;
        }
        if let Some(scrobble) = self.scrobble(duration) {
            self.submitted = true;
            scrobbler.enqueue(scrobble);
            tracing::debug!(
                target: "lekis_core::scrobble",
                track = %self.track_id,
                played_ms = self.played_ms,
                duration_ms = duration,
                "play threshold reached; scrobble queued"
            );
        }
    }

    fn finalize(&mut self, scrobbler: &Scrobbler) {
        // 曲目结束 / 切歌 / 暂停：把这一小段也算进去再判定。
        self.maybe_submit(scrobbler);
    }
}

/// 服务标识 → 枚举。未知值按 Last.fm 处理（向前兼容）。
pub(crate) fn parse_service(value: &str) -> ScrobbleService {
    match value.trim().to_ascii_lowercase().as_str() {
        "listenbrainz" | "listen_brainz" | "lb" => ScrobbleService::ListenBrainz,
        "librefm" | "libre.fm" | "libre_fm" => ScrobbleService::LibreFm,
        _ => ScrobbleService::LastFm,
    }
}

/// 枚举 → 稳定存储值。
pub(crate) fn service_id(service: ScrobbleService) -> &'static str {
    match service {
        ScrobbleService::LastFm => "lastfm",
        ScrobbleService::LibreFm => "librefm",
        ScrobbleService::ListenBrainz => "listenbrainz",
    }
}

/// 凭据引用：按服务分开存，切换服务不会互相覆盖。
fn credential_ref(service: ScrobbleService, name: &str) -> String {
    format!("lekis.scrobble.{}.{name}", service_id(service))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn service_ids_roundtrip() {
        for service in [
            ScrobbleService::LastFm,
            ScrobbleService::LibreFm,
            ScrobbleService::ListenBrainz,
        ] {
            assert_eq!(parse_service(service_id(service)), service);
        }
        assert_eq!(parse_service("LISTENBRAINZ"), ScrobbleService::ListenBrainz);
        assert_eq!(parse_service("nonsense"), ScrobbleService::LastFm);
    }

    /// 官方阈值：>30 秒才够格；一半或 4 分钟取较短者。
    #[test]
    fn threshold_matches_lastfm_rules() {
        assert!(!should_scrobble(30_000, 30_000), "30 秒整不算");
        assert!(!should_scrobble(31_000, 15_499));
        assert!(should_scrobble(31_000, 15_500), "31 秒听一半算");
        assert!(should_scrobble(10 * 60_000, 4 * 60_000), "长曲 4 分钟封顶");
        assert!(!should_scrobble(10 * 60_000, 3 * 60_000));
    }

    /// 队列必须按 FIFO 出队、失败时原样放回队头。
    #[test]
    fn queue_drain_and_requeue_preserve_order() {
        let mut queue = ScrobbleQueue::new();
        for index in 0..5 {
            queue.enqueue(Scrobble::new(
                "artist",
                format!("track-{index}"),
                1_000 + index,
            ));
        }
        let batch = queue.drain(3);
        let titles: Vec<&str> = batch.iter().map(|item| item.title.as_str()).collect();
        assert_eq!(titles, vec!["track-0", "track-1", "track-2"]);
        assert_eq!(queue.len(), 2);
        queue.requeue(batch);
        assert_eq!(queue.len(), 5);
        let all = queue.drain(10);
        let titles: Vec<&str> = all.iter().map(|item| item.title.as_str()).collect();
        assert_eq!(
            titles,
            vec!["track-0", "track-1", "track-2", "track-3", "track-4"]
        );
    }

    /// 设置 / 凭据 / 队列的本地往返：测试里**不**发任何网络请求。
    #[tokio::test]
    async fn settings_credentials_and_queue_roundtrip_without_network() {
        let root = std::env::temp_dir().join(format!(
            "lekis-scrobble-settings-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create temp dir");
        let library = Library::open(&root.join("library.sqlite")).expect("open library");
        let credentials = Arc::new(crate::MemoryCredentialStore::default());
        let scrobbler = Scrobbler::new(library.clone(), credentials.clone(), &root);

        let settings = scrobbler
            .update(ScrobbleSettingsInput {
                enabled: true,
                service: "lastfm".into(),
                username: "lekis-user".into(),
                now_playing: true,
                api_key: Some("api-key".into()),
                api_secret: Some("api-secret".into()),
                session_key: Some("session-key".into()),
                user_token: None,
            })
            .await
            .expect("save settings");
        assert!(settings.enabled);
        assert!(settings.configured());
        assert!(settings.has_api_key && settings.has_api_secret && settings.has_session_key);
        assert_eq!(settings.username.as_deref(), Some("lekis-user"));
        assert_eq!(scrobbler.status().queued, 0);
        assert!(scrobbler.status().configured);

        // 凭据按服务分开保存；切换服务不会覆盖 Last.fm 的值。
        assert_eq!(
            credentials.get("lekis.scrobble.lastfm.api_key").as_deref(),
            Some("api-key")
        );
        let settings = scrobbler
            .update(ScrobbleSettingsInput {
                enabled: true,
                service: "listenbrainz".into(),
                username: "lekis-user".into(),
                now_playing: false,
                api_key: None,
                api_secret: None,
                session_key: None,
                user_token: Some("lb-token".into()),
            })
            .await
            .expect("switch to listenbrainz");
        assert!(settings.configured());
        assert!(settings.has_user_token);
        assert!(
            !settings.has_api_key,
            "Last.fm 凭据不应算到 ListenBrainz 上"
        );
        assert_eq!(
            credentials.get("lekis.scrobble.lastfm.api_key").as_deref(),
            Some("api-key")
        );

        // 入队 + 落盘；重新打开只读回队列，不发送。
        scrobbler.enqueue(Scrobble::new("周杰伦", "晴天", 1_700_000_000_000));
        assert_eq!(scrobbler.queue_len(), 1);
        let reopened = Scrobbler::new(library, credentials, &root);
        reopened.load_queue();
        assert_eq!(reopened.queue_len(), 1);
        assert_eq!(reopened.status().queued, 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    /// 暂停时间不能算成播放时间；达到阈值后只提交一次。
    #[test]
    fn track_run_accumulates_only_playing_time() {
        let track = lekis_types::Track {
            id: TrackId(1),
            uid: lekis_types::TrackUid("uid-1".into()),
            title: "晴天".into(),
            sort_title: None,
            artists: vec![lekis_types::ArtistCredit {
                artist_id: None,
                name: "周杰伦".into(),
                role: lekis_types::ArtistRole::Main,
            }],
            album_id: None,
            album_title: Some("叶惠美".into()),
            track_no: Some(3),
            disc_no: None,
            year: Some(2003),
            duration_ms: 40_000,
            genres: Vec::new(),
            mbid_recording: Some("mbid-1".into()),
            audio: None,
            replaygain: Default::default(),
            artwork_id: None,
            overlay: None,
            is_local: false,
        };
        let mut run = TrackRun::new(TrackId(1), Some(track));
        run.played_ms = 19_000;
        run.start_if_needed();
        assert!(!should_scrobble(40_000, run.played_ms));
        run.played_ms = 20_000;
        let scrobble = run
            .scrobble(40_000)
            .expect("metadata must produce a scrobble");
        assert_eq!(scrobble.artist, "周杰伦");
        assert_eq!(scrobble.title, "晴天");
        assert_eq!(scrobble.album.as_deref(), Some("叶惠美"));
        assert_eq!(scrobble.duration_ms, 40_000);
        assert_eq!(scrobble.track_number, Some(3));
        assert_eq!(scrobble.mbid_recording.as_deref(), Some("mbid-1"));
    }
}
