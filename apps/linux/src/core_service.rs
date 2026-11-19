//! 核心服务：准备 XDG 目录、持有唯一的 [`LekisCore`] 实例。
//!
//! `docs/ARCHITECTURE.md` 第 7 节要求平台 UI 层不写业务逻辑：这里只负责
//! “怎么把核心跑起来”，以及把核心返回的错误翻译成界面文案，不做任何缓存、
//! 索引或播放决策——那些都在 `lekis-core` 里。

use std::path::PathBuf;
use std::sync::Arc;

use lekis_core::{CoreConfig, LekisCore, PlatformKind, PlatformServices};
use lekis_types::{ErrorCode, LekisError, Result};

/// 核心版本号（界面展示用）。
///
/// TODO(SET-02)：等 `lekis-core` 暴露 `core_version()` 之后换成真实值。
pub const CORE_VERSION: &str = "0.1.0（core 工作区）";

/// 核心句柄：页面和播放器只通过它调 `lekis-core`。
///
/// 克隆只是 `Arc` 的引用计数加一，可以随便往闭包里搬。
#[derive(Clone)]
pub struct CoreHandle {
    /// 核心实例。
    core: Arc<LekisCore>,
    /// 数据目录（设置页展示）。
    data_dir: PathBuf,
    /// 缓存目录（设置页展示）。
    cache_dir: PathBuf,
}

impl CoreHandle {
    /// 按 XDG 目录启动核心。
    ///
    /// 失败时返回 `LekisError`，调用方（[`crate::main`]）负责显示错误窗口，
    /// 不能 panic——用户可能只是 HOME 不可写。
    pub fn start() -> Result<Self> {
        let data_dir = xdg_app_dir("XDG_DATA_HOME", ".local/share", "lekis-music");
        let cache_dir = xdg_app_dir("XDG_CACHE_HOME", ".cache", "lekis-music");
        // 核心自己只写 device_id 文件、不建目录，所以这里先建好。
        std::fs::create_dir_all(&data_dir)?;
        std::fs::create_dir_all(&cache_dir)?;

        let config = CoreConfig {
            data_dir: data_dir.clone(),
            cache_dir: cache_dir.clone(),
            device_name: device_name(),
            platform: PlatformKind::Linux,
            worker_threads: None,
        };
        // TODO(PTF-02)：Linux 桌面正式版用 libsecret 存凭据（`secret-tool` / `libsecret-1`），
        // 现在先用内存实现，重启后需要重新输入密码。
        let platform = PlatformServices::in_memory();
        let core = LekisCore::new(config, platform)?;
        Ok(Self {
            core: Arc::new(core),
            data_dir,
            cache_dir,
        })
    }

    /// 拿到 `Arc` 克隆，用于搬进异步任务。
    pub fn arc(&self) -> Arc<LekisCore> {
        Arc::clone(&self.core)
    }

    /// 数据目录。
    pub fn data_dir(&self) -> &std::path::Path {
        &self.data_dir
    }

    /// 缓存目录。
    pub fn cache_dir(&self) -> &std::path::Path {
        &self.cache_dir
    }

    /// 设备 ID（同步，来自核心）。
    pub fn device_id(&self) -> String {
        self.core.device_id().to_string()
    }
}

/// 取 `XDG_*_HOME/<app>`，没有环境变量时退回 `$HOME/<fallback>/<app>`。
fn xdg_app_dir(env_key: &str, fallback: &str, app: &str) -> PathBuf {
    if let Ok(base) = std::env::var(env_key) {
        if !base.is_empty() {
            return PathBuf::from(base).join(app);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(fallback).join(app)
}

/// 设备名，写进核心配置，同步冲突时用来区分来源。
fn device_name() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "linux-desktop".to_string())
}

/// 把声卡 / 目录之类的底层错误包成核心错误（界面只显示错误码对应的文案）。
#[allow(dead_code)]
pub fn io_error(context: &str, err: std::io::Error) -> LekisError {
    LekisError::new(ErrorCode::Io, format!("{context}: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// XDG 目录应该落在应用子目录里。
    #[test]
    fn xdg_dir_appends_app_name() {
        let dir = xdg_app_dir("LEKIS_TEST_XDG_UNSET", ".cache", "lekis-music");
        assert!(dir.ends_with("lekis-music"));
    }
}
