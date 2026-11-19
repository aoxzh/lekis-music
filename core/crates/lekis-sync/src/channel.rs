//! 同步通道（SYN-02~05）。
//!
//! | 通道 | 说明 | 阶段 |
//! |---|---|---|
//! | NAS 同步目录 | `.lekis/sync/<device_id>/<日期>.log.zst`，每台设备只写自己的目录 | Beta |
//! | 局域网 P2P | mDNS 发现 + 扫码配对 + 端到端加密 | 1.x |
//! | Headless 节点 | 节点作为同步中枢 | 1.0 |
//! | 用户云盘 | iCloud / OneDrive / Google Drive 上的文件夹 | 1.x |
//!
//! # NAS 同步目录通道
//!
//! 所有设备共享一个目录（NAS、移动硬盘、云盘同步文件夹都行），每台设备**只往自己的目录追加**，
//! 所以不存在写冲突：谁的时间线谁负责。读取方扫所有设备目录，按 HLC 过滤出没见过的操作。
//!
//! ## 文件布局
//!
//! ```text
//! <共享根目录>/
//!   .lekis/
//!     sync/
//!       <device_id>/                 # 一台设备一个目录，只有该设备会写
//!         20260101.log.zst           # 按天切分，文件名是写入当天的 UTC 日期
//!         20260102.log.zst
//!       <另一个 device_id>/
//!         20260101.log.zst
//! ```
//!
//! 目录名就是设备 ID（同时是 [`Hlc::device`] 的值），文件按文件名（即日期）字典序排列——
//! 字典序同时就是时间序。写入先写临时文件再重命名（[`Vfs::write_atomic`]），
//! 所以读者不会看到写了一半的文件。
//!
//! ## 文件格式（`*.log.zst`）
//!
//! 一个 zstd 帧，解压后是一串**首尾相接的 CBOR 对象**（不是 CBOR 数组、没有分隔符）：
//!
//! ```text
//! [SyncLogHeader] [SyncOp] [SyncOp] ...
//! ```
//!
//! - 第一个对象固定是 [`SyncLogHeader`]：格式版本、写它的设备、文件创建时间；
//! - 之后是一条接一条的 [`SyncOp`]，直接 CBOR 序列化（不需要额外的长度前缀：
//!   CBOR 对象自带长度，按对象边界连续读就行），读到字节流结束为止；
//! - `format_version` 比本机 [`FORMAT_VERSION`] 高的文件**直接忽略**（前向兼容：
//!   新版本设备写的日志，旧版本读不懂，但也不能因此报错）；
//! - 单个文件损坏（zstd 解不开、CBOR 头部坏）只跳过这个文件并 `warn`，不影响其它设备/其它日期。
//!
//! 追加写 = 读当天文件 → 解压 → 解析出已有操作 → 加上新操作 → 重新压缩 → 原子替换整个文件。
//! 因此当天文件每次 push 都要重写一遍（`O(n²)` 的天级开销），对个人库（每天几千条操作）无所谓；
//! 操作量真的上来以后再做分段追加或快照归档（见文末 TODO）。
//!
//! ## 端到端加密（未实现，只留接口）
//!
//! NAS 目录可能被别人看到（云盘、共享盘），所以最终要支持可选加密：
//!
//! - 算法：XChaCha20-Poly1305 AEAD（24 字节随机 nonce 放在文件开头，密文即上面那串 CBOR 字节，
//!   AAD 用文件头里的 `device_id` + `format_version` 防跨设备重放）；
//! - 密钥：用户口令经 Argon2id 派生，不进日志、不上传；
//! - 加密顺序：CBOR → zstd 压缩 → 加密（加密后的字节不可压缩，压缩必须在内层）；
//! - 文件扩展名：`.log.enc.zst`。这个后缀**不**匹配 [`LOG_SUFFIX`]，所以现在没有密钥的
//!   读取方会自然跳过加密文件；
//! - 代价：需要新加依赖（`chacha20poly1305`、`argon2`），且密钥管理要接到系统钥匙串上。
//!
//! 这里**没有**实现加密，只是把命名/后缀/文档接口先定下来，避免以后改文件布局。
//!
//! TODO(SYN-05)：超过阈值（比如 30 天或 2 MB）后生成快照（物化后的全部字段状态），旧日志归档删除。
//! TODO(SYN-07)：可选端到端加密（见上）。

