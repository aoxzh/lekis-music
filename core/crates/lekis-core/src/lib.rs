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
pub mod events;
pub mod platform;
mod resolver;

pub use config::{CoreConfig, PlatformKind};
pub use events::EventListener;
pub use lekis_playback::PlaybackSnapshot;
pub use platform::{CredentialStore, MemoryCredentialStore, PlatformServices};

use events::EventBus;
use lekis_library::Library;
use lekis_playback::{EngineCommand, PlaybackEngine};
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

        // 播放引擎和后台任务都要在运行时上下文里创建。
        let _guard = handle.enter();
        let (resolve_tx, resolve_rx) = tokio::sync::mpsc::channel(16);
        let engine = PlaybackEngine::spawn(resolve_tx);
        handle.spawn(resolver::run(library.clone(), resolve_rx));
        handle.spawn(events::forward_playback(engine.subscribe(), events.clone()));

        Ok(Arc::new(Services {
            config,
            device_id,
            library,
            scanner,
            engine,
            events,
            platform,
        }))
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
            // TODO(SRC-04~06)：服务器源走 lekis-providers 的同步流程。
            return Err(LekisError::not_implemented(
                "sync from media server sources",
            ));
        }
        let password = source
            .credential_ref
            .as_deref()
            .and_then(|r| s.platform.credentials.get(r));
        let vfs = lekis_vfs::open(&source, password)?;
        self.handle.spawn(async move {
            let events = s.events.clone();
            let progress: lekis_scanner::ProgressFn = Arc::new(move |e| events.emit(e));
            match s.scanner.scan(source_id, vfs, progress).await {
                Ok(report) => {
                    tracing::info!(target: "core", %source_id, ?report, "scan finished");
                    s.events.emit(CoreEvent::LibraryChanged {
                        scope: LibraryScope::Catalog,
                    });
                }
                Err(e) => tracing::warn!(target: "core", %source_id, error = %e, "scan failed"),
            }
        });
        Ok(())
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

    /// 收藏 / 取消收藏。
    pub async fn set_loved(&self, id: TrackId, loved: bool) -> Result<()> {
        let s = self.services.clone();
        self.run(async move {
            let track = s.library.get_track(id).await?;
            s.library.set_loved(track.uid, loved).await?;
            // TODO(SYN-01)：生成 SyncOp 写入 sync_outbox。
            s.events.emit(CoreEvent::LibraryChanged {
                scope: LibraryScope::UserState,
            });
            Ok(())
        })
        .await
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

    /// 当前播放状态（UI 首次显示时用；之后靠事件更新）。
    pub fn playback_snapshot(&self) -> PlaybackSnapshot {
        self.services.engine.snapshot()
    }
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
