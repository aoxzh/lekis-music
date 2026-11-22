//! 离线下载（OFF-01/02/03/04 的第一版）。
//!
//! 缓存放在应用数据目录的 `offline/` 下，不放进 SQLite。下载统一走
//! [`lekis_playback::MediaSource`]：文件系统 / SMB / WebDAV 用 VFS Range 读取，
//! 服务器源（OpenSubsonic / Jellyfin / Plex）用解析出来的 HTTP 地址流式读取。
//!
//! 写入策略：先写唯一的 `.part` 临时文件，完整落盘后再改名成最终文件；中途失败 / 取消只删临时文件。
//! 进度通过 [`CoreEvent::OfflineProgress`] 推送，不阻塞播放线程。

use crate::events::EventBus;
use crate::Services;
use lekis_library::{Library, OfflineDownload, TrackFile};
use lekis_playback::{MediaLocation, MediaSource};
use lekis_types::{ErrorCode, LekisError, OfflineState, Result, SourceId, TrackId};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

/// 每次从源读取 / 写入的块大小。
const CHUNK: u64 = 512 * 1024;
/// 进度事件的最小间隔。
const EVENT_INTERVAL: Duration = Duration::from_millis(100);
/// 进度落库的最小间隔。
const DB_INTERVAL: Duration = Duration::from_millis(1_000);

/// 建一个下载任务（立即返回，真正的解析 / 拷贝在后台跑）。
pub(crate) async fn schedule(s: &Arc<Services>, track_id: TrackId) -> Result<()> {
    // 曲目必须存在；离线记录可以不存在（第一次下载）。
    let files = s.library.track_files(track_id).await?;
    if files
        .iter()
        .any(|f| f.source_kind == lekis_types::SourceKind::Local)
    {
        // 本机已经存在本地文件副本，无需重复下载到离线缓存。
        return Ok(());
    }
    let first = files
        .first()
        .ok_or_else(|| LekisError::not_found(format!("no playable file for track {track_id}")))?;
    if let Some(existing) = current_row(&s.library, track_id).await? {
        if existing.state == OfflineState::Ready && Path::new(&existing.cache_path).is_file() {
            return Ok(());
        }
        if existing.state == OfflineState::Downloading && active(s, track_id) {
            return Ok(());
        }
    }

    let token = Arc::new(AtomicBool::new(false));
    if let Ok(mut map) = s.downloads.lock() {
        if let Some(existing) = map.get(&track_id) {
            if !existing.load(Ordering::Relaxed) {
                return Ok(());
            }
        }
        map.insert(track_id, token.clone());
    }

    // 先落一条 queued 记录：解析源 / 连服务器失败时也能在下载页看到"失败 + 重试"，
    // 而不是什么状态都没有。
    let placeholder = s
        .config
        .data_dir
        .join("offline")
        .join(format!("{}.bin", track_id.0));
    if let Err(e) = s
        .library
        .upsert_offline_queued(
            track_id,
            first.source_id,
            placeholder.to_string_lossy().into_owned(),
            0,
        )
        .await
    {
        if let Ok(mut map) = s.downloads.lock() {
            if map.get(&track_id).is_some_and(|t| Arc::ptr_eq(t, &token)) {
                map.remove(&track_id);
            }
        }
        return Err(e);
    }
    s.events.emit(lekis_types::CoreEvent::OfflineChanged {
        track_id,
        state: OfflineState::Queued,
        error: None,
    });

    let services = s.clone();
    tokio::spawn(async move {
        let result = run_download(services.clone(), track_id, token.clone()).await;
        if let Err(e) = &result {
            if !token.load(Ordering::Relaxed) {
                tracing::warn!(target: "core::offline", %track_id, error = %e, "offline download failed");
            }
        }
        // 只有还是当前任务时才清理，避免覆盖用户刚发起的新下载。
        if let Ok(mut map) = services.downloads.lock() {
            if map.get(&track_id).is_some_and(|t| Arc::ptr_eq(t, &token)) {
                map.remove(&track_id);
            }
        }
    });
    Ok(())
}

fn active(s: &Arc<Services>, track_id: TrackId) -> bool {
    s.downloads
        .lock()
        .ok()
        .and_then(|m| m.get(&track_id).map(|t| !t.load(Ordering::Relaxed)))
        .unwrap_or(false)
}

async fn current_row(library: &Library, track_id: TrackId) -> Result<Option<OfflineDownload>> {
    library.offline_download(track_id).await
}