use crate::{Hlc, SyncOp};
use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result};
use lekis_vfs::{EntryKind, Vfs, VfsPath};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// `.lekis` 共享目录名（和共享索引用的是同一个，见 `lekis_scanner::shared_index`）。
pub const SHARED_DIR: &str = ".lekis";
/// 同步日志子目录。
pub const SYNC_DIR: &str = "sync";
/// 日志格式版本。格式不兼容地变化时 +1；读到更高版本的文件就忽略。
pub const FORMAT_VERSION: u16 = 1;
/// 明文日志文件的后缀。
pub const LOG_SUFFIX: &str = ".log.zst";
/// 加密日志文件的后缀（尚未实现，见模块文档）。
pub const ENCRYPTED_LOG_SUFFIX: &str = ".log.enc.zst";
/// zstd 压缩级别。日志是文本型 CBOR，级别 3 已经能压到很小，再高不值得多花 CPU。
pub const COMPRESSION_LEVEL: i32 = 3;

/// 同步通道。
#[async_trait]
pub trait SyncChannel: Send + Sync {
    /// 通道名称（同时用作 `sync_cursor` 表的键）。
    fn name(&self) -> &str;

    /// 推送本机的操作。
    async fn push(&self, ops: &[SyncOp]) -> Result<()>;

    /// 拉取其他设备在 `since`（按设备分别记录）之后的操作。
    async fn pull(&self, since: &[(String, Hlc)]) -> Result<Vec<SyncOp>>;

    /// 列出这个通道上出现过的设备 ID（含本机）。
    ///
    /// 调用方用它来查"每个远端设备读到哪了"，所以在实现不了的时候返回空是允许的 ——
    /// 那只是意味着每次都从头读，不丢数据。
    async fn devices(&self) -> Result<Vec<String>> {
        Ok(Vec::new())
    }
}

/// 日志文件头（每个 `*.log.zst` 的第一个 CBOR 对象）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncLogHeader {
    /// 格式版本，见 [`FORMAT_VERSION`]。
    pub format_version: u16,
    /// 写这个日志的设备 ID。
    pub device_id: String,
    /// 文件创建时间（Unix 毫秒）。后续追加时保持不变。
    pub created_at_ms: i64,
}

/// 某个设备的日志目录（`.lekis/sync/<device_id>`）。
///
/// `device_id` 会直接变成目录名，所以要挡住跳出 `.lekis/sync/` 的写法：为空、以 `.` 开头
/// （点开头的目录在 [`NasFolderChannel::pull`] 里被当作预留目录跳过）、含路径分隔符、
/// 含 `..`，或者会被 [`VfsPath::parse`] 规范化成别的样子时返回 `None`。
pub fn device_log_dir(device_id: &str) -> Option<VfsPath> {
    if device_id.is_empty()
        || device_id.starts_with('.')
        || device_id.contains('/')
        || device_id.contains('\\')
    {
        return None;
    }
    let parsed = VfsPath::parse(device_id)?;
    if parsed.is_root() || parsed.as_str() != device_id {
        return None;
    }
    Some(
        VfsPath::root()
            .join(SHARED_DIR)
            .join(SYNC_DIR)
            .join(device_id),
    )
}

/// 同步日志根目录（`.lekis/sync`）。
fn sync_root() -> VfsPath {
    VfsPath::root().join(SHARED_DIR).join(SYNC_DIR)
}

