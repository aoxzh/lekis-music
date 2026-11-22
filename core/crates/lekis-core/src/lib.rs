//! Lekis 核心门面。
//!
//! Flutter 客户端（通过 lekis-bridge）和 lekis-node 都只和 [`LekisCore`] 打交道。
//! 它负责：
//! - 拥有唯一的 tokio 运行时（或者借用宿主的运行时，见 [`LekisCore::with_runtime`]）；
//! - 组装资料库、扫描器、播放引擎、补全、同步、插件；
//! - 把领域层的结果转成 [`CoreEvent`] 推给监听者；
//! - 做跨领域的决策：选源、离线策略、自动补全的触发时机。
//!
//! 所有耗时的公开方法都是 `async`，并且内部总是在核心自己的运行时上执行，
//! 所以调用方用什么执行器（UniFFI 的 Kotlin 协程、C# Task）都可以。

mod artwork_local;
pub mod config;
pub mod connect;
pub mod discovery;
mod enrich;
pub mod equalizer;
pub mod events;
mod folders;
mod health;
/// In-memory diagnostic log ring for the Settings screen (SET-03).
pub mod logs;
mod lyrics_local;
mod offline;
pub mod platform;
pub mod plugins;
pub mod podcast;
pub mod radio;
mod remote_scan;
mod resolver;
pub mod scrobble;
pub mod selection;
mod source_browse;
mod sync_engine;

pub use config::{CoreConfig, PlatformKind};
pub use enrich::EnrichReport;
pub use equalizer::EqualizerSettings;
pub use events::EventListener;
pub use folders::{FolderEntry, FolderListing, FolderRoot};
pub use health::HealthScanReport;
pub use lekis_playback::PlaybackSnapshot;
pub use lekis_vfs::ShareInfo;
pub use platform::{CredentialStore, MemoryCredentialStore, PlatformServices};
pub use plugins::{PluginInfo, PluginPermissions, PluginSettingView};
pub use podcast::{
    DirectoryPodcast, OpmlImportReport, PodcastRefreshReport, PODCAST_DIRECTORY_MAX,
};
pub use radio::{
    RadioFilterOption, RadioFilterOptions, RadioPage, RadioQuery, RadioSort, RADIO_PAGE_MAX,
};
pub use scrobble::{ScrobbleSettings, ScrobbleSettingsInput, ScrobbleStatus};
pub use selection::{NetworkContext, Reachability, SourceHealth};
pub use source_browse::SourceListing;
pub use sync_engine::SyncReport;

use events::EventBus;
pub use lekis_library::ListeningSummary;
pub use lekis_library::{
    BatchTagWriteItem, DuplicateGroup, DuplicateTrack, HealthIssueKind, LetterOffset,
    LibraryHealthEntry, LibraryHealthSummary, OfflineDownload, OfflineStats, PlaybackStateRow,
    SourceInfo, TagWriteResult, TrackContext, TrackUserState,
};
use lekis_library::{EnrichCandidateRow, Library, LyricsRow, PlaylistEntry};
use lekis_playback::{EngineCommand, EqControl, OutputDevice, OutputMode, PlaybackEngine};
use lekis_scanner::{tags::LoftyTagReader, Scanner};
use lekis_types::*;
use std::future::Future;
use std::sync::Arc;
use tokio::runtime::{Handle, Runtime};

/// 本次运行里已经在线查过歌词的曲目（查不到也不再重复请求）。
static LYRICS_TRIED: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<TrackId>>> =
    std::sync::LazyLock::new(Default::default);

/// 统一资料库里一首歌对应的某个可播放来源（含当前选源状态，SRC-13/SRC-14）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackSourceInfo {
    /// 所属音源 ID。
    pub source_id: SourceId,
    /// 音源名称。
    pub source_name: String,
    /// 音源类型。
    pub source_kind: SourceKind,
    /// 文件系统类音源的文件 ID；服务器源为 `None`。
    pub file_id: Option<i64>,
    /// 源内相对路径（服务器源为空串）。
    pub path: String,
    /// 服务器源的曲目 ID（文件系统源为 `None`）。
    pub external_id: Option<String>,
    /// 文件大小（字节；未知或服务器源为 0）。
    pub size_bytes: u64,
    /// 音质徽章（如 `FLAC 24/96`）。
    pub format: Option<String>,
    /// 音质分（越大越好）。
    pub quality_score: i64,
    /// 最近探测的可达性（`None` = 尚未探测）。
    pub reachable: Option<bool>,
    /// 按当前网络环境与可达性，现在点击播放是否会优先选中这一份。
    pub preferred: bool,
}

/// 核心实例。一个进程里只应该有一个。
pub struct LekisCore {
    /// 自己创建的运行时（借用宿主运行时时为 `None`）。
    runtime: Option<Runtime>,
    handle: Handle,
    services: Arc<Services>,
}

struct Services {
    config: CoreConfig,
    device_id: DeviceId,
    library: Library,
    scanner: Scanner,
    engine: PlaybackEngine,
    events: EventBus,
    platform: PlatformServices,
    /// 音源可达性与网络环境（SRC-14）。
    health: Arc<SourceHealth>,
    /// 已经构造好的服务器客户端缓存（SRC-04~06）。
    servers: std::sync::Mutex<
        std::collections::HashMap<SourceId, Arc<dyn lekis_providers::MediaServer>>,
    >,
    /// HLC 时钟（SYN-01）。
    clock: std::sync::Mutex<lekis_sync::HlcClock>,
    /// 元数据补全流水线（ENR-01/03/06）。
    enrich: Arc<enrich::EnrichPipeline>,
    /// 已经打开的 VFS（播放引擎按 `source_id` 取回来分块读音频）。
    vfs: std::sync::Mutex<std::collections::HashMap<SourceId, Arc<dyn lekis_vfs::Vfs>>>,
    /// 选源器（持有服务器客户端缓存和 ReplayGain 模式）。
    resolver: Arc<resolver::Resolver>,
    /// 第三方听歌记录上报（DIS-07）。
    scrobble: Arc<scrobble::Scrobbler>,
    /// 网络电台（SRC-11）：Radio Browser 客户端和筛选缓存。
    radio: radio::RadioBrowser,
    /// 播客（SRC-12）：Apple 目录 + RSS 抓取。
    podcast: podcast::PodcastClient,
    /// 正在进行的离线下载（曲目 → 取消标记）。
    downloads:
        std::sync::Mutex<std::collections::HashMap<TrackId, Arc<std::sync::atomic::AtomicBool>>>,
    /// 本地插件管理（PLG-01~07）。
    plugins: Arc<plugins::PluginManager>,
    /// 10 段均衡器参数（PLY-04）；和播放引擎共享，设置后立即生效。
    eq: Arc<EqControl>,
    /// 「在其他设备上播放」/ 遥控（CST-01~06）。
    connect: connect::ConnectHub,
}

impl Services {
    fn vfs_get(&self, source_id: SourceId) -> Option<Arc<dyn lekis_vfs::Vfs>> {
        self.vfs.lock().ok()?.get(&source_id).cloned()
    }

    fn vfs_put(&self, source_id: SourceId, vfs: Arc<dyn lekis_vfs::Vfs>) {
        if let Ok(mut map) = self.vfs.lock() {
            map.insert(source_id, vfs);
        }
    }

    /// 按源配置打开 VFS；密码按 `credential_ref` 从平台钥匙串读（没有引用时退回地址里的密码）。
    fn open_vfs(&self, source: &SourceConfig) -> Result<Arc<dyn lekis_vfs::Vfs>> {
        let password = source
            .credential_ref
            .as_deref()
            .filter(|r| !r.is_empty())
            .and_then(|r| self.platform.credentials.get(r));
        lekis_vfs::open(source, password)
    }

    /// 源配置或凭据变了：丢掉所有按旧配置构造的客户端，下次用到时重建。
    fn forget_source(&self, source_id: SourceId) {
        if let Ok(mut map) = self.vfs.lock() {
            map.remove(&source_id);
        }
        if let Ok(mut map) = self.servers.lock() {
            map.remove(&source_id);
        }
        self.resolver.forget(source_id);
    }

    /// 文件系统源：预先登记 VFS（不发网络请求），这样重启后不扫描也能直接播放。
    fn register_vfs(&self, source: &SourceConfig) {
        let Some(id) = source.id else { return };
        if !source.kind.is_filesystem() || !source.enabled {
            return;
        }
        match self.open_vfs(source) {
            Ok(vfs) => self.vfs_put(id, vfs),
            Err(e) => {
                tracing::debug!(target: "core", %id, code = %e.code.as_str(), "cannot pre-open source")
            }
        }
    }

    /// 让一个设置项立即生效（启动时和每次 `set_setting` 后调用）。
    fn apply_setting(&self, key: &str, value: Option<&str>) {
        match key {
            settings::GAPLESS => {
                let enabled = value.map(|v| v.trim() != "false").unwrap_or(true);
                let _ = self.engine.send(EngineCommand::SetGapless(enabled));
            }
            settings::REPLAYGAIN => self
                .resolver
                .set_replaygain_mode(resolver::ReplayGainMode::from_setting(value)),
            settings::EQ_ENABLED => {
                let mut current = self.eq.settings();
                current.enabled = value
                    .map(|value| value.trim() != "false" && value.trim() != "0")
                    .unwrap_or(false);
                self.eq.set(current);
            }
            settings::EQ_PREAMP => {
                let mut current = self.eq.settings();
                current.preamp_db = value
                    .and_then(|value| value.trim().parse::<f32>().ok())
                    .unwrap_or(0.0);
                self.eq.set(current);
            }
            settings::EQ_BANDS => {
                let mut current = self.eq.settings();
                if let Some(bands) = value.and_then(|value| {
                    serde_json::from_str::<Vec<f32>>(value)
                        .ok()
                        .map(|bands| lekis_playback::EqSettings::new(true, 0.0, &bands))
                }) {
                    current.bands_db = bands.bands_db;
                }
                self.eq.set(current);
            }
            settings::EQ_PRESET => {}
            _ => {}
        }
    }

    /// 记录一次后台扫描失败：持久化到音源上，并推 `ScanFailed` 事件。
    async fn scan_failed(&self, source_id: SourceId, error: &LekisError) {
        tracing::warn!(target: "core", %source_id, error = %error, "scan failed");
        if let Err(e) = self.library.mark_scan_failed(source_id, error).await {
            tracing::warn!(target: "core", %source_id, error = %e, "cannot persist scan failure");
        }
        self.events.emit(CoreEvent::ScanFailed {
            source_id,
            code: error.code,
            detail: error.message.clone(),
        });
        self.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Sources,
        });
    }
}

/// 核心自己会读的设置项。
pub mod settings {
    /// 是否提前解析下一首（`"true"` / `"false"`，默认开）。
    pub const GAPLESS: &str = "playback.gapless";
    /// ReplayGain：`track`（默认）/ `album` / `off`。
    pub const REPLAYGAIN: &str = "playback.replaygain";
    /// 均衡器开关：`true` / `false`（默认关，PLY-04）。
    pub const EQ_ENABLED: &str = "playback.eq.enabled";
    /// 均衡器 preamp（dB，-12..=+12）。
    pub const EQ_PREAMP: &str = "playback.eq.preamp";
    /// 均衡器 10 段增益（dB）的 JSON 数组。
    pub const EQ_BANDS: &str = "playback.eq.bands";
    /// 均衡器当前预设 ID（可选）。
    pub const EQ_PRESET: &str = "playback.eq.preset";
}

/// `test_source` 的整体超时。
const TEST_SOURCE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

