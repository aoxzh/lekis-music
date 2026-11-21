//! Lekis Connect：在其他设备上播放 / 遥控其他设备（CST-01~06）。
//!
//! - **发现**：每台运行中的 Lekis 用 mDNS / DNS-SD 广播 `_lekis._tcp`（TXT 里有设备 ID、名称、平台），
//!   同时持续浏览同类服务（[`mdns`]）。也可以手动按 IP:端口添加（组播被路由器挡住时）。
//! - **控制通道**：同一个 TCP 端口上一行一个 JSON（[`protocol`]）。第一次连接必须配对：
//!   被控端显示 6 位配对码，用户在控制端输入；之后用长期密钥做双向认证（[`crypto`]）。
//! - **媒体**：被控端优先从自己能访问的地方播放（同一音源 → 自己的资料库 → 控制端的局域网流），
//!   见 [`media`] 和 [`stream`]。
//! - **两种用法**：转移播放（把当前队列和进度交给另一台设备，本机暂停）和遥控（看 / 控制
//!   另一台设备自己的播放）。

mod client;
pub(crate) mod crypto;
mod mdns;
pub(crate) mod media;
mod peers;
pub mod protocol;
mod server;
pub(crate) mod stream;

pub use peers::PairedPeer;
pub use protocol::{Control, MediaVia, QueueReport, RemoteState, RemoteTrack};

use crate::{LekisCore, Services};
use lekis_types::{ErrorCode, LekisError, Result, TrackId};
use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

/// 设置项：本机在其他设备上显示的名字。
pub const SETTING_DEVICE_NAME: &str = "connect.device_name";
/// 设置项：是否允许其他设备控制本机（默认允许，仍需配对）。
pub const SETTING_ALLOW_CONTROL: &str = "connect.allow_control";
/// 默认监听端口（被占用时退回系统分配）。
pub const DEFAULT_PORT: u16 = 47655;

/// 「在其他设备上播放」的设置。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectSettings {
    /// 本机名称。
    pub device_name: String,
    /// 允许其他设备控制本机。
    pub allow_control: bool,
}

/// 启动选项。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectStartOptions {
    /// 监听端口；`None` 用 [`DEFAULT_PORT`]（被占用时系统分配），`Some(0)` 直接系统分配。
    pub port: Option<u16>,
    /// 是否在局域网广播 / 浏览（测试里关掉，用手动添加）。
    pub mdns: bool,
}

impl Default for ConnectStartOptions {
    fn default() -> Self {
        Self {
            port: None,
            mdns: true,
        }
    }
}

/// 局域网里的一台 Lekis。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectDevice {
    /// 设备 ID。
    pub device_id: String,
    /// 名称。
    pub name: String,
    /// 平台（android / windows / ...）。
    pub platform: String,
    /// 地址。
    pub host: String,
    /// 端口。
    pub port: u16,
    /// 已经配对过。
    pub paired: bool,
    /// 当前有控制连接。
    pub connected: bool,
}

/// 发起配对的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairStart {
    /// 已经配对过，连接已建立。
    AlreadyPaired,
    /// 对方屏幕上显示了配对码，等用户输入。
    NeedsCode,
}

/// Connect 事件（和 `CoreEvent` 分开，界面单独订阅）。
#[derive(Debug, Clone, PartialEq)]
pub enum ConnectEvent {
    /// 设备列表变了。
    DevicesChanged {
        /// 当前局域网里（含手动添加的）所有设备。
        devices: Vec<ConnectDevice>,
    },
    /// 本机作为被控端：有设备请求配对，请把配对码显示出来。
    PairingCode {
        /// 请求配对的设备 ID。
        peer_id: String,
        /// 请求配对的设备名。
        peer_name: String,
        /// 6 位配对码，用户需要把它输进那台设备。
        code: String,
    },
    /// 本机作为被控端：配对结束（成功或失败），可以收起配对码。
    PairingFinished {
        /// 请求配对的设备 ID。
        peer_id: String,
        /// 请求配对的设备名。
        peer_name: String,
        /// 是否成功。
        success: bool,
    },
    /// 本机作为控制端：远端设备的状态变了。
    RemoteState {
        /// 哪台设备。
        device_id: String,
        /// 它的最新状态。
        state: RemoteState,
    },
    /// 本机作为控制端：和远端设备的连接断了。
    SessionClosed {
        /// 哪台设备。
        device_id: String,
        /// 断开的原因（给日志 / 提示用）。
        reason: String,
    },
    /// 本机作为被控端：有设备连上 / 断开了。
    ControllersChanged {
        /// 当前连着本机的控制端名字。
        names: Vec<String>,
    },
}

