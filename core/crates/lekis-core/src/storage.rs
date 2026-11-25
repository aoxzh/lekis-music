//! 存储管理（OFF-04）：按类别统计空间占用并支持一键清理。
//!
//! 分类（参考 Finamp 存储管理页设计）：
//! - **封面与图片缓存**（`<cache_dir>/artwork`）：可随时清理，浏览时按需重新生成；
//! - **流媒体播放缓存**（`<cache_dir>/stream_cache` + `stream_cache` 表）：NAS / 服务器播放自动缓存；
//! - **离线下载**（`<data_dir>/offline` + `offline_download` 表）：用户手动下载的离线曲目；
//! - **其他缓存**（`<cache_dir>` 下其余临时文件）；
//! - **资料库数据库**（`<data_dir>/library.sqlite*`）：只读展示占用，不随清缓存删除。

use crate::{LekisCore, Services};
use lekis_types::Result;
use std::path::Path;

/// 按类别汇总的存储空间占用。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StorageUsage {
    /// 封面与艺人头像磁盘缓存占用（字节）。
    pub artwork_bytes: u64,
    /// 封面与艺人头像磁盘缓存文件数。
    pub artwork_count: u64,
    /// NAS / 远端流媒体播放缓存占用（字节）。
    pub stream_cache_bytes: u64,
    /// 流媒体播放缓存曲目数。
    pub stream_cache_count: u64,
    /// 流媒体播放缓存上限（MB，0 = 关闭）。
    pub stream_cache_limit_mb: u64,
    /// 离线下载占用（字节）。
    pub offline_bytes: u64,
    /// 离线下载已就绪曲目数。
    pub offline_count: u64,
    /// 资料库数据库文件占用（字节，含 WAL / SHM）。
    pub database_bytes: u64,
    /// 缓存目录下其余临时文件占用（字节）。
    pub other_cache_bytes: u64,
    /// 总占用（字节）。
    pub total_bytes: u64,
}

/// 可执行清理的存储类别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageCategory {
    /// 封面与艺人头像磁盘缓存。
    Artwork,
    /// NAS / 远端流媒体播放缓存。
    StreamCache,
    /// 用户主动下载的离线曲目。
    OfflineDownloads,
    /// 其余临时缓存文件。
    OtherCache,
    /// 全部缓存（封面 + 流媒体播放缓存 + 其他临时缓存；保留离线下载与数据库）。
    AllCaches,
}

/// 递归统计一个目录里的文件总字节数与文件数。
fn dir_usage(path: &Path) -> (u64, u64) {
    let Ok(rd) = std::fs::read_dir(path) else {
        return (0, 0);
    };
    let mut bytes = 0u64;
    let mut count = 0u64;
    for entry in rd.flatten() {
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.is_dir() {
            let (b, c) = dir_usage(&entry.path());
            bytes = bytes.saturating_add(b);
            count = count.saturating_add(c);
        } else if meta.is_file() {
            bytes = bytes.saturating_add(meta.len());
            count = count.saturating_add(1);
        }
    }
    (bytes, count)
}

/// 删除一个目录下的所有内容（保留目录本身），返回释放的字节数。
fn clear_dir_contents(path: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(path) else {
        return 0;
    };
    let mut freed = 0u64;
    for entry in rd.flatten() {
        let p = entry.path();
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.is_dir() {
            let (b, _) = dir_usage(&p);
            if std::fs::remove_dir_all(&p).is_ok() {
                freed = freed.saturating_add(b);
            }
        } else if meta.is_file() && std::fs::remove_file(&p).is_ok() {
            freed = freed.saturating_add(meta.len());
        }
    }
    freed
}

fn database_bytes(data_dir: &Path) -> u64 {
    let mut total = 0u64;
    for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
        if let Ok(meta) = std::fs::metadata(data_dir.join(name)) {
            total = total.saturating_add(meta.len());
        }
    }
    total
}

