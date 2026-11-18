//! SMB 2/3（SRC-02）。
//!
//! **选型待验证**（最大的技术风险之一）：
//! - 方案 A：libsmb2（C，LGPL-2.1，VLC 在用）通过 FFI 调用，动态链接。
//! - 方案 B：纯 Rust 的 `smb` crate，没有 C 依赖，但成熟度需要验证。
//!
//! 需要支持：NTLMv2、SMB3 加密、访客登录；目录列表一次拿到元数据；
//! 大块 Range 读取（SMB2 READ 单次最大 1~8MB，按协商结果拆分）。
//! 自动发现（mDNS `_smb._tcp`、WS-Discovery、NetBIOS）放在 lekis-core 的发现模块里，不在这里。

use crate::{DirEntry, FileMeta, Vfs, VfsCapabilities, VfsPath};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceKind};
use std::ops::Range;

/// SMB 文件系统（占位）。
pub struct SmbVfs {
    #[allow(dead_code)]
    url: String,
}

impl SmbVfs {
    /// 连接 `smb://host/share`。
    pub fn connect(url: &str, _password: Option<String>) -> Result<Self> {
        if !url.starts_with("smb://") {
            return Err(LekisError::invalid("SMB address must start with smb://"));
        }
        Ok(Self {
            url: url.to_string(),
        })
    }
}

#[async_trait]
impl Vfs for SmbVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Smb
    }

    fn capabilities(&self) -> VfsCapabilities {
        VfsCapabilities {
            writable: true, // 实际值在连接后根据共享权限确定
            watch: false,   // 以后支持 SMB2 CHANGE_NOTIFY
            reliable_dir_mtime: true,
            suggested_concurrency: 8,
        }
    }

    async fn list_dir(&self, _dir: &VfsPath) -> Result<Vec<DirEntry>> {
        Err(LekisError::not_implemented("smb list_dir"))
    }

    async fn stat(&self, _path: &VfsPath) -> Result<FileMeta> {
        Err(LekisError::not_implemented("smb stat"))
    }

    async fn read_range(&self, _path: &VfsPath, _range: Range<u64>) -> Result<Bytes> {
        Err(LekisError::not_implemented("smb read_range"))
    }

    async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
        Err(LekisError::not_implemented("smb write_atomic"))
    }

    async fn create_dir_all(&self, _path: &VfsPath) -> Result<()> {
        Err(LekisError::not_implemented("smb create_dir_all"))
    }
}