/// 取消正在进行的下载（不删除记录；删除记录走 [`remove`]）。
pub(crate) fn cancel(s: &Services, track_id: TrackId) {
    if let Ok(map) = s.downloads.lock() {
        if let Some(token) = map.get(&track_id) {
            token.store(true, Ordering::Relaxed);
        }
    }
}

/// 删除一条下载：取消正在进行的任务、删记录、删最终文件和所有临时文件。
pub(crate) async fn remove(s: &Arc<Services>, track_id: TrackId) -> Result<()> {
    cancel(s, track_id);
    let removed = s.library.remove_offline_download(track_id).await?;
    let Some(row) = removed else {
        return Ok(());
    };
    remove_file_if_exists(Path::new(&row.cache_path)).await;
    remove_parts_for(&s.config.data_dir.join("offline"), track_id).await;
    s.events
        .emit(lekis_types::CoreEvent::OfflineRemoved { track_id });
    Ok(())
}

/// 启动时恢复：`downloading` → `queued`，并检查 `ready` 的缓存文件还在不在。
pub(crate) async fn recover(s: Arc<Services>) {
    match s.library.recover_stale_offline_downloads().await {
        Ok(n) if n > 0 => {
            tracing::info!(target: "core::offline", recovered = n, "stale offline downloads requeued");
        }
        Ok(_) => {}
        Err(e) => {
            tracing::warn!(target: "core::offline", error = %e, "cannot recover offline downloads")
        }
    }

    let rows = match s.library.offline_downloads().await {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!(target: "core::offline", error = %e, "cannot list offline downloads");
            return;
        }
    };
    for row in rows {
        if row.state == OfflineState::Ready && !Path::new(&row.cache_path).is_file() {
            tracing::warn!(
                target: "core::offline",
                track_id = %row.track_id,
                path = %row.cache_path,
                "offline cache file is missing"
            );
            if let Err(e) = s
                .library
                .mark_offline_failed(
                    row.track_id,
                    lekis_types::tr!(
                        "缓存文件已丢失，请重新下载",
                        "Cached file is missing, please download again"
                    ),
                )
                .await
            {
                tracing::warn!(target: "core::offline", error = %e, "cannot mark missing cache file");
            }
        }
    }
    // 上次进程异常退出留下的临时文件。
    remove_stale_parts(&s.config.data_dir.join("offline")).await;
}

async fn run_download(s: Arc<Services>, track_id: TrackId, cancel: Arc<AtomicBool>) -> Result<()> {
    let result = run_download_inner(s.clone(), track_id, cancel.clone()).await;
    if let Err(e) = &result {
        if cancel.load(Ordering::Relaxed) {
            tracing::debug!(target: "core::offline", %track_id, "offline download cancelled");
            return Ok(());
        }
        // 记录还在才标失败；用户已经删除时不要复活它。
        if current_row(&s.library, track_id).await?.is_some() {
            let message = e.message.clone();
            let _ = s
                .library
                .mark_offline_failed(track_id, message.clone())
                .await;
            s.events.emit(lekis_types::CoreEvent::OfflineChanged {
                track_id,
                state: OfflineState::Failed,
                error: Some(message),
            });
        }
    }
    result
}