/// Connect 事件监听者（回调在核心线程上，不能阻塞）。
pub trait ConnectListener: Send + Sync {
    /// 收到事件。
    fn on_connect_event(&self, event: ConnectEvent);
}

/// mDNS 看到的 / 手动添加的设备。
#[derive(Debug, Clone)]
pub(crate) struct Discovered {
    pub device_id: String,
    pub name: String,
    pub platform: String,
    pub host: String,
    pub port: u16,
    /// mDNS 全名（手动添加的为空）。
    pub fullname: String,
}

#[derive(Default)]
struct HubState {
    started: bool,
    port: u16,
    settings: Option<ConnectSettings>,
    mdns: Option<mdns::MdnsHandle>,
    accept_task: Option<tokio::task::AbortHandle>,
    devices: BTreeMap<String, Discovered>,
    sessions: HashMap<String, Arc<client::Session>>,
    pending: HashMap<String, Box<client::PendingPair>>,
    /// 连着本机的控制端：连接序号 → 名称。
    controllers: BTreeMap<u64, String>,
}

/// 核心里 Connect 的全部状态。
pub(crate) struct ConnectHub {
    pub(crate) tokens: stream::StreamTokens,
    peers: peers::PeerStore,
    listeners: RwLock<Vec<Arc<dyn ConnectListener>>>,
    state: Mutex<HubState>,
    /// 最近的配对请求时间（被控端限流）。
    pair_attempts: Mutex<Vec<Instant>>,
    next_conn: std::sync::atomic::AtomicU64,
}

impl ConnectHub {
    pub(crate) fn new(
        data_dir: &std::path::Path,
        credentials: Arc<dyn crate::CredentialStore>,
    ) -> Self {
        Self {
            tokens: stream::StreamTokens::default(),
            peers: peers::PeerStore::open(data_dir.join("connect_peers.json"), credentials),
            listeners: RwLock::new(Vec::new()),
            state: Mutex::new(HubState::default()),
            pair_attempts: Mutex::new(Vec::new()),
            next_conn: std::sync::atomic::AtomicU64::new(1),
        }
    }

    pub(crate) fn emit(&self, event: ConnectEvent) {
        let listeners = match self.listeners.read() {
            Ok(l) => l.clone(),
            Err(_) => return,
        };
        for l in listeners {
            l.on_connect_event(event.clone());
        }
    }

    fn with_state<R>(&self, f: impl FnOnce(&mut HubState) -> R) -> Option<R> {
        self.state.lock().ok().map(|mut s| f(&mut s))
    }

    pub(crate) fn settings(&self) -> Option<ConnectSettings> {
        self.with_state(|s| s.settings.clone()).flatten()
    }

    pub(crate) fn allow_control(&self) -> bool {
        self.settings().map(|s| s.allow_control).unwrap_or(false)
    }

    pub(crate) fn port(&self) -> u16 {
        self.with_state(|s| s.port).unwrap_or(0)
    }

    pub(crate) fn devices(&self) -> Vec<ConnectDevice> {
        let paired: std::collections::HashSet<String> =
            self.peers.list().into_iter().map(|p| p.device_id).collect();
        self.with_state(|s| {
            s.devices
                .values()
                .map(|d| ConnectDevice {
                    device_id: d.device_id.clone(),
                    name: d.name.clone(),
                    platform: d.platform.clone(),
                    host: d.host.clone(),
                    port: d.port,
                    paired: paired.contains(&d.device_id),
                    connected: s.sessions.contains_key(&d.device_id),
                })
                .collect()
        })
        .unwrap_or_default()
    }

    pub(crate) fn emit_devices(&self) {
        self.emit(ConnectEvent::DevicesChanged {
            devices: self.devices(),
        });
    }

    pub(crate) fn upsert_device(&self, d: Discovered) {
        let changed = self
            .with_state(|s| {
                let changed = s
                    .devices
                    .get(&d.device_id)
                    .map(|old| {
                        old.name != d.name
                            || old.host != d.host
                            || old.port != d.port
                            || old.platform != d.platform
                    })
                    .unwrap_or(true);
                s.devices.insert(d.device_id.clone(), d);
                changed
            })
            .unwrap_or(false);
        if changed {
            self.emit_devices();
        }
    }

