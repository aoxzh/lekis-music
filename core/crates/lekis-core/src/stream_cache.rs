//! NAS / 远端流媒体播放缓存管理（OFF-03）。
//!
//! - 缓存目录：`<cache_dir>/stream_cache/`；
//! - 默认上限：2048 MB（2 GiB），由设置项 `cache.stream_limit_mb` 控制（`0` = 关闭自动缓存）；
//! - 播放远端曲目（SMB / WebDAV / NFS / SFTP / OpenSubsonic / Jellyfin / Emby / Plex）时，
//!   如果尚未缓存且处于上限内，在后台把完整音频文件原子写入缓存并按 LRU 裁剪；
//! - 再次播放或断网 / NAS 不可达时，选源层优先命中本机缓存，无需重新拉取。

use lekis_library::Library;
use lekis_playback::{MediaLocation, MediaSource};
use lekis_types::{ErrorCode, LekisError, Result, SourceId, SourceKind, TrackId};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::AsyncWriteExt;

/// 默认流媒体播放缓存上限（MB）：2 GiB。
pub const DEFAULT_STREAM_CACHE_LIMIT_MB: u64 = 2048;

/// 单文件最大允许进入自动流媒体缓存的大小（512 MiB，避免整张超大 DSD/WAV 镜像一次吃光配额）。
const MAX_SINGLE_CACHED_FILE_BYTES: u64 = 512 * 1024 * 1024;

/// 每次读取 / 写入的块大小。
const CHUNK: u64 = 512 * 1024;

/// 流媒体播放缓存管理器。
pub(crate) struct StreamCacheManager {
    library: Library,
    dir: PathBuf,
    limit_mb: AtomicU64,
    in_flight: Mutex<HashSet<TrackId>>,
}

impl StreamCacheManager {
    pub(crate) fn new(library: Library, cache_dir: &Path) -> Self {
        Self {
            library,
            dir: cache_dir.join("stream_cache"),
            limit_mb: AtomicU64::new(DEFAULT_STREAM_CACHE_LIMIT_MB),
            in_flight: Mutex::new(HashSet::new()),
        }
    }

    pub(crate) fn limit_mb(&self) -> u64 {
        self.limit_mb.load(Ordering::Acquire)
    }

    pub(crate) fn limit_bytes(&self) -> u64 {
        self.limit_mb().saturating_mul(1024 * 1024)
    }

    /// 更新缓存上限（MB），并异步执行一次 LRU 裁剪。
    pub(crate) fn set_limit_mb(self: &Arc<Self>, mb: u64) {
        self.limit_mb.store(mb, Ordering::Release);
        let mgr = self.clone();
        tokio::spawn(async move {
            let _ = mgr.evict_if_needed(None).await;
        });
    }

    /// 查询该曲目是否有可用的本机流媒体缓存；若磁盘文件存在则刷新 LRU 并返回路径。
    pub(crate) async fn lookup_ready(&self, track_id: TrackId) -> Option<String> {
        let entry = self.library.stream_cache_get(track_id).await.ok()??;
        if Path::new(&entry.cache_path).is_file() {
            let _ = self.library.stream_cache_touch(track_id).await;
            return Some(entry.cache_path);
        }
        // 磁盘文件被系统清理掉了：顺手清掉失效数据库记录。
        let _ = self.library.stream_cache_remove(track_id).await;
        None
    }

    /// 启动后台任务缓存刚解析出的远端曲目（幂等去重、不阻塞播放启动）。
    pub(crate) fn schedule_cache(
        self: &Arc<Self>,
        track_id: TrackId,
        source_id: SourceId,
        source_kind: SourceKind,
        media: MediaSource,
    ) {
        if self.limit_bytes() == 0 {
            return;
        }
        // 仅缓存可有限读取的远端音频（NAS / 媒体服务器），不缓存本机文件或无限电台流。
        if !matches!(
            source_kind,
            SourceKind::Smb
                | SourceKind::WebDav
                | SourceKind::Nfs
                | SourceKind::Sftp
                | SourceKind::OpenSubsonic
                | SourceKind::Jellyfin
                | SourceKind::Emby
                | SourceKind::Plex
        ) {
            return;
        }
        if matches!(media.location, MediaLocation::CachedFile { .. }) {
            return;
        }
        {
            let Ok(mut set) = self.in_flight.lock() else {
                return;
            };
            if !set.insert(track_id) {
                return;
            }
        }
        let mgr = self.clone();
        tokio::spawn(async move {
            let res = mgr.cache_now(track_id, source_id, &media).await;
            if let Err(e) = res {
                tracing::debug!(
                    target: "core::stream_cache",
                    %track_id,
                    error = %e,
                    "background stream cache skipped"
                );
            }
            if let Ok(mut set) = mgr.in_flight.lock() {
                set.remove(&track_id);
            }
        });
    }