/// NAS 同步目录通道。
///
/// 只通过 [`Vfs`] 访问文件，所以本地目录、SMB、WebDAV、NFS 上的 `.lekis/sync/` 都能用。
pub struct NasFolderChannel {
    /// 共享根目录所在的文件系统。
    root: Arc<dyn Vfs>,
    /// 本机设备 ID，同时也是本机日志目录名。
    device_id: String,
}

impl NasFolderChannel {
    /// 在共享根目录 `root` 上创建通道，本机以 `device_id` 身份写入。
    pub fn new(root: Arc<dyn Vfs>, device_id: impl Into<String>) -> Self {
        Self {
            root,
            device_id: device_id.into(),
        }
    }

    /// 本机设备 ID。
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    /// 本机的日志目录。
    fn own_dir(&self) -> Result<VfsPath> {
        device_log_dir(&self.device_id).ok_or_else(|| {
            LekisError::invalid(format!("invalid sync device id: {:?}", self.device_id))
        })
    }
}

#[async_trait]
impl SyncChannel for NasFolderChannel {
    fn name(&self) -> &str {
        "nas-folder"
    }

    async fn push(&self, ops: &[SyncOp]) -> Result<()> {
        if !self.root.capabilities().writable {
            return Err(LekisError::new(
                ErrorCode::PermissionDenied,
                format!(
                    "sync channel is read-only (device {}): 共享目录不可写，跳过同步日志写入",
                    self.device_id
                ),
            ));
        }
        if ops.is_empty() {
            return Ok(());
        }

        let dir = self.own_dir()?;
        self.root.create_dir_all(&dir).await?;

        let now = now_ms();
        let path = dir.join(&day_log_name(now));

        // 先读当天已有的日志，再整体重写。只有本机目录会走到这里，不存在并发写同一个文件。
        let loaded = load_log(self.root.as_ref(), &path).await?;
        let (header, mut accumulated) = match loaded {
            Some(loaded) if loaded.header.format_version > FORMAT_VERSION => {
                // 本机目录里是更新版本写的日志：多半是升级后又降级运行。直接覆盖会丢数据。
                tracing::error!(
                    path = %path,
                    version = loaded.header.format_version,
                    supported = FORMAT_VERSION,
                    "本机同步日志来自更新的格式版本，拒绝覆盖",
                );
                return Err(LekisError::new(
                    ErrorCode::Unsupported,
                    format!(
                        "sync log {} uses format version {} (this build supports {}); \
                         请升级客户端，降级运行会丢失数据",
                        path, loaded.header.format_version, FORMAT_VERSION
                    ),
                ));
            }
            Some(loaded) => {
                if loaded.truncated {
                    tracing::warn!(
                        path = %path,
                        kept = loaded.ops.len(),
                        "本机同步日志末尾已损坏，重写时会丢弃损坏部分",
                    );
                }
                if loaded.header.device_id != self.device_id {
                    tracing::warn!(
                        path = %path,
                        found = %loaded.header.device_id,
                        expected = %self.device_id,
                        "本机目录里出现了别的设备 ID 写的日志，继续追加",
                    );
                }
                (loaded.header, loaded.ops)
            }
            None => (new_header(&self.device_id, now), Vec::new()),
        };

        accumulated.extend_from_slice(ops);
        let encoded = encode_log(&header, &accumulated)?;
        self.root.write_atomic(&path, Bytes::from(encoded)).await?;

        tracing::debug!(
            path = %path,
            appended = ops.len(),
            total = accumulated.len(),
            "同步日志已更新",
        );
        Ok(())
    }

