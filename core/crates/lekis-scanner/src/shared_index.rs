//! NAS 共享索引（LIB-05）。
//!
//! 第一台扫完的设备把结果写到 `<共享根目录>/.lekis/index/`，其他设备直接复用，只做 size + mtime 校验。
//!
//! 文件布局：
//! ```text
//! .lekis/
//!   index/
//!     <目录路径的哈希>.cbor.zst   一个目录一个分片
//!   sync/<device_id>/...         同步日志（见 lekis-sync）
//! ```
//!
//! 写入规则：先写临时文件再重命名（`Vfs::write_atomic`）；分片不可变，更新就是整个替换。
//! 共享是只读的（`VfsCapabilities::writable == false`）时，`write_shard` 返回
//! [`ErrorCode::PermissionDenied`]，不静默成功。
//!
//! 编码格式（和 `lekis-sync/src/channel.rs` 一致）：一个 zstd 帧，解压后是首尾相接的 CBOR 对象流
//! `[ShardHeader][ShardEntry][ShardEntry]...`。这样单个坏尾部不会毁掉前面的条目。

use crate::PreviousScan;
use bytes::Bytes;
use lekis_library::ScannedTags;
use lekis_types::{now_ms, ErrorCode, LekisError, Result};
use lekis_vfs::{EntryKind, Vfs, VfsPath};
use serde::{Deserialize, Serialize};
#[cfg(test)]
use std::collections::HashMap;

/// 共享目录名。
pub const SHARED_DIR: &str = ".lekis";
/// 索引子目录。
pub const INDEX_DIR: &str = "index";
/// 分片格式版本。格式不兼容地变化时 +1，读取方遇到更高版本就忽略这个分片。
pub const FORMAT_VERSION: u16 = 1;
/// zstd 压缩级别。索引是元数据，压得快比压得小重要。
const COMPRESSION_LEVEL: i32 = 3;
/// 分片文件后缀。
const SHARD_SUFFIX: &str = ".cbor.zst";

/// 分片文件头。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShardEntry {
    /// 文件名（不含目录）。
    pub name: String,
    /// 大小。
    pub size: u64,
    /// 修改时间。
    pub mtime_ms: i64,
    /// 解析好的标签（结构见 [`tags_blob`]）。
    pub tags_blob: Vec<u8>,
    /// 内嵌封面的内容哈希（有的话）。
    pub artwork_hash: Option<String>,
}

/// 某个目录对应的分片文件路径。
pub fn shard_path(dir: &VfsPath) -> VfsPath {
    VfsPath::root()
        .join(SHARED_DIR)
        .join(INDEX_DIR)
        .join(&format!("{:016x}{SHARD_SUFFIX}", fnv1a(dir.as_str())))
}

/// 共享索引目录（`.lekis/index`）。
pub fn index_dir() -> VfsPath {
    VfsPath::root().join(SHARED_DIR).join(INDEX_DIR)
}

/// FNV-1a 64，和 `TrackUid` 用的是同一个算法；只用于生成文件名。
fn fnv1a(s: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in s.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// 把标签编码成 [`ShardEntry::tags_blob`]（CBOR）。
pub fn tags_blob(tags: &ScannedTags) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    ciborium::ser::into_writer(tags, &mut out)
        .map_err(|e| LekisError::internal(format!("encode tags: {e}")))?;
    Ok(out)
}

/// 从 [`ShardEntry::tags_blob`] 解出标签。
pub fn tags_from_blob(blob: &[u8]) -> Result<ScannedTags> {
    if blob.is_empty() {
        return Ok(ScannedTags::default());
    }
    ciborium::de::from_reader(blob).map_err(|e| {
        LekisError::new(
            ErrorCode::Decode,
            format!("shared index tags blob is corrupt: {e}"),
        )
    })
}

/// 写一个目录分片（分片不可变，整片替换）。
///
/// 只读共享返回 [`ErrorCode::PermissionDenied`]。
pub async fn write_shard(
    vfs: &dyn Vfs,
    header: &ShardHeader,
    entries: &[ShardEntry],
) -> Result<()> {
    if !vfs.capabilities().writable {
        return Err(LekisError::new(
            ErrorCode::PermissionDenied,
            format!(
                "shared index is read-only, cannot write shard for {:?}",
                header.dir
            ),
        ));
    }
    let dir = VfsPath::parse(&header.dir)
        .ok_or_else(|| LekisError::invalid(format!("invalid shard dir: {:?}", header.dir)))?;
    let path = shard_path(&dir);
    if let Some(parent) = path.parent() {
        vfs.create_dir_all(&parent).await?;
    }
    let encoded = encode_shard(header, entries)?;
    vfs.write_atomic(&path, Bytes::from(encoded)).await?;
    tracing::debug!(
        target: "scanner::shared_index",
        path = %path,
        entries = entries.len(),
        "wrote shared index shard"
    );
    Ok(())
}

