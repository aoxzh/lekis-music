//! NAS 共享索引（LIB-05，ADR-0004）。
//!
//! 第一台扫完的设备把结果写到 `<共享根目录>/.lekis/index/`，其他设备直接复用，只做 size + mtime 校验。
//!
//! 文件布局：
//! ```text
//! .lekis/
//!   index/
//!     manifest.cbor.zst          全部分片的列表（目录 → 分片文件名 + 目录 mtime）
//!     <目录路径的哈希>.cbor.zst   一个目录一个分片
//!   sync/<device_id>/...         同步日志（见 lekis-sync）
//! ```
//!
//! 写入规则：先写临时文件再重命名（`Vfs::write_atomic`）；分片不可变，更新就是整个替换。
//! 共享是只读的（`VfsCapabilities::writable == false`）时，跳过写入。
//!
//! TODO：编码用 ciborium + zstd（workspace 里已选型，见 core/Cargo.toml）。

use lekis_vfs::VfsPath;

/// 共享目录名。
pub const SHARED_DIR: &str = ".lekis";
/// 索引子目录。
pub const INDEX_DIR: &str = "index";
/// 分片格式版本。格式不兼容地变化时 +1，读取方遇到更高版本就忽略这个分片。
pub const FORMAT_VERSION: u16 = 1;

/// 分片文件头。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShardHeader {
    /// 格式版本。
    pub format_version: u16,
    /// 这个分片对应的目录。
    pub dir: String,
    /// 写入时目录的 mtime。
    pub dir_mtime_ms: i64,
    /// 写入设备。
    pub written_by: String,
    /// 写入时间。
    pub written_at_ms: i64,
}

/// 分片里的一个文件条目。
#[derive(Debug, Clone, PartialEq)]
pub struct ShardEntry {
    /// 文件名（不含目录）。
    pub name: String,
    /// 大小。
    pub size: u64,
    /// 修改时间。
    pub mtime_ms: i64,
    /// 解析好的标签（以后改成可序列化的结构）。
    pub tags_blob: Vec<u8>,
    /// 内嵌封面的内容哈希（有的话）。
    pub artwork_hash: Option<String>,
}

/// 某个目录对应的分片文件路径。
pub fn shard_path(dir: &VfsPath) -> VfsPath {
    // FNV-1a，和 TrackUid 用的是同一个算法；只用于生成文件名，不要求跨版本稳定以外的任何性质。
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in dir.as_str().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    VfsPath::root()
        .join(SHARED_DIR)
        .join(INDEX_DIR)
        .join(&format!("{hash:016x}.cbor.zst"))
}