async fn run_download_inner(
    s: Arc<Services>,
    track_id: TrackId,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    let resolver = s.resolver.clone();
    let (file, media) = resolver.resolve_file(track_id).await?;
    if cancel.load(Ordering::Relaxed) {
        return Err(LekisError::new(ErrorCode::Io, "cancelled"));
    }
    let ext = extension_for(&file, &media);
    let final_path = s
        .config
        .data_dir
        .join("offline")
        .join(format!("{}.{ext}", track_id.0));
    let total_hint = media_total_hint(&s, &media).await?;
    s.library
        .upsert_offline_queued(
            track_id,
            file.source_id,
            final_path.to_string_lossy().into_owned(),
            total_hint.unwrap_or(0),
        )
        .await?;
    s.events.emit(lekis_types::CoreEvent::OfflineChanged {
        track_id,
        state: OfflineState::Queued,
        error: None,
    });

    let mut writer = CacheWriter::create(&final_path).await?;
    s.library.mark_offline_downloading(track_id).await?;
    s.events.emit(lekis_types::CoreEvent::OfflineChanged {
        track_id,
        state: OfflineState::Downloading,
        error: None,
    });
    let mut progress = Progress::new(&s, track_id, total_hint);

    let copy = match &media.location {
        MediaLocation::CachedFile { path } => Err(LekisError::invalid(format!(
            "refusing to download an already cached file: {path}"
        ))),
        MediaLocation::Vfs { source_id, path } => {
            let vfs = vfs_for(&s, *source_id).await?;
            let vfs_path = lekis_vfs::VfsPath::parse(path)
                .ok_or_else(|| LekisError::invalid(format!("invalid vfs path: {path}")))?;
            let meta = vfs.stat(&vfs_path).await.ok();
            if let Some(meta) = meta {
                progress.set_total(Some(meta.size));
            }
            copy_vfs(&vfs, &vfs_path, &mut writer, &mut progress, &cancel).await
        }
        MediaLocation::Url { url, headers } => {
            copy_http(url, headers, &mut writer, &mut progress, &cancel).await
        }
    };

    match copy {
        Ok(bytes) => {
            if cancel.load(Ordering::Relaxed) {
                writer.abort().await;
                return Err(LekisError::new(ErrorCode::Io, "cancelled"));
            }
            writer.finish().await?;
            progress.finish(bytes).await?;
            if current_row(&s.library, track_id).await?.is_none() {
                // 下载完成前用户删除了记录：缓存文件也一起清掉。
                remove_file_if_exists(&final_path).await;
                return Ok(());
            }
            s.library.mark_offline_ready(track_id, bytes).await?;
            s.events.emit(lekis_types::CoreEvent::OfflineProgress {
                track_id,
                downloaded: bytes,
                total: progress.total.or(Some(bytes)),
            });
            s.events.emit(lekis_types::CoreEvent::OfflineChanged {
                track_id,
                state: OfflineState::Ready,
                error: None,
            });
            Ok(())
        }
        Err(e) => {
            writer.abort().await;
            Err(e)
        }
    }
}

async fn vfs_for(s: &Arc<Services>, source_id: SourceId) -> Result<Arc<dyn lekis_vfs::Vfs>> {
    if let Some(vfs) = s.vfs_get(source_id) {
        return Ok(vfs);
    }
    let config = s.library.get_source(source_id).await?;
    let vfs = s.open_vfs(&config)?;
    s.vfs_put(source_id, vfs.clone());
    Ok(vfs)
}

async fn media_total_hint(s: &Arc<Services>, media: &MediaSource) -> Result<Option<u64>> {
    if let MediaLocation::Vfs { source_id, path } = &media.location {
        if let Some(vfs_path) = lekis_vfs::VfsPath::parse(path) {
            let vfs = vfs_for(s, *source_id).await?;
            if let Ok(meta) = vfs.stat(&vfs_path).await {
                return Ok(Some(meta.size));
            }
        }
    }
    Ok(None)
}

async fn copy_vfs(
    vfs: &Arc<dyn lekis_vfs::Vfs>,
    path: &lekis_vfs::VfsPath,
    writer: &mut CacheWriter,
    progress: &mut Progress<'_>,
    cancel: &AtomicBool,
) -> Result<u64> {
    let mut offset = 0u64;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(LekisError::new(ErrorCode::Io, "cancelled"));
        }
        let chunk = vfs.read_range(path, offset..offset + CHUNK).await?;
        if chunk.is_empty() {
            break;
        }
        writer.write(&chunk).await?;
        offset += chunk.len() as u64;
        progress.report(offset).await?;
        if (chunk.len() as u64) < CHUNK {
            // 已经到文件末尾（read_range 会截断）。
            break;
        }
    }
    Ok(offset)
}

async fn copy_http(
    url: &str,
    headers: &[(String, String)],
    writer: &mut CacheWriter,
    progress: &mut Progress<'_>,
    cancel: &AtomicBool,
) -> Result<u64> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .read_timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("http client: {e}")))?;
    let mut request = client.get(url).header("Accept-Encoding", "identity");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    let mut response = request.send().await.map_err(|e| {
        LekisError::new(ErrorCode::Network, format!("offline download request: {e}"))
    })?;
    if !response.status().is_success() {
        return Err(LekisError::new(
            ErrorCode::Network,
            format!("offline download HTTP {}", response.status()),
        ));
    }
    let total = response.content_length();
    progress.set_total(total.or(progress.total));
    let mut offset = 0u64;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| LekisError::new(ErrorCode::Network, format!("offline download body: {e}")))?
    {
        if cancel.load(Ordering::Relaxed) {
            return Err(LekisError::new(ErrorCode::Io, "cancelled"));
        }
        writer.write(&chunk).await?;
        offset += chunk.len() as u64;
        progress.report(offset).await?;
    }
    Ok(offset)
}

