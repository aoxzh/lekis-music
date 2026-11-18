//! 虚拟文件系统。
//!
//! 扫描器、播放器、共享索引、同步都只通过 [`Vfs`] trait 访问文件，不关心底层是本地磁盘还是 NAS。
//!
//! 设计要点：
//! - **按范围读取**（[`Vfs::read_range`]）是一等公民：扫描只读文件头尾（见 [`partial`]），
//!   播放用 Range 分块读取，避免把整个文件拉下来。
//! - 路径统一用 [`VfsPath`]：相对于源根目录、用 `/` 分隔，和操作系统无关。
//! - 写入只用于 `.lekis/` 目录（共享索引、同步日志），并且要能在只读共享上降级
//!   （[`VfsCapabilities::writable`]）。

pub mod local;
pub mod nfs;
pub mod partial;
pub mod path;
pub mod sftp;
pub mod smb;
pub mod webdav;

use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{LekisError, Result, SourceConfig, SourceKind};
use std::ops::Range;
use std::sync::Arc;

pub use path::VfsPath;

/// 目录项类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    /// 文件。
    File,
    /// 目录。
    Dir,
    /// 其他（符号链接、设备文件……扫描时跳过）。
    Other,
}

/// 文件 / 目录元数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileMeta {
    /// 类型。
    pub kind: EntryKind,
    /// 大小（字节）。目录为 0。
    pub size: u64,
    /// 修改时间（Unix 毫秒）。拿不到时为 0。
    pub mtime_ms: i64,
}

/// 一个目录项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    /// 完整路径。
    pub path: VfsPath,
    /// 元数据（大多数协议在列目录时就能拿到，避免再逐个 `stat`）。
    pub meta: FileMeta,
}

/// 文件系统能力。扫描器和同步模块据此选择策略。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VfsCapabilities {
    /// 能否写入（只读共享上要禁用共享索引和同步目录）。
    pub writable: bool,
    /// 能否监听变化（本地 inotify / ReadDirectoryChangesW，SMB2 CHANGE_NOTIFY）。
    pub watch: bool,
    /// 目录的 mtime 在增删文件时是否可靠地变化（用于增量扫描剪枝）。
    pub reliable_dir_mtime: bool,
    /// 建议的并发请求数。
    pub suggested_concurrency: usize,
}

/// 统一的文件系统接口。
#[async_trait]
pub trait Vfs: Send + Sync {
    /// 源类型。
    fn kind(&self) -> SourceKind;

    /// 能力。
    fn capabilities(&self) -> VfsCapabilities;

    /// 列出目录（不递归）。
    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>>;

    /// 获取元数据。
    async fn stat(&self, path: &VfsPath) -> Result<FileMeta>;

    /// 读取 `range` 范围内的字节。超出文件末尾的部分会被截断。
    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes>;

    /// 原子地写入整个文件（先写临时文件再重命名）。只用于 `.lekis/` 目录。
    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()>;

    /// 创建目录（含父目录）。
    async fn create_dir_all(&self, path: &VfsPath) -> Result<()>;
}

/// 根据音源配置创建对应的文件系统实现。
///
/// `password` 由调用方（lekis-core）从系统钥匙串里取出后传进来，VFS 不负责凭据存储。
pub fn open(config: &SourceConfig, password: Option<String>) -> Result<Arc<dyn Vfs>> {
    let address = config
        .addresses
        .first()
        .ok_or_else(|| LekisError::invalid("source has no address"))?;
    let vfs: Arc<dyn Vfs> = match config.kind {
        SourceKind::Local => Arc::new(local::LocalVfs::new(address)?),
        SourceKind::Smb => Arc::new(smb::SmbVfs::connect(address, password)?),
        SourceKind::WebDav => Arc::new(webdav::WebDavVfs::new(address, password)?),
        SourceKind::Nfs => Arc::new(nfs::NfsVfs::connect(address)?),
        SourceKind::Sftp => Arc::new(sftp::SftpVfs::connect(address, password)?),
        other => {
            return Err(LekisError::invalid(format!(
                "source kind {other:?} is not a filesystem source"
            )))
        }
    };
    Ok(vfs)
}

/// 支持的音频文件扩展名（小写）。扫描器只处理这些文件。
pub const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "ogg", "oga", "opus", "ape",
    "wv", "tta", "dsf", "dff", "mka", "cue",
];

/// 判断路径是不是音频文件。
pub fn is_audio_file(path: &VfsPath) -> bool {
    path.extension()
        .map(|ext| AUDIO_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}