/// 读一个目录分片；不存在返回 `Ok(None)`；格式版本更高或解析失败返回 `Ok(None)` 并 warn。
pub async fn read_shard(
    vfs: &dyn Vfs,
    dir: &VfsPath,
) -> Result<Option<(ShardHeader, Vec<ShardEntry>)>> {
    read_shard_file(vfs, &shard_path(dir)).await
}

/// 读一个分片文件（[`load_previous_scan`] 要遍历目录，所以按路径读）。
async fn read_shard_file(
    vfs: &dyn Vfs,
    path: &VfsPath,
) -> Result<Option<(ShardHeader, Vec<ShardEntry>)>> {
    let size = match vfs.stat(path).await {
        Ok(meta) => meta.size,
        Err(e) if e.code == ErrorCode::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    if size == 0 {
        tracing::warn!(target: "scanner::shared_index", path = %path, "empty shard");
        return Ok(None);
    }
    let raw = vfs.read_range(path, 0..size).await?;
    match decode_shard(&raw) {
        Ok(Some((header, entries))) => {
            if header.format_version > FORMAT_VERSION {
                tracing::debug!(
                    target: "scanner::shared_index",
                    path = %path,
                    version = header.format_version,
                    supported = FORMAT_VERSION,
                    "skipping shard written by a newer format version"
                );
                return Ok(None);
            }
            Ok(Some((header, entries)))
        }
        Ok(None) => {
            tracing::warn!(
                target: "scanner::shared_index",
                path = %path,
                "shard is corrupt, ignoring it"
            );
            Ok(None)
        }
        Err(e) => {
            tracing::warn!(
                target: "scanner::shared_index",
                path = %path,
                error = %e,
                "cannot decode shard, ignoring it"
            );
            Ok(None)
        }
    }
}

/// 从共享索引重建一份 [`PreviousScan`]（扫 `.lekis/index/*.cbor.zst`，跳过版本不匹配的）。
///
/// 一个分片都读不出来时返回 `Ok(None)`（共享索引不存在或全部损坏都算"没有上一次扫描"）。
pub async fn load_previous_scan(vfs: &dyn Vfs) -> Result<Option<PreviousScan>> {
    let index = index_dir();
    let entries = match vfs.list_dir(&index).await {
        Ok(entries) => entries,
        Err(e) if e.code == ErrorCode::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };

    let mut shards: Vec<VfsPath> = entries
        .into_iter()
        .filter(|e| e.meta.kind == EntryKind::File)
        .filter(|e| {
            e.path
                .file_name()
                .is_some_and(|n| n.ends_with(SHARD_SUFFIX) && !n.starts_with('.'))
        })
        .map(|e| e.path)
        .collect();
    shards.sort_by(|a, b| a.as_str().cmp(b.as_str()));

    let mut previous = PreviousScan::default();
    let mut loaded = 0usize;
    for shard in shards {
        let Some((header, entries)) = read_shard_file(vfs, &shard).await? else {
            continue;
        };
        loaded += 1;
        previous
            .dirs
            .insert(header.dir.clone(), header.dir_mtime_ms);
        let dir = match VfsPath::parse(&header.dir) {
            Some(dir) => dir,
            None => {
                tracing::warn!(
                    target: "scanner::shared_index",
                    dir = %header.dir,
                    "shard header has an invalid dir, skipping its entries"
                );
                continue;
            }
        };
        for entry in entries {
            let path = if dir.is_root() {
                VfsPath::parse(&entry.name)
            } else {
                VfsPath::parse(&format!("{}/{}", dir.as_str(), entry.name))
            };
            let Some(path) = path else {
                tracing::warn!(
                    target: "scanner::shared_index",
                    name = %entry.name,
                    "shard entry has an invalid file name, skipping"
                );
                continue;
            };
            previous
                .files
                .insert(path.as_str().to_string(), (entry.size, entry.mtime_ms));
        }
    }

    if loaded == 0 {
        return Ok(None);
    }
    tracing::debug!(
        target: "scanner::shared_index",
        shards = loaded,
        files = previous.files.len(),
        "loaded previous scan from shared index"
    );
    Ok(Some(previous))
}

/// 把库里的文件按目录分组、写成共享索引分片。
///
/// 返回写成功的分片数。只读共享返回 0（这不是错误：索引是可选的加速手段）。
pub(crate) async fn write_source_index(
    vfs: &dyn Vfs,
    device_id: &str,
    files: &[lekis_library::ScannedFile],
) -> Result<u64> {
    if !vfs.capabilities().writable {
        tracing::debug!(
            target: "scanner::shared_index",
            "shared index is read-only, skipping"
        );
        return Ok(0);
    }
    // 按目录分组（BTreeMap 保证写入顺序稳定）。
    let mut by_dir: std::collections::BTreeMap<String, Vec<ShardEntry>> = Default::default();
    for file in files {
        let path = match VfsPath::parse(&file.path) {
            Some(path) => path,
            None => {
                tracing::warn!(
                    target: "scanner::shared_index",
                    path = %file.path,
                    "file path is not a valid VfsPath, skipping"
                );
                continue;
            }
        };
        let Some(name) = path.file_name().map(str::to_string) else {
            continue;
        };
        let dir = path
            .parent()
            .map(|p| p.as_str().to_string())
            .unwrap_or_default();
        let tags = tags_blob(&file.tags)?;
        by_dir.entry(dir).or_default().push(ShardEntry {
            name,
            size: file.size,
            mtime_ms: file.mtime_ms,
            tags_blob: tags,
            artwork_hash: None,
        });
    }

    let now = now_ms();
    let mut written = 0u64;
    for (dir, mut entries) in by_dir {
        let dir_path = match VfsPath::parse(&dir) {
            Some(p) => p,
            None => continue,
        };
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        // 目录 mtime 只对可靠的协议保留；拿不到就写 0，读取方不会用它剪枝。
        let dir_mtime_ms = match vfs.stat(&dir_path).await {
            Ok(meta) => meta.mtime_ms,
            Err(e) => {
                tracing::debug!(
                    target: "scanner::shared_index",
                    dir = %dir_path,
                    error = %e,
                    "cannot stat directory, writing shard without its mtime"
                );
                0
            }
        };
        let header = ShardHeader {
            format_version: FORMAT_VERSION,
            dir: dir_path.as_str().to_string(),
            dir_mtime_ms,
            written_by: device_id.to_string(),
            written_at_ms: now,
        };
        write_shard(vfs, &header, &entries).await?;
        written += 1;
    }
    tracing::debug!(
        target: "scanner::shared_index",
        shards = written,
        files = files.len(),
        "wrote shared index"
    );
    Ok(written)
}

/// 序列化 + 压缩一个分片。
fn encode_shard(header: &ShardHeader, entries: &[ShardEntry]) -> Result<Vec<u8>> {
    let mut plain = Vec::new();
    ciborium::ser::into_writer(header, &mut plain)
        .map_err(|e| LekisError::internal(format!("encode shard header: {e}")))?;
    for entry in entries {
        ciborium::ser::into_writer(entry, &mut plain)
            .map_err(|e| LekisError::internal(format!("encode shard entry: {e}")))?;
    }
    zstd::stream::encode_all(&plain[..], COMPRESSION_LEVEL)
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("compress shard: {e}")))
}