/// 进度上报：事件最多 10 Hz，落库最多 1 Hz；结束 / 取消时不丢最后一次。
struct Progress<'a> {
    library: &'a Library,
    events: &'a EventBus,
    track_id: TrackId,
    total: Option<u64>,
    last_event: Instant,
    last_db: Instant,
    last_event_bytes: u64,
    last_db_bytes: u64,
}

impl<'a> Progress<'a> {
    fn new(s: &'a Services, track_id: TrackId, total: Option<u64>) -> Self {
        Self {
            library: &s.library,
            events: &s.events,
            track_id,
            total,
            last_event: Instant::now() - EVENT_INTERVAL,
            last_db: Instant::now() - DB_INTERVAL,
            last_event_bytes: 0,
            last_db_bytes: 0,
        }
    }

    fn set_total(&mut self, total: Option<u64>) {
        if total.is_some() {
            self.total = total;
            self.events.emit(lekis_types::CoreEvent::OfflineProgress {
                track_id: self.track_id,
                downloaded: self.last_event_bytes,
                total: self.total,
            });
        }
    }

    async fn finish(&mut self, downloaded: u64) -> Result<()> {
        if self.last_db_bytes != downloaded {
            self.library
                .update_offline_progress(self.track_id, downloaded, self.total)
                .await?;
            self.last_db_bytes = downloaded;
        }
        Ok(())
    }

    async fn report(&mut self, downloaded: u64) -> Result<()> {
        if downloaded == self.last_event_bytes {
            return Ok(());
        }
        if self.last_event.elapsed() >= EVENT_INTERVAL || Some(downloaded) == self.total {
            self.events.emit(lekis_types::CoreEvent::OfflineProgress {
                track_id: self.track_id,
                downloaded,
                total: self.total,
            });
            self.last_event = Instant::now();
            self.last_event_bytes = downloaded;
        }
        if self.last_db.elapsed() >= DB_INTERVAL {
            self.library
                .update_offline_progress(self.track_id, downloaded, self.total)
                .await?;
            self.last_db = Instant::now();
            self.last_db_bytes = downloaded;
        }
        Ok(())
    }
}

/// 先写 `.part`、再改名的缓存写入器。
struct CacheWriter {
    final_path: PathBuf,
    part_path: PathBuf,
    file: Option<tokio::fs::File>,
    bytes: u64,
}

impl CacheWriter {
    async fn create(final_path: &Path) -> Result<Self> {
        if let Some(parent) = final_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| LekisError::new(ErrorCode::Io, format!("create offline dir: {e}")))?;
        }
        let name = final_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("download");
        static PART_SEQ: AtomicU64 = AtomicU64::new(0);
        let part_path = final_path.with_file_name(format!(
            "{name}.{}.{:x}.{}.part",
            std::process::id(),
            lekis_types::now_ms(),
            PART_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let file = tokio::fs::File::create(&part_path)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("create cache part: {e}")))?;
        Ok(Self {
            final_path: final_path.to_path_buf(),
            part_path,
            file: Some(file),
            bytes: 0,
        })
    }

    async fn write(&mut self, data: &[u8]) -> Result<()> {
        let Some(file) = self.file.as_mut() else {
            return Err(LekisError::new(ErrorCode::Io, "cache writer is closed"));
        };
        file.write_all(data)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("write cache: {e}")))?;
        self.bytes += data.len() as u64;
        Ok(())
    }

    async fn finish(mut self) -> Result<u64> {
        let file = self
            .file
            .take()
            .ok_or_else(|| LekisError::new(ErrorCode::Io, "cache writer is closed"))?;
        file.sync_all()
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("flush cache: {e}")))?;
        drop(file);
        // Windows 上 rename 不能覆盖已有文件；重试同一个曲目时先删旧的最终文件。
        remove_file_if_exists(&self.final_path).await;
        tokio::fs::rename(&self.part_path, &self.final_path)
            .await
            .map_err(|e| LekisError::new(ErrorCode::Io, format!("rename cache: {e}")))?;
        Ok(self.bytes)
    }

    async fn abort(mut self) {
        self.file.take();
        remove_file_if_exists(&self.part_path).await;
    }
}

async fn remove_file_if_exists(path: &Path) {
    match tokio::fs::remove_file(path).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            tracing::warn!(target: "core::offline", path = %path.display(), error = %e, "cannot delete offline file")
        }
    }
}

