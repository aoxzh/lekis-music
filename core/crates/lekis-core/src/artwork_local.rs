//! 本地封面补填（ENR-01 的本地部分）。
//!
//! 扫描只读头尾、不碰封面，所以扫描结束后单独跑一遍：
//! 对每个还没有封面的专辑 / 单曲，先找同目录的 `cover.jpg` 等侧车文件，
//! 再退回音频文件里的内嵌封面，生成缩略图并写进封面缓存。
//!
//! 只处理文件系统源（本地磁盘 / 移动硬盘）；网络共享上的封面留给补全管线，
//! 避免一次扫描对 NAS 发出成百上千次大块读取。

use crate::enrich::{self, ArtworkTarget};
use crate::Services;
use lekis_types::{CoreEvent, LibraryScope, Result, ScanPhase, SourceId};
use lekis_vfs::{partial, EntryKind, Vfs, VfsPath};
use std::sync::Arc;

/// 一张侧车封面允许的最大字节数（和补全的下载上限一致）。
const MAX_SIDECAR_BYTES: u64 = 16 * 1024 * 1024;

/// 内嵌封面读取的初始 / 回退窗口。FLAC / ID3v2 的封面通常在文件头部；
/// MP4 的 `moov` 可能在尾部，所以尾部也要留足。
const HEAD_WINDOW: u64 = 4 * 1024 * 1024;
const TAIL_WINDOW: u64 = 4 * 1024 * 1024;
const HEAD_WINDOW_RETRY: u64 = 12 * 1024 * 1024;
const TAIL_WINDOW_RETRY: u64 = 12 * 1024 * 1024;

/// 常见侧车封面文件名（Android 的 /sdcard 区分大小写，所以大小写都列）。
pub(crate) const SIDECAR_NAMES: &[&str] = &[
    "cover.jpg",
    "cover.jpeg",
    "cover.png",
    "Cover.jpg",
    "Cover.jpeg",
    "Cover.png",
    "folder.jpg",
    "folder.jpeg",
    "folder.png",
    "Folder.jpg",
    "Folder.png",
    "front.jpg",
    "front.jpeg",
    "front.png",
    "Front.jpg",
    "album.jpg",
    "albumart.jpg",
    "AlbumArt.jpg",
    "artwork.jpg",
];

/// 单曲专用封面：`<歌曲名>.jpg`，用于同一目录里每首歌封面不同的情况。
pub(crate) const TRACK_COVER_EXTS: &[&str] = &["jpg", "jpeg", "png", "JPG", "JPEG", "PNG"];

/// 给一个源补全缺失的封面。返回成功补上的数量。
pub(crate) async fn ingest_missing(
    services: Arc<Services>,
    source_id: SourceId,
    vfs: Arc<dyn Vfs>,
) -> Result<usize> {
    // 一次最多处理 2000 张；剩下的下次扫描再补，避免首次扫描卡太久。
    let candidates = services.library.artwork_candidates(source_id, 2000).await?;
    if candidates.is_empty() {
        return Ok(0);
    }
    let total = candidates.len() as u64;
    tracing::info!(
        target: "core",
        %source_id,
        candidates = candidates.len(),
        "looking for local artwork"
    );
    services.events.emit(CoreEvent::ScanProgress {
        source_id,
        phase: ScanPhase::Artwork,
        done: 0,
        total: Some(total),
    });

    let mut ingested = 0usize;
    let mut seen = 0u64;
    for candidate in candidates {
        seen += 1;
        if seen % 4 == 0 || seen == total {
            services.events.emit(CoreEvent::ScanProgress {
                source_id,
                phase: ScanPhase::Artwork,
                done: seen,
                total: Some(total),
            });
        }
        let Some(path) = VfsPath::parse(&candidate.path) else {
            continue;
        };
        let Some((bytes, source)) = load_cover(vfs.as_ref(), &path).await else {
            continue;
        };
        let target = ArtworkTarget {
            track_id: candidate.album_id.is_none().then_some(candidate.track_id),
            album_id: candidate.album_id,
            replace_album: false,
        };
        match enrich::store_artwork_bytes(
            &services.config.cache_dir,
            &services.library,
            target,
            bytes,
            source,
        )
        .await
        {
            Ok(_) => {
                ingested += 1;
                if ingested % 8 == 0 {
                    services.events.emit(CoreEvent::LibraryChanged {
                        scope: LibraryScope::Catalog,
                    });
                }
            }
            Err(e) => {
                tracing::warn!(
                    target: "core",
                    path = %candidate.path,
                    error = %e,
                    "local artwork ingest failed"
                );
            }
        }
    }

    if ingested > 0 {
        services.events.emit(CoreEvent::LibraryChanged {
            scope: LibraryScope::Catalog,
        });
        tracing::info!(target: "core", %source_id, ingested, "local artwork ingested");
    }
    Ok(ingested)
}

