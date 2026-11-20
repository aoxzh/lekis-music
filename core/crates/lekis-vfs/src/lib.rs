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

pub mod failover;
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
///
/// 用户名可以写在地址里（`smb://ao@nas/music`），也可以放在 `options["username"]`
/// （UI 推荐这样做：地址里不放任何凭据，密码按 `credential_ref` 存进钥匙串）。
/// 地址里已经带用户名时以地址为准。
pub fn open(config: &SourceConfig, password: Option<String>) -> Result<Arc<dyn Vfs>> {
    if config.addresses.is_empty() {
        return Err(LekisError::invalid("source has no address"));
    }
    let mut backends: Vec<Arc<dyn Vfs>> = Vec::new();
    let mut last_error = None;
    for raw in &config.addresses {
        let address = with_username(raw, config.options.get("username").map(String::as_str));
        match build_backend(config, &address, password.clone()) {
            Ok(vfs) => backends.push(vfs),
            Err(e) => last_error = Some(e),
        }
    }
    if backends.is_empty() {
        return Err(
            last_error.unwrap_or_else(|| LekisError::invalid("source has no usable address"))
        );
    }
    if backends.len() == 1 {
        return Ok(backends.remove(0));
    }
    Ok(Arc::new(failover::FailoverVfs::new(backends)?))
}

fn build_backend(
    config: &SourceConfig,
    address: &str,
    password: Option<String>,
) -> Result<Arc<dyn Vfs>> {
    let vfs: Arc<dyn Vfs> = match config.kind {
        SourceKind::Local => Arc::new(local::LocalVfs::new(address)?),
        SourceKind::Smb => Arc::new(smb::SmbVfs::connect(address, password)?),
        SourceKind::WebDav => Arc::new(webdav::WebDavVfs::new(address, password)?),
        SourceKind::Nfs => Arc::new(nfs::NfsVfs::connect(address)?),
        SourceKind::Sftp => {
            // `options["auth"] = "key"`：凭据库里存的是私钥本身，不是密码。
            let inline_key = config
                .options
                .get(sftp::AUTH_OPTION)
                .is_some_and(|v| v.trim() == sftp::AUTH_KEY);
            Arc::new(sftp::SftpVfs::connect_with(address, password, inline_key)?)
        }
        other => {
            return Err(LekisError::invalid(format!(
                "source kind {other:?} is not a filesystem source"
            )))
        }
    };
    Ok(vfs)
}

/// 服务器上的一个共享（SMB）或导出（NFS）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareInfo {
    /// 共享名（SMB）或导出路径（NFS，形如 `/volume1/music`）。
    pub name: String,
    /// 服务器给的备注，没有时为空串。
    pub comment: String,
}

/// 列出服务器上的共享 / 导出，用于「添加音源」时让用户点选，不用手打共享名。
///
/// 只看 `config.addresses` 的第一个地址的主机部分：SMB 地址可以不带共享名
/// （`smb://nas`），NFS 地址可以不带导出路径（`nfs://nas`）。其他类型返回 `Unsupported`。
pub async fn list_shares(config: &SourceConfig, password: Option<String>) -> Result<Vec<ShareInfo>> {
    let raw = config
        .addresses
        .first()
        .ok_or_else(|| LekisError::invalid("source has no address"))?;
    let address = with_username(raw, config.options.get("username").map(String::as_str));
    let mut shares = match config.kind {
        SourceKind::Smb => smb::list_shares(&address, password).await?,
        SourceKind::Nfs => nfs::list_exports(&address).await?,
        other => {
            return Err(LekisError::new(
                lekis_types::ErrorCode::Unsupported,
                format!("source kind {other:?} has no share list"),
            ))
        }
    };
    shares.sort_by_key(|s| s.name.to_lowercase());
    shares.dedup_by(|a, b| a.name == b.name);
    Ok(shares)
}

/// 地址里没有用户名、而选项里给了用户名时，把用户名补进 URL 的 userinfo。
///
/// 只处理带 `scheme://` 的 URL（本地路径原样返回），用户名按 URL 规则百分号编码。
fn with_username(address: &str, username: Option<&str>) -> String {
    let Some(user) = username.map(str::trim).filter(|u| !u.is_empty()) else {
        return address.to_string();
    };
    if !address.contains("://") {
        return address.to_string();
    }
    match url::Url::parse(address) {
        Ok(mut parsed) if parsed.username().is_empty() => {
            if parsed.set_username(user).is_ok() {
                parsed.to_string()
            } else {
                address.to_string()
            }
        }
        _ => address.to_string(),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod open_tests {
    use super::with_username;

    #[test]
    fn username_option_fills_missing_userinfo_only() {
        assert_eq!(
            with_username("smb://nas/music", Some("ao")),
            "smb://ao@nas/music"
        );
        assert_eq!(
            with_username("smb://me@nas/music", Some("ao")),
            "smb://me@nas/music"
        );
        assert_eq!(
            with_username("https://nas:5006/dav", Some("a b")),
            "https://a%20b@nas:5006/dav"
        );
        assert_eq!(with_username("smb://nas/music", None), "smb://nas/music");
        assert_eq!(
            with_username("smb://nas/music", Some("  ")),
            "smb://nas/music"
        );
        assert_eq!(with_username("C:\\Music", Some("ao")), "C:\\Music");
    }
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