impl LekisCore {
    /// 创建核心，并创建它自己的 tokio 运行时（客户端 App 用这个）。
    pub fn new(config: CoreConfig, platform: PlatformServices) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(config.worker_threads.unwrap_or(4))
            .thread_name("lekis-core")
            .enable_all()
            .build()?;
        let handle = runtime.handle().clone();
        let services = Self::build(config, platform, &handle)?;
        Ok(Self {
            runtime: Some(runtime),
            handle,
            services,
        })
    }

    /// 创建核心，使用宿主已有的 tokio 运行时（lekis-node 用这个）。
    pub fn with_runtime(
        config: CoreConfig,
        platform: PlatformServices,
        handle: Handle,
    ) -> Result<Self> {
        let services = Self::build(config, platform, &handle)?;
        Ok(Self {
            runtime: None,
            handle,
            services,
        })
    }

    fn build(
        config: CoreConfig,
        platform: PlatformServices,
        handle: &Handle,
    ) -> Result<Arc<Services>> {
        logs::init();
        std::fs::create_dir_all(&config.data_dir)?;
        std::fs::create_dir_all(&config.cache_dir)?;
        // SFTP 首次连接学到的主机密钥记在这里（TOFU），之后必须一致。
        lekis_vfs::sftp::set_known_hosts_path(config.data_dir.join("ssh_known_hosts"));
        let device_id = config::load_or_create_device_id(&config.data_dir)?;
        tracing::info!(target: "core", %device_id, platform = ?config.platform, "starting lekis core");

        let library = Library::open(&config.data_dir.join("library.sqlite"))?;
        let scanner = Scanner::new(library.clone(), Arc::new(LoftyTagReader));
        let events = EventBus::default();
        let health = Arc::new(SourceHealth::new());
        let clock = std::sync::Mutex::new(lekis_sync::HlcClock::new(device_id.0.clone()));
        let enrich = Arc::new(enrich::EnrichPipeline::new(&config));

        // 播放引擎和后台任务都要在运行时上下文里创建。
        let _guard = handle.enter();
        let (resolve_tx, resolve_rx) = tokio::sync::mpsc::channel(16);
        let eq = Arc::new(EqControl::default());
        let engine = PlaybackEngine::spawn_with_eq(resolve_tx, eq.clone());
        let resolver = Arc::new(resolver::Resolver::new(
            library.clone(),
            health.clone(),
            platform.credentials.clone(),
        ));
        handle.spawn(resolver.clone().run(resolve_rx));
        handle.spawn(events::forward_playback(engine.subscribe(), events.clone()));
        let scrobbler = Arc::new(scrobble::Scrobbler::new(
            library.clone(),
            platform.credentials.clone(),
            &config.data_dir,
        ));
        let radio = radio::RadioBrowser::new()?;
        let podcast = podcast::PodcastClient::new()?;
        let plugins = Arc::new(plugins::PluginManager::new(
            &config.data_dir,
            library.clone(),
        ));
        let connect = connect::ConnectHub::new(&config.data_dir, platform.credentials.clone());

        let services = Arc::new(Services {
            config,
            device_id,
            library,
            scanner,
            engine,
            events,
            platform,
            health,
            servers: std::sync::Mutex::new(std::collections::HashMap::new()),
            clock,
            enrich,
            vfs: std::sync::Mutex::new(std::collections::HashMap::new()),
            resolver,
            scrobble: scrobbler,
            radio,
            podcast,
            downloads: std::sync::Mutex::new(std::collections::HashMap::new()),
            plugins,
            eq,
            connect,
        });

        // 启动时：让播放相关设置生效，并给文件系统源预先登记 VFS（不发网络请求）。
        {
            let s = services.clone();
            handle.spawn(async move {
                for key in [
                    settings::GAPLESS,
                    settings::REPLAYGAIN,
                    settings::EQ_BANDS,
                    settings::EQ_PREAMP,
                    settings::EQ_ENABLED,
                ] {
                    let value = s.library.get_setting(key).await.ok().flatten();
                    s.apply_setting(key, value.as_deref());
                }
                // 上报设置 / 凭据 / 待补报队列在后台读入，不阻塞启动。
                s.scrobble.load().await;
                match s.library.list_sources().await {
                    Ok(sources) => sources.iter().for_each(|src| s.register_vfs(src)),
                    Err(e) => {
                        tracing::warn!(target: "core", error = %e, "cannot list sources at startup")
                    }
                }
                // OFF-04：上次进程中断留下的 downloading 行改回 queued；不自动继续。
                offline::recover(s.clone()).await;
            });
        }

        // DIS-07：播放监听 + 后台补报。都只读快照 / 队列，不阻塞播放。
        handle.spawn(services.scrobble.clone().run_worker());
        handle.spawn(scrobble::track_playback(
            services.engine.subscribe(),
            services.scrobble.clone(),
            services.library.clone(),
        ));

        // 播放引擎要按 Range 读音频文件，但「哪个 source_id 对应哪个 Vfs」只有 core 知道。
        // 用弱引用注册一个回调，避免 Services ↔ 注册表之间形成引用环（drop 时不泄漏）。
        let weak = Arc::downgrade(&services);
        lekis_playback::vfs_access::install_resolver(Box::new(move |source_id| {
            weak.upgrade()?.vfs_get(source_id)
        }));

        Ok(services)
    }

    /// 在核心运行时上执行一个 future，并等待结果。
    async fn run<F, T>(&self, fut: F) -> Result<T>
    where
        F: Future<Output = Result<T>> + Send + 'static,
        T: Send + 'static,
    {
        self.handle
            .spawn(fut)
            .await
            .map_err(|e| LekisError::internal(format!("core task failed: {e}")))?
    }

    // -----------------------------------------------------------------------
    // 基本信息与事件
    // -----------------------------------------------------------------------

    /// 本机设备 ID。
    pub fn device_id(&self) -> DeviceId {
        self.services.device_id.clone()
    }

    /// 配置。
    pub fn config(&self) -> &CoreConfig {
        &self.services.config
    }

    /// 注册事件监听者（UI 启动时调用一次）。
    pub fn add_listener(&self, listener: Arc<dyn EventListener>) {
        self.services.events.add(listener);
    }

    // -----------------------------------------------------------------------
    // 音源与扫描
    // -----------------------------------------------------------------------

    /// 添加音源。
    pub async fn add_source(&self, config: SourceConfig) -> Result<SourceId> {
        let s = self.services.clone();
        self.run(async move {
            if config.addresses.is_empty() {
                return Err(LekisError::invalid("source must have at least one address"));
            }
            reject_inline_secrets(&config)?;
            let mut stored = config.clone();
            let id = s.library.add_source(config).await?;
            stored.id = Some(id);
            s.register_vfs(&stored);
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Sources,
            });
            Ok(id)
        })
        .await
    }

    /// 修改音源（`config.id` 必须有值）。旧的连接 / 客户端会被丢掉，下次按新配置重建。
    pub async fn update_source(&self, config: SourceConfig) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let id = config
                .id
                .ok_or_else(|| LekisError::invalid("update_source needs a source id"))?;
            if config.addresses.is_empty() {
                return Err(LekisError::invalid("source must have at least one address"));
            }
            reject_inline_secrets(&config)?;
            s.library.update_source(config.clone()).await?;
            s.forget_source(id);
            s.register_vfs(&config);
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Sources,
            });
            Ok(())
        })
        .await
    }

    /// 删除音源以及它的曲目、索引行。不会删除钥匙串里的凭据（多个源可能共用一个引用），
    /// 需要时 UI 再调 [`Self::delete_credential`]。
    pub async fn remove_source(&self, source_id: SourceId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            s.library.remove_source(source_id).await?;
            s.forget_source(source_id);
            s.health.record(source_id, Reachability::Unknown);
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Sources,
            });
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            });
            Ok(())
        })
        .await
    }

    /// 试连一个音源（不保存）：文件系统源列根目录，服务器源 ping 并取一首曲目。
    ///
    /// 密码 / token 走 `credential_ref`：还没保存的源也可以先 [`Self::set_credential`] 再测试。
    pub async fn test_source(&self, config: SourceConfig) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            if config.addresses.is_empty() {
                return Err(LekisError::invalid("source must have at least one address"));
            }
            let probe = async {
                if config.kind.is_filesystem() {
                    let vfs = s.open_vfs(&config)?;
                    vfs.list_dir(&lekis_vfs::VfsPath::root()).await.map(|_| ())
                } else {
                    let server = resolver::build_server(&config, s.platform.credentials.as_ref())?;
                    server.ping().await?;
                    server.list_tracks(0, 1, None).await.map(|_| ())
                }
            };
            tokio::time::timeout(TEST_SOURCE_TIMEOUT, probe)
                .await
                .map_err(|_| LekisError::new(ErrorCode::Network, "source test timed out"))?
        })
        .await
    }

    /// 列出一个**未保存**音源配置里某个目录下的子文件夹（「添加音源」时选子目录用）。
    ///
    /// `path` 相对于配置的根目录（SMB 是共享根，NFS 是导出根，WebDAV 是 URL，
    /// SFTP 是地址里的路径），`/` 分隔，空串是根。不包含 `..`。密码按
    /// `credential_ref` 读取，和 [`test_source`](Self::test_source) 一样。
    pub async fn browse_source(&self, config: SourceConfig, path: String) -> Result<SourceListing> {
        let s = self.services.clone();
        self.run(async move {
            if !config.kind.is_filesystem() || config.kind == SourceKind::Local {
                return Err(LekisError::new(
                    ErrorCode::Unsupported,
                    "only network filesystem sources can be browsed",
                ));
            }
            let dir = lekis_vfs::VfsPath::parse(&path)
                .ok_or_else(|| LekisError::invalid("browse path must not contain .."))?;
            let probe = async {
                let vfs = s.open_vfs(&config)?;
                vfs.list_dir(&dir).await
            };
            let entries = tokio::time::timeout(TEST_SOURCE_TIMEOUT, probe)
                .await
                .map_err(|_| LekisError::new(ErrorCode::Network, "browse timed out"))??;
            Ok(SourceListing::from_entries(entries))
        })
        .await
    }

    /// 列出服务器上的 SMB 共享 / NFS 导出（只用配置第一个地址的主机部分）。
    pub async fn list_shares(&self, config: SourceConfig) -> Result<Vec<ShareInfo>> {
        let s = self.services.clone();
        self.run(async move {
            let password = config
                .credential_ref
                .as_deref()
                .filter(|r| !r.is_empty())
                .and_then(|r| s.platform.credentials.get(r));
            tokio::time::timeout(
                TEST_SOURCE_TIMEOUT,
                lekis_vfs::list_shares(&config, password),
            )
            .await
            .map_err(|_| LekisError::new(ErrorCode::Network, "listing shares timed out"))?
        })
        .await
    }

    /// 局域网自动发现 SMB / WebDAV / DLNA 服务（一次性，`timeout` 后返回）。
    ///
    /// Android 上调用方要先拿到 `MulticastLock`，否则收不到 mDNS 应答。
    pub async fn discover_lan(
        &self,
        timeout: std::time::Duration,
    ) -> Vec<discovery::DiscoveredService> {
        self.run(async move { Ok(discovery::discover(timeout).await) })
            .await
            .unwrap_or_default()
    }

    /// 音源列表，带每个源最近一次扫描的时间和失败信息。
    pub async fn list_source_infos(&self) -> Result<Vec<SourceInfo>> {
        self.migrate_embedded_credentials().await;
        let s = self.services.clone();
        self.run(async move { s.library.list_source_infos().await })
            .await
    }

    // -----------------------------------------------------------------------
    // 凭据（SRC-15）
    // -----------------------------------------------------------------------

    /// 按引用保存一个密码 / token（`SourceConfig.credential_ref` 指向它）。
    ///
    /// 用到这个引用的源会丢掉旧连接，下次访问时用新密码重连。
    pub async fn set_credential(&self, credential_ref: String, secret: String) -> Result<()> {
        if credential_ref.trim().is_empty() {
            return Err(LekisError::invalid("credential_ref must not be empty"));
        }
        let s = self.services.clone();
        self.run(async move {
            s.platform.credentials.set(&credential_ref, &secret)?;
            forget_sources_using(&s, &credential_ref).await;
            Ok(())
        })
        .await
    }

    /// 删除一个凭据。
    pub async fn delete_credential(&self, credential_ref: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            s.platform.credentials.delete(&credential_ref)?;
            forget_sources_using(&s, &credential_ref).await;
            Ok(())
        })
        .await
    }

    /// 某个引用当前有没有保存密码（UI 显示"已保存"用；不返回密码本身）。
    pub fn has_credential(&self, credential_ref: &str) -> bool {
        self.services
            .platform
            .credentials
            .get(credential_ref)
            .is_some()
    }

    /// 列出音源。
    pub async fn list_sources(&self) -> Result<Vec<SourceConfig>> {
        self.migrate_embedded_credentials().await;
        let s = self.services.clone();
        self.run(async move { s.library.list_sources().await })
            .await
    }

    /// 把旧版本直接写在地址 / options 里的密码迁到凭据库（SRC-15）。
    ///
    /// 这是尽力而为的兼容步骤：失败时只记日志，仍然返回原有列表，避免一个旧音源
    /// 让整个列表打不开。迁移成功后数据库里只剩 `credential_ref`。
    async fn migrate_embedded_credentials(&self) {
        let sources = match self.services.library.list_sources().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(target: "core", error = %e, "cannot inspect sources for embedded credentials");
                return;
            }
        };
        for mut config in sources {
            if config
                .credential_ref
                .as_deref()
                .is_some_and(|r| !r.trim().is_empty())
            {
                continue;
            }
            let Some(secret) = take_embedded_secret(&mut config) else {
                continue;
            };
            let Some(id) = config.id else { continue };
            let reference = format!("lekis.source.{}", id.0);
            if let Err(e) = self.services.platform.credentials.set(&reference, &secret) {
                tracing::warn!(target: "core", %id, error = %e, "cannot migrate embedded source credential");
                continue;
            }
            config.credential_ref = Some(reference.clone());
            if let Err(e) = self.services.library.update_source(config.clone()).await {
                let _ = self.services.platform.credentials.delete(&reference);
                tracing::warn!(target: "core", %id, error = %e, "cannot store migrated source credential");
                continue;
            }
            self.services.forget_source(id);
            self.services.register_vfs(&config);
            tracing::info!(target: "core", %id, "migrated embedded source credential");
        }
    }

    /// 在后台开始扫描一个音源，立即返回。进度通过 `ScanProgress` / `ScanFinished` 事件推送。
    pub async fn start_scan(&self, source_id: SourceId) -> Result<()> {
        let s = self.services.clone();
        let source = self
            .run({
                let s = s.clone();
                async move { s.library.get_source(source_id).await }
            })
            .await?;

        if !source.kind.is_filesystem() {
            // 服务器源（SRC-04~06）：没有文件和目录可遍历，直接拉曲目列表入库。
            let server = match self.server_for(&source) {
                Ok(server) => server,
                Err(e) => {
                    s.scan_failed(source_id, &e).await;
                    return Err(e);
                }
            };
            self.handle.spawn(async move {
                match remote_scan::sync_source(server, s.library.clone(), source_id, s.events.clone())
                    .await
                {
                    Ok(total) => {
                        tracing::info!(target: "core", %source_id, total, "media server sync finished");
                        s.events.emit(CoreEvent::LibraryChanged {
                            scope: LibraryScope::Catalog,
                        });
                    }
                    Err(e) => {
                        if matches!(e.code, ErrorCode::Network) {
                            s.health.record(source_id, Reachability::Unreachable);
                            s.events.emit(CoreEvent::SourceReachability {
                                source_id,
                                reachable: false,
                            });
                        }
                        s.scan_failed(source_id, &e).await;
                    }
                }
            });
            return Ok(());
        }

        // 本地目录被删除/移动后要明确报错并落库，而不是把空目录当成“扫描成功”
        // （把资料库清空）。`content://` 等非路径地址交给平台 VFS 处理。
        if source.kind == SourceKind::Local {
            if let Some(address) = source.addresses.first() {
                let path = address.strip_prefix("file://").unwrap_or(address);
                if !path.contains("://") && !std::path::Path::new(path).is_dir() {
                    let e = LekisError::new(
                        ErrorCode::NotFound,
                        format!("local source folder is missing: {path}"),
                    );
                    s.scan_failed(source_id, &e).await;
                    return Err(e);
                }
            }
        }

        let vfs = match s.open_vfs(&source) {
            Ok(vfs) => vfs,
            Err(e) => {
                s.scan_failed(source_id, &e).await;
                return Err(e);
            }
        };
        // 播放引擎要按 Range 读这个音源里的音频文件，先登记进去。
        s.vfs_put(source_id, vfs.clone());
        self.handle.spawn(async move {
            let events = s.events.clone();
            let progress: lekis_scanner::ProgressFn = Arc::new(move |e| events.emit(e));
            // LIB-05：先看共享索引里有没有别的设备写好的扫描摘要，有就复用它做增量剪枝。
            let previous = match lekis_scanner::shared_index::load_previous_scan(vfs.as_ref()).await {
                Ok(prev) => prev,
                Err(e) => {
                    tracing::warn!(target: "core", %source_id, error = %e, "shared index unreadable, falling back to full walk");
                    None
                }
            };
            if previous.is_some() {
                tracing::info!(target: "core", %source_id, "reusing shared scan index");
            }
            let incremental = previous.is_some();
            let report = s
                .scanner
                .scan_incremental(source_id, vfs.clone(), progress, previous.as_ref())
                .await;
            match report {
                Ok(report) => {
                    tracing::info!(target: "core", %source_id, ?report, incremental, "scan finished");
                    // LIB-05：写回共享索引，供别的设备下次扫描时复用。
                    // 默认开着；用户可在设置里用 `scan.write_shared_index = "false"` 关掉
                    // （只读共享、或不想让别的设备看到本机的标签解析结果时）。
                    let write_index = s
                        .library
                        .get_setting("scan.write_shared_index")
                        .await
                        .ok()
                        .flatten()
                        .map(|v| v != "false")
                        .unwrap_or(true);
                    if write_index {
                        match s.scanner.write_shared_index(source_id, vfs.clone()).await {
                            Ok(n) if n > 0 => {
                                tracing::debug!(target: "core", %source_id, shards = n, "shared index written");
                            }
                            Ok(_) => {}
                            Err(e) => {
                                tracing::warn!(target: "core", %source_id, error = %e, "shared index write failed")
                            }
                        }
                    }
                    s.events.emit(CoreEvent::LibraryChanged {
                        scope: LibraryScope::Catalog,
                    });

                    // ENR-01 本地部分：扫描先把曲目显示出来，再在后台补封面。
                    // 只在本地磁盘上跑；网络共享的大块读取留给补全管线。
                    if source.kind == SourceKind::Local {
                        if let Err(e) = artwork_local::ingest_missing(
                            s.clone(),
                            source_id,
                            vfs.clone(),
                        )
                        .await
                        {
                            tracing::warn!(
                                target: "core",
                                %source_id,
                                error = %e,
                                "local artwork ingest failed"
                            );
                        }
                    }
                }
                Err(e) => s.scan_failed(source_id, &e).await,
            }
        });
        Ok(())
    }

    /// 取（或构造）某个服务器源的客户端，并按可达性发事件。
    fn server_for(&self, source: &SourceConfig) -> Result<Arc<dyn lekis_providers::MediaServer>> {
        let s = &self.services;
        if let Ok(map) = s.servers.lock() {
            if let Some(id) = source.id {
                if let Some(server) = map.get(&id) {
                    return Ok(server.clone());
                }
            }
        }
        let server: Arc<dyn lekis_providers::MediaServer> = Arc::from(resolver::build_server(
            source,
            s.platform.credentials.as_ref(),
        )?);
        if let (Ok(mut map), Some(id)) = (s.servers.lock(), source.id) {
            map.insert(id, server.clone());
        }
        Ok(server)
    }

    // -----------------------------------------------------------------------
    // 网络电台（SRC-11）
    // -----------------------------------------------------------------------

    /// 浏览 / 搜索 Radio Browser，并把结果缓存到本地（返回带本机 ID 的电台）。
    pub async fn radio_browse(&self, query: RadioQuery) -> Result<RadioPage> {
        let s = self.services.clone();
        self.run(async move {
            let page = s.radio.browse(&query).await?;
            let stations = s.library.radio_upsert_many(page.stations).await?;
            Ok(RadioPage {
                stations,
                has_more: page.has_more,
            })
        })
        .await
    }

    /// 国家 / 语言 / 标签筛选选项（失败时 UI 可以用本地兜底列表）。
    pub async fn radio_filter_options(&self) -> Result<RadioFilterOptions> {
        let s = self.services.clone();
        self.run(async move { s.radio.filter_options().await })
            .await
    }

    /// 收藏的电台，最近播放的排前面。
    pub async fn radio_favorites(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let s = self.services.clone();
        self.run(async move { s.library.radio_favorites(limit).await })
            .await
    }

    /// 最近播放过的电台。
    pub async fn radio_recent(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let s = self.services.clone();
        self.run(async move { s.library.radio_recent(limit).await })
            .await
    }

    /// 用户自定义的电台。
    pub async fn radio_custom(&self, limit: u32) -> Result<Vec<RadioStation>> {
        let s = self.services.clone();
        self.run(async move { s.library.radio_custom(limit).await })
            .await
    }

    /// 添加自定义电台；`address` 可以是流地址，也可以是粘贴的 M3U / PLS 文本。
    ///
    /// 只接受 http/https。名称留空时用主机名。同一个流地址重复添加会更新名称和主页。
    pub async fn radio_add_custom(
        &self,
        name: String,
        address: String,
        homepage: Option<String>,
    ) -> Result<RadioStation> {
        let url = radio::parse_stream_address(&address)?;
        let homepage = radio::validate_homepage(homepage.as_deref())?;
        let mut name = name.trim().to_string();
        if name.is_empty() {
            name = url::Url::parse(&url)
                .ok()
                .and_then(|u| u.host_str().map(str::to_string))
                .unwrap_or_else(|| "自定义电台".to_string());
        }
        let s = self.services.clone();
        self.run(async move {
            let station = s
                .library
                .radio_add_custom(&name, &url, homepage.as_deref())
                .await?;
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::UserState,
            });
            Ok(station)
        })
        .await
    }

    /// 删除自定义电台（浏览缓存不能通过这个入口删除）。
    pub async fn radio_delete_custom(&self, id: RadioStationId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.radio_delete_custom(id).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::UserState,
        });
        Ok(())
    }

    /// 收藏 / 取消收藏电台。
    pub async fn radio_set_favorite(&self, id: RadioStationId, favorite: bool) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.radio_set_favorite(id, favorite).await })
            .await?;
        self.services.events.emit(radio::favorite_event());
        Ok(())
    }

    /// 用一组电台替换播放队列并开始播放，返回队列长度。
    ///
    /// 电台映射成负数合成 `TrackId`，播放器把它当成时长未知的网络流：
    /// 不扫描、不 seek，进度条只显示已播放时间。
    pub async fn radio_play(&self, stations: Vec<RadioStationId>, start: u32) -> Result<u32> {
        if stations.is_empty() {
            return Err(LekisError::invalid("radio queue must not be empty"));
        }
        let s = self.services.clone();
        let (tracks, start, first) = self
            .run(async move {
                let mut tracks = Vec::with_capacity(stations.len());
                for id in &stations {
                    let station = s.library.radio_station(*id).await?;
                    tracks.push(station.id.track_id());
                }
                let start = (start as usize).min(tracks.len() - 1);
                let first = stations[start];
                s.library
                    .radio_mark_played(first, radio::played_at_now())
                    .await?;
                Ok((tracks, start, first))
            })
            .await?;
        let len = tracks.len() as u32;
        self.services
            .engine
            .send(EngineCommand::SetQueue { tracks, start })?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::UserState,
        });
        tracing::info!(target: "core::radio", station = %first, queue = len, "radio queue started");
        Ok(len)
    }

    // -----------------------------------------------------------------------
    // 资料库查询
    // -----------------------------------------------------------------------

    /// 分页列出曲目。
    pub async fn list_tracks(&self, query: TrackQuery) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_track_rows(query).await })
            .await
    }

    /// 曲目详情。
    ///
    /// 负数的合成 `TrackId` 表示网络电台（SRC-11），返回一个时长 0 的虚拟曲目，
    /// 让「正在播放」和播放队列不需要为电台单独做 UI。
    pub async fn get_track(&self, id: TrackId) -> Result<Track> {
        let s = self.services.clone();
        self.run(async move {
            if let Some(station_id) = RadioStationId::from_track_id(id) {
                let station = s.library.radio_station(station_id).await?;
                return Ok(radio::station_track(&station));
            }
            if let Some(episode_id) = PodcastEpisodeId::from_track_id(id) {
                let episode = s.library.podcast_episode(episode_id).await?;
                return Ok(podcast::episode_track(&episode));
            }
            if let Some(media) = connect::media::remote_media(&s, id) {
                return Ok(media.as_track(id));
            }
            if ConnectMediaId::from_track_id(id).is_some() {
                return Err(LekisError::not_found("远端曲目已失效"));
            }
            s.library.get_track(id).await
        })
        .await
    }

    /// 曲目详情 + 用户状态（收藏、评分、播放次数）。
    pub async fn get_track_with_state(&self, id: TrackId) -> Result<(Track, TrackUserState)> {
        let s = self.services.clone();
        self.run(async move {
            if let Some(station_id) = RadioStationId::from_track_id(id) {
                let station = s.library.radio_station(station_id).await?;
                let state = TrackUserState {
                    loved: station.favorite,
                    rating: None,
                    play_count: 0,
                    updated_hlc: None,
                };
                return Ok((radio::station_track(&station), state));
            }
            if let Some(episode_id) = PodcastEpisodeId::from_track_id(id) {
                let episode = s.library.podcast_episode(episode_id).await?;
                let state = TrackUserState {
                    loved: false,
                    rating: None,
                    play_count: 0,
                    updated_hlc: None,
                };
                return Ok((podcast::episode_track(&episode), state));
            }
            if let Some(media) = connect::media::remote_media(&s, id) {
                let state = TrackUserState {
                    loved: false,
                    rating: None,
                    play_count: 0,
                    updated_hlc: None,
                };
                return Ok((media.as_track(id), state));
            }
            if ConnectMediaId::from_track_id(id).is_some() {
                return Err(LekisError::not_found("远端曲目已失效"));
            }
            let track = s.library.get_track(id).await?;
            let state = s.library.user_state(track.uid.clone()).await?;
            Ok((track, state))
        })
        .await
    }

    /// 曲目总数。
    pub async fn count_tracks(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.track_count().await }).await
    }

    /// 专辑总数。
    pub async fn count_albums(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.album_count().await }).await
    }

    /// 艺人总数。
    pub async fn count_artists(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.artist_count().await })
            .await
    }

    /// 某个流派的曲目数。
    pub async fn count_genre_tracks(&self, name: String) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.genre_track_count(&name).await })
            .await
    }

    /// 收藏的曲目数。
    pub async fn count_loved(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.loved_count().await }).await
    }

    /// 最近播放过的曲目（首页"继续收听"）。
    pub async fn recently_played(&self, limit: u32) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.recently_played(limit).await })
            .await
    }

    /// 搜索。
    pub async fn search(&self, text: String, limit: u32) -> Result<SearchResults> {
        let s = self.services.clone();
        self.run(async move { s.library.search(&text, limit.min(100)).await })
            .await
    }

    // ---- 重复检测与库健康（LIB-10 / LIB-11）----

    /// 分页列出重复组。每组的保留版本按无损 / 音质 / 文件大小挑选。
    pub async fn duplicate_groups(&self, offset: u32, limit: u32) -> Result<Vec<DuplicateGroup>> {
        let s = self.services.clone();
        self.run(async move { s.library.duplicate_groups(offset, limit).await })
            .await
    }

    /// 重复组总数。
    pub async fn duplicate_group_count(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.duplicate_group_count().await })
            .await
    }

    /// 库健康汇总。
    pub async fn library_health_summary(&self) -> Result<LibraryHealthSummary> {
        let s = self.services.clone();
        self.run(async move { s.library.library_health_summary().await })
            .await
    }

    /// 某一类健康问题的条目数。
    pub async fn library_health_count(&self, kind: HealthIssueKind) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.library_health_count(kind).await })
            .await
    }

    /// 某一类健康问题的一页条目。
    pub async fn library_health_page(
        &self,
        kind: HealthIssueKind,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<LibraryHealthEntry>> {
        let s = self.services.clone();
        self.run(async move { s.library.library_health_page(kind, offset, limit).await })
            .await
    }

    /// 扫描所有文件系统音源的可读性，写入"损坏 / 不可读"状态。
    ///
    /// 一次性返回；每个文件只读 1 个字节，不解析标签，也不做频谱分析。
    /// 某个音源整体打不开时只记录音源级错误，不会把它的所有文件都标成损坏。
    pub async fn scan_library_health(&self) -> Result<HealthScanReport> {
        let s = self.services.clone();
        self.run(async move { health::scan(&s).await }).await
    }

    // ---- 浏览维度（LIB-06）----

    /// 专辑列表。`TrackSort::Artist` 按专辑艺人排序，其余维度同曲目列表。
    pub async fn list_albums(
        &self,
        sort: TrackSort,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<Album>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_albums(sort, offset, limit).await })
            .await
    }

    /// 专辑详情。
    pub async fn get_album(&self, id: AlbumId) -> Result<Album> {
        let s = self.services.clone();
        self.run(async move { s.library.get_album(id).await }).await
    }

    /// 专辑的生效封面（专辑自己没有时取它第一首有封面的曲目）。
    pub async fn album_artwork(&self, id: AlbumId) -> Result<Option<lekis_library::ArtworkRow>> {
        let s = self.services.clone();
        self.run(async move {
            let album = s.library.get_album(id).await?;
            match album.artwork_hash {
                Some(hash) => s.library.artwork_by_hash(&hash).await,
                None => Ok(None),
            }
        })
        .await
    }

    /// 按 ID 取封面元数据。
    pub async fn get_artwork(&self, id: ArtworkId) -> Result<lekis_library::ArtworkRow> {
        let s = self.services.clone();
        self.run(async move { s.library.get_artwork(id).await })
            .await
    }

    /// 专辑里的曲目（按碟号 + 曲号）。
    pub async fn album_tracks(
        &self,
        id: AlbumId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.album_tracks(id, offset, limit).await })
            .await
    }

    /// 专辑的艺人署名。
    pub async fn album_artists(&self, id: AlbumId) -> Result<Vec<Artist>> {
        let s = self.services.clone();
        self.run(async move { s.library.album_artists(id).await })
            .await
    }

    /// 艺人列表。
    pub async fn list_artists(&self, offset: u32, limit: u32) -> Result<Vec<Artist>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_artists(offset, limit).await })
            .await
    }

    /// 艺人详情。
    pub async fn get_artist(&self, id: ArtistId) -> Result<Artist> {
        let s = self.services.clone();
        self.run(async move { s.library.get_artist(id).await })
            .await
    }

    /// 艺人参与的曲目。
    pub async fn artist_tracks(
        &self,
        id: ArtistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.artist_tracks(id, offset, limit).await })
            .await
    }

    /// 艺人的专辑。
    pub async fn artist_albums(&self, id: ArtistId, offset: u32, limit: u32) -> Result<Vec<Album>> {
        let s = self.services.clone();
        self.run(async move { s.library.artist_albums(id, offset, limit).await })
            .await
    }

    /// 流派列表（名称 + 曲目数）。
    pub async fn list_genres(&self, limit: u32) -> Result<Vec<GenreCount>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_genres(limit).await })
            .await
    }

    /// 某个流派的曲目。
    pub async fn genre_tracks(
        &self,
        name: String,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.genre_tracks(&name, offset, limit).await })
            .await
    }

    /// 最近添加的曲目（首页用）。
    pub async fn recently_added(&self, limit: u32) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.recently_added(limit).await })
            .await
    }

    /// 收藏 / 取消收藏。
    ///
    /// 电台的负合成 ID 映射到电台收藏；普通曲目走原有 `user_state` 和同步日志。
    pub async fn set_loved(&self, id: TrackId, loved: bool) -> Result<()> {
        if let Some(station_id) = RadioStationId::from_track_id(id) {
            self.radio_set_favorite(station_id, loved).await?;
            return Ok(());
        }
        // 播客单集没有收藏（订阅在节目级别）；远端曲目不在本机资料库里。
        if PodcastEpisodeId::from_track_id(id).is_some()
            || ConnectMediaId::from_track_id(id).is_some()
        {
            return Ok(());
        }
        let s = self.services.clone();
        self.run(async move {
            let track = s.library.get_track(id).await?;
            s.library.set_loved(track.uid.clone(), loved).await?;
            // SYN-01：同时记一条同步操作，等同步时推给其他设备。
            let op = sync_engine::track_state_op(
                &s.clock,
                &track.uid,
                "loved",
                Some(serde_json::json!(loved)),
            );
            s.library
                .enqueue_sync_op(op.hlc.to_string(), op_json(&op)?)
                .await?;
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::UserState,
            });
            Ok(())
        })
        .await
    }

    /// 给一首歌打分（1~5；0 表示清除评分）。
    pub async fn set_rating(&self, id: TrackId, rating: i64) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let track = s.library.get_track(id).await?;
            s.library.set_rating(track.uid.clone(), rating).await?;
            let op = sync_engine::track_state_op(
                &s.clock,
                &track.uid,
                "rating",
                Some(serde_json::json!(rating)),
            );
            s.library
                .enqueue_sync_op(op.hlc.to_string(), op_json(&op)?)
                .await?;
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::UserState,
            });
            Ok(())
        })
        .await
    }

    /// 读一个设置项（SET-01~04）。
    pub async fn get_setting(&self, key: String) -> Result<Option<String>> {
        let s = self.services.clone();
        self.run(async move { s.library.get_setting(&key).await })
            .await
    }

    /// 写一个设置项。
    pub async fn set_setting(&self, key: String, value: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            s.library.set_setting(&key, &value).await?;
            s.apply_setting(&key, Some(&value));
            // 只有 `sync.` 前缀的设置项才跨设备同步（本机设置不同步）。
            if key.starts_with("sync.") {
                let op = sync_engine::setting_op(&s.clock, &key, &value);
                s.library
                    .enqueue_sync_op(op.hlc.to_string(), op_json(&op)?)
                    .await?;
            }
            Ok(())
        })
        .await
    }

    /// 读取 10 段均衡器设置（PLY-04）。缺省值是关闭、平直曲线。
    pub async fn equalizer(&self) -> Result<EqualizerSettings> {
        let s = self.services.clone();
        self.run(async move {
            let enabled = s.library.get_setting(settings::EQ_ENABLED).await?;
            let preamp = s.library.get_setting(settings::EQ_PREAMP).await?;
            let bands = s.library.get_setting(settings::EQ_BANDS).await?;
            let preset = s.library.get_setting(settings::EQ_PRESET).await?;
            Ok(equalizer::from_values(
                enabled.as_deref(),
                preamp.as_deref(),
                bands.as_deref(),
                preset.as_deref(),
            ))
        })
        .await
    }

    /// 保存并立即应用 10 段均衡器设置。
    ///
    /// 输入会先钳制到合法范围；正在播放的共享输出会话会在下一个解码块使用新参数。
    /// 比特完美独占输出不经过 DSP，因此不受影响（UI 会提示）。
    pub async fn set_equalizer(&self, settings: EqualizerSettings) -> Result<()> {
        let settings = settings.sanitized();
        let s = self.services.clone();
        self.run(async move {
            let bands = serde_json::to_string(&settings.bands_db)
                .map_err(|e| LekisError::internal(format!("serialize eq bands: {e}")))?;
            s.library
                .set_setting(
                    settings::EQ_ENABLED,
                    if settings.enabled { "true" } else { "false" },
                )
                .await?;
            s.library
                .set_setting(settings::EQ_PREAMP, &settings.preamp_db.to_string())
                .await?;
            s.library.set_setting(settings::EQ_BANDS, &bands).await?;
            s.library
                .set_setting(
                    settings::EQ_PRESET,
                    settings.preset.as_deref().unwrap_or(""),
                )
                .await?;
            // 全部写完后一次性更新共享参数，避免解码线程看到半套设置。
            s.eq.set(settings.to_playback());
            Ok(())
        })
        .await
    }

    // -----------------------------------------------------------------------
    // 本地插件（PLG-01~07）
    // -----------------------------------------------------------------------

    /// 本地插件目录（`<data_dir>/plugins`）。设置页可以展示或复制这个路径。
    pub fn plugins_dir(&self) -> String {
        self.services.plugins.root().to_string_lossy().into_owned()
    }

    /// 已安装插件列表。清单损坏的插件也会返回，错误放在 `error` 字段。
    pub async fn plugins(&self) -> Result<Vec<plugins::PluginInfo>> {
        self.services.plugins.list().await
    }

    /// 从本地文件夹或 `.zip` 安装插件。
    pub async fn install_plugin_from_path(&self, path: String) -> Result<plugins::PluginInfo> {
        self.services
            .plugins
            .install(std::path::Path::new(&path))
            .await
    }

    /// 启用 / 停用插件。状态持久化在资料库设置里。
    pub async fn set_plugin_enabled(&self, plugin_id: String, enabled: bool) -> Result<()> {
        self.services.plugins.set_enabled(&plugin_id, enabled).await
    }

    /// 移除插件目录、插件数据和相关设置。
    pub async fn remove_plugin(&self, plugin_id: String) -> Result<()> {
        self.services.plugins.remove(&plugin_id).await
    }

    /// 插件声明的设置项及当前值（密码项不回传值）。
    pub async fn plugin_settings(
        &self,
        plugin_id: String,
    ) -> Result<Vec<plugins::PluginSettingView>> {
        self.services.plugins.settings(&plugin_id).await
    }

    /// 保存一个插件设置项。
    pub async fn set_plugin_setting(
        &self,
        plugin_id: String,
        key: String,
        value: String,
    ) -> Result<()> {
        self.services
            .plugins
            .set_setting(&plugin_id, &key, &value)
            .await
    }

    /// 当前网络环境（SRC-14）。平台层在 Wi-Fi 切换时调用。
    pub fn set_network_context(&self, net: NetworkContext) {
        self.services.health.set_network(net);
    }

    /// 记录一次源可达性探测结果（SRC-14）。
    pub fn report_source_reachability(&self, source_id: SourceId, reachable: bool) {
        let reach = if reachable {
            Reachability::Reachable
        } else {
            Reachability::Unreachable
        };
        self.services.health.record(source_id, reach);
        self.services.events.emit(CoreEvent::SourceReachability {
            source_id,
            reachable,
        });
    }

    // -----------------------------------------------------------------------
    // 统一资料库（SRC-13）：查看曲目全部来源、手动合并 / 拆分
    // -----------------------------------------------------------------------

    /// 列出 `track_id` 关联的全部音源文件，并标注每个源的当前可达性以及
    /// 按当前网络环境（Home / Away）会优先播放哪一份。
    pub async fn track_sources(&self, track_id: TrackId) -> Result<Vec<TrackSourceInfo>> {
        let s = self.services.clone();
        self.run(async move {
            let entries = s.library.track_source_entries(track_id).await?;
            let files = s.library.track_files(track_id).await?;
            let chosen = s.health.pick(&files);
            let out = entries
                .into_iter()
                .map(|e| {
                    let reachable = match s.health.get(e.source_id) {
                        Reachability::Reachable => Some(true),
                        Reachability::Unreachable => Some(false),
                        Reachability::Unknown => None,
                    };
                    let preferred = chosen.is_some_and(|best| {
                        best.source_id == e.source_id
                            && best.path == e.path
                            && best.external_id == e.external_id
                    });
                    TrackSourceInfo {
                        source_id: e.source_id,
                        source_name: e.source_name,
                        source_kind: e.source_kind,
                        file_id: e.file_id,
                        path: e.path,
                        external_id: e.external_id,
                        size_bytes: e.size_bytes,
                        format: e.format,
                        quality_score: e.quality_score,
                        reachable,
                        preferred,
                    }
                })
                .collect();
            Ok(out)
        })
        .await
    }

    /// 把 `absorb_ids` 合并到 `keep_id` 下（SRC-13 手动合并），不删除磁盘文件。
    pub async fn merge_tracks(&self, keep_id: TrackId, absorb_ids: Vec<TrackId>) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move {
            let n = s.library.merge_tracks(keep_id, absorb_ids).await?;
            if n > 0 {
                s.events.emit(CoreEvent::LibraryChanged {
                    scope: LibraryScope::Catalog,
                });
            }
            Ok(n)
        })
        .await
    }

    /// 删除重复歌曲中的一个低音质文件副本（可选同时删除磁盘 / NAS 源文件）。
    pub async fn delete_duplicate_file(
        &self,
        source_id: SourceId,
        path: String,
        delete_source_file: bool,
    ) -> Result<bool> {
        let s = self.services.clone();
        self.run(async move {
            if delete_source_file {
                let source = s
                    .library
                    .list_sources()
                    .await?
                    .into_iter()
                    .find(|src| src.id == Some(source_id))
                    .ok_or_else(|| LekisError::not_found(format!("source {source_id}")))?;
                if !matches!(
                    source.kind,
                    SourceKind::Local
                        | SourceKind::Smb
                        | SourceKind::WebDav
                        | SourceKind::Nfs
                        | SourceKind::Sftp
                ) {
                    return Err(LekisError::unsupported(
                        "媒体服务器来源不支持直接删除源文件，请取消勾选磁盘删除，仅从资料库移除",
                    ));
                }
                let vfs = match s.vfs_get(source_id) {
                    Some(v) => v,
                    None => {
                        let v = s.open_vfs(&source)?;
                        s.vfs_put(source_id, v.clone());
                        v
                    }
                };
                let vfs_path = lekis_vfs::VfsPath::parse(&path)
                    .ok_or_else(|| LekisError::invalid("文件路径非法"))?;
                vfs.delete_file(&vfs_path).await?;
            }

            let removed = s.library.remove_file_copy(source_id, path).await?;
            if removed {
                s.events.emit(CoreEvent::LibraryChanged {
                    scope: LibraryScope::Catalog,
                });
            }
            Ok(removed)
        })
        .await
    }

    /// 歌曲按标题排序时的首字母索引表（UIX-05）。
    pub async fn track_index_offsets(&self) -> Result<Vec<LetterOffset>> {
        let s = self.services.clone();
        self.run(async move { s.library.track_title_index_offsets().await })
            .await
    }

    /// 艺人列表的首字母索引表（UIX-05）。
    pub async fn artist_index_offsets(&self) -> Result<Vec<LetterOffset>> {
        let s = self.services.clone();
        self.run(async move { s.library.artist_index_offsets().await })
            .await
    }

    /// 把 `track_id` 下的某一个来源拆成独立曲目（SRC-13 手动拆分）。
    pub async fn split_track_source(
        &self,
        track_id: TrackId,
        source_id: SourceId,
        file_id: Option<i64>,
        external_id: Option<String>,
    ) -> Result<TrackId> {
        let s = self.services.clone();
        self.run(async move {
            let new_id = s
                .library
                .split_track_source(track_id, source_id, file_id, external_id)
                .await?;
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            });
            Ok(new_id)
        })
        .await
    }

    /// 手动跑一轮同步（SYN-01/02）。`share` 是 NAS 上共享目录的 Vfs。
    pub async fn sync_now(
        &self,
        share: Arc<dyn lekis_vfs::Vfs>,
    ) -> Result<sync_engine::SyncReport> {
        let s = self.services.clone();
        let channel = sync_engine::channel_for(share, &s.device_id.0);
        self.run(async move {
            let mut clock = match s.clock.lock() {
                Ok(c) => c.clone(),
                Err(_) => return Err(LekisError::internal("sync clock poisoned")),
            };
            let report = sync_engine::sync_once(
                channel.as_ref(),
                &s.library,
                &s.device_id.0,
                &mut clock,
                &s.events,
            )
            .await?;
            if let Ok(mut guard) = s.clock.lock() {
                *guard = clock;
            }
            Ok(report)
        })
        .await
    }

    /// 用某个文件系统音源指向的共享目录跑一轮同步。
    ///
    /// 便利版 `sync_now`：音源必须在数据库里，凭据从平台钥匙串取。
    pub async fn sync_source(&self, source_id: SourceId) -> Result<sync_engine::SyncReport> {
        let s = self.services.clone();
        let source = self
            .run({
                let s = s.clone();
                async move { s.library.get_source(source_id).await }
            })
            .await?;
        if !source.kind.is_filesystem() {
            return Err(LekisError::invalid(
                "sync needs a filesystem source (local folder, SMB or WebDAV share)",
            ));
        }
        let vfs = s.open_vfs(&source)?;
        s.vfs_put(source_id, vfs.clone());
        self.sync_now(vfs).await
    }

    // -----------------------------------------------------------------------
    // 离线下载（OFF-01/02/04）
    // -----------------------------------------------------------------------

    /// 把一首歌加入离线下载队列。立即返回，进度靠 `OfflineProgress` / `OfflineChanged` 事件。
    ///
    /// 已下载且缓存文件还在时不重复下载；可重复调用。
    pub async fn download_track(&self, id: TrackId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { offline::schedule(&s, id).await })
            .await
    }

    /// 批量加入下载队列，返回成功入队 / 已在下载的条数。
    pub async fn download_tracks(&self, ids: Vec<TrackId>) -> Result<u32> {
        let s = self.services.clone();
        self.run(async move {
            let mut count = 0u32;
            for id in ids {
                match offline::schedule(&s, id).await {
                    Ok(()) => count += 1,
                    Err(e) => tracing::warn!(
                        target: "core::offline",
                        %id,
                        error = %e,
                        "cannot schedule offline download"
                    ),
                }
            }
            Ok(count)
        })
        .await
    }

    /// 全部离线记录（下载中 / 排队 / 已完成 / 失败）。
    pub async fn offline_downloads(&self) -> Result<Vec<OfflineDownload>> {
        let s = self.services.clone();
        self.run(async move { s.library.offline_downloads().await })
            .await
    }

    /// 已下载曲目数 + 缓存总字节数。
    pub async fn offline_stats(&self) -> Result<OfflineStats> {
        let s = self.services.clone();
        self.run(async move { s.library.offline_stats().await })
            .await
    }

    /// 某首歌的离线状态；没有记录时为 `None`。
    pub async fn offline_status(&self, id: TrackId) -> Result<Option<OfflineDownload>> {
        let s = self.services.clone();
        self.run(async move { s.library.offline_download(id).await })
            .await
    }

    /// 删除离线记录和缓存文件；正在下载时同时取消。
    pub async fn remove_download(&self, id: TrackId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { offline::remove(&s, id).await }).await
    }

    // -----------------------------------------------------------------------
    // 播放控制（都是非阻塞的：只是给引擎发命令）
    // -----------------------------------------------------------------------

    /// 用一组曲目替换队列，从 `start` 开始播放。
    pub fn play_tracks(&self, tracks: Vec<TrackId>, start: u32) -> Result<()> {
        if tracks.is_empty() {
            return Err(LekisError::invalid("tracks must not be empty"));
        }
        self.services.engine.send(EngineCommand::SetQueue {
            tracks,
            start: start as usize,
        })
    }

    /// 把一个浏览上下文（整个曲库、专辑、艺人、流派、歌单、收藏）整体放进队列，
    /// 从 UI 列表里的第 `start_index` 行开始播放。
    ///
    /// 队列在核心里按上下文完整生成，不依赖 UI 已经加载了哪些行。歌单里的占位条目会被跳过，
    /// `start_index` 指向占位时从它后面第一首可播放的开始。
    pub async fn play_context(&self, context: TrackContext, start_index: u32) -> Result<u32> {
        let s = self.services.clone();
        let rows = self
            .run(async move { s.library.context_track_ids(context).await })
            .await?;
        let (tracks, start) = queue_from_rows(rows, start_index as usize)
            .ok_or_else(|| LekisError::invalid("nothing playable in this context"))?;
        let len = tracks.len() as u32;
        self.services
            .engine
            .send(EngineCommand::SetQueue { tracks, start })?;
        Ok(len)
    }

    /// 追加到队尾（队列为空时直接开始播放）。
    pub fn add_to_queue(&self, tracks: Vec<TrackId>) -> Result<()> {
        if tracks.is_empty() {
            return Ok(());
        }
        self.services.engine.send(EngineCommand::AddToQueue(tracks))
    }

    /// 插到当前曲目之后（"下一首播放"）。
    pub fn play_next(&self, tracks: Vec<TrackId>) -> Result<()> {
        if tracks.is_empty() {
            return Ok(());
        }
        self.services.engine.send(EngineCommand::PlayNext(tracks))
    }

    /// 从队列删除播放顺序里的第 `index` 首。
    pub fn queue_remove(&self, index: u32) -> Result<()> {
        self.services
            .engine
            .send(EngineCommand::RemoveFromQueue(index as usize))
    }

    /// 在队列里移动一首（播放顺序下标）。
    pub fn queue_move(&self, from: u32, to: u32) -> Result<()> {
        self.services.engine.send(EngineCommand::MoveInQueue {
            from: from as usize,
            to: to as usize,
        })
    }

    /// 队列的一页（按播放顺序；`PlaybackSnapshot.queue_index` 是这个顺序里的下标）。
    pub async fn queue_items(&self, offset: u32, limit: u32) -> Result<Vec<TrackRow>> {
        let limit = limit.clamp(1, TrackQuery::MAX_LIMIT) as usize;
        let ids: Vec<TrackId> = self
            .services
            .engine
            .snapshot()
            .queue
            .iter()
            .skip(offset as usize)
            .take(limit)
            .copied()
            .collect();
        let s = self.services.clone();
        self.run(async move {
            let mut rows = Vec::with_capacity(ids.len());
            for id in ids {
                if let Some(station_id) = RadioStationId::from_track_id(id) {
                    match s.library.radio_station(station_id).await {
                        Ok(station) => {
                            rows.push(radio::station_track_row(&station));
                            continue;
                        }
                        Err(e) if e.code == ErrorCode::NotFound => {}
                        Err(e) => return Err(e),
                    }
                } else if let Some(episode_id) = PodcastEpisodeId::from_track_id(id) {
                    match s.library.podcast_episode(episode_id).await {
                        Ok(episode) => {
                            rows.push(podcast::episode_track_row(&episode));
                            continue;
                        }
                        Err(e) if e.code == ErrorCode::NotFound => {}
                        Err(e) => return Err(e),
                    }
                } else if ConnectMediaId::from_track_id(id).is_some() {
                    if let Some(media) = connect::media::remote_media(&s, id) {
                        rows.push(media.as_row(id));
                        continue;
                    }
                } else {
                    match s.library.track_row(id).await {
                        Ok(row) => {
                            rows.push(row);
                            continue;
                        }
                        // 曲目在队列里但已经被删（源被移除）：给一行占位，保持下标对齐。
                        Err(e) if e.code != ErrorCode::NotFound => return Err(e),
                        Err(_) => {}
                    }
                }
                rows.push(TrackRow {
                    id,
                    title: String::new(),
                    artist_line: String::new(),
                    album_title: None,
                    duration_ms: 0,
                    artwork_id: None,
                    quality_badge: None,
                    loved: false,
                });
            }
            Ok(rows)
        })
        .await
    }

    /// 播放 / 继续。
    pub fn play(&self) -> Result<()> {
        self.services.engine.send(EngineCommand::Play)
    }

    /// 暂停。
    pub fn pause(&self) -> Result<()> {
        self.services.engine.send(EngineCommand::Pause)
    }

    /// 下一首。
    pub fn next(&self) -> Result<()> {
        self.services.engine.send(EngineCommand::Next)
    }

    /// 上一首。
    pub fn previous(&self) -> Result<()> {
        self.services.engine.send(EngineCommand::Previous)
    }

    /// 跳转。
    pub fn seek(&self, position_ms: u64) -> Result<()> {
        self.services.engine.send(EngineCommand::Seek(position_ms))
    }

    /// 循环模式。
    pub fn set_repeat(&self, mode: RepeatMode) -> Result<()> {
        self.services.engine.send(EngineCommand::SetRepeat(mode))
    }

    /// 随机模式。
    pub fn set_shuffle(&self, mode: ShuffleMode) -> Result<()> {
        self.services.engine.send(EngineCommand::SetShuffle(mode))
    }

    /// 音量（0..=1）。
    pub fn set_volume(&self, volume: f32) -> Result<()> {
        self.services.engine.send(EngineCommand::SetVolume(volume))
    }

    /// 系统音频焦点"闪避"：`true` 时临时压到 30%，`false` 恢复。
    /// 不改用户音量（快照、遥控端、保存的会话都不受影响）。
    pub fn set_ducked(&self, ducked: bool) -> Result<()> {
        self.services
            .engine
            .send(EngineCommand::SetDuck(if ducked { DUCK_GAIN } else { 1.0 }))
    }

    /// 切输出设备（PLY-05/PLY-12）。`None` 表示跟随系统默认。
    pub fn set_output_device(&self, device_id: Option<String>) -> Result<()> {
        self.services
            .engine
            .send(EngineCommand::SetOutputDevice(device_id))
    }

    /// 切输出模式：共享 / 独占（PLY-05）。
    pub fn set_output_mode(&self, mode: OutputMode) -> Result<()> {
        self.services
            .engine
            .send(EngineCommand::SetOutputMode(mode))
    }

    /// 列出本机可用的输出设备（PLY-12 热插拔时重新拉一次）。
    pub fn list_output_devices(&self) -> Result<Vec<OutputDevice>> {
        lekis_playback::list_output_devices()
    }

    /// 当前播放状态（UI 首次显示时用；之后靠事件更新）。
    pub fn playback_snapshot(&self) -> PlaybackSnapshot {
        self.services.engine.snapshot()
    }

    /// 保存当前播放会话：队列、游标、进度、随机 / 循环模式和音量。
    ///
    /// 队列为空时清除旧记录。这是给 App 在暂停、跳转、队列变化和退到后台时调用的；
    /// 播放中由 App 节流调用，不要每个进度 tick 都写库。
    pub async fn save_playback_state(&self) -> Result<()> {
        let snap = self.services.engine.snapshot();
        // SRC-12：正在播的是播客单集时顺带记住进度（失败不影响会话保存）。
        if let Err(e) = self.podcast_save_progress(&snap).await {
            tracing::debug!(target: "core::podcast", error = %e.message, "save podcast progress failed");
        }
        let s = self.services.clone();
        if snap.queue.is_empty() {
            return self
                .run(async move { s.library.clear_playback_state().await })
                .await;
        }
        let state = PlaybackStateRow {
            queue: snap.queue.to_vec(),
            current_index: snap.queue_index.unwrap_or(0),
            position_ms: snap.position_ms,
            shuffle: snap.shuffle,
            repeat: snap.repeat,
            volume: snap.volume,
            updated_at: now_ms(),
        };
        self.run(async move { s.library.save_playback_state(state).await })
            .await
    }

    /// 上次保存的播放会话（不恢复、不自动播放）。
    pub async fn playback_state(&self) -> Result<Option<PlaybackStateRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.load_playback_state().await })
            .await
    }

    /// 清除保存的播放会话。
    pub async fn clear_playback_state(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.clear_playback_state().await })
            .await
    }

    /// 恢复上次的播放会话：队列、游标、进度、模式和音量，**暂停**在保存的位置。
    ///
    /// 返回是否恢复出了队列。曲目已被删除时由资料库过滤并修正游标；
    /// 队列全部失效时返回 `false`，不会自动开始播放。
    pub async fn restore_playback_state(&self) -> Result<bool> {
        let s = self.services.clone();
        let Some(state) = self
            .run(async move { s.library.load_playback_state().await })
            .await?
        else {
            return Ok(false);
        };
        let engine = &self.services.engine;
        // 先把音量压到 0 再装队列：SetQueue 会照常打开输出流，压低音量保证
        // 恢复过程不会漏出一小段声音；暂停后再把用户音量还回去。
        engine.send(EngineCommand::SetVolume(0.0))?;
        engine.send(EngineCommand::SetShuffle(state.shuffle))?;
        engine.send(EngineCommand::SetRepeat(state.repeat))?;
        engine.send(EngineCommand::SetQueue {
            tracks: state.queue,
            start: state.current_index as usize,
        })?;
        // 引擎按命令顺序处理：SetQueue 打开输出后立刻暂停，不会继续出声。
        engine.send(EngineCommand::Pause)?;
        if state.position_ms > 0 {
            engine.send(EngineCommand::Seek(state.position_ms))?;
        }
        engine.send(EngineCommand::SetVolume(state.volume))?;
        Ok(true)
    }

    // -----------------------------------------------------------------------
    // 元数据补全（ENR-01/03/06/07）
    // -----------------------------------------------------------------------

    /// 对单曲跑一次补全（歌词 + 封面）。
    ///
    /// 分数 ≥ 0.85 的直接应用（写覆盖层 / 封面 / 歌词，不动原文件），
    /// 0.5~0.85 的进待确认队列，< 0.5 丢弃。返回本次的处理统计。
    pub async fn enrich_track(&self, id: TrackId) -> Result<EnrichReport> {
        let s = self.services.clone();
        let report = self
            .run(async move { s.enrich.enrich_track(&s.library, id).await })
            .await?;
        if report.queued > 0 {
            let s2 = self.services.clone();
            let pending = self
                .run(async move { s2.library.pending_candidate_count().await })
                .await? as u32;
            self.services
                .events
                .emit(CoreEvent::EnrichQueueChanged { pending });
        }
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(report)
    }

    /// 后台补全一批曲目（合并成一次 `LibraryChanged` 事件，避免事件风暴）。
    pub async fn enrich_tracks(&self, ids: Vec<TrackId>) -> Result<EnrichReport> {
        let s = self.services.clone();
        let report = self
            .run(async move {
                let mut total = EnrichReport::default();
                for id in ids {
                    match s.enrich.enrich_track(&s.library, id).await {
                        Ok(r) => {
                            total.auto_applied += r.auto_applied;
                            total.queued += r.queued;
                            total.discarded += r.discarded;
                        }
                        Err(e) => tracing::warn!(
                            target: "lekis_core::enrich",
                            code = %e.code.as_str(),
                            "补全单曲失败，继续下一首"
                        ),
                    }
                }
                Ok(total)
            })
            .await?;
        let s2 = self.services.clone();
        let pending = self
            .run(async move { s2.library.pending_candidate_count().await })
            .await? as u32;
        self.services
            .events
            .emit(CoreEvent::EnrichQueueChanged { pending });
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(report)
    }

    /// 待确认队列里的一页候选。
    pub async fn pending_candidates(&self, limit: u32) -> Result<Vec<EnrichCandidateRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_pending_candidates(limit).await })
            .await
    }

    /// 待确认候选总数（"待确认 (N)" 角标用）。
    pub async fn pending_candidate_count(&self) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.pending_candidate_count().await })
            .await
    }

    /// 接受一条候选：把内容真正写进库（歌词 / 覆盖层），再改状态。
    pub async fn accept_candidate(&self, id: i64) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let pending = s
                .library
                .list_pending_candidates(TrackQuery::MAX_LIMIT)
                .await?;
            let row = pending
                .into_iter()
                .find(|r| r.id == id)
                .ok_or_else(|| LekisError::not_found(format!("enrich candidate {id}")))?;
            s.enrich.apply_candidate(&s.library, &row).await?;
            s.library.accept_candidate(id).await?;
            let pending = s.library.pending_candidate_count().await? as u32;
            s.events.emit(CoreEvent::EnrichQueueChanged { pending });
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog,
            });
            Ok(())
        })
        .await
    }

    /// 拒绝一条候选。
    pub async fn reject_candidate(&self, id: i64) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            s.library.reject_candidate(id).await?;
            let pending = s.library.pending_candidate_count().await? as u32;
            s.events.emit(CoreEvent::EnrichQueueChanged { pending });
            Ok(())
        })
        .await
    }

    /// 全部接受。
    pub async fn accept_all_candidates(&self) -> Result<u64> {
        let s = self.services.clone();
        let n = self
            .run(async move {
                // 逐条应用内容再改状态，否则 accepted 了但数据没写进去。
                let pending = s
                    .library
                    .list_pending_candidates(TrackQuery::MAX_LIMIT)
                    .await?;
                let mut applied = 0u64;
                for row in &pending {
                    if s.enrich.apply_candidate(&s.library, row).await.is_ok() {
                        s.library.accept_candidate(row.id).await?;
                        applied += 1;
                    }
                }
                Ok(applied)
            })
            .await?;
        self.services
            .events
            .emit(CoreEvent::EnrichQueueChanged { pending: 0 });
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(n)
    }

    // -----------------------------------------------------------------------
    // 歌词与封面（ENR-03/07/12）
    // -----------------------------------------------------------------------

    /// 当前生效的歌词（ENR-03）。
    ///
    /// 电台没有歌词：直接返回 `None`，不查库、不发网络请求。
    pub async fn lyrics(&self, id: TrackId) -> Result<Option<Lyrics>> {
        if id.0 < 0 {
            return Ok(None);
        }
        let s = self.services.clone();
        self.run(async move {
            if let Some(found) = s.library.active_lyrics(id).await? {
                return Ok(Some(found));
            }
            // 本地：同名 .lrc / 内嵌歌词标签。
            match lyrics_local::find_and_store(&s, id).await {
                Ok(Some(found)) => return Ok(Some(found)),
                Ok(None) => {}
                Err(e) => tracing::debug!(target: "core", code = %e.code.as_str(), "local lyrics lookup failed"),
            }
            // 在线：LRCLIB。每首歌每次运行只试一次，查不到不反复打网络。
            let first_try = LYRICS_TRIED
                .lock()
                .map(|mut set| set.insert(id))
                .unwrap_or(false);
            if first_try {
                let fetch = s.enrich.fetch_lyrics(&s.library, id);
                match tokio::time::timeout(std::time::Duration::from_secs(12), fetch).await {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => tracing::warn!(target: "core", code = %e.code.as_str(), "LRCLIB lyrics lookup failed"),
                    Err(_) => tracing::warn!(target: "core", "LRCLIB lyrics lookup timed out"),
                }
                return s.library.active_lyrics(id).await;
            }
            Ok(None)
        })
            .await
    }

    /// 这首歌所有可用歌词（按来源优先级排序，供用户切换）。
    pub async fn lyrics_versions(&self, id: TrackId) -> Result<Vec<LyricsRow>> {
        if id.0 < 0 {
            return Ok(Vec::new());
        }
        let s = self.services.clone();
        self.run(async move { s.library.list_lyrics(id).await })
            .await
    }

    /// 手动导入 / 粘贴歌词（ENR-07）。
    pub async fn set_lyrics(&self, id: TrackId, lyrics: Lyrics) -> Result<i64> {
        let s = self.services.clone();
        let created = self
            .run(async move { s.library.save_lyrics(id, lyrics).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(created)
    }

    /// 调整歌词整体偏移（ENR-07）。
    pub async fn set_lyrics_offset(&self, id: TrackId, offset_ms: i32) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_lyrics_offset(id, offset_ms).await })
            .await
    }

    /// 曲目的生效封面（曲目级优先，回落专辑级）。电台没有本地封面。
    pub async fn artwork(&self, id: TrackId) -> Result<Option<lekis_library::ArtworkRow>> {
        if ConnectMediaId::from_track_id(id).is_some() {
            let s = self.services.clone();
            return self
                .run(async move { connect::media::remote_artwork(&s, id).await })
                .await;
        }
        if id.0 < 0 {
            return Ok(None);
        }
        let s = self.services.clone();
        self.run(async move { s.library.effective_artwork(id).await })
            .await
    }

    /// 封面文件在本机缓存里的绝对路径（UI 取图用）。
    pub fn artwork_path(&self, hash: String, width: u32) -> String {
        enrich::artwork_file_path(&self.services.config, &hash, width)
            .to_string_lossy()
            .into_owned()
    }

    /// 手动指定曲目封面（ENR-01 的"本地导入"路径）。
    pub async fn set_track_artwork(
        &self,
        id: TrackId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_track_artwork(id, artwork_id).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(())
    }

    /// 用用户选的图片当封面（ENR-01 的"本地导入"）。
    ///
    /// 图片走和自动补全一样的流水线：生成各档缩略图、取色、按内容哈希去重，
    /// 只写本机缓存和数据库，不动音频文件。给了 `album_id` 就换专辑封面；
    /// `track_ids` 里的曲目会钉上这张图（盖过它们内嵌的封面）。
    /// 返回换之前的状态，交给 [`Self::restore_artwork`] 可以撤销。
    pub async fn set_artwork_from_image(
        &self,
        image: Vec<u8>,
        track_ids: Vec<TrackId>,
        album_id: Option<AlbumId>,
    ) -> Result<ArtworkChange> {
        check_artwork_image(&image)?;
        if track_ids.is_empty() && album_id.is_none() {
            return Err(LekisError::invalid("没有指定要换封面的曲目或专辑"));
        }
        let s = self.services.clone();
        let change = self
            .run(async move {
                // 先记下原来的封面（撤销用）。
                let mut previous_tracks = Vec::with_capacity(track_ids.len());
                for id in &track_ids {
                    previous_tracks.push((*id, s.library.track_own_artwork(*id).await?));
                }
                let previous_album = match album_id {
                    Some(id) => Some((id, s.library.album_own_artwork(id).await?)),
                    None => None,
                };
                let target = enrich::ArtworkTarget {
                    track_id: None,
                    album_id,
                    replace_album: true,
                };
                let artwork = enrich::store_artwork_bytes(
                    &s.config.cache_dir,
                    &s.library,
                    target,
                    image,
                    "user",
                )
                .await?;
                for id in &track_ids {
                    s.library.set_track_artwork(*id, Some(artwork)).await?;
                }
                Ok(ArtworkChange {
                    artwork_id: artwork,
                    previous_tracks,
                    previous_album,
                })
            })
            .await?;
        self.emit_library_changed();
        Ok(change)
    }

    /// 把用户选的图片存进封面缓存（缩略图、取色、按内容去重），不挂到任何东西上。
    /// 返回封面 ID，调用方再用它设歌单封面之类（[`Self::set_playlist_artwork`]）。
    pub async fn import_artwork(&self, image: Vec<u8>) -> Result<ArtworkId> {
        check_artwork_image(&image)?;
        let s = self.services.clone();
        self.run(async move {
            let target = enrich::ArtworkTarget {
                track_id: None,
                album_id: None,
                replace_album: false,
            };
            enrich::store_artwork_bytes(&s.config.cache_dir, &s.library, target, image, "user")
                .await
        })
        .await
    }

    /// 撤销 [`Self::set_artwork_from_image`]：把曲目和专辑的封面改回原样。
    pub async fn restore_artwork(&self, change: ArtworkChange) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            for (id, previous) in change.previous_tracks {
                s.library.set_track_artwork(id, previous).await?;
            }
            if let Some((id, previous)) = change.previous_album {
                s.library.set_album_artwork(id, previous).await?;
            }
            Ok(())
        })
        .await?;
        self.emit_library_changed();
        Ok(())
    }

    // -----------------------------------------------------------------------
    // 歌单（PL-01/PL-05）
    // -----------------------------------------------------------------------

    /// 新建歌单。
    pub async fn create_playlist(&self, name: String) -> Result<PlaylistId> {
        let s = self.services.clone();
        let id = self
            .run(async move { s.library.create_playlist(&name, None).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(id)
    }

    /// 重命名歌单。
    pub async fn rename_playlist(&self, id: PlaylistId, name: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.rename_playlist(id, &name).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    /// 删除歌单（墓碑，可通过同步恢复）。
    pub async fn delete_playlist(&self, id: PlaylistId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.delete_playlist(id).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    /// 所有歌单。
    pub async fn list_playlists(&self) -> Result<Vec<lekis_library::Playlist>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_playlists().await })
            .await
    }

    /// 一个歌单的元数据。
    pub async fn get_playlist(&self, id: PlaylistId) -> Result<lekis_library::Playlist> {
        let s = self.services.clone();
        self.run(async move { s.library.get_playlist(id).await })
            .await
    }

    /// 歌单里的一页条目（占位曲目用 `track: None` 表示，PL-05）。
    pub async fn playlist_items(
        &self,
        id: PlaylistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<PlaylistEntry>> {
        let s = self.services.clone();
        self.run(async move { s.library.playlist_items(id, offset, limit).await })
            .await
    }

    /// 往歌单加曲目，返回新的位置键。
    pub async fn add_to_playlist(
        &self,
        id: PlaylistId,
        track_uid: String,
        before_key: Option<String>,
        after_key: Option<String>,
    ) -> Result<String> {
        let s = self.services.clone();
        let key = self
            .run(async move {
                s.library
                    .add_to_playlist(
                        id,
                        TrackUid(track_uid),
                        before_key.as_deref(),
                        after_key.as_deref(),
                    )
                    .await
            })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(key)
    }

    /// 从歌单移除一条。
    pub async fn remove_from_playlist(&self, id: PlaylistId, position_key: String) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.remove_from_playlist(id, &position_key).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    /// 在歌单里移动一条。
    pub async fn move_playlist_item(
        &self,
        id: PlaylistId,
        position_key: String,
        before_key: Option<String>,
        after_key: Option<String>,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            s.library
                .move_playlist_item(
                    id,
                    &position_key,
                    before_key.as_deref(),
                    after_key.as_deref(),
                )
                .await
        })
        .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    /// 给歌单设封面。
    pub async fn set_playlist_artwork(
        &self,
        id: PlaylistId,
        artwork_id: Option<ArtworkId>,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_playlist_artwork(id, artwork_id).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    // -----------------------------------------------------------------------
    // M3U / M3U8 导入导出（PL-03）
    // -----------------------------------------------------------------------

    /// 把普通歌单导出成 M3U8 文本。智能歌单没有固定条目，返回 `invalid`。
    pub async fn export_playlist_m3u(&self, id: PlaylistId) -> Result<String> {
        let s = self.services.clone();
        self.run(async move { s.library.export_playlist_m3u(id).await })
            .await
    }

    /// 从 M3U / M3U8 文本新建一个普通歌单，返回匹配统计和缺失路径。
    pub async fn import_playlist_m3u(
        &self,
        name: String,
        content: String,
    ) -> Result<lekis_library::PlaylistImportReport> {
        let s = self.services.clone();
        let report = self
            .run(async move { s.library.import_playlist_m3u(&name, &content).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(report)
    }

    /// 把普通歌单导出成 XSPF 文本；智能歌单没有固定条目，返回 `invalid`。
    pub async fn export_playlist_xspf(&self, id: PlaylistId) -> Result<String> {
        let s = self.services.clone();
        self.run(async move { s.library.export_playlist_xspf(id).await })
            .await
    }

    /// 从 XSPF 文本新建一个普通歌单，返回匹配统计和缺失路径。
    pub async fn import_playlist_xspf(
        &self,
        name: String,
        content: String,
    ) -> Result<lekis_library::PlaylistImportReport> {
        let s = self.services.clone();
        let report = self
            .run(async move { s.library.import_playlist_xspf(&name, &content).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(report)
    }

    // -----------------------------------------------------------------------
    // 智能歌单（DIS-01）
    // -----------------------------------------------------------------------

    /// 所有智能歌单（`kind = smart`）。
    pub async fn smart_playlists(&self) -> Result<Vec<lekis_library::Playlist>> {
        let s = self.services.clone();
        let all = self
            .run(async move { s.library.list_playlists().await })
            .await?;
        Ok(all
            .into_iter()
            .filter(|p| p.kind == lekis_library::PlaylistKind::Smart)
            .collect())
    }

    /// 求值一个智能歌单，返回一页曲目。
    pub async fn smart_playlist_tracks(
        &self,
        id: PlaylistId,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.smart_playlist_tracks(id, offset, limit).await })
            .await
    }

    /// 读歌单规则（普通歌单返回 `None`）。
    pub async fn playlist_rules(
        &self,
        id: PlaylistId,
    ) -> Result<Option<lekis_library::SmartRules>> {
        let s = self.services.clone();
        self.run(async move { s.library.playlist_rules(id).await })
            .await
    }

    /// 设置 / 清除歌单规则；有规则时歌单自动变成智能歌单。
    pub async fn set_playlist_rules(
        &self,
        id: PlaylistId,
        rules: Option<lekis_library::SmartRules>,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_playlist_rules(id, rules.as_ref()).await })
            .await?;
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Playlists,
        });
        Ok(())
    }

    /// 按规则预览曲目（不落库；规则编辑器用）。
    pub async fn evaluate_smart_rules(
        &self,
        rules: lekis_library::SmartRules,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.evaluate_smart_rules(&rules, offset, limit).await })
            .await
    }

    /// 按规则统计匹配曲目数（规则编辑器预览用）。
    pub async fn count_smart_rules(&self, rules: lekis_library::SmartRules) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move { s.library.count_smart_rules(&rules).await })
            .await
    }

    // -----------------------------------------------------------------------
    // 用户状态与统计（PL-02 / DIS-06）
    // -----------------------------------------------------------------------

    /// 收藏列表。
    pub async fn loved_tracks(&self, offset: u32, limit: u32) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_loved(offset, limit).await })
            .await
    }

    /// 播放最多的曲目。
    pub async fn most_played(&self, limit: u32) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.most_played(limit).await })
            .await
    }

    /// 有听歌记录的年份，新的在前（DIS-06）。
    pub async fn listening_years(&self) -> Result<Vec<i32>> {
        let s = self.services.clone();
        self.run(async move { s.library.listening_years().await })
            .await
    }

    /// 某年/全部时间的听歌统计（DIS-06）。
    pub async fn listening_summary(
        &self,
        year: Option<i32>,
        top_limit: u32,
    ) -> Result<ListeningSummary> {
        let s = self.services.clone();
        self.run(async move { s.library.listening_summary(year, top_limit).await })
            .await
    }

    /// 记一次播放（DIS-06；scrobble 判定也用这条记录）。
    ///
    /// 电台只更新最近播放时间，不写曲目播放统计，也不产生 scrobble。
    pub async fn record_play(&self, id: TrackId, ms_played: u64) -> Result<()> {
        // 播客单集的进度由 save_playback_state 写回，不进曲目播放统计；
        // 远端曲目的播放记在控制端。
        if PodcastEpisodeId::from_track_id(id).is_some()
            || ConnectMediaId::from_track_id(id).is_some()
        {
            return Ok(());
        }
        if let Some(station_id) = RadioStationId::from_track_id(id) {
            let s = self.services.clone();
            self.run(async move {
                s.library
                    .radio_mark_played(station_id, radio::played_at_now())
                    .await
            })
            .await?;
            self.services.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::UserState,
            });
            return Ok(());
        }
        let s = self.services.clone();
        self.run(async move {
            let track = s.library.get_track(id).await?;
            s.library
                .record_play(track.uid, s.device_id.0.clone(), ms_played, now_ms())
                .await
        })
        .await
    }

    // -----------------------------------------------------------------------
    // 听歌记录上报（DIS-07）
    // -----------------------------------------------------------------------

    /// 当前上报设置（不含明文凭据）。
    pub fn scrobble_settings(&self) -> ScrobbleSettings {
        self.services.scrobble.settings()
    }

    /// 已保存的上报设置：`None` 字段保留原凭据，`Some("")` 删除，`Some(v)` 覆盖。
    pub async fn set_scrobble_settings(
        &self,
        input: ScrobbleSettingsInput,
    ) -> Result<ScrobbleSettings> {
        let s = self.services.clone();
        self.run(async move { s.scrobble.update(input).await })
            .await
    }

    /// 上报状态：是否配置完整、队列条数、最近错误 / 成功时间。
    pub fn scrobble_status(&self) -> ScrobbleStatus {
        self.services.scrobble.status()
    }

    /// 测试连接（只读接口，不会产生 scrobble / now-playing）。
    pub async fn test_scrobble(&self) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.scrobble.test().await }).await
    }

    /// 给曲目写覆盖层（补全结果 / 手动修正，不改原文件）。
    pub async fn set_track_overlay(
        &self,
        id: TrackId,
        overlay: Option<TrackOverlay>,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_track_overlay(id, overlay).await })
            .await?;
        self.emit_library_changed();
        Ok(())
    }

    /// 读手工标签覆盖层（LIB-13）。没有覆盖层返回 `None`。
    pub async fn track_tag_overrides(&self, id: TrackId) -> Result<Option<TrackTagOverrides>> {
        let s = self.services.clone();
        self.run(async move { s.library.track_tag_overrides(id).await })
            .await
    }

    /// 读本地文件里的现有标签（编辑对话框预填用，不读覆盖层）。
    pub async fn read_track_file_tags(&self, id: TrackId) -> Result<TrackTagOverrides> {
        let s = self.services.clone();
        self.run(async move { s.library.read_track_file_tags(id).await })
            .await
    }

    /// 保存手工标签覆盖层（只改资料库，不碰文件）。
    pub async fn set_track_tag_overrides(
        &self,
        id: TrackId,
        fields: TrackTagOverrides,
    ) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.set_track_tag_overrides(id, fields).await })
            .await?;
        self.emit_library_changed();
        Ok(())
    }

    /// 清除手工标签覆盖层。
    pub async fn clear_track_tag_overrides(&self, id: TrackId) -> Result<()> {
        let s = self.services.clone();
        self.run(async move { s.library.clear_track_tag_overrides(id).await })
            .await?;
        self.emit_library_changed();
        Ok(())
    }

    /// 把当前覆盖层写回音频文件（先备份，失败时尝试自动恢复）。
    pub async fn write_track_tags(&self, id: TrackId) -> Result<TagWriteResult> {
        let s = self.services.clone();
        let result = self
            .run(async move { s.library.write_track_tags(id).await })
            .await?;
        self.emit_library_changed();
        Ok(result)
    }

    /// 从备份恢复上一份原标签；成功后清除覆盖层。
    pub async fn restore_track_tags(&self, id: TrackId) -> Result<TagWriteResult> {
        let s = self.services.clone();
        let result = self
            .run(async move { s.library.restore_track_tags(id).await })
            .await?;
        self.emit_library_changed();
        Ok(result)
    }

    /// 批量写回，逐项返回；单首失败不影响其余曲目。
    pub async fn batch_write_track_tags(
        &self,
        ids: Vec<TrackId>,
    ) -> Result<Vec<BatchTagWriteItem>> {
        let s = self.services.clone();
        let results = self
            .run(async move { s.library.batch_write_track_tags(ids).await })
            .await?;
        if results.iter().any(|item| item.result.is_some()) {
            self.emit_library_changed();
        }
        Ok(results)
    }

    fn emit_library_changed(&self) {
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
    }
}