    pub(crate) fn remove_device_by_fullname(&self, fullname: &str) {
        let removed = self
            .with_state(|s| {
                let id = s
                    .devices
                    .values()
                    .find(|d| d.fullname == fullname)
                    .map(|d| d.device_id.clone());
                match id {
                    // 有控制连接的设备不从列表里拿掉（mDNS 偶尔会丢包）。
                    Some(id) if !s.sessions.contains_key(&id) => s.devices.remove(&id).is_some(),
                    _ => false,
                }
            })
            .unwrap_or(false);
        if removed {
            self.emit_devices();
        }
    }

    pub(crate) fn session_closed(
        &self,
        device_id: &str,
        session: &Arc<client::Session>,
        reason: &str,
    ) {
        let removed = self
            .with_state(|s| match s.sessions.get(device_id) {
                Some(cur) if Arc::ptr_eq(cur, session) => s.sessions.remove(device_id).is_some(),
                _ => false,
            })
            .unwrap_or(false);
        if removed {
            self.emit(ConnectEvent::SessionClosed {
                device_id: device_id.to_string(),
                reason: reason.to_string(),
            });
            self.emit_devices();
        }
    }

    /// 配对请求限流：一分钟最多 5 次。
    pub(crate) fn allow_pair_attempt(&self) -> bool {
        let Ok(mut attempts) = self.pair_attempts.lock() else {
            return false;
        };
        let now = Instant::now();
        attempts.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
        if attempts.len() >= 5 {
            return false;
        }
        attempts.push(now);
        true
    }

    pub(crate) fn controller_joined(&self, name: String) -> u64 {
        let id = self
            .next_conn
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let names = self
            .with_state(|s| {
                s.controllers.insert(id, name);
                s.controllers.values().cloned().collect()
            })
            .unwrap_or_default();
        self.emit(ConnectEvent::ControllersChanged { names });
        id
    }

    pub(crate) fn controller_left(&self, id: u64) {
        let names = self
            .with_state(|s| {
                s.controllers.remove(&id);
                s.controllers.values().cloned().collect()
            })
            .unwrap_or_default();
        self.emit(ConnectEvent::ControllersChanged { names });
    }

    pub(crate) fn peers(&self) -> &peers::PeerStore {
        &self.peers
    }
}

fn not_started() -> LekisError {
    LekisError::new(ErrorCode::Unsupported, "connect is not started")
}

fn unknown_device(id: &str) -> LekisError {
    LekisError::not_found(format!("connect device {id} not found"))
}

/// 读设置（缺省：设备名 = 平台层给的名字，允许被控制）。
async fn load_settings(s: &Services) -> ConnectSettings {
    let name = s
        .library
        .get_setting(SETTING_DEVICE_NAME)
        .await
        .ok()
        .flatten()
        // Early Android builds saved the hostname "localhost" (what Android
        // reports for every app), and later ones the placeholder "Android 设备"
        // (saving the allow-control switch also saves the name); treat both as
        // never set so the platform's real device name shows up instead.
        .filter(|n| {
            let n = n.trim();
            !n.is_empty() && !n.eq_ignore_ascii_case("localhost") && n != "Android 设备"
        })
        .unwrap_or_else(|| s.config.device_name.clone());
    let allow = s
        .library
        .get_setting(SETTING_ALLOW_CONTROL)
        .await
        .ok()
        .flatten()
        .map(|v| v.trim() != "false")
        .unwrap_or(true);
    ConnectSettings {
        device_name: name,
        allow_control: allow,
    }
}

pub(crate) fn platform_name(s: &Services) -> String {
    format!("{:?}", s.config.platform).to_ascii_lowercase()
}

impl LekisCore {
    /// 注册 Connect 事件监听者。
    pub fn add_connect_listener(&self, listener: Arc<dyn ConnectListener>) {
        if let Ok(mut l) = self.services.connect.listeners.write() {
            l.push(listener);
        }
    }