/// 解压 + 解析一个分片。返回 `Ok(None)` 表示"解不出来/不可用"，不是错误。
///
/// 文件头坏掉就没法判断格式版本，直接放弃整个分片；条目部分在末尾坏掉时保留已解析的部分
/// （和 `lekis-sync` 的日志解析同一个策略：不能因为一条半截记录丢掉整份索引）。
fn decode_shard(raw: &[u8]) -> Result<Option<(ShardHeader, Vec<ShardEntry>)>> {
    let plain = match zstd::stream::decode_all(raw) {
        Ok(plain) => plain,
        Err(e) => {
            tracing::warn!(
                target: "scanner::shared_index",
                error = %e,
                bytes = raw.len(),
                "zstd decode failed"
            );
            return Ok(None);
        }
    };
    let mut rest = &plain[..];
    let header: ShardHeader = match ciborium::de::from_reader(&mut rest) {
        Ok(header) => header,
        Err(e) => {
            tracing::warn!(
                target: "scanner::shared_index",
                error = %e,
                "shard header is corrupt"
            );
            return Ok(None);
        }
    };
    let mut entries = Vec::new();
    while !rest.is_empty() {
        match ciborium::de::from_reader::<ShardEntry, _>(&mut rest) {
            Ok(entry) => entries.push(entry),
            Err(e) => {
                tracing::warn!(
                    target: "scanner::shared_index",
                    error = %e,
                    remaining = rest.len(),
                    kept = entries.len(),
                    "shard entries are truncated, keeping what was decoded"
                );
                break;
            }
        }
    }
    Ok(Some((header, entries)))
}