/// 用户选的封面图片不能为空，也不能大得离谱（解码会吃光内存）。
fn check_artwork_image(image: &[u8]) -> Result<()> {
    const MAX_IMAGE: usize = 40 * 1024 * 1024;
    if image.is_empty() || image.len() > MAX_IMAGE {
        return Err(LekisError::invalid("封面图片为空或超过 40 MB"));
    }
    Ok(())
}

/// 闪避时的音量系数（和常见播放器一致，压到 30%）。
const DUCK_GAIN: f32 = 0.3;

/// 一次换封面的结果：新封面，以及换之前的状态（撤销用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtworkChange {
    /// 新封面。
    pub artwork_id: ArtworkId,
    /// 每首曲目原来自己钉的封面。
    pub previous_tracks: Vec<(TrackId, Option<ArtworkId>)>,
    /// 专辑原来的封面。
    pub previous_album: Option<(AlbumId, Option<ArtworkId>)>,
}

/// 从旧配置里剥出内嵌密码：地址 userinfo 优先，其次是 options 里的
/// `api_key` / `token`。会就地清理地址和 options，返回找到的明文。
fn take_embedded_secret(config: &mut SourceConfig) -> Option<String> {
    let mut secret = None;
    for address in &mut config.addresses {
        let Ok(mut url) = url::Url::parse(address) else {
            continue;
        };
        let Some(password) = url.password().map(str::to_string) else {
            continue;
        };
        if !password.is_empty() {
            secret = Some(password);
        }
        let _ = url.set_password(None);
        *address = url.to_string();
        if secret.is_some() {
            break;
        }
    }
    // SFTP 私钥文件的 passphrase（`?key_passphrase=`）：同样搬进凭据库，
    // SFTP 用私钥文件登录时把凭据当成 passphrase。
    for address in &mut config.addresses {
        let Ok(mut url) = url::Url::parse(address) else {
            continue;
        };
        let mut found = None;
        let kept: Vec<(String, String)> = url
            .query_pairs()
            .filter_map(|(k, v)| {
                if matches!(k.as_ref(), "key_passphrase" | "passphrase") {
                    found = Some(v.into_owned());
                    None
                } else {
                    Some((k.into_owned(), v.into_owned()))
                }
            })
            .collect();
        let Some(passphrase) = found else { continue };
        if kept.is_empty() {
            url.set_query(None);
        } else {
            url.query_pairs_mut().clear().extend_pairs(kept);
        }
        *address = url.to_string();
        if secret.is_none() && !passphrase.is_empty() {
            secret = Some(passphrase);
        }
    }
    // 地址里已经有密码时也把 options 里的旧 token 清掉，避免数据库里残留明文。
    for key in ["api_key", "token"] {
        if let Some(value) = config.options.remove(key) {
            if secret.is_none() && !value.trim().is_empty() {
                secret = Some(value);
            }
        }
    }
    secret
}

