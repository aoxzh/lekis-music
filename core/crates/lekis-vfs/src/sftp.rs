//! SFTP（SRC-07，P1）。计划用 russh + russh-sftp（纯 Rust），支持密码和密钥登录。

use crate::{DirEntry, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceKind};
use std::ops::Range;

/// SFTP 文件系统（占位）。
pub struct SftpVfs;

impl SftpVfs {
    /// 连接 `sftp://user@host:port/path`。
    pub fn connect(_url: &str, _password: Option<String>) -> Result<Self> {
        Err(LekisError::not_implemented("sftp"))
    }
}

#[async_trait]
impl Vfs for SftpVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Sftp
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime: true,
            suggested_concurrency: 4,
        }
    }

    async fn list_dir(&self, _dir: &VfsPath) -> Result<Vec<DirEntry>> {
        Err(LekisError::not_implemented("sftp list_dir"))
    }

    async fn stat(&self, _path: &VfsPath) -> Result<FileMeta> {
        Err(LekisError::not_implemented("sftp stat"))
    }

    async fn read_range(&self, _path: &VfsPath, _range: Range<u64>) -> Result<Bytes> {
        Err(LekisError::not_implemented("sftp read_range"))
    }

    async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
        Err(LekisError::not_implemented("sftp write_atomic"))
    }

    async fn create_dir_all(&self, _path: &VfsPath) -> Result<()> {
        Err(LekisError::not_implemented("sftp create_dir_all"))
    }
}