/// 目录 → 分片条目数（调试用）。
#[cfg(test)]
fn shard_count(entries: &HashMap<String, Vec<ShardEntry>>) -> usize {
    entries.len()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::path::PathBuf;
    use std::sync::Arc;

    /// 每个测试一个临时目录，`Drop` 时删掉。
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let base = std::env::temp_dir().join(format!(
                "lekis-shared-index-{tag}-{}-{:?}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&base).unwrap();
            Self(base)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn sample_tags(title: &str) -> ScannedTags {
        ScannedTags {
            title: title.into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            album_artists: vec!["周杰伦".into()],
            track_no: Some(3),
            disc_no: Some(1),
            year: Some(2003),
            genres: vec!["华语流行".into()],
            duration_ms: 269_000,
            mbid_recording: Some("mbid-1".into()),
            audio: None,
            replaygain: Default::default(),
        }
    }

    fn entry(name: &str, size: u64, mtime_ms: i64) -> ShardEntry {
        ShardEntry {
            name: name.into(),
            size,
            mtime_ms,
            tags_blob: tags_blob(&sample_tags(name)).unwrap(),
            artwork_hash: None,
        }
    }

    /// `LocalVfs` 上真实 roundtrip：写进去再读出来，header / entries 全等。
    #[tokio::test]
    async fn shard_roundtrip_on_local_vfs() {
        let tmp = TempDir::new("roundtrip");
        let vfs = lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap();

        let dir = VfsPath::parse("Music/周杰伦/叶惠美").unwrap();
        let header = ShardHeader {
            format_version: FORMAT_VERSION,
            dir: dir.as_str().to_string(),
            dir_mtime_ms: 1_700_000_000_000,
            written_by: "device-a".into(),
            written_at_ms: 1_700_000_001_000,
        };
        let entries = vec![
            entry("晴天.flac", 12_345, 1_700_000_000),
            entry("以父之名.flac", 22_222, 1_700_000_001),
        ];
        write_shard(&vfs, &header, &entries).await.unwrap();

        // 文件真的落在 .lekis/index/<hash>.cbor.zst
        let expected = shard_path(&dir);
        assert!(expected.as_str().starts_with(".lekis/index/"));
        assert!(expected.as_str().ends_with(".cbor.zst"));
        assert!(
            std::fs::metadata(
                tmp.path().join(
                    expected
                        .as_str()
                        .replace('/', std::path::MAIN_SEPARATOR_STR)
                )
            )
            .unwrap()
            .len()
                > 0
        );

        let (read_header, read_entries) = read_shard(&vfs, &dir).await.unwrap().unwrap();
        assert_eq!(read_header, header);
        assert_eq!(read_entries, entries);
        // tags_blob 是 CBOR 编码的 ScannedTags
        assert_eq!(
            tags_from_blob(&read_entries[0].tags_blob).unwrap(),
            sample_tags("晴天.flac")
        );

        // 分片不可变：整片替换，不是追加
        let replaced = vec![entry("晴天.flac", 1, 2)];
        write_shard(&vfs, &header, &replaced).await.unwrap();
        let (_, after) = read_shard(&vfs, &dir).await.unwrap().unwrap();
        assert_eq!(after, replaced);
    }

    /// 分片不存在 → `Ok(None)`，不是错误。
    #[tokio::test]
    async fn missing_shard_is_none() {
        let tmp = TempDir::new("missing");
        let vfs = lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap();
        let dir = VfsPath::parse("nothing/here").unwrap();
        assert!(read_shard(&vfs, &dir).await.unwrap().is_none());
        assert!(load_previous_scan(&vfs).await.unwrap().is_none());
    }

    /// 只读共享：`write_shard` 必须是 PermissionDenied，不能静默成功。
    #[tokio::test]
    async fn read_only_shared_rejects_writes() {
        use async_trait::async_trait;
        use lekis_types::SourceKind;
        use lekis_vfs::{DirEntry, FileMeta, VfsCapabilities};

        struct ReadOnlyVfs(Arc<lekis_vfs::local::LocalVfs>);

        #[async_trait]
        impl Vfs for ReadOnlyVfs {
            fn kind(&self) -> SourceKind {
                SourceKind::Local
            }

            fn capabilities(&self) -> VfsCapabilities {
                VfsCapabilities {
                    writable: false,
                    watch: false,
                    reliable_dir_mtime: true,
                    suggested_concurrency: 4,
                }
            }

            async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
                self.0.list_dir(dir).await
            }

            async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
                self.0.stat(path).await
            }

            async fn read_range(
                &self,
                path: &VfsPath,
                range: std::ops::Range<u64>,
            ) -> Result<Bytes> {
                self.0.read_range(path, range).await
            }

            async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
                Err(LekisError::new(
                    ErrorCode::PermissionDenied,
                    "read-only test vfs",
                ))
            }

            async fn create_dir_all(&self, _dir: &VfsPath) -> Result<()> {
                Err(LekisError::new(
                    ErrorCode::PermissionDenied,
                    "read-only test vfs",
                ))
            }
        }

        let tmp = TempDir::new("readonly");
        let vfs = ReadOnlyVfs(Arc::new(
            lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap(),
        ));
        let header = ShardHeader {
            format_version: FORMAT_VERSION,
            dir: "Music".into(),
            dir_mtime_ms: 1,
            written_by: "device-a".into(),
            written_at_ms: 1,
        };
        let err = write_shard(&vfs, &header, &[entry("a.flac", 1, 1)])
            .await
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::PermissionDenied);
    }

    /// 损坏的分片返回 `None`，不返回错误（一个坏分片不能中断整次扫描）。
    #[tokio::test]
    async fn corrupt_shard_is_ignored() {
        let tmp = TempDir::new("corrupt");
        let vfs = lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap();
        let dir = VfsPath::parse("Music").unwrap();
        let path = shard_path(&dir);
        let full = tmp
            .path()
            .join(path.as_str().replace('/', std::path::MAIN_SEPARATOR_STR));
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(&full, b"this is not a zstd frame").unwrap();

        assert!(read_shard(&vfs, &dir).await.unwrap().is_none());
        // 索引目录里只有一个坏分片 → 整体也当作"没有上一次扫描"
        assert!(load_previous_scan(&vfs).await.unwrap().is_none());
    }

    /// 版本更高的分片被忽略；`load_previous_scan` 汇总所有分片。
    #[tokio::test]
    async fn load_previous_scan_merges_shards_and_skips_newer_version() {
        let tmp = TempDir::new("load");
        let vfs = lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap();

        let dir_a = VfsPath::parse("Music/AlbumA").unwrap();
        let header_a = ShardHeader {
            format_version: FORMAT_VERSION,
            dir: dir_a.as_str().to_string(),
            dir_mtime_ms: 111,
            written_by: "device-a".into(),
            written_at_ms: 1,
        };
        write_shard(
            &vfs,
            &header_a,
            &[entry("a1.flac", 100, 1000), entry("a2.flac", 200, 2000)],
        )
        .await
        .unwrap();

        let header_root = ShardHeader {
            format_version: FORMAT_VERSION,
            dir: String::new(),
            dir_mtime_ms: 999,
            written_by: "device-a".into(),
            written_at_ms: 1,
        };
        write_shard(&vfs, &header_root, &[entry("root.flac", 300, 3000)])
            .await
            .unwrap();

        // 一份更高版本的分片，必须被跳过
        let dir_new = VfsPath::parse("Music/Newer").unwrap();
        let header_new = ShardHeader {
            format_version: FORMAT_VERSION + 1,
            dir: dir_new.as_str().to_string(),
            dir_mtime_ms: 777,
            written_by: "device-future".into(),
            written_at_ms: 2,
        };
        write_shard(&vfs, &header_new, &[entry("future.flac", 400, 4000)])
            .await
            .unwrap();

        let previous = load_previous_scan(&vfs).await.unwrap().unwrap();
        assert_eq!(previous.files.len(), 3);
        assert_eq!(
            previous.files.get("Music/AlbumA/a1.flac"),
            Some(&(100, 1000))
        );
        assert_eq!(
            previous.files.get("Music/AlbumA/a2.flac"),
            Some(&(200, 2000))
        );
        // 根目录分片的条目不能拼成 "/root.flac"
        assert_eq!(previous.files.get("root.flac"), Some(&(300, 3000)));
        assert!(!previous.files.contains_key("Music/Newer/future.flac"));
        assert_eq!(previous.dirs.get("Music/AlbumA"), Some(&111));
        assert_eq!(previous.dirs.get(""), Some(&999));
        assert!(!previous.dirs.contains_key("Music/Newer"));
    }

    /// `write_source_index` 按目录分组：一个目录一个分片，只读源返回 0。
    #[tokio::test]
    async fn write_source_index_groups_by_directory() {
        use lekis_library::ScannedFile;
        use lekis_types::SourceId;

        let tmp = TempDir::new("write-source");
        let vfs = lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap();

        let files: Vec<ScannedFile> = vec![
            ScannedFile {
                source_id: SourceId(1),
                path: "Music/A/one.flac".into(),
                size: 10,
                mtime_ms: 100,
                tags: sample_tags("one"),
            },
            ScannedFile {
                source_id: SourceId(1),
                path: "Music/A/two.flac".into(),
                size: 20,
                mtime_ms: 200,
                tags: sample_tags("two"),
            },
            ScannedFile {
                source_id: SourceId(1),
                path: "Music/B/three.flac".into(),
                size: 30,
                mtime_ms: 300,
                tags: sample_tags("three"),
            },
            ScannedFile {
                source_id: SourceId(1),
                path: "root.flac".into(),
                size: 40,
                mtime_ms: 400,
                tags: sample_tags("root"),
            },
        ];

        let written = write_source_index(&vfs, "device-test", &files)
            .await
            .unwrap();
        assert_eq!(written, 3); // Music/A、Music/B、根目录

        let previous = load_previous_scan(&vfs).await.unwrap().unwrap();
        assert_eq!(previous.files.len(), 4);
        assert_eq!(previous.files.get("Music/A/one.flac"), Some(&(10, 100)));
        assert_eq!(previous.files.get("root.flac"), Some(&(40, 400)));

        // 分片里保留了标签，别的设备可以直接用，不用再读文件
        let dir = VfsPath::parse("Music/A").unwrap();
        let (header, entries) = read_shard(&vfs, &dir).await.unwrap().unwrap();
        assert_eq!(header.written_by, "device-test");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "one.flac");
        let tags = tags_from_blob(&entries[0].tags_blob).unwrap();
        assert_eq!(tags.title, "one");
        assert_eq!(tags.album.as_deref(), Some("叶惠美"));

        struct NoWriteVfs(Arc<lekis_vfs::local::LocalVfs>);
        use async_trait::async_trait;
        use lekis_types::SourceKind;
        use lekis_vfs::{DirEntry, FileMeta, VfsCapabilities};
        #[async_trait]
        impl Vfs for NoWriteVfs {
            fn kind(&self) -> SourceKind {
                SourceKind::Local
            }
            fn capabilities(&self) -> VfsCapabilities {
                VfsCapabilities {
                    writable: false,
                    watch: false,
                    reliable_dir_mtime: true,
                    suggested_concurrency: 2,
                }
            }
            async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
                self.0.list_dir(dir).await
            }
            async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
                self.0.stat(path).await
            }
            async fn read_range(
                &self,
                path: &VfsPath,
                range: std::ops::Range<u64>,
            ) -> Result<Bytes> {
                self.0.read_range(path, range).await
            }
            async fn write_atomic(&self, _p: &VfsPath, _d: Bytes) -> Result<()> {
                Err(LekisError::new(ErrorCode::PermissionDenied, "read-only"))
            }
            async fn create_dir_all(&self, _d: &VfsPath) -> Result<()> {
                Err(LekisError::new(ErrorCode::PermissionDenied, "read-only"))
            }
        }
        let ro = NoWriteVfs(Arc::new(
            lekis_vfs::local::LocalVfs::new(tmp.path()).unwrap(),
        ));
        assert_eq!(write_source_index(&ro, "d", &files).await.unwrap(), 0);
    }

    /// `shard_path` 对同一个目录稳定、对不同目录不同，并且哈希是 FNV-1a。
    #[test]
    fn shard_path_is_stable() {
        let a = shard_path(&VfsPath::parse("Music/A").unwrap());
        let b = shard_path(&VfsPath::parse("Music/A").unwrap());
        let c = shard_path(&VfsPath::parse("Music/B").unwrap());
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(fnv1a(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(shard_count(&HashMap::new()), 0);
    }
}