async fn remove_parts_for(dir: &Path, track_id: TrackId) -> u64 {
    let prefix = format!("{}.", track_id.0);
    let Ok(mut entries) = tokio::fs::read_dir(dir).await else {
        return 0;
    };
    let mut removed = 0u64;
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with(&prefix)
            && name.ends_with(".part")
            && tokio::fs::remove_file(entry.path()).await.is_ok()
        {
            removed += 1;
        }
    }
    removed
}

async fn remove_stale_parts(dir: &Path) {
    let Ok(mut entries) = tokio::fs::read_dir(dir).await else {
        return;
    };
    // 启动恢复和下载可能并发：只清掉明显陈旧的临时文件，避免删掉
    // 刚创建、正在写入的 `.part`（旧实现会在测试/快速启动时偶发复现）。
    let cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(600))
        .unwrap_or(std::time::UNIX_EPOCH);
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.ends_with(".part") {
            continue;
        }
        let fresh = entry
            .metadata()
            .await
            .ok()
            .and_then(|m| m.modified().ok())
            .is_some_and(|m| m > cutoff);
        if fresh {
            continue;
        }
        let _ = tokio::fs::remove_file(entry.path()).await;
    }
}

/// 缓存文件扩展名：优先源内路径，其次服务器 ID，最后播放地址。
fn extension_for(file: &TrackFile, media: &MediaSource) -> String {
    let mut candidates = Vec::new();
    candidates.push(file.path.as_str());
    if let Some(external) = file.external_id.as_deref() {
        candidates.push(external);
    }
    if let MediaLocation::Url { url, .. } = &media.location {
        candidates.push(url.as_str());
    }
    for candidate in candidates {
        if let Some(ext) = extension_of(candidate) {
            return ext;
        }
    }
    "bin".into()
}

fn extension_of(raw: &str) -> Option<String> {
    let path = raw.split(['?', '#']).next().unwrap_or(raw);
    let ext = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    if ext.is_empty() || ext.len() > 8 || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some(ext)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lekis-offline-{name}-{}-{}",
            std::process::id(),
            lekis_types::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn cache_writer_is_atomic_and_cleans_up_on_abort() {
        let dir = temp_dir("atomic");
        let final_path = dir.join("7.flac");

        let mut writer = CacheWriter::create(&final_path).await.unwrap();
        writer.write(b"hello ").await.unwrap();
        writer.write(b"world").await.unwrap();
        assert!(!final_path.exists(), "最终文件在 finish 之前不能出现");
        let part = writer.part_path.clone();
        assert!(part.exists());
        assert_eq!(writer.finish().await.unwrap(), 11);
        assert_eq!(std::fs::read(&final_path).unwrap(), b"hello world");
        assert!(!part.exists(), "改名后不能留下 .part");

        let final_path = dir.join("8.flac");
        let mut writer = CacheWriter::create(&final_path).await.unwrap();
        writer.write(b"partial").await.unwrap();
        let part = writer.part_path.clone();
        writer.abort().await;
        assert!(!final_path.exists());
        assert!(!part.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn cache_writer_replaces_old_file_after_successful_retry() {
        let dir = temp_dir("replace");
        let final_path = dir.join("9.mp3");
        std::fs::write(&final_path, b"old").unwrap();

        let mut writer = CacheWriter::create(&final_path).await.unwrap();
        writer.write(b"new").await.unwrap();
        writer.finish().await.unwrap();
        assert_eq!(std::fs::read(&final_path).unwrap(), b"new");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn extension_prefers_source_path_and_sanitizes() {
        let file = TrackFile {
            source_id: SourceId(1),
            source_kind: lekis_types::SourceKind::Local,
            path: "music/a.FLAC".into(),
            external_id: None,
            quality_score: 100,
            duration_ms: 1000,
            replaygain: Default::default(),
        };
        let media = MediaSource {
            track_id: TrackId(1),
            location: MediaLocation::Vfs {
                source_id: SourceId(1),
                path: "music/a.FLAC".into(),
            },
            duration_hint_ms: 1000,
            gain_db: None,
        };
        assert_eq!(extension_for(&file, &media), "flac");

        let media = MediaSource {
            track_id: TrackId(1),
            location: MediaLocation::Url {
                url: "https://host/stream?token=1".into(),
                headers: Vec::new(),
            },
            duration_hint_ms: 0,
            gain_db: None,
        };
        let file = TrackFile {
            path: String::new(),
            external_id: Some("track-id-without-extension".into()),
            ..file
        };
        assert_eq!(extension_for(&file, &media), "bin");
    }
}