/// 先找单曲专用封面，再找目录侧车封面，最后读内嵌封面。
async fn load_cover(vfs: &dyn Vfs, path: &VfsPath) -> Option<(Vec<u8>, &'static str)> {
    if let Some(bytes) = read_track_sidecar(vfs, path).await {
        return Some((bytes, "sidecar"));
    }
    if let Some(dir) = path.parent() {
        if let Some(bytes) = read_sidecar(vfs, &dir).await {
            return Some((bytes, "sidecar"));
        }
        // 多碟专辑的封面经常放在上一级目录。
        if let Some(parent) = dir.parent() {
            if let Some(bytes) = read_sidecar(vfs, &parent).await {
                return Some((bytes, "sidecar"));
            }
        }
    }
    read_embedded(vfs, path)
        .await
        .map(|bytes| (bytes, "embedded"))
}

/// `<歌曲名>.jpg` 这类单曲封面；同一目录里每首歌可以有不同封面。
async fn read_track_sidecar(vfs: &dyn Vfs, path: &VfsPath) -> Option<Vec<u8>> {
    let stem = path.as_str().rsplit_once('.').map(|(stem, _)| stem)?;
    for ext in TRACK_COVER_EXTS {
        let Some(candidate) = VfsPath::parse(&format!("{stem}.{ext}")) else {
            continue;
        };
        let Ok(meta) = vfs.stat(&candidate).await else {
            continue;
        };
        if !matches!(meta.kind, EntryKind::File) || meta.size == 0 || meta.size > MAX_SIDECAR_BYTES
        {
            continue;
        }
        match vfs.read_range(&candidate, 0..meta.size).await {
            Ok(bytes) if !bytes.is_empty() => return Some(bytes.to_vec()),
            Ok(_) => {}
            Err(e) => {
                tracing::debug!(target: "core", path = %candidate, error = %e, "track cover read failed");
            }
        }
    }
    None
}

async fn read_sidecar(vfs: &dyn Vfs, dir: &VfsPath) -> Option<Vec<u8>> {
    for name in SIDECAR_NAMES {
        let path = dir.join(name);
        let Ok(meta) = vfs.stat(&path).await else {
            continue;
        };
        if !matches!(meta.kind, EntryKind::File) || meta.size == 0 || meta.size > MAX_SIDECAR_BYTES
        {
            continue;
        }
        match vfs.read_range(&path, 0..meta.size).await {
            Ok(bytes) if !bytes.is_empty() => return Some(bytes.to_vec()),
            Ok(_) => {}
            Err(e) => {
                tracing::debug!(target: "core", path = %path, error = %e, "sidecar cover read failed");
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use lekis_vfs::local::LocalVfs;

    #[tokio::test]
    async fn sidecar_cover_wins_over_embedded_lookup() {
        let dir = std::env::temp_dir().join(format!(
            "lekis-sidecar-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(dir.join("album")).unwrap();
        std::fs::write(dir.join("album/cover.jpg"), b"sidecar-bytes").unwrap();
        let vfs = LocalVfs::new(&dir).unwrap();
        let path = VfsPath::parse("album/track.flac").unwrap();

        let (bytes, source) = load_cover(&vfs, &path).await.unwrap();
        assert_eq!(source, "sidecar");
        assert_eq!(bytes, b"sidecar-bytes");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn sidecar_cover_can_live_one_level_up() {
        let dir = std::env::temp_dir().join(format!(
            "lekis-sidecar-parent-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(dir.join("album/disc1")).unwrap();
        std::fs::write(dir.join("album/cover.jpg"), b"parent-bytes").unwrap();
        let vfs = LocalVfs::new(&dir).unwrap();
        let path = VfsPath::parse("album/disc1/track.flac").unwrap();

        let (bytes, source) = load_cover(&vfs, &path).await.unwrap();
        assert_eq!(source, "sidecar");
        assert_eq!(bytes, b"parent-bytes");

        std::fs::remove_dir_all(&dir).unwrap();
    }
}

async fn read_embedded(vfs: &dyn Vfs, path: &VfsPath) -> Option<Vec<u8>> {
    let meta = vfs.stat(path).await.ok()?;
    if !matches!(meta.kind, EntryKind::File) || meta.size == 0 {
        return None;
    }

    for (head, tail) in [
        (HEAD_WINDOW, TAIL_WINDOW),
        (HEAD_WINDOW_RETRY, TAIL_WINDOW_RETRY),
    ] {
        let Ok(data) = partial::read_head_tail(vfs, path, meta.size, head, tail).await else {
            continue;
        };
        match lekis_scanner::tags::read_cover_art(path, &data) {
            Ok(Some(bytes)) if !bytes.is_empty() => return Some(bytes),
            Ok(_) => return None,
            Err(e) => {
                tracing::debug!(
                    target: "core",
                    path = %path,
                    error = %e,
                    "embedded cover parse failed, retrying with a larger window"
                );
            }
        }
    }
    None
}