    async fn devices(&self) -> Result<Vec<String>> {
        let root = sync_root();
        let entries = match self.root.list_dir(&root).await {
            Ok(entries) => entries,
            Err(e) if e.code == ErrorCode::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        Ok(entries
            .into_iter()
            .filter(|e| e.meta.kind == EntryKind::Dir)
            .filter_map(|e| e.path.file_name().map(str::to_string))
            .filter(|name| !name.starts_with('.'))
            .collect())
    }

    async fn pull(&self, since: &[(String, Hlc)]) -> Result<Vec<SyncOp>> {
        let root = sync_root();
        let devices = match self.root.list_dir(&root).await {
            Ok(entries) => entries,
            // 还没人写过任何同步日志：空的，不是错误。
            Err(e) if e.code == ErrorCode::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };

        let mut out = Vec::new();
        for entry in devices {
            if entry.meta.kind != EntryKind::Dir {
                continue;
            }
            let Some(name) = entry.path.file_name() else {
                continue;
            };
            let device = name.to_string();
            // 只读别人的目录：自己的操作本地数据库里已经有了。
            if device == self.device_id {
                continue;
            }
            // 跳过隐藏目录（将来放锁文件/快照索引之类）。
            if device.starts_with('.') {
                continue;
            }
            let cursor = since.iter().find(|(d, _)| d == &device).map(|(_, hlc)| hlc);

            let files = match self.root.list_dir(&entry.path).await {
                Ok(files) => files,
                Err(e) => {
                    tracing::warn!(device = %device, error = %e, "列出设备同步目录失败，跳过");
                    continue;
                }
            };
            let mut logs: Vec<_> = files
                .into_iter()
                .filter(|f| {
                    f.meta.kind == EntryKind::File
                        && f.path.file_name().is_some_and(|n| n.ends_with(LOG_SUFFIX))
                })
                .collect();
            // 文件名就是日期，字典序即时间序；排序只为可读性和稳定行为，最终结果仍按 HLC 排。
            logs.sort_by(|a, b| a.path.as_str().cmp(b.path.as_str()));

            for log in logs {
                let loaded = match load_log(self.root.as_ref(), &log.path).await {
                    Ok(Some(loaded)) => loaded,
                    Ok(None) => continue,
                    Err(e) => {
                        // 单个文件坏掉不影响整体同步：跳过它，下次 push 会重写自己的日志。
                        tracing::warn!(
                            path = %log.path,
                            error = %e,
                            "同步日志损坏，跳过",
                        );
                        continue;
                    }
                };
                if loaded.header.format_version > FORMAT_VERSION {
                    tracing::debug!(
                        path = %log.path,
                        version = loaded.header.format_version,
                        "跳过更高格式版本的同步日志",
                    );
                    continue;
                }
                if loaded.truncated {
                    tracing::warn!(
                        path = %log.path,
                        kept = loaded.ops.len(),
                        "同步日志末尾损坏，只采用已解析的部分",
                    );
                }
                out.extend(loaded.ops.into_iter().filter(|op| match cursor {
                    Some(cursor) => op.hlc > *cursor,
                    None => true,
                }));
            }
        }

        // 调用方按顺序应用到数据库；这里给出全文一致的 HLC 顺序。
        out.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        Ok(out)
    }
}

/// 一个解析好的日志文件。
struct LoadedLog {
    /// 文件头。
    header: SyncLogHeader,
    /// 解析出来的操作（可能因为末尾损坏而少于文件中实际写入的条数）。
    ops: Vec<SyncOp>,
    /// 末尾是否有损坏/截断，导致有操作被丢弃。
    truncated: bool,
}

/// 读并解析一个日志文件。文件不存在返回 `Ok(None)`。
async fn load_log(root: &dyn Vfs, path: &VfsPath) -> Result<Option<LoadedLog>> {
    let size = match root.stat(path).await {
        Ok(meta) => meta.size,
        Err(e) if e.code == ErrorCode::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    if size == 0 {
        return Err(LekisError::new(
            ErrorCode::Decode,
            format!("empty sync log: {path}"),
        ));
    }
    let raw = root.read_range(path, 0..size).await?;
    let plain = zstd::stream::decode_all(&raw[..]).map_err(|e| {
        LekisError::new(
            ErrorCode::Decode,
            format!("zstd decode failed ({path}): {e}"),
        )
    })?;
    let (header, ops, truncated) = parse_log(&plain)?;
    Ok(Some(LoadedLog {
        header,
        ops,
        truncated,
    }))
}

/// 解析解压后的 CBOR 字节流：先文件头，再连续的操作。
///
/// 文件头坏了是硬错误（没法判断格式版本）；操作部分在末尾坏掉时只保留已经解出来的部分，
/// 并通过返回值告诉调用方（同步要能容错，不能因为一条半截记录丢掉整个文件）。
fn parse_log(plain: &[u8]) -> Result<(SyncLogHeader, Vec<SyncOp>, bool)> {
    let mut rest = plain;
    let header: SyncLogHeader = ciborium::de::from_reader(&mut rest)
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("同步日志文件头损坏: {e}")))?;

