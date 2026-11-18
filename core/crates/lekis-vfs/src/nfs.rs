//! NFS v3/v4（SRC-08，P1）。计划用 libnfs（LGPL）通过 FFI 调用，只在桌面和 Android 提供。

use crate::{DirEntry, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceKind};
use std::ops::Range;

/// NFS 文件系统（占位）。
pub struct NfsVfs;

impl NfsVfs {
    /// 连接 `nfs://host/export`。
    pub fn connect(_url: &str) -> Result<Self> {
        Err(LekisError::not_implemented("nfs"))
    }
}

#[async_trait]
impl Vfs for NfsVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Nfs
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime: true,
            suggested_concurrency: 8,
        }
    }

    async fn list_dir(&self, _dir: &VfsPath) -> Result<Vec<DirEntry>> {
        Err(LekisError::not_implemented("nfs list_dir"))
    }

    async fn stat(&self, _path: &VfsPath) -> Result<FileMeta> {
        Err(LekisError::not_implemented("nfs stat"))
    }

    async fn read_range(&self, _path: &VfsPath, _range: Range<u64>) -> Result<Bytes> {
        Err(LekisError::not_implemented("nfs read_range"))
    }

    async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
        Err(LekisError::not_implemented("nfs write_atomic"))
    }

    async fn create_dir_all(&self, _path: &VfsPath) -> Result<()> {
        Err(LekisError::not_implemented("nfs create_dir_all"))
    }
}
