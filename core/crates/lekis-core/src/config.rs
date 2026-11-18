//! 核心配置。

use lekis_types::{DeviceId, Result};
use std::path::{Path, PathBuf};

/// 运行平台（影响默认策略：后台任务、并发数、可用的输出后端）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlatformKind {
    /// Android。
    Android,
    /// Windows。
    Windows,
    /// Linux 桌面。
    Linux,
    /// headless NAS 节点。
    Node,
}

/// 核心配置。由平台层在启动时提供。
#[derive(Debug, Clone)]
pub struct CoreConfig {
    /// 应用数据目录（数据库、离线下载、插件）。不能被系统自动清理。
    pub data_dir: PathBuf,
    /// 缓存目录（缩略图、播放缓存）。可以被清理。
    pub cache_dir: PathBuf,
    /// 设备名称（显示在其他设备的同步列表里）。
    pub device_name: String,
    /// 平台。
    pub platform: PlatformKind,
    /// tokio 工作线程数，默认 4。
    pub worker_threads: Option<usize>,
}

impl CoreConfig {
    /// 测试用配置：所有目录都放在 `root` 下面。
    pub fn for_tests(root: &Path) -> Self {
        Self {
            data_dir: root.join("data"),
            cache_dir: root.join("cache"),
            device_name: "test".into(),
            platform: PlatformKind::Linux,
            worker_threads: Some(2),
        }
    }
}

/// 读取设备 ID；第一次启动时生成并保存。
pub(crate) fn load_or_create_device_id(data_dir: &Path) -> Result<DeviceId> {
    let path = data_dir.join("device_id");
    match std::fs::read_to_string(&path) {
        Ok(s) if !s.trim().is_empty() => Ok(DeviceId(s.trim().to_string())),
        _ => {
            let id = DeviceId::generate();
            std::fs::write(&path, &id.0)?;
            Ok(id)
        }
    }
}