    /// 开始监听控制连接、在局域网广播本机并浏览其他设备。重复调用直接返回端口。
    pub async fn connect_start(&self, options: ConnectStartOptions) -> Result<u16> {
        let s = self.services.clone();
        self.run(async move {
            if let Some(port) = s.connect.with_state(|st| st.started.then_some(st.port)).flatten() {
                return Ok(port);
            }
            let settings = load_settings(&s).await;
            let listener = match options.port {
                Some(p) => tokio::net::TcpListener::bind(("0.0.0.0", p)).await?,
                None => match tokio::net::TcpListener::bind(("0.0.0.0", DEFAULT_PORT)).await {
                    Ok(l) => l,
                    Err(_) => tokio::net::TcpListener::bind(("0.0.0.0", 0)).await?,
                },
            };
            let port = listener.local_addr()?.port();
            let task = tokio::spawn(server::accept_loop(listener, Arc::downgrade(&s)));
            let mdns = if options.mdns {
                match mdns::start(&s, port, &settings) {
                    Ok(h) => Some(h),
                    Err(e) => {
                        tracing::warn!(target: "connect", error = %e, "mDNS unavailable; manual add only");
                        None
                    }
                }
            } else {
                None
            };
            s.connect.with_state(|st| {
                st.started = true;
                st.port = port;
                st.settings = Some(settings);
                st.mdns = mdns;
                st.accept_task = Some(task.abort_handle());
            });
            tracing::info!(target: "connect", port, "connect started");
            Ok(port)
        })
        .await
    }

