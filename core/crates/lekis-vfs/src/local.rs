//! 本地文件系统（含移动硬盘）。

use crate::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceKind};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

/// 本地文件系统。
///
/// TODO(SRC-01)：按卷 ID 识别移动硬盘（盘符变了也能认出来）。
/// TODO(LIB-04)：文件监听（notify crate）。
pub struct LocalVfs {
    root: PathBuf,
}

impl LocalVfs {
    /// 以 `root` 为根目录创建。
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        if !root.is_absolute() {
            return Err(LekisError::invalid(
                "local source root must be an absolute path",
            ));
        }
        Ok(Self { root })
    }

    fn resolve(&self, path: &VfsPath) -> PathBuf {
        let mut full = self.root.clone();
        for part in path.as_str().split('/').filter(|s| !s.is_empty()) {
            full.push(part);
        }
        full
    }
}

fn to_meta(m: &std::fs::Metadata) -> FileMeta {
    let kind = if m.is_file() {
        EntryKind::File
    } else if m.is_dir() {
        EntryKind::Dir
    } else {
        EntryKind::Other
    };
    let mtime_ms = m
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    FileMeta {
        kind,
        size: if m.is_file() { m.len() } else { 0 },
        mtime_ms,
    }
}

#[async_trait]
impl Vfs for LocalVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Local
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false, // 实现文件监听后改为 true
            reliable_dir_mtime: true,
            suggested_concurrency: 16,
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let mut rd = tokio::fs::read_dir(self.resolve(dir)).await?;
        let mut out = Vec::new();
        while let Some(entry) = rd.next_entry().await? {
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                tracing::warn!(target: "vfs::local", "skipping non-UTF-8 file name");
                continue;
            };
            let meta = match entry.metadata().await {
                Ok(m) => to_meta(&m),
                Err(e) => {
                    tracing::debug!(target: "vfs::local", error = %e, "stat failed, skipping");
                    continue;
                }
            };
            out.push(DirEntry {
                path: dir.join(&name),
                meta,
            });
        }
        Ok(out)
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        Ok(to_meta(&tokio::fs::metadata(self.resolve(path)).await?))
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid("range end < start"));
        }
        let mut file = tokio::fs::File::open(self.resolve(path)).await?;
        let len = file.metadata().await?.len();
        let start = range.start.min(len);
        let end = range.end.min(len);
        file.seek(std::io::SeekFrom::Start(start)).await?;
        let mut buf = vec![0u8; (end - start) as usize];
        file.read_exact(&mut buf).await?;
        Ok(Bytes::from(buf))
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        let target = self.resolve(path);
        let tmp = target.with_extension("lekis-tmp");
        tokio::fs::write(&tmp, &data).await?;
        tokio::fs::rename(&tmp, &target).await?;
        Ok(())
    }

    async fn create_dir_all(&self, path: &VfsPath) -> Result<()> {
        tokio::fs::create_dir_all(self.resolve(path)).await?;
        Ok(())
    }

    async fn delete_file(&self, path: &VfsPath) -> Result<()> {
        if path.is_root() {
            return Err(LekisError::invalid("不能删除根目录"));
        }
        match tokio::fs::remove_file(self.resolve(path)).await {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn list_read_write_roundtrip() -> Result<()> {
        let dir = std::env::temp_dir().join(format!("lekis-vfs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir)?;
        let vfs = LocalVfs::new(&dir)?;
        let p = VfsPath::parse("a.flac").unwrap_or_default();
        vfs.write_atomic(&p, Bytes::from_static(b"0123456789"))
            .await?;

        let entries = vfs.list_dir(&VfsPath::root()).await?;
        assert!(entries.iter().any(|e| e.path == p && e.meta.size == 10));

        let head = vfs.read_range(&p, 0..4).await?;
        assert_eq!(&head[..], b"0123");
        let tail = vfs.read_range(&p, 8..100).await?;
        assert_eq!(&tail[..], b"89");

        std::fs::remove_dir_all(&dir)?;
        Ok(())
    }
}