/// 凭据变了：丢掉所有引用它的源的连接。
async fn forget_sources_using(s: &Services, credential_ref: &str) {
    if let Ok(sources) = s.library.list_sources().await {
        for src in sources {
            if src.credential_ref.as_deref() == Some(credential_ref) {
                if let Some(id) = src.id {
                    s.forget_source(id);
                    s.register_vfs(&src);
                }
            }
        }
    }
}

/// 上下文行（`None` 是歌单占位）→ 可播放的队列 + 起始下标。没有任何可播放曲目时返回 `None`。
fn queue_from_rows(rows: Vec<Option<TrackId>>, start_row: usize) -> Option<(Vec<TrackId>, usize)> {
    let start_row = start_row.min(rows.len().saturating_sub(1));
    // 起始行之前有几首可播放的，就是队列里的起始下标（起始行是占位时自然落到它后面那首）。
    let start = rows[..start_row].iter().filter(|r| r.is_some()).count();
    let tracks: Vec<TrackId> = rows.into_iter().flatten().collect();
    if tracks.is_empty() {
        return None;
    }
    let last = tracks.len() - 1;
    Some((tracks, start.min(last)))
}

/// 把一条 `SyncOp` 序列化成写进 outbox 的 JSON 文本。
fn op_json(op: &lekis_sync::SyncOp) -> Result<String> {
    serde_json::to_string(op).map_err(|e| LekisError::internal(format!("serialize sync op: {e}")))
}