    let mut ops = Vec::new();
    let mut truncated = false;
    while !rest.is_empty() {
        match ciborium::de::from_reader::<SyncOp, _>(&mut rest) {
            Ok(op) => ops.push(op),
            Err(e) => {
                truncated = true;
                tracing::warn!(error = %e, remaining = rest.len(), "同步日志操作部分损坏");
                break;
            }
        }
    }
    Ok((header, ops, truncated))
}

/// 序列化并压缩一个完整日志文件。
fn encode_log(header: &SyncLogHeader, ops: &[SyncOp]) -> Result<Vec<u8>> {
    let mut plain = Vec::new();
    // ciborium 的 `into_writer` 支持连续写多个对象（每次调用写一个完整 CBOR 项），
    // 这里靠它拼出「文件头 + 若干操作」的流，不需要自己做长度前缀。
    ciborium::ser::into_writer(header, &mut plain).map_err(|e| {
        LekisError::new(
            ErrorCode::Internal,
            format!("序列化同步日志文件头失败: {e}"),
        )
    })?;
    for op in ops {
        ciborium::ser::into_writer(op, &mut plain).map_err(|e| {
            LekisError::new(ErrorCode::Internal, format!("序列化同步操作失败: {e}"))
        })?;
    }
    zstd::stream::encode_all(&plain[..], COMPRESSION_LEVEL)
        .map_err(|e| LekisError::new(ErrorCode::Io, format!("压缩同步日志失败: {e}")))
}

/// 新的文件头。
fn new_header(device_id: &str, now: i64) -> SyncLogHeader {
    SyncLogHeader {
        format_version: FORMAT_VERSION,
        device_id: device_id.to_string(),
        created_at_ms: now,
    }
}

/// 当天日志文件名：`<YYYYMMDD>.log.zst`（UTC 日期）。
fn day_log_name(at_ms: i64) -> String {
    let (year, month, day) = civil_from_days(at_ms.div_euclid(86_400_000));
    format!("{year:04}{month:02}{day:02}{LOG_SUFFIX}")
}

/// Unix 天序号 → (年, 月, 日)。Howard Hinnant 的 `civil_from_days`。
///
/// 自己算而不是引入 `chrono`/`time`：只为了一个日期字符串不值得多一个依赖，
/// 而且这个算法是纯整数运算、没有时区概念（同步日志统一用 UTC 日期切分）。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]，3 月为 0
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 {
        (mp + 3) as u32
    } else {
        (mp - 9) as u32
    };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month, day)
}

