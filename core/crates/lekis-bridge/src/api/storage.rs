//! 存储管理（OFF-04）与统一资料库自动合并（SRC-13）桥接 API。

use crate::api::error::CoreError;
use crate::internal::core;

/// 按类别划分的存储空间占用汇总。
#[derive(Debug, Clone)]
pub struct StorageUsageDto {
    /// 封面与艺人头像磁盘缓存（字节）。
    pub artwork_bytes: u64,
    /// 封面缓存文件数。
    pub artwork_count: u64,
    /// NAS / 远端流媒体播放缓存（字节）。
    pub stream_cache_bytes: u64,
    /// 流媒体播放缓存曲目数。
    pub stream_cache_count: u64,
    /// 流媒体播放缓存上限（MB，0 = 关闭）。
    pub stream_cache_limit_mb: u64,
    /// 离线下载占用（字节）。
    pub offline_bytes: u64,
    /// 离线下载曲目数。
    pub offline_count: u64,
    /// 资料库数据库占用（字节）。
    pub database_bytes: u64,
    /// 其他临时缓存占用（字节）。
    pub other_cache_bytes: u64,
    /// 总占用（字节）。
    pub total_bytes: u64,
}

impl From<lekis_core::StorageUsage> for StorageUsageDto {
    fn from(u: lekis_core::StorageUsage) -> Self {
        Self {
            artwork_bytes: u.artwork_bytes,
            artwork_count: u.artwork_count,
            stream_cache_bytes: u.stream_cache_bytes,
            stream_cache_count: u.stream_cache_count,
            stream_cache_limit_mb: u.stream_cache_limit_mb,
            offline_bytes: u.offline_bytes,
            offline_count: u.offline_count,
            database_bytes: u.database_bytes,
            other_cache_bytes: u.other_cache_bytes,
            total_bytes: u.total_bytes,
        }
    }
}

/// 可清理的存储类别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageCategoryDto {
    /// 封面与艺人头像磁盘缓存。
    Artwork,
    /// 流媒体播放缓存。
    StreamCache,
    /// 离线下载。
    OfflineDownloads,
    /// 其他临时缓存。
    OtherCache,
    /// 全部缓存（保留离线下载与数据库）。
    AllCaches,
}

impl From<StorageCategoryDto> for lekis_core::StorageCategory {
    fn from(c: StorageCategoryDto) -> Self {
        match c {
            StorageCategoryDto::Artwork => Self::Artwork,
            StorageCategoryDto::StreamCache => Self::StreamCache,
            StorageCategoryDto::OfflineDownloads => Self::OfflineDownloads,
            StorageCategoryDto::OtherCache => Self::OtherCache,
            StorageCategoryDto::AllCaches => Self::AllCaches,
        }
    }
}

/// 统一资料库自动合并结果。
#[derive(Debug, Clone)]
pub struct UnifiedMergeReportDto {
    /// 本次合并的重复组数。
    pub merged_groups: u64,
    /// 本次吸收合并掉的冗余曲目条数。
    pub merged_tracks: u64,
    /// 本次新计算音频指纹的文件数。
    pub fingerprinted_files: u64,
}

impl From<lekis_core::UnifiedMergeReport> for UnifiedMergeReportDto {
    fn from(r: lekis_core::UnifiedMergeReport) -> Self {
        Self {
            merged_groups: r.merged_groups,
            merged_tracks: r.merged_tracks,
            fingerprinted_files: r.fingerprinted_files,
        }
    }
}

/// 查询按类别汇总的存储空间占用（OFF-04）。
pub async fn storage_usage() -> Result<StorageUsageDto, CoreError> {
    Ok(core().storage_usage().await?.into())
}

/// 清理指定类别的缓存 / 离线数据，返回释放的字节数（OFF-04）。
pub async fn clear_storage(category: StorageCategoryDto) -> Result<u64, CoreError> {
    Ok(core().clear_storage(category.into()).await?)
}

/// 手动触发统一资料库跨源自动合并（SRC-13），可选启用 Chromaprint 音频指纹比对。
pub async fn auto_merge_unified_library(
    use_fingerprints: bool,
) -> Result<UnifiedMergeReportDto, CoreError> {
    Ok(core()
        .auto_merge_unified_library(use_fingerprints)
        .await?
        .into())
}
