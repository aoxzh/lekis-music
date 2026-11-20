//! Multi-address failover for filesystem sources (SRC-14).
//!
//! A source may list a home NAS address, a Tailscale address and a public
//! address. Construction does not contact the network, so the first backend is
//! simply tried at operation time; when it fails we transparently retry the
//! remaining addresses and remember the one that worked. Writes intentionally
//! stay on the current (or first writable) backend so one `write_atomic` can
//! never be duplicated on two NAS endpoints.

use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use std::ops::Range;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use crate::{DirEntry, FileMeta, Vfs, VfsCapabilities, VfsPath};

/// A VFS that tries several addresses in order.
pub struct FailoverVfs {
    backends: Vec<Arc<dyn Vfs>>,
    current: AtomicUsize,
    /// Set once the current backend has answered successfully. After that, a
    /// definite answer from it (file missing, bad argument...) is final: the
    /// other addresses point at the same share, so asking them again would only
    /// add a network timeout per missing file.
    verified: AtomicBool,
}

/// Whether `error` says something about the request rather than about the
/// address being reachable.
pub fn is_definite_answer(error: &LekisError) -> bool {
    matches!(
        error.code,
        ErrorCode::NotFound
            | ErrorCode::InvalidArgument
            | ErrorCode::Unsupported
            | ErrorCode::NotImplemented
            | ErrorCode::Decode
            | ErrorCode::Cancelled
    )
}

impl FailoverVfs {
    /// Build from at least one backend; the first one is preferred.
    pub fn new(backends: Vec<Arc<dyn Vfs>>) -> Result<Self> {
        if backends.is_empty() {
            return Err(LekisError::invalid(
                "failover vfs needs at least one backend",
            ));
        }
        Ok(Self {
            backends,
            current: AtomicUsize::new(0),
            verified: AtomicBool::new(false),
        })
    }

    fn current(&self) -> usize {
        self.current.load(Ordering::Relaxed) % self.backends.len()
    }

    /// Try every backend, starting at the last known-good one.
    async fn try_read<T, F, Fut>(&self, mut f: F) -> Result<T>
    where
        F: FnMut(Arc<dyn Vfs>) -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        let start = self.current();
        let mut last_error = None;
        for step in 0..self.backends.len() {
            let index = (start + step) % self.backends.len();
            match f(self.backends[index].clone()).await {
                Ok(value) => {
                    self.current.store(index, Ordering::Relaxed);
                    self.verified.store(true, Ordering::Relaxed);
                    return Ok(value);
                }
                Err(e) => {
                    if step == 0 && self.verified.load(Ordering::Relaxed) && is_definite_answer(&e)
                    {
                        return Err(e);
                    }
                    if step == 0 {
                        self.verified.store(false, Ordering::Relaxed);
                    }
                    last_error = Some(e);
                }
            }
        }
        Err(last_error.unwrap_or_else(|| LekisError::internal("failover vfs has no backend")))
    }

    fn write_backend(&self) -> Arc<dyn Vfs> {
        let current = self.current();
        if self.backends[current].capabilities().writable {
            return self.backends[current].clone();
        }
        self.backends
            .iter()
            .find(|vfs| vfs.capabilities().writable)
            .cloned()
            .unwrap_or_else(|| self.backends[current].clone())
    }
}

#[async_trait]
impl Vfs for FailoverVfs {
    fn kind(&self) -> SourceKind {
        self.backends[self.current()].kind()
    }

    fn capabilities(&self) -> VfsCapabilities {
        // The UI only needs one summary. Prefer the current backend, but if it
        // is read-only and another address is writable, expose writable so
        // shared-index writes are still attempted via `write_backend`.
        let current = self.backends[self.current()].capabilities();
        if current.writable {
            current
        } else {
            self.backends
                .iter()
                .map(|vfs| vfs.capabilities())
                .find(|caps| caps.writable)
                .unwrap_or(current)
        }
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let dir = dir.clone();
        self.try_read(move |vfs| {
            let dir = dir.clone();
            async move { vfs.list_dir(&dir).await }
        })
        .await
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let path = path.clone();
        self.try_read(move |vfs| {
            let path = path.clone();
            async move { vfs.stat(&path).await }
        })
        .await
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        let path = path.clone();
        self.try_read(move |vfs| {
            let path = path.clone();
            let range = range.clone();
            async move { vfs.read_range(&path, range).await }
        })
        .await
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        let vfs = self.write_backend();
        vfs.write_atomic(path, data).await
    }

    async fn create_dir_all(&self, path: &VfsPath) -> Result<()> {
        let vfs = self.write_backend();
        vfs.create_dir_all(path).await
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::local::LocalVfs;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("lekis-vfs-failover-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn missing_first_backend_falls_back_and_remembers_the_second() {
        let first = temp_dir("first");
        let second = temp_dir("second");
        std::fs::write(second.join("track.flac"), b"audio").unwrap();
        std::fs::remove_dir_all(&first).unwrap();

        let vfs = FailoverVfs::new(vec![
            Arc::new(LocalVfs::new(&first).unwrap()) as Arc<dyn Vfs>,
            Arc::new(LocalVfs::new(&second).unwrap()) as Arc<dyn Vfs>,
        ])
        .unwrap();

        let entries = vfs.list_dir(&VfsPath::root()).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path.as_str(), "track.flac");
        // The second address becomes sticky for later reads.
        let meta = vfs
            .stat(&VfsPath::parse("track.flac").unwrap())
            .await
            .unwrap();
        assert_eq!(meta.size, 5);
        assert_eq!(vfs.current(), 1);

        let _ = std::fs::remove_dir_all(&second);
    }

    #[tokio::test]
    async fn missing_file_on_a_verified_backend_does_not_fail_over() {
        let first = temp_dir("verified-first");
        let second = temp_dir("verified-second");
        std::fs::write(first.join("a.flac"), b"a").unwrap();
        std::fs::write(second.join("b.flac"), b"b").unwrap();
        let vfs = FailoverVfs::new(vec![
            Arc::new(LocalVfs::new(&first).unwrap()) as Arc<dyn Vfs>,
            Arc::new(LocalVfs::new(&second).unwrap()) as Arc<dyn Vfs>,
        ])
        .unwrap();
        vfs.list_dir(&VfsPath::root()).await.unwrap();
        // b.flac only exists on the second address, but the first one is known
        // good, so "not found" is the answer and we stay on it.
        assert!(vfs.stat(&VfsPath::parse("b.flac").unwrap()).await.is_err());
        assert_eq!(vfs.current(), 0);
        let _ = std::fs::remove_dir_all(&first);
        let _ = std::fs::remove_dir_all(&second);
    }

    #[test]
    fn rejects_empty_backend_list() {
        assert!(FailoverVfs::new(Vec::new()).is_err());
    }
}