fn other_cache_usage(cache_dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(cache_dir) else {
        return 0;
    };
    let mut bytes = 0u64;
    for entry in rd.flatten() {
        let name = entry.file_name();
        if name == "artwork" || name == "stream_cache" {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.is_dir() {
            let (b, _) = dir_usage(&entry.path());
            bytes = bytes.saturating_add(b);
        } else if meta.is_file() {
            bytes = bytes.saturating_add(meta.len());
        }
    }
    bytes
}

fn clear_other_cache(cache_dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(cache_dir) else {
        return 0;
    };
    let mut freed = 0u64;
    for entry in rd.flatten() {
        let name = entry.file_name();
        if name == "artwork" || name == "stream_cache" {
            continue;
        }
        let p = entry.path();
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if meta.is_dir() {
            let (b, _) = dir_usage(&p);
            if std::fs::remove_dir_all(&p).is_ok() {
                freed = freed.saturating_add(b);
            }
        } else if meta.is_file() && std::fs::remove_file(&p).is_ok() {
            freed = freed.saturating_add(meta.len());
        }
    }
    freed
}

async fn compute_usage(s: &Services) -> Result<StorageUsage> {
    let cache_dir = s.config.cache_dir.clone();
    let data_dir = s.config.data_dir.clone();
    let stream_limit_mb = s.stream_cache.limit_mb();
    let stream_stats = s.library.stream_cache_stats().await.unwrap_or_default();
    let offline_stats = s.library.offline_stats().await.unwrap_or_default();

    let (artwork_bytes, artwork_count, offline_disk, stream_disk, db_bytes, other_bytes) =
        tokio::task::spawn_blocking(move || {
            let (art_b, art_c) = dir_usage(&cache_dir.join("artwork"));
            let (off_b, _) = dir_usage(&data_dir.join("offline"));
            let (sc_b, _) = dir_usage(&cache_dir.join("stream_cache"));
            let db_b = database_bytes(&data_dir);
            let other_b = other_cache_usage(&cache_dir);
            (art_b, art_c, off_b, sc_b, db_b, other_b)
        })
        .await
        .map_err(|e| lekis_types::LekisError::internal(format!("storage scan: {e}")))?;

    let stream_cache_bytes = stream_disk.max(stream_stats.bytes);
    let offline_bytes = offline_disk.max(offline_stats.bytes);
    let total_bytes = artwork_bytes
        .saturating_add(stream_cache_bytes)
        .saturating_add(offline_bytes)
        .saturating_add(db_bytes)
        .saturating_add(other_bytes);

    Ok(StorageUsage {
        artwork_bytes,
        artwork_count,
        stream_cache_bytes,
        stream_cache_count: stream_stats.count,
        stream_cache_limit_mb: stream_limit_mb,
        offline_bytes,
        offline_count: offline_stats.count,
        database_bytes: db_bytes,
        other_cache_bytes: other_bytes,
        total_bytes,
    })
}

impl LekisCore {
    /// 获取按类别划分的磁盘存储占用汇总（OFF-04）。
    pub async fn storage_usage(&self) -> Result<StorageUsage> {
        let s = self.services.clone();
        self.run(async move { compute_usage(&s).await }).await
    }

    /// 清理指定类别的缓存 / 离线数据，返回释放的字节数（OFF-04）。
    pub async fn clear_storage(&self, category: StorageCategory) -> Result<u64> {
        let s = self.services.clone();
        self.run(async move {
            let mut freed = 0u64;
            match category {
                StorageCategory::Artwork => {
                    let dir = s.config.cache_dir.join("artwork");
                    freed = tokio::task::spawn_blocking(move || clear_dir_contents(&dir))
                        .await
                        .unwrap_or(0);
                }
                StorageCategory::StreamCache => {
                    freed = s.stream_cache.clear_all().await?;
                }
                StorageCategory::OfflineDownloads => {
                    let rows = s.library.offline_downloads().await?;
                    for row in rows {
                        freed = freed.saturating_add(row.bytes);
                        let _ = crate::offline::remove(&s, row.track_id).await;
                    }
                    let dir = s.config.data_dir.join("offline");
                    let extra = tokio::task::spawn_blocking(move || clear_dir_contents(&dir))
                        .await
                        .unwrap_or(0);
                    freed = freed.max(extra);
                }
                StorageCategory::OtherCache => {
                    let dir = s.config.cache_dir.clone();
                    freed = tokio::task::spawn_blocking(move || clear_other_cache(&dir))
                        .await
                        .unwrap_or(0);
                }
                StorageCategory::AllCaches => {
                    let art_dir = s.config.cache_dir.join("artwork");
                    let cache_dir = s.config.cache_dir.clone();
                    let sc = s.stream_cache.clear_all().await?;
                    let (art, other) = tokio::task::spawn_blocking(move || {
                        (clear_dir_contents(&art_dir), clear_other_cache(&cache_dir))
                    })
                    .await
                    .unwrap_or((0, 0));
                    freed = sc.saturating_add(art).saturating_add(other);
                }
            }
            tracing::info!(target: "core::storage", ?category, freed, "storage cleared");
            Ok(freed)
        })
        .await
    }
}