    async fn cache_now(
        &self,
        track_id: TrackId,
        source_id: SourceId,
        media: &MediaSource,
    ) -> Result<()> {
        let limit = self.limit_bytes();
        if limit == 0 {
            return Ok(());
        }
        // 已缓存且文件存在则跳过。
        if let Some(existing) = self.library.stream_cache_get(track_id).await? {
            if Path::new(&existing.cache_path).is_file() {
                let _ = self.library.stream_cache_touch(track_id).await;
                return Ok(());
            }
        }
        tokio::fs::create_dir_all(&self.dir)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("create stream cache dir: {e}")))?;

        let ext = guess_ext(&media.location);
        let final_path = self.dir.join(format!("{}.{ext}", track_id.0));
        let part_path = self.dir.join(format!(
            "{}.{}.{}.part",
            track_id.0,
            std::process::id(),
            lekis_types::now_ms()
        ));

        let max_bytes = limit.min(MAX_SINGLE_CACHED_FILE_BYTES);
        let written = match &media.location {
            MediaLocation::Vfs {
                source_id: vfs_sid,
                path,
            } => {
                let Some(vfs) = lekis_playback::vfs_access::resolve(*vfs_sid) else {
                    return Ok(());
                };
                let Some(vpath) = lekis_vfs::VfsPath::parse(path) else {
                    return Ok(());
                };
                if let Ok(meta) = vfs.stat(&vpath).await {
                    if meta.size > max_bytes || meta.size == 0 {
                        return Ok(());
                    }
                }
                copy_vfs_to_part(&vfs, &vpath, &part_path, max_bytes).await
            }
            MediaLocation::Url { url, headers } => {
                copy_http_to_part(url, headers, &part_path, max_bytes).await
            }
            MediaLocation::CachedFile { .. } => return Ok(()),
        };

        let bytes = match written {
            Ok(n) if n > 0 => n,
            Ok(_) => {
                let _ = tokio::fs::remove_file(&part_path).await;
                return Ok(());
            }
            Err(e) => {
                let _ = tokio::fs::remove_file(&part_path).await;
                return Err(e);
            }
        };

        let _ = tokio::fs::remove_file(&final_path).await;
        tokio::fs::rename(&part_path, &final_path)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("rename stream cache: {e}")))?;

        self.library
            .stream_cache_upsert(
                track_id,
                source_id,
                final_path.to_string_lossy().into_owned(),
                bytes,
            )
            .await?;
        self.evict_if_needed(Some(track_id)).await?;
        tracing::debug!(
            target: "core::stream_cache",
            %track_id,
            bytes,
            "cached remote stream for offline playback"
        );
        Ok(())
    }

    /// 执行 LRU 淘汰并删除磁盘文件。
    pub(crate) async fn evict_if_needed(&self, protect: Option<TrackId>) -> Result<u64> {
        let limit = self.limit_bytes();
        let evicted = self.library.stream_cache_evict_to(limit, protect).await?;
        let mut freed = 0u64;
        for entry in evicted {
            freed += entry.bytes;
            let _ = tokio::fs::remove_file(&entry.cache_path).await;
        }
        Ok(freed)
    }

    /// 清空全部流媒体播放缓存（数据库 + 磁盘）。
    pub(crate) async fn clear_all(&self) -> Result<u64> {
        let entries = self.library.stream_cache_clear().await?;
        let mut freed = 0u64;
        for entry in entries {
            freed += entry.bytes;
            let _ = tokio::fs::remove_file(&entry.cache_path).await;
        }
        // 顺手清理目录里可能残留的孤立文件 / .part 临时文件。
        if let Ok(mut rd) = tokio::fs::read_dir(&self.dir).await {
            while let Ok(Some(item)) = rd.next_entry().await {
                if let Ok(meta) = item.metadata().await {
                    if meta.is_file() {
                        let _ = tokio::fs::remove_file(item.path()).await;
                    }
                }
            }
        }
        Ok(freed)
    }
}

async fn copy_vfs_to_part(
    vfs: &Arc<dyn lekis_vfs::Vfs>,
    path: &lekis_vfs::VfsPath,
    part_path: &Path,
    max_bytes: u64,
) -> Result<u64> {
    let mut file = tokio::fs::File::create(part_path)
        .await
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("create stream cache part: {e}")))?;
    let mut offset = 0u64;
    loop {
        let chunk = vfs.read_range(path, offset..offset + CHUNK).await?;
        if chunk.is_empty() {
            break;
        }
        offset += chunk.len() as u64;
        if offset > max_bytes {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "track exceeds stream cache limit",
            ));
        }
        file.write_all(&chunk)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("write stream cache: {e}")))?;
        if (chunk.len() as u64) < CHUNK {
            break;
        }
    }
    file.flush()
        .await
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("flush stream cache: {e}")))?;
    Ok(offset)
}

async fn copy_http_to_part(
    url: &str,
    headers: &[(String, String)],
    part_path: &Path,
    max_bytes: u64,
) -> Result<u64> {
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .read_timeout(std::time::Duration::from_secs(45))
        .build()
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("http client: {e}")))?;
    let mut req = client.get(url).header("Accept-Encoding", "identity");
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let mut resp = req
        .send()
        .await
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("stream cache http: {e}")))?;
    if !resp.status().is_success() {
        return Err(LekisError::new(
            ErrorCode::Network,
            format!("stream cache HTTP {}", resp.status()),
        ));
    }
    if let Some(len) = resp.content_length() {
        if len > max_bytes {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "remote file exceeds stream cache limit",
            ));
        }
    }
    let mut file = tokio::fs::File::create(part_path)
        .await
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("create stream cache part: {e}")))?;
    let mut total = 0u64;
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("stream cache chunk: {e}")))?
    {
        total += chunk.len() as u64;
        if total > max_bytes {
            return Err(LekisError::new(
                ErrorCode::Unsupported,
                "remote file exceeds stream cache limit",
            ));
        }
        file.write_all(&chunk)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("write stream cache: {e}")))?;
    }
    file.flush()
        .await
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("flush stream cache: {e}")))?;
    Ok(total)
}

fn guess_ext(loc: &MediaLocation) -> String {
    let raw = match loc {
        MediaLocation::Vfs { path, .. } => path.as_str(),
        MediaLocation::Url { url, .. } => url.split(['?', '#']).next().unwrap_or(url),
        MediaLocation::CachedFile { path } => path.as_str(),
    };
    Path::new(raw)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .filter(|e| !e.is_empty() && e.len() <= 8 && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or_else(|| "bin".to_string())
}