    /// 停止（App 退出或进入后台很久时）。已有的控制连接一并断开。
    pub async fn connect_stop(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let (mdns, task, sessions) = s
                .connect
                .with_state(|st| {
                    st.started = false;
                    st.devices.clear();
                    st.pending.clear();
                    (
                        st.mdns.take(),
                        st.accept_task.take(),
                        st.sessions.drain().map(|(_, v)| v).collect::<Vec<_>>(),
                    )
                })
                .unwrap_or_default();
            if let Some(task) = task {
                task.abort();
            }
            if let Some(mdns) = mdns {
                mdns.shutdown();
            }
            for session in sessions {
                session.close().await;
            }
            s.connect.emit_devices();
            Ok(())
        })
        .await
    }

    /// 本机监听端口（未启动时为 0）。
    pub fn connect_port(&self) -> u16 {
        self.services.connect.port()
    }

    /// 当前设置。
    pub async fn connect_settings(&self) -> Result<ConnectSettings> {
        if let Some(settings) = self.services.connect.settings() {
            return Ok(settings);
        }
        let s = self.services.clone();
        self.run(async move { Ok(load_settings(&s).await) }).await
    }

    /// 修改设置：改名后重新广播；关掉"允许控制"会停止广播并断开所有控制端。
    pub async fn connect_set_settings(&self, settings: ConnectSettings) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let name = settings.device_name.trim().to_string();
            if name.is_empty() || name.chars().count() > 60 {
                return Err(LekisError::invalid("device name must be 1..=60 characters"));
            }
            s.library.set_setting(SETTING_DEVICE_NAME, &name).await?;
            s.library
                .set_setting(
                    SETTING_ALLOW_CONTROL,
                    if settings.allow_control {
                        "true"
                    } else {
                        "false"
                    },
                )
                .await?;
            let settings = ConnectSettings {
                device_name: name,
                allow_control: settings.allow_control,
            };
            let port = s
                .connect
                .with_state(|st| {
                    st.settings = Some(settings.clone());
                    st.started.then_some(st.port)
                })
                .flatten();
            if let Some(port) = port {
                // mDNS 里的名字 / 是否广播跟着设置走。
                s.connect.with_state(|st| {
                    if let Some(m) = &st.mdns {
                        m.update(&s, port, &settings);
                    }
                });
            }
            Ok(())
        })
        .await
    }

    /// 局域网里的其他 Lekis。
    pub fn connect_devices(&self) -> Vec<ConnectDevice> {
        self.services.connect.devices()
    }

    /// 已配对的设备（包括当前不在线的）。
    pub fn connect_paired_devices(&self) -> Vec<PairedPeer> {
        self.services.connect.peers().list()
    }

    /// 手动按地址添加一台设备（组播不通时）。会连上去读一下对方的名字。
    pub async fn connect_add_device(&self, host: String, port: u16) -> Result<ConnectDevice> {
        let s = self.services.clone();
        self.run(async move {
            let d = client::probe(&s, &host, port).await?;
            let id = d.device_id.clone();
            s.connect.upsert_device(d);
            s.connect
                .devices()
                .into_iter()
                .find(|d| d.device_id == id)
                .ok_or_else(|| unknown_device(&id))
        })
        .await
    }

    /// 连接一台设备：配对过就直接认证；没配对过就请对方显示配对码（之后调 `connect_pair_confirm`）。
    pub async fn connect_pair(&self, device_id: String) -> Result<PairStart> {
        let s = self.services.clone();
        self.run(async move {
            if session_for(&s, &device_id).await.is_ok() {
                return Ok(PairStart::AlreadyPaired);
            }
            let target = device(&s, &device_id)?;
            match client::open(&s, &target, true).await? {
                client::Opened::Session(session) => {
                    install_session(&s, &device_id, session);
                    Ok(PairStart::AlreadyPaired)
                }
                client::Opened::NeedsCode(pending) => {
                    s.connect
                        .with_state(|st| st.pending.insert(device_id, pending));
                    Ok(PairStart::NeedsCode)
                }
            }
        })
        .await
    }

    /// 输入对方屏幕上的配对码，完成配对。
    pub async fn connect_pair_confirm(&self, device_id: String, code: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let pending = s
                .connect
                .with_state(|st| st.pending.remove(&device_id))
                .flatten()
                .ok_or_else(|| LekisError::invalid("no pairing in progress"))?;
            let session = client::finish_pair(&s, *pending, code.trim()).await?;
            install_session(&s, &device_id, session);
            Ok(())
        })
        .await
    }

    /// 放弃正在进行的配对。
    pub fn connect_pair_cancel(&self, device_id: String) {
        self.services
            .connect
            .with_state(|st| st.pending.remove(&device_id));
    }

    /// 删除配对（之后需要重新输入配对码）。
    pub async fn connect_forget(&self, device_id: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let session = s
                .connect
                .with_state(|st| st.sessions.remove(&device_id))
                .flatten();
            if let Some(session) = session {
                session.close().await;
            }
            s.connect.peers().forget(&device_id)?;
            s.connect.emit_devices();
            Ok(())
        })
        .await
    }

    /// 断开和某台设备的控制连接（不删除配对）。
    pub async fn connect_disconnect(&self, device_id: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let session = s
                .connect
                .with_state(|st| st.sessions.remove(&device_id))
                .flatten();
            if let Some(session) = session {
                session.close().await;
                s.connect.emit_devices();
            }
            Ok(())
        })
        .await
    }

    /// 远端设备的当前状态（同时开始接收它的状态推送）。
    pub async fn connect_remote_state(&self, device_id: String) -> Result<RemoteState> {
        let s = self.services.clone();
        self.run(async move {
            let session = session_for(&s, &device_id).await?;
            session.subscribe().await?;
            match session.request(protocol::Request::GetState).await? {
                protocol::Reply::State { state } => Ok(state),
                _ => Err(LekisError::invalid("unexpected reply")),
            }
        })
        .await
    }

    /// 遥控：播放 / 暂停 / 切歌 / 跳转 / 音量……
    pub async fn connect_control(&self, device_id: String, action: Control) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let session = session_for(&s, &device_id).await?;
            session
                .request(protocol::Request::Control { action })
                .await
                .map(|_| ())
        })
        .await
    }

    /// 远端队列的一页。
    pub async fn connect_remote_queue(
        &self,
        device_id: String,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<RemoteTrack>> {
        let s = self.services.clone();
        self.run(async move {
            let session = session_for(&s, &device_id).await?;
            match session
                .request(protocol::Request::GetQueue { offset, limit })
                .await?
            {
                protocol::Reply::Queue { items } => Ok(items),
                _ => Err(LekisError::invalid("unexpected reply")),
            }
        })
        .await
    }

    /// 远端曲目的封面（字节）。对方没有时，用 `uid` 在本机资料库里找同一首歌的封面。
    pub async fn connect_remote_artwork(
        &self,
        device_id: String,
        track_id: i64,
        uid: Option<String>,
    ) -> Result<Option<Vec<u8>>> {
        let s = self.services.clone();
        self.run(async move {
            let session = session_for(&s, &device_id).await?;
            if let protocol::Reply::Artwork {
                data_base64: Some(b64),
            } = session
                .request(protocol::Request::GetArtwork { track_id })
                .await?
            {
                use base64::Engine as _;
                if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64) {
                    return Ok(Some(bytes));
                }
            }
            let Some(uid) = uid else { return Ok(None) };
            let Some(local) = s.library.find_track_by_uid(&uid).await? else {
                return Ok(None);
            };
            Ok(server::artwork_bytes(&s, local).await)
        })
        .await
    }

    /// 转移播放：把本机当前队列和进度交给另一台设备，成功后本机暂停（`pause_local`）。
    pub async fn connect_transfer(
        &self,
        device_id: String,
        pause_local: bool,
    ) -> Result<QueueReport> {
        let snap = self.services.engine.snapshot();
        if snap.queue.is_empty() {
            return Err(LekisError::invalid("nothing is playing"));
        }
        let index = snap.queue_index.unwrap_or(0) as usize;
        let from = index.saturating_sub(protocol::MAX_TRANSFER_ITEMS / 10);
        let to = (from + protocol::MAX_TRANSFER_ITEMS).min(snap.queue.len());
        let tracks = snap.queue[from..to].to_vec();
        let report = self
            .connect_play_on(
                device_id,
                tracks,
                (index - from) as u32,
                snap.position_ms,
                snap.state == lekis_types::PlaybackState::Playing
                    || snap.state == lekis_types::PlaybackState::Buffering,
            )
            .await?;
        if pause_local && report.total > report.skipped {
            let _ = self.pause();
        }
        Ok(report)
    }

    /// 让另一台设备播放一组本机曲目（"在 xx 上播放"）。
    pub async fn connect_play_on(
        &self,
        device_id: String,
        tracks: Vec<TrackId>,
        start: u32,
        position_ms: u64,
        play: bool,
    ) -> Result<QueueReport> {
        let s = self.services.clone();
        self.run(async move {
            let session = session_for(&s, &device_id).await?;
            let items = describe_for(&s, &session, &tracks).await?;
            match session
                .request(protocol::Request::SetQueue {
                    items,
                    start,
                    position_ms,
                    play,
                })
                .await?
            {
                protocol::Reply::Queued { report } => Ok(report),
                _ => Err(LekisError::invalid("unexpected reply")),
            }
        })
        .await
    }
}

