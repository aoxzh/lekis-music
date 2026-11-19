//! Lekis 核心门面。
//!
//! 平台层（通过 lekis-ffi）、Linux GTK 应用和 lekis-node 都只和 [`LekisCore`] 打交道。
//! 它负责：
//! - 拥有唯一的 tokio 运行时（或者借用宿主的运行时，见 [`LekisCore::with_runtime`]）；
//! - 组装资料库、扫描器、播放引擎、补全、同步、插件；
//! - 把领域层的结果转成 [`CoreEvent`] 推给监听者；
//! - 做跨领域的决策：选源、离线策略、自动补全的触发时机。
//!
//! 所有耗时的公开方法都是 `async`，并且内部总是在核心自己的运行时上执行，
//! 所以调用方用什么执行器（UniFFI 的 Kotlin 协程、C# Task）都可以。

pub mod config;
mod enrich;
pub mod events;
pub mod platform;
mod remote_scan;
mod resolver;
pub mod selection;
mod sync_engine;

pub use config::{CoreConfig, PlatformKind};
pub use enrich::EnrichReport;
pub use events::EventListener;
pub use lekis_playback::PlaybackSnapshot;
pub use platform::{CredentialStore, MemoryCredentialStore, PlatformServices};
pub use selection::{NetworkContext, Reachability, SourceHealth};
pub use sync_engine::SyncReport;

use events::EventBus;
use lekis_library::{EnrichCandidateRow, Library, LyricsRow, PlaylistEntry};
use lekis_playback::{EngineCommand, OutputDevice, OutputMode, PlaybackEngine};
use lekis_scanner::{tags::LoftyTagReader, Scanner};
use lekis_types::*;
use std::future::Future;
use std::sync::Arc;
use tokio::runtime::{Handle, Runtime};

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
}

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
        std::fs::create_dir_all(&config.data_dir)?;
        std::fs::create_dir_all(&config.cache_dir)?;
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
        let engine = PlaybackEngine::spawn(resolve_tx);
        let resolver = Arc::new(resolver::Resolver::new(
            library.clone(),
            health.clone(),
            platform.credentials.clone(),
        ));
        handle.spawn(resolver.run(resolve_rx));
        handle.spawn(events::forward_playback(engine.subscribe(), events.clone()));

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
        });

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
            let id = s.library.add_source(config).await?;
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::Sources,
            });
            Ok(id)
        })
        .await
    }

    /// 列出音源。
    pub async fn list_sources(&self) -> Result<Vec<SourceConfig>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_sources().await })
            .await
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
            let server = self.server_for(&source)?;
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
                        s.health.record(source_id, Reachability::Unreachable);
                        s.events.emit(CoreEvent::SourceReachability {
                            source_id,
                            reachable: false,
                        });
                        tracing::warn!(target: "core", %source_id, error = %e, "media server sync failed");
                    }
                }
            });
            return Ok(());
        }

        let password = source
            .credential_ref
            .as_deref()
            .and_then(|r| s.platform.credentials.get(r));
        let vfs = lekis_vfs::open(&source, password)?;
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
                        match s.scanner.write_shared_index(source_id, vfs).await {
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
                }
                Err(e) => tracing::warn!(target: "core", %source_id, error = %e, "scan failed"),
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
    // 资料库查询
    // -----------------------------------------------------------------------

    /// 分页列出曲目。
    pub async fn list_tracks(&self, query: TrackQuery) -> Result<Vec<TrackRow>> {
        let s = self.services.clone();
        self.run(async move { s.library.list_track_rows(query).await })
            .await
    }

    /// 曲目详情。
    pub async fn get_track(&self, id: TrackId) -> Result<Track> {
        let s = self.services.clone();
        self.run(async move { s.library.get_track(id).await }).await
    }

    /// 搜索。
    pub async fn search(&self, text: String, limit: u32) -> Result<SearchResults> {
        let s = self.services.clone();
        self.run(async move { s.library.search(&text, limit.min(100)).await })
            .await
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
    pub async fn set_loved(&self, id: TrackId, loved: bool) -> Result<()> {
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
        let password = source
            .credential_ref
            .as_deref()
            .and_then(|r| s.platform.credentials.get(r));
        let vfs = lekis_vfs::open(&source, password)?;
        s.vfs_put(source_id, vfs.clone());
        self.sync_now(vfs).await
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
            enrich::apply_candidate(&s.library, &row).await?;
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
                    if enrich::apply_candidate(&s.library, row).await.is_ok() {
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
    pub async fn lyrics(&self, id: TrackId) -> Result<Option<Lyrics>> {
        let s = self.services.clone();
        self.run(async move { s.library.active_lyrics(id).await })
            .await
    }

    /// 这首歌所有可用歌词（按来源优先级排序，供用户切换）。
    pub async fn lyrics_versions(&self, id: TrackId) -> Result<Vec<LyricsRow>> {
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

    /// 曲目的生效封面（曲目级优先，回落专辑级）。
    pub async fn artwork(&self, id: TrackId) -> Result<Option<lekis_library::ArtworkRow>> {
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

    /// 记一次播放（DIS-06；scrobble 判定也用这条记录）。
    pub async fn record_play(&self, id: TrackId, ms_played: u64) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let track = s.library.get_track(id).await?;
            s.library
                .record_play(track.uid, s.device_id.0.clone(), ms_played, now_ms())
                .await
        })
        .await
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
        self.services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        Ok(())
    }
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
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
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
}
