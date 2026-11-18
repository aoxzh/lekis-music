//! UniFFI 导出层（ADR-0005）。
//!
//! 规则：
//! - 这里**只做类型转换**，不写业务逻辑；
//! - FFI 类型（`*Dto`）和领域类型分开定义，通过 `From` 转换，领域 crate 不知道 UniFFI 的存在；
//! - 改了这里的任何公开项，都要运行 `tools/gen-bindings.sh` 重新生成绑定，并同步修改 Android / Windows 的桥接层。
//!
//! 生成的绑定：Kotlin 包名 `uniffi.lekis_ffi`，C# 命名空间 `uniffi.lekis_ffi`。

mod dto;
mod error;

pub use dto::*;
pub use error::CoreError;

use std::sync::Arc;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// 平台实现的回调接口
// ---------------------------------------------------------------------------

/// 核心事件监听者。回调在核心线程上触发，平台要自己切回 UI 线程。
#[uniffi::export(callback_interface)]
pub trait CoreEventListener: Send + Sync {
    fn on_event(&self, event: CoreEventDto);
}

/// 凭据存储（系统钥匙串），由平台实现。
#[uniffi::export(callback_interface)]
pub trait CredentialStore: Send + Sync {
    fn get(&self, key: String) -> Option<String>;
    fn set(&self, key: String, secret: String) -> bool;
    fn delete(&self, key: String) -> bool;
}

struct ListenerAdapter(Box<dyn CoreEventListener>);

impl lekis_core::EventListener for ListenerAdapter {
    fn on_event(&self, event: lekis_types::CoreEvent) {
        self.0.on_event(event.into());
    }
}

struct CredentialAdapter(Box<dyn CredentialStore>);

impl lekis_core::CredentialStore for CredentialAdapter {
    fn get(&self, key: &str) -> Option<String> {
        self.0.get(key.to_string())
    }

    fn set(&self, key: &str, secret: &str) -> lekis_types::Result<()> {
        if self.0.set(key.to_string(), secret.to_string()) {
            Ok(())
        } else {
            Err(lekis_types::LekisError::new(
                lekis_types::ErrorCode::PermissionDenied,
                "platform credential store rejected the write",
            ))
        }
    }

    fn delete(&self, key: &str) -> lekis_types::Result<()> {
        self.0.delete(key.to_string());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 核心对象
// ---------------------------------------------------------------------------

/// 核心句柄。平台层在启动时创建一个，整个进程共用。
#[derive(uniffi::Object)]
pub struct LekisCore {
    inner: lekis_core::LekisCore,
}

#[uniffi::export]
impl LekisCore {
    /// 创建核心。会打开数据库并启动后台运行时，耗时几十毫秒，不要在 UI 线程上调用。
    #[uniffi::constructor]
    pub fn new(
        config: CoreConfigDto,
        credentials: Box<dyn CredentialStore>,
    ) -> Result<Arc<Self>, CoreError> {
        let platform = lekis_core::PlatformServices {
            credentials: Arc::new(CredentialAdapter(credentials)),
        };
        let inner = lekis_core::LekisCore::new(config.into(), platform)?;
        Ok(Arc::new(Self { inner }))
    }

    /// 本机设备 ID。
    pub fn device_id(&self) -> String {
        self.inner.device_id().0
    }

    /// 注册事件监听者。
    pub fn add_listener(&self, listener: Box<dyn CoreEventListener>) {
        self.inner.add_listener(Arc::new(ListenerAdapter(listener)));
    }

    // ---- 音源 ----

    pub async fn add_source(&self, source: SourceConfigDto) -> Result<i64, CoreError> {
        Ok(self.inner.add_source(source.into()).await?.0)
    }

    pub async fn list_sources(&self) -> Result<Vec<SourceConfigDto>, CoreError> {
        Ok(self
            .inner
            .list_sources()
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn start_scan(&self, source_id: i64) -> Result<(), CoreError> {
        Ok(self
            .inner
            .start_scan(lekis_types::SourceId(source_id))
            .await?)
    }

    // ---- 资料库 ----

    pub async fn list_tracks(
        &self,
        sort: TrackSortDto,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<TrackRowDto>, CoreError> {
        let q = lekis_types::TrackQuery {
            sort: sort.into(),
            offset,
            limit,
        };
        Ok(self
            .inner
            .list_tracks(q)
            .await?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_track(&self, track_id: i64) -> Result<TrackDto, CoreError> {
        Ok(self
            .inner
            .get_track(lekis_types::TrackId(track_id))
            .await?
            .into())
    }

    pub async fn search(&self, text: String, limit: u32) -> Result<SearchResultsDto, CoreError> {
        Ok(self.inner.search(text, limit).await?.into())
    }

    pub async fn set_loved(&self, track_id: i64, loved: bool) -> Result<(), CoreError> {
        Ok(self
            .inner
            .set_loved(lekis_types::TrackId(track_id), loved)
            .await?)
    }

    // ---- 播放（非阻塞）----

    pub fn play_tracks(&self, track_ids: Vec<i64>, start: u32) -> Result<(), CoreError> {
        let ids = track_ids.into_iter().map(lekis_types::TrackId).collect();
        Ok(self.inner.play_tracks(ids, start)?)
    }

    pub fn play(&self) -> Result<(), CoreError> {
        Ok(self.inner.play()?)
    }

    pub fn pause(&self) -> Result<(), CoreError> {
        Ok(self.inner.pause()?)
    }

    pub fn next(&self) -> Result<(), CoreError> {
        Ok(self.inner.next()?)
    }

    pub fn previous(&self) -> Result<(), CoreError> {
        Ok(self.inner.previous()?)
    }

    pub fn seek(&self, position_ms: u64) -> Result<(), CoreError> {
        Ok(self.inner.seek(position_ms)?)
    }

    pub fn set_repeat(&self, mode: RepeatModeDto) -> Result<(), CoreError> {
        Ok(self.inner.set_repeat(mode.into())?)
    }

    pub fn set_shuffle(&self, mode: ShuffleModeDto) -> Result<(), CoreError> {
        Ok(self.inner.set_shuffle(mode.into())?)
    }

    pub fn set_volume(&self, volume: f32) -> Result<(), CoreError> {
        Ok(self.inner.set_volume(volume)?)
    }

    pub fn playback_snapshot(&self) -> PlaybackSnapshotDto {
        self.inner.playback_snapshot().into()
    }
}

/// 初始化日志（平台层在创建核心之前调用一次）。
///
/// TODO：Android 输出到 logcat（android_logger），Windows 输出到文件（滚动日志 + 脱敏）。
#[uniffi::export]
pub fn init_logging(level: String) {
    tracing::info!(target: "ffi", %level, "logging requested (not wired yet)");
}

/// 核心库版本，用于"关于"页面和诊断信息。
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