impl Drop for LekisCore {
    fn drop(&mut self) {
        let _ = self.services.engine.send(EngineCommand::Shutdown);
        // shutdown_background 在任何上下文里都可以安全调用（包括 async 上下文）。
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_background();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct Collect(Mutex<Vec<CoreEvent>>);
    impl EventListener for Collect {
        fn on_event(&self, event: CoreEvent) {
            if let Ok(mut v) = self.0.lock() {
                v.push(event);
            }
        }
    }

    #[test]
    fn queue_from_rows_skips_placeholders_and_maps_start() {
        let rows = vec![Some(TrackId(1)), None, Some(TrackId(3)), Some(TrackId(4))];
        assert_eq!(
            queue_from_rows(rows.clone(), 0),
            Some((vec![TrackId(1), TrackId(3), TrackId(4)], 0))
        );
        // 起始行是占位：从它后面第一首开始。
        assert_eq!(queue_from_rows(rows.clone(), 1).map(|q| q.1), Some(1));
        assert_eq!(queue_from_rows(rows.clone(), 3).map(|q| q.1), Some(2));
        // 越界钳到最后一行。
        assert_eq!(queue_from_rows(rows, 99).map(|q| q.1), Some(2));
        assert_eq!(queue_from_rows(vec![None, None], 0), None);
        assert_eq!(queue_from_rows(vec![], 0), None);
        // 最后一行是占位：退到最后一首可播放的。
        assert_eq!(
            queue_from_rows(vec![Some(TrackId(1)), None], 1).map(|q| q.1),
            Some(0)
        );
    }

    #[test]
    fn end_to_end_scan_of_local_folder() -> Result<()> {
        let root = std::env::temp_dir().join(format!("lekis-core-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let music = root.join("music/周杰伦/叶惠美");
        std::fs::create_dir_all(&music)?;
        std::fs::write(music.join("03. 晴天.flac"), b"not really flac")?;

        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let events = Arc::new(Collect(Mutex::new(Vec::new())));
        core.add_listener(events.clone());

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            let source = core
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Local,
                    name: "Music".into(),
                    addresses: vec![root.join("music").to_string_lossy().into_owned()],
                    root_path: String::new(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: true,
                })
                .await?;
            core.start_scan(source).await?;
            // 等待后台扫描完成。
            for _ in 0..100 {
                if core
                    .list_tracks(TrackQuery {
                        sort: TrackSort::Title,
                        offset: 0,
                        limit: 10,
                    })
                    .await?
                    .len()
                    == 1
                {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            let rows = core
                .list_tracks(TrackQuery {
                    sort: TrackSort::Title,
                    offset: 0,
                    limit: 10,
                })
                .await?;
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].title, "晴天");

            core.play_tracks(vec![rows[0].id], 0)?;
            // 并行跑整个测试套件时引擎任务可能晚几百毫秒才被调度；不要用固定睡眠。
            for _ in 0..100 {
                if core.playback_snapshot().track_id == Some(rows[0].id) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            assert_eq!(core.playback_snapshot().track_id, Some(rows[0].id));
            Ok::<_, LekisError>(())
        })?;

        let seen = events.0.lock().map(|v| v.clone()).unwrap_or_default();
        assert!(seen
            .iter()
            .any(|e| matches!(e, CoreEvent::ScanFinished { added: 1, .. })));
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    /// 建一个带若干本地"音频"文件的核心，扫描完返回（核心、根目录、音源 ID、事件收集器）。
    fn core_with_local_tracks(
        name: &str,
        files: &[&str],
    ) -> Result<(
        LekisCore,
        std::path::PathBuf,
        SourceId,
        Arc<Collect>,
        tokio::runtime::Runtime,
    )> {
        let root = std::env::temp_dir().join(format!("lekis-core-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let music = root.join("music");
        std::fs::create_dir_all(&music)?;
        for f in files {
            std::fs::write(music.join(f), b"not really audio")?;
        }
        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let events = Arc::new(Collect(Mutex::new(Vec::new())));
        core.add_listener(events.clone());
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let expected = files.len();
        let source = rt.block_on(async {
            let source = core
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Local,
                    name: "Music".into(),
                    addresses: vec![music.to_string_lossy().into_owned()],
                    root_path: String::new(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: true,
                })
                .await?;
            core.start_scan(source).await?;
            for _ in 0..200 {
                if core.count_tracks().await? as usize == expected {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
            assert_eq!(core.count_tracks().await? as usize, expected);
            // 等初始扫描真正结束（ScanFinished 在 mark_scanned 之后发出），
            // 否则并行测试里后续操作可能被仍在跑的首次扫描覆盖。
            for _ in 0..400 {
                if seen(&events).iter().any(
                    |e| matches!(e, CoreEvent::ScanFinished { source_id, .. } if *source_id == source),
                ) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
            Ok::<_, LekisError>(source)
        })?;
        Ok((core, root, source, events, rt))
    }

    fn seen(events: &Collect) -> Vec<CoreEvent> {
        events.0.lock().map(|v| v.clone()).unwrap_or_default()
    }

    #[test]
    fn update_test_and_remove_source() -> Result<()> {
        let (core, root, source, events, rt) =
            core_with_local_tracks("sources", &["01. Alpha.flac", "02. Beta.flac"])?;
        rt.block_on(async {
            let mut cfg = core.list_sources().await?.remove(0);
            // 试连：存在的目录可以列出；不存在的目录报错且不入库。
            core.test_source(cfg.clone()).await?;
            let mut broken = cfg.clone();
            broken.id = None;
            broken.addresses = vec![root.join("nope").to_string_lossy().into_owned()];
            assert!(core.test_source(broken).await.is_err());
            assert_eq!(core.list_sources().await?.len(), 1);

            cfg.name = "Renamed".into();
            core.update_source(cfg.clone()).await?;
            let infos = core.list_source_infos().await?;
            assert_eq!(infos[0].config.name, "Renamed");
            assert!(infos[0].last_scan_at.is_some());
            assert!(infos[0].last_scan_error.is_none());

            core.remove_source(source).await?;
            assert!(core.list_sources().await?.is_empty());
            assert_eq!(core.count_tracks().await?, 0);
            assert_eq!(core.count_albums().await?, 0);
            assert_eq!(core.count_artists().await?, 0);
            Ok::<_, LekisError>(())
        })?;
        assert!(seen(&events).iter().any(|e| matches!(
            e,
            CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog
            }
        )));
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn scan_failure_is_persisted_and_reported() -> Result<()> {
        let (core, root, source, events, rt) = core_with_local_tracks("scanfail", &["a.flac"])?;
        // 把音源目录删掉，再扫：要么同步返回错误，要么后台推 ScanFailed；两种情况都要落库。
        std::fs::remove_dir_all(root.join("music"))?;
        rt.block_on(async {
            let started = core.start_scan(source).await;
            // 整个套件并行跑时后台扫描任务可能被 CPU 抢占；给足 30 秒。
            for _ in 0..1200 {
                let info = core.list_source_infos().await?.remove(0);
                if info.last_scan_error.is_some() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
            let info = core.list_source_infos().await?.remove(0);
            assert!(info.last_scan_error.is_some(), "failure must be persisted");
            assert!(info.last_scan_error_code.is_some());
            if started.is_ok() {
                assert!(seen(&events).iter().any(
                    |e| matches!(e, CoreEvent::ScanFailed { source_id, .. } if *source_id == source)
                ));
            }
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn browse_and_share_listing_reject_unsupported_input() -> Result<()> {
        let root = std::env::temp_dir().join(format!("lekis-core-browse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let config = |kind: SourceKind, address: &str| SourceConfig {
            id: None,
            kind,
            name: "draft".into(),
            addresses: vec![address.into()],
            root_path: String::new(),
            credential_ref: None,
            options: Default::default(),
            enabled: true,
        };
        rt.block_on(async {
            let err = core
                .browse_source(config(SourceKind::Local, "C:/Music"), String::new())
                .await
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::Unsupported);
            let err = core
                .browse_source(config(SourceKind::Smb, "smb://nas/music"), "a/../..".into())
                .await
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidArgument);
            let err = core
                .list_shares(config(SourceKind::WebDav, "http://nas"))
                .await
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::Unsupported);
            let err = core
                .list_shares(config(SourceKind::Smb, "http://nas"))
                .await
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidArgument);
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn credentials_are_stored_by_reference() -> Result<()> {
        let root = std::env::temp_dir().join(format!("lekis-core-creds-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            assert!(!core.has_credential("lekis.source.nas"));
            core.set_credential("lekis.source.nas".into(), "hunter2".into())
                .await?;
            assert!(core.has_credential("lekis.source.nas"));
            core.delete_credential("lekis.source.nas".into()).await?;
            assert!(!core.has_credential("lekis.source.nas"));
            assert_eq!(
                core.set_credential(" ".into(), "x".into())
                    .await
                    .unwrap_err()
                    .code,
                ErrorCode::InvalidArgument
            );
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn embedded_source_credentials_are_migrated_out_of_the_database() -> Result<()> {
        let root =
            std::env::temp_dir().join(format!("lekis-core-cred-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let platform = PlatformServices::in_memory();
        let credentials = platform.credentials.clone();
        let core = LekisCore::new(CoreConfig::for_tests(&root), platform)?;
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            let smb_secret = "smb-secret-7jw";
            let mut smb_options = std::collections::BTreeMap::new();
            smb_options.insert("username".to_string(), "ao".to_string());
            let smb = core
                .services
                .library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Smb,
                    name: "nas".into(),
                    addresses: vec![format!("smb://ao:{smb_secret}@nas/music")],
                    root_path: String::new(),
                    credential_ref: None,
                    options: smb_options,
                    enabled: true,
                })
                .await?;
            let mut plex_options = std::collections::BTreeMap::new();
            plex_options.insert("token".to_string(), "plex-secret-7jw".to_string());
            let plex = core
                .services
                .library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Plex,
                    name: "plex".into(),
                    addresses: vec!["http://plex:32400".into()],
                    root_path: String::new(),
                    credential_ref: None,
                    options: plex_options,
                    enabled: true,
                })
                .await?;

            let sources = core.list_sources().await?;
            let smb_cfg = sources
                .iter()
                .find(|s| s.id == Some(smb))
                .expect("smb source must exist");
            let plex_cfg = sources
                .iter()
                .find(|s| s.id == Some(plex))
                .expect("plex source must exist");
            assert!(!smb_cfg.addresses[0].contains("smb-secret-7jw"));
            assert_eq!(smb_cfg.addresses[0], "smb://ao@nas/music");
            assert_eq!(
                smb_cfg.options.get("username").map(String::as_str),
                Some("ao")
            );
            let smb_ref = smb_cfg.credential_ref.as_deref().expect("smb ref");
            assert_eq!(credentials.get(smb_ref).as_deref(), Some("smb-secret-7jw"));
            assert!(plex_cfg.options.get("token").is_none());
            let plex_ref = plex_cfg.credential_ref.as_deref().expect("plex ref");
            assert_eq!(
                credentials.get(plex_ref).as_deref(),
                Some("plex-secret-7jw")
            );

            // 第二次读取不会再次迁移，也不会改坏已经干净的配置。
            let again = core.list_sources().await?;
            assert_eq!(again.len(), 2);

            // SFTP 私钥文件的 passphrase 写在地址查询参数里：搬进凭据库，地址保留 key=。
            let sftp = core
                .services
                .library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Sftp,
                    name: "box".into(),
                    addresses: vec![
                        "sftp://ao@box:2200/music?key=%2Fk%2Fid_ed25519&key_passphrase=pp-7jw"
                            .into(),
                    ],
                    root_path: String::new(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: true,
                })
                .await?;
            let sources = core.list_sources().await?;
            let sftp_cfg = sources.iter().find(|s| s.id == Some(sftp)).expect("sftp");
            assert!(
                !sftp_cfg.addresses[0].contains("pp-7jw"),
                "{}",
                sftp_cfg.addresses[0]
            );
            assert!(sftp_cfg.addresses[0].contains("key="));
            let sftp_ref = sftp_cfg.credential_ref.as_deref().expect("sftp ref");
            assert_eq!(credentials.get(sftp_ref).as_deref(), Some("pp-7jw"));

            // 新保存的音源不能把秘密写进地址。
            let err = core
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Sftp,
                    name: "typed".into(),
                    addresses: vec!["sftp://ao:hunter2@box/music".into()],
                    root_path: String::new(),
                    credential_ref: None,
                    options: Default::default(),
                    enabled: true,
                })
                .await
                .unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidArgument);
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn user_picked_image_becomes_the_album_and_track_cover() -> Result<()> {
        let (core, root, _source, _events, rt) =
            core_with_local_tracks("user-artwork", &["01. A.flac", "02. B.flac"])?;
        rt.block_on(async {
            let track = core.get_track(TrackId(1)).await?;
            let album = track.album_id;
            let mut png = Vec::new();
            image::RgbImage::from_pixel(64, 64, image::Rgb([200, 30, 40]))
                .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                .map_err(|e| LekisError::internal(e.to_string()))?;

            let png_copy = png.clone();
            let before_track = core.artwork(track.id).await?.map(|a| a.id);
            let change = core
                .set_artwork_from_image(png, vec![track.id], album)
                .await?;
            let artwork = change.artwork_id;
            let shown = core.artwork(track.id).await?.expect("track artwork");
            assert_eq!(shown.id, artwork);
            assert_eq!(shown.source, "user");
            if let Some(album) = album {
                let album_art = core.album_artwork(album).await?.expect("album artwork");
                assert_eq!(album_art.id, artwork);
            }
            let path = core.artwork_path(shown.hash.clone(), 256);
            assert!(std::path::Path::new(&path).exists(), "{path}");

            // 不是图片 / 空：明确报错，不改任何东西。
            assert!(core
                .set_artwork_from_image(b"nope".to_vec(), vec![track.id], None)
                .await
                .is_err());
            assert!(core
                .set_artwork_from_image(Vec::new(), vec![track.id], None)
                .await
                .is_err());
            assert_eq!(core.artwork(track.id).await?.map(|a| a.id), Some(artwork));

            // 撤销：回到换之前。
            core.restore_artwork(change).await?;
            assert_eq!(core.artwork(track.id).await?.map(|a| a.id), before_track);

            // 歌单封面：同一张图按内容去重，拿到同一个封面 ID。
            let imported = core.import_artwork(png_copy).await?;
            assert_eq!(imported, artwork);
            assert!(core.import_artwork(Vec::new()).await.is_err());
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn play_context_queues_the_whole_library_and_queue_is_editable() -> Result<()> {
        let (core, root, _source, events, rt) = core_with_local_tracks(
            "context",
            &["01. A.flac", "02. B.flac", "03. C.flac", "04. D.flac"],
        )?;
        rt.block_on(async {
            let n = core
                .play_context(TrackContext::Library(TrackSort::Title), 2)
                .await?;
            assert_eq!(n, 4);
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            let snap = core.playback_snapshot();
            assert_eq!(snap.queue_len, 4);
            assert_eq!(snap.queue_index, Some(2));
            let items = core.queue_items(0, 10).await?;
            let titles: Vec<&str> = items.iter().map(|r| r.title.as_str()).collect();
            assert_eq!(titles, vec!["A", "B", "C", "D"]);

            core.queue_move(3, 0)?;
            core.queue_remove(1)?; // 删掉 A
            core.play_next(vec![items[0].id])?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            let titles: Vec<String> = core
                .queue_items(0, 10)
                .await?
                .into_iter()
                .map(|r| r.title)
                .collect();
            assert_eq!(titles, vec!["D", "B", "C", "A"]);
            assert_eq!(core.playback_snapshot().queue_index, Some(2));

            core.set_repeat(RepeatMode::All)?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            assert_eq!(core.playback_snapshot().repeat, RepeatMode::All);

            // 记一次播放后出现在"最近播放"里。
            core.record_play(items[1].id, 30_000).await?;
            let recent = core.recently_played(10).await?;
            assert_eq!(recent.first().map(|r| r.id), Some(items[1].id));
            let (_, state) = core.get_track_with_state(items[1].id).await?;
            assert_eq!(state.play_count, 1);
            Ok::<_, LekisError>(())
        })?;
        let seen = seen(&events);
        assert!(seen.iter().any(|e| matches!(
            e,
            CoreEvent::PlaybackOptionsChanged {
                repeat: RepeatMode::All,
                ..
            }
        )));
        assert!(seen
            .iter()
            .any(|e| matches!(e, CoreEvent::QueueChanged { length: 4, .. })));
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn playback_session_roundtrip_restores_paused() -> Result<()> {
        let (core, root, _source, _events, rt) =
            core_with_local_tracks("session", &["01. A.flac", "02. B.flac"])?;
        rt.block_on(async {
            let rows = core
                .list_tracks(TrackQuery {
                    sort: TrackSort::Title,
                    offset: 0,
                    limit: 10,
                })
                .await?;
            let ids: Vec<TrackId> = rows.iter().map(|r| r.id).collect();
            core.play_tracks(ids.clone(), 0)?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            core.set_repeat(RepeatMode::All)?;
            core.set_shuffle(ShuffleMode::Random)?;
            core.set_volume(0.4)?;
            core.seek(5_000)?;
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;

            core.save_playback_state().await?;
            let saved = core.playback_state().await?.expect("saved session");
            assert_eq!(saved.queue, ids);
            assert_eq!(saved.current_index, 0);
            assert_eq!(saved.repeat, RepeatMode::All);
            assert_eq!(saved.shuffle, ShuffleMode::Random);
            assert!((saved.volume - 0.4).abs() < 1e-6);

            // 清空引擎里的队列，模拟一次冷启动。
            core.queue_remove(0)?;
            core.queue_remove(0)?;
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            assert_eq!(core.playback_snapshot().queue_len, 0);

            assert!(core.restore_playback_state().await?);
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            let snap = core.playback_snapshot();
            assert_eq!(snap.queue_len, 2);
            assert_eq!(snap.queue_index, Some(0));
            assert_eq!(snap.track_id, Some(ids[0]));
            assert_eq!(snap.position_ms, 5_000);
            assert_eq!(snap.repeat, RepeatMode::All);
            assert_eq!(snap.shuffle, ShuffleMode::Random);
            assert!((snap.volume - 0.4).abs() < 1e-6);
            // 恢复出来的会话是暂停的，不会自动播放。
            assert_ne!(snap.state, PlaybackState::Playing);

            core.clear_playback_state().await?;
            assert_eq!(core.playback_state().await?, None);
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn gapless_and_replaygain_settings_take_effect() -> Result<()> {
        let root = std::env::temp_dir().join(format!("lekis-core-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        {
            let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            rt.block_on(async {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                assert!(core.playback_snapshot().gapless);
                core.set_setting(settings::GAPLESS.into(), "false".into())
                    .await?;
                core.set_setting(settings::REPLAYGAIN.into(), "album".into())
                    .await?;
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                assert!(!core.playback_snapshot().gapless);
                assert_eq!(
                    core.services.resolver.replaygain_mode(),
                    resolver::ReplayGainMode::Album
                );
                Ok::<_, LekisError>(())
            })?;
        }
        // 重启后从数据库读回来。
        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            for _ in 0..400 {
                if !core.playback_snapshot().gapless
                    && core.services.resolver.replaygain_mode() == resolver::ReplayGainMode::Album
                {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        });
        assert!(!core.playback_snapshot().gapless);
        assert_eq!(
            core.services.resolver.replaygain_mode(),
            resolver::ReplayGainMode::Album
        );
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    /// PLY-04：设置写入资料库、立即进入播放控制句柄，重启后还能读回来。
    #[test]
    fn equalizer_settings_persist_and_apply_immediately() -> Result<()> {
        let root = std::env::temp_dir().join(format!("lekis-core-eq-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let saved = EqualizerSettings {
            enabled: true,
            preamp_db: 99.0,
            bands_db: vec![-99.0, 99.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            preset: Some("sennheiser-hd-600".into()),
        };
        {
            let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            rt.block_on(async {
                // 等启动任务读完全部设置，避免和测试写入互相覆盖。
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                core.set_equalizer(saved.clone()).await?;
                let loaded = core.equalizer().await?;
                assert!(loaded.enabled);
                assert_eq!(loaded.preamp_db, 12.0);
                assert_eq!(loaded.bands_db.len(), 10);
                assert_eq!(loaded.bands_db[0], -12.0);
                assert_eq!(loaded.bands_db[1], 12.0);
                assert_eq!(loaded.bands_db[2], 3.0);
                assert_eq!(loaded.bands_db[9], 0.0);
                assert_eq!(loaded.preset.as_deref(), Some("sennheiser-hd-600"));

                // 共享控制句柄必须已经收到新参数（不需要重启播放会话）。
                let live = core.services.eq.settings();
                assert!(live.enabled);
                assert_eq!(live.preamp_db, 12.0);
                assert_eq!(live.bands_db, loaded.to_playback().bands_db);
                Ok::<_, LekisError>(())
            })?;
        }
        let core = LekisCore::new(CoreConfig::for_tests(&root), PlatformServices::in_memory())?;
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let loaded = rt.block_on(async {
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            core.equalizer().await
        })?;
        assert!(loaded.enabled);
        assert_eq!(loaded.bands_db[2], 3.0);
        assert_eq!(core.services.eq.settings().bands_db[2], 3.0);
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    /// 起一个只会回一张 PNG 的本地 HTTP 服务。
    async fn serve_png(png: Vec<u8>) -> Result<String> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let body = png.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let _ = sock.read(&mut buf).await;
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    let _ = sock.write_all(&body).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        Ok(format!("http://{addr}/cover.png"))
    }

    /// OFF-01/02 端到端（本地源，不走网络）：入队 → 分块拷贝 → 原子落盘 → 统计 → 删除。
    #[test]
    fn offline_download_copies_local_track_and_removes_it() -> Result<()> {
        let (core, root, _source, events, rt) =
            core_with_local_tracks("offline-download", &["01. Tone.wav"])?;
        rt.block_on(async {
            let track = core
                .list_tracks(TrackQuery {
                    sort: TrackSort::Title,
                    offset: 0,
                    limit: 10,
                })
                .await?
                .remove(0);
            core.download_track(track.id).await?;
            let mut row = None;
            for _ in 0..300 {
                if let Some(current) = core.offline_status(track.id).await? {
                    if current.state == OfflineState::Ready || current.state == OfflineState::Failed
                    {
                        row = Some(current);
                        break;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            let row = row.expect("download should finish");
            assert_eq!(row.state, OfflineState::Ready, "error: {:?}", row.error);
            let source_bytes = std::fs::read(root.join("music/01. Tone.wav"))?;
            let cached = std::fs::read(&row.cache_path)?;
            assert_eq!(cached, source_bytes, "缓存文件必须和源逐字节一致");
            assert_eq!(row.bytes, source_bytes.len() as u64);
            let stats = core.offline_stats().await?;
            assert_eq!(stats.count, 1);
            assert_eq!(stats.bytes, source_bytes.len() as u64);

            core.remove_download(track.id).await?;
            assert!(core.offline_status(track.id).await?.is_none());
            assert!(!std::path::Path::new(&row.cache_path).exists());
            Ok::<_, LekisError>(())
        })?;
        let seen = seen(&events);
        assert!(seen.iter().any(|e| matches!(
            e,
            CoreEvent::OfflineChanged {
                state: OfflineState::Ready,
                ..
            }
        )));
        assert!(seen
            .iter()
            .any(|e| matches!(e, CoreEvent::OfflineProgress { .. })));
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn accepting_an_artwork_candidate_applies_it() -> Result<()> {
        let (core, root, _source, events, rt) =
            core_with_local_tracks("artwork", &["01. Cover Me.flac"])?;
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            600,
            600,
            image::Rgb([20, 90, 200]),
        ))
        .write_to(&mut png, image::ImageFormat::Png)
        .map_err(|e| LekisError::internal(e.to_string()))?;
        let png = png.into_inner();

        rt.block_on(async {
            let url = serve_png(png).await?;
            let track = core
                .list_tracks(TrackQuery {
                    sort: TrackSort::Title,
                    offset: 0,
                    limit: 10,
                })
                .await?
                .remove(0);
            let full = core.get_track(track.id).await?;
            core.services
                .library
                .insert_enrich_candidates(vec![lekis_library::NewEnrichCandidate {
                    track_id: Some(track.id),
                    album_id: full.album_id,
                    kind: "artwork".into(),
                    payload_json: serde_json::json!({ "url": url, "width": 600, "height": 600 })
                        .to_string(),
                    source: "itunes".into(),
                    score: 0.7,
                }])
                .await?;
            let candidate = core.pending_candidates(10).await?.remove(0);
            core.accept_candidate(candidate.id).await?;

            let art = core
                .artwork(track.id)
                .await?
                .ok_or_else(|| LekisError::internal("artwork must be set"))?;
            assert_eq!(art.width, Some(600));
            for w in [128, 256, 512, 1024] {
                let path = core.artwork_path(art.hash.clone(), w);
                assert!(std::path::Path::new(&path).exists(), "tier {w} missing");
            }
            if let Some(album_id) = full.album_id {
                let album = core.get_album(album_id).await?;
                assert_eq!(album.artwork_hash.as_deref(), Some(art.hash.as_str()));
                let album_art = core.album_artwork(album_id).await?;
                assert_eq!(album_art.map(|a| a.hash), Some(art.hash.clone()));
            }
            assert_eq!(core.pending_candidate_count().await?, 0);
            Ok::<_, LekisError>(())
        })?;
        assert!(seen(&events).iter().any(|e| matches!(
            e,
            CoreEvent::LibraryChanged {
                scope: LibraryScope::Catalog
            }
        )));
        // 原始音频文件没被动过。
        assert_eq!(
            std::fs::read(root.join("music/01. Cover Me.flac"))?,
            b"not really audio"
        );
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }

    #[test]
    fn health_scan_marks_and_clears_unreadable_files() -> Result<()> {
        let (core, root, _source, _events, rt) =
            core_with_local_tracks("healthscan", &["01. Alpha.flac", "02. Beta.flac"])?;
        let missing = root.join("music/01. Alpha.flac");
        std::fs::remove_file(&missing)?;
        rt.block_on(async {
            let report = core.scan_library_health().await?;
            assert_eq!(report.sources, 1);
            assert_eq!(report.files_checked, 2);
            assert_eq!(report.unreadable, 1);
            assert_eq!(report.failed_sources, 0);
            assert_eq!(core.library_health_summary().await?.unreadable_files, 1);
            let page = core
                .library_health_page(HealthIssueKind::Unreadable, 0, 10)
                .await?;
            assert_eq!(page.len(), 1);
            assert_eq!(page[0].path, "01. Alpha.flac");
            assert!(page[0].detail.is_some());

            // 文件回来后重新扫描，错误状态要被清掉。
            std::fs::write(&missing, b"x")?;
            let report = core.scan_library_health().await?;
            assert_eq!(report.unreadable, 0);
            assert_eq!(report.cleared, 1);
            assert_eq!(core.library_health_summary().await?.unreadable_files, 0);
            Ok::<_, LekisError>(())
        })?;
        drop(core);
        let _ = std::fs::remove_dir_all(&root);
        Ok(())
    }
}

/// 保存音源前把关：地址里不能带密码一类的秘密（会原样进 `library.sqlite`）。
/// 界面总是把秘密放进凭据库；这里防的是手填 / 粘贴的地址。
fn reject_inline_secrets(config: &SourceConfig) -> Result<()> {
    if config
        .addresses
        .iter()
        .any(|a| lekis_vfs::address_has_secret(a))
    {
        return Err(LekisError::invalid(
            "密码 / 私钥密码不能写在地址里，请填到对应的密码栏（会加密保存）",
        ));
    }
    Ok(())
}