/// 当前 Unix 毫秒。
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EntityKind;
    use lekis_types::SourceKind;
    use lekis_vfs::{local::LocalVfs, DirEntry, FileMeta, VfsCapabilities};
    use std::ops::Range;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// 测试用临时目录，析构时删掉。
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Result<Self> {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let dir =
                std::env::temp_dir().join(format!("lekis-sync-{tag}-{}-{n}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir)?;
            Ok(Self(dir))
        }

        fn path(&self) -> &PathBuf {
            &self.0
        }

        fn local_vfs(&self) -> Result<Arc<dyn Vfs>> {
            Ok(Arc::new(LocalVfs::new(&self.0)?))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn op(wall_ms: i64, counter: u32, device: &str, field: &str) -> SyncOp {
        SyncOp {
            hlc: Hlc {
                wall_ms,
                counter,
                device: device.into(),
            },
            entity: EntityKind::TrackState,
            entity_id: "mb:0123456789abcdef".into(),
            field: field.into(),
            value: Some(serde_json::json!(true)),
        }
    }

    #[test]
    fn day_name_matches_utc_date() {
        assert_eq!(day_log_name(0), "19700101.log.zst");
        assert_eq!(day_log_name(1_700_000_000_000), "20231114.log.zst");
        // 2024-02-29T00:00:00Z，闰日
        assert_eq!(day_log_name(1_709_164_800_000), "20240229.log.zst");
        // 当天内的任意时刻都是同一个文件
        let day_start = 1_709_164_800_000;
        assert_eq!(day_log_name(day_start + 1), "20240229.log.zst");
        assert_eq!(day_log_name(day_start + 86_399_999), "20240229.log.zst");
    }

    #[test]
    fn device_dir_rejects_escaping_ids() {
        assert_eq!(
            device_log_dir("dev-a").map(|p| p.as_str().to_string()),
            Some(".lekis/sync/dev-a".to_string())
        );
        assert!(device_log_dir("").is_none());
        assert!(device_log_dir("a/b").is_none());
        assert!(device_log_dir("a\\b").is_none());
        assert!(device_log_dir("..").is_none());
        assert!(device_log_dir(".").is_none());
        // 点开头的名字在 pull 里被当作预留目录跳过，自己写进去别人就永远看不到。
        assert!(device_log_dir(".hidden").is_none());
    }

    #[test]
    fn log_bytes_roundtrip_through_cbor_stream() -> Result<()> {
        let header = new_header("dev-a", 1_700_000_000_000);
        let ops = vec![op(1, 0, "dev-a", "loved"), op(2, 5, "dev-a", "rating")];
        let encoded = encode_log(&header, &ops)?;
        // 确实是 zstd 帧，而不是明文
        assert_eq!(&encoded[..4], &[0x28, 0xb5, 0x2f, 0xfd]);
        let plain = zstd::stream::decode_all(&encoded[..])
            .map_err(|e| LekisError::new(ErrorCode::Decode, e.to_string()))?;
        let (got_header, got_ops, truncated) = parse_log(&plain)?;
        assert_eq!(got_header, header);
        assert_eq!(got_ops, ops);
        assert!(!truncated);
        Ok(())
    }

    /// 真实 roundtrip：push 3 条，另一个设备拉回来 3 条且顺序正确。
    ///
    /// 注意：`pull` 按设计只读**别人**的目录（自己的操作本地已有），
    /// 所以读的一方用另一个 device_id，和生产里的行为一致。
    #[tokio::test]
    async fn push_then_pull_roundtrip_in_order() -> Result<()> {
        let dir = TempDir::new("roundtrip")?;
        let vfs = dir.local_vfs()?;

        let writer = NasFolderChannel::new(vfs.clone(), "dev-a");
        let ops = vec![
            op(1_000, 0, "dev-a", "loved"),
            op(1_500, 0, "dev-a", "rating"),
            op(1_500, 3, "dev-a", "play_count"),
        ];
        writer.push(&ops).await?;

        // 文件确实落在 .lekis/sync/dev-a/<今天>.log.zst 上
        let path = dir
            .path()
            .join(".lekis")
            .join("sync")
            .join("dev-a")
            .join(day_log_name(now_ms()));
        assert!(path.is_file(), "expected sync log at {}", path.display());

        let reader = NasFolderChannel::new(vfs, "dev-b");
        let got = reader.pull(&[]).await?;
        assert_eq!(got, ops);
        assert_eq!(reader.name(), "nas-folder");
        Ok(())
    }

    /// 增量：给了游标就只拿到游标之后的操作。
    #[tokio::test]
    async fn pull_since_cursor_only_returns_newer_ops() -> Result<()> {
        let dir = TempDir::new("cursor")?;
        let vfs = dir.local_vfs()?;
        let writer = NasFolderChannel::new(vfs.clone(), "dev-a");
        let ops = vec![
            op(1_000, 0, "dev-a", "a"),
            op(2_000, 0, "dev-a", "b"),
            op(3_000, 0, "dev-a", "c"),
        ];
        writer.push(&ops).await?;

        let reader = NasFolderChannel::new(vfs, "dev-b");
        let all = reader.pull(&[]).await?;
        assert_eq!(all.len(), 3);

        let since = vec![("dev-a".to_string(), ops[1].hlc.clone())];
        let incremental = reader.pull(&since).await?;
        assert_eq!(incremental.len(), 1);
        assert_eq!(incremental[0], ops[2]);

        // 游标是最新的：什么都不多拿
        let latest = vec![("dev-a".to_string(), ops[2].hlc.clone())];
        assert!(reader.pull(&latest).await?.is_empty());
        Ok(())
    }

    /// 两个设备往同一个共享目录写，各自只看到对方的操作。
    #[tokio::test]
    async fn two_devices_see_each_other_but_not_themselves() -> Result<()> {
        let dir = TempDir::new("two-devices")?;
        let vfs = dir.local_vfs()?;
        let dev_a = NasFolderChannel::new(vfs.clone(), "dev-a");
        let dev_b = NasFolderChannel::new(vfs.clone(), "dev-b");

        dev_a.push(&[op(1_000, 0, "dev-a", "loved")]).await?;
        dev_b.push(&[op(2_000, 0, "dev-b", "loved")]).await?;

        let a_sees = dev_a.pull(&[]).await?;
        assert_eq!(a_sees.len(), 1);
        assert_eq!(a_sees[0].hlc.device, "dev-b");

        let b_sees = dev_b.pull(&[]).await?;
        assert_eq!(b_sees.len(), 1);
        assert_eq!(b_sees[0].hlc.device, "dev-a");

        // 再来一轮：追加进 dev-a 的同一个当天文件，dev-b 用游标只拿到新增那条
        dev_a.push(&[op(3_000, 0, "dev-a", "rating")]).await?;
        let b_all = dev_b.pull(&[]).await?;
        assert_eq!(b_all.len(), 2, "dev-b 现在能看到 dev-a 的两条操作");
        assert_eq!(b_all[0].hlc.wall_ms, 1_000);
        assert_eq!(b_all[1].hlc.wall_ms, 3_000, "结果必须按 HLC 排序");

        let b_incremental = dev_b
            .pull(&[("dev-a".to_string(), b_all[0].hlc.clone())])
            .await?;
        assert_eq!(b_incremental.len(), 1);
        assert_eq!(b_incremental[0].hlc.wall_ms, 3_000);

        // 自己的目录永远不读回来，即使 pull 的 since 里根本没有自己
        assert!(a_sees.iter().all(|o| o.hlc.device != "dev-a"));
        Ok(())
    }

    /// 损坏的文件被跳过，不影响其它设备；更高格式版本的文件被忽略。
    #[tokio::test]
    async fn corrupt_and_future_logs_are_skipped() -> Result<()> {
        let dir = TempDir::new("corrupt")?;
        let vfs = dir.local_vfs()?;

        let good = NasFolderChannel::new(vfs.clone(), "dev-a");
        good.push(&[op(1_000, 0, "dev-a", "loved")]).await?;

        // dev-c: 完全不是 zstd 的垃圾字节
        let c_dir = VfsPath::root().join(".lekis").join("sync").join("dev-c");
        vfs.create_dir_all(&c_dir).await?;
        vfs.write_atomic(
            &c_dir.join("20260101.log.zst"),
            Bytes::from_static(b"definitely not a zstd frame"),
        )
        .await?;

        // dev-z: 合法 CBOR + zstd，但 format_version 是未来版本
        let mut plain = Vec::new();
        ciborium::ser::into_writer(
            &SyncLogHeader {
                format_version: FORMAT_VERSION + 7,
                device_id: "dev-z".into(),
                created_at_ms: 0,
            },
            &mut plain,
        )
        .map_err(|e| LekisError::internal(e.to_string()))?;
        ciborium::ser::into_writer(&op(9_000, 0, "dev-z", "loved"), &mut plain)
            .map_err(|e| LekisError::internal(e.to_string()))?;
        let z_bytes = zstd::stream::encode_all(&plain[..], COMPRESSION_LEVEL)
            .map_err(|e| LekisError::internal(e.to_string()))?;
        let z_dir = VfsPath::root().join(".lekis").join("sync").join("dev-z");
        vfs.create_dir_all(&z_dir).await?;
        vfs.write_atomic(&z_dir.join("20990101.log.zst"), Bytes::from(z_bytes))
            .await?;

        let reader = NasFolderChannel::new(vfs, "dev-b");
        let got = reader.pull(&[]).await?;
        assert_eq!(got.len(), 1, "只应拿到 dev-a 的正常操作");
        assert_eq!(got[0].hlc.device, "dev-a");
        Ok(())
    }

    /// 只读共享：push 返回 PermissionDenied，不 panic。
    #[tokio::test]
    async fn push_on_read_only_share_is_permission_denied() -> Result<()> {
        let channel = NasFolderChannel::new(Arc::new(ReadOnlyVfs), "dev-a");
        let err = match channel.push(&[op(1, 0, "dev-a", "loved")]).await {
            Ok(()) => {
                return Err(LekisError::internal("read-only push should have failed"));
            }
            Err(e) => e,
        };
        assert_eq!(err.code, ErrorCode::PermissionDenied);
        Ok(())
    }

    /// 空的 `ops` 直接成功（不需要建目录、不需要读写）。
    #[tokio::test]
    async fn push_empty_ops_is_noop() -> Result<()> {
        let dir = TempDir::new("empty")?;
        let vfs = dir.local_vfs()?;
        let channel = NasFolderChannel::new(vfs, "dev-a");
        channel.push(&[]).await?;
        assert!(!dir.path().join(".lekis").exists());
        Ok(())
    }

    /// 只读的假 VFS：能力位 `writable == false`，其它方法一律报错。
    struct ReadOnlyVfs;

    #[async_trait]
    impl Vfs for ReadOnlyVfs {
        fn kind(&self) -> SourceKind {
            SourceKind::Local
        }

        fn capabilities(&self) -> VfsCapabilities {
            VfsCapabilities {
                writable: false,
                watch: false,
                reliable_dir_mtime: false,
                suggested_concurrency: 1,
            }
        }

        async fn list_dir(&self, _dir: &VfsPath) -> Result<Vec<DirEntry>> {
            Err(LekisError::unsupported("read-only test vfs"))
        }

        async fn stat(&self, _path: &VfsPath) -> Result<FileMeta> {
            Err(LekisError::unsupported("read-only test vfs"))
        }

        async fn read_range(&self, _path: &VfsPath, _range: Range<u64>) -> Result<Bytes> {
            Err(LekisError::unsupported("read-only test vfs"))
        }

        async fn write_atomic(&self, _path: &VfsPath, _data: Bytes) -> Result<()> {
            Err(LekisError::unsupported("read-only test vfs"))
        }

        async fn create_dir_all(&self, _dir: &VfsPath) -> Result<()> {
            Err(LekisError::unsupported("read-only test vfs"))
        }
    }
}
