//! WebDAV（SRC-03）：覆盖 Alist/OpenList、Nextcloud、群晖 WebDAV。
//!
//! 实现方式：基于 reqwest 自己实现，只需要 `PROPFIND`（Depth: 1）、`GET` + `Range`、`PUT`、`MKCOL`、`MOVE`。
//! 注意：
//! - 有些服务（Alist 的部分存储驱动）会 302 跳转到网盘直链，Range 请求要跟随跳转；
//! - 有些服务不返回 `getlastmodified`，此时 `reliable_dir_mtime = false`，增量扫描退化为逐个比对文件；
//! - Basic 认证只允许在 HTTPS 上用，HTTP 上要给用户警告。

use crate::{DirEntry, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceKind};
use std::ops::Range;

/// WebDAV 文件系统（占位）。
pub struct WebDavVfs {
    #[allow(dead_code)]
    base_url: String,
}

impl WebDavVfs {
    /// 以 `http(s)://host/path` 为根创建。
    pub fn new(base_url: &str, _password: Option<String>) -> Result<Self> {
        if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
            return Err(LekisError::invalid(
                "WebDAV address must start with http(s)://",
            ));
        }
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
        })
    }
}

#[async_trait]
impl Vfs for WebDavVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::WebDav
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime: false,
            suggested_concurrency: 4,
        }
    }

    async fn list_dir(&self, _dir: &VfsPath) -> Result<Vec<DirEntry>> {
        Err(LekisError::not_implemented("webdav list_dir (PROPFIND)"))
    }

    async fn stat(&self, _path: &VfsPath) -> Result<FileMeta> {
        Err(LekisError::not_implemented("webdav stat"))
    }

    async fn read_range(&self, _path: &VfsPath, _range: Range<u64>) -> Result<Bytes> {
        Err(LekisError::not_implemented(
            "webdav read_range (GET + Range)",
        ))
    }

    async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
        Err(LekisError::not_implemented(
            "webdav write_atomic (PUT + MOVE)",
        ))
    }

    async fn create_dir_all(&self, _path: &VfsPath) -> Result<()> {
        Err(LekisError::not_implemented("webdav create_dir_all (MKCOL)"))
    }
}