fn device(s: &Services, device_id: &str) -> Result<Discovered> {
    s.connect
        .with_state(|st| {
            if !st.started {
                return Err(not_started());
            }
            st.devices
                .get(device_id)
                .cloned()
                .ok_or_else(|| unknown_device(device_id))
        })
        .unwrap_or_else(|| Err(not_started()))
}

fn install_session(s: &Arc<Services>, device_id: &str, session: Arc<client::Session>) {
    let old = s
        .connect
        .with_state(|st| st.sessions.insert(device_id.to_string(), session))
        .flatten();
    if let Some(old) = old {
        tokio::spawn(async move { old.close().await });
    }
    s.connect.emit_devices();
}

/// 取（必要时建立）到某台**已配对**设备的控制连接。没配对过时报 `Auth`，不会触发对方弹配对码。
async fn session_for(s: &Arc<Services>, device_id: &str) -> Result<Arc<client::Session>> {
    if let Some(session) = s
        .connect
        .with_state(|st| st.sessions.get(device_id).cloned())
        .flatten()
    {
        if session.is_alive() {
            return Ok(session);
        }
    }
    if s.connect.peers().key(device_id).is_none() {
        return Err(LekisError::new(ErrorCode::Auth, "device is not paired"));
    }
    let target = device(s, device_id)?;
    match client::open(s, &target, false).await? {
        client::Opened::Session(session) => {
            install_session(s, device_id, session.clone());
            Ok(session)
        }
        client::Opened::NeedsCode(_) => {
            Err(LekisError::new(ErrorCode::Auth, "device is not paired"))
        }
    }
}

/// 给要发出去的曲目生成描述，局域网流地址指向本机（对方连过来时看到的那个地址）。
async fn describe_for(
    s: &Arc<Services>,
    session: &client::Session,
    tracks: &[TrackId],
) -> Result<Vec<protocol::TrackRef>> {
    let sources: HashMap<_, _> = s
        .library
        .list_sources()
        .await?
        .into_iter()
        .filter_map(|c| c.id.map(|id| (id, c)))
        .collect();
    let port = s.connect.port();
    let host = match session.local_ip() {
        IpAddr::V6(v6) => format!("[{v6}]"),
        v4 => v4.to_string(),
    };
    let mut out = Vec::with_capacity(tracks.len());
    for &id in tracks {
        // 电台 / 播客用原始地址，不经过本机。
        let streamable = id.0 > 0;
        let stream_url = if streamable && port != 0 {
            let token = s.connect.tokens.issue(id)?;
            let ext = s.library.track_files(id).await.ok().and_then(|f| {
                f.first()
                    .and_then(|f| stream::extension_of(&f.path).map(str::to_string))
            });
            Some(match ext {
                Some(ext) => format!("http://{host}:{port}/stream/{token}.{ext}"),
                None => format!("http://{host}:{port}/stream/{token}"),
            })
        } else {
            None
        };
        match media::describe_track(s, &sources, id, stream_url).await {
            Ok(r) => out.push(r),
            Err(e) => {
                tracing::debug!(target: "connect", %id, error = %e, "skip undescribable track")
            }
        }
    }
    Ok(out)
}
