//! 同步通道（SYN-02~05）。
//!
//! | 通道 | 说明 | 阶段 |
//! |---|---|---|
//! | NAS 同步目录 | `.lekis/sync/<device_id>/<日期>.log.zst`，每台设备只写自己的目录 | Beta |
//! | 局域网 P2P | mDNS 发现 + 扫码配对 + 端到端加密 | 1.x |
//! | Headless 节点 | 节点作为同步中枢 | 1.0 |
//! | 用户云盘 | iCloud / OneDrive / Google Drive 上的文件夹 | 1.x |

use crate::{Hlc, SyncOp};
use async_trait::async_trait;
use lekis_types::{LekisError, Result};

/// 同步通道。
#[async_trait]
pub trait SyncChannel: Send + Sync {
    /// 通道名称（同时用作 `sync_cursor` 表的键）。
    fn name(&self) -> &str;

    /// 推送本机的操作。
    async fn push(&self, ops: &[SyncOp]) -> Result<()>;

    /// 拉取其他设备在 `since`（按设备分别记录）之后的操作。
    async fn pull(&self, since: &[(String, Hlc)]) -> Result<Vec<SyncOp>>;
}

/// NAS 同步目录通道（占位）。
///
/// TODO：
/// - 日志文件格式：文件头（格式版本、设备 ID）+ 若干 `cbor` 编码的 [`SyncOp`]，整体 zstd 压缩；
/// - 按天切分文件，当天的文件追加写（先写临时文件再重命名）；
/// - 超过阈值后生成快照（物化后的全部字段状态），旧日志归档；
/// - 可选端到端加密（XChaCha20-Poly1305，密钥由用户口令派生）。
pub struct NasFolderChannel;

#[async_trait]
impl SyncChannel for NasFolderChannel {
    fn name(&self) -> &str {
        "nas-folder"
    }

    async fn push(&self, _ops: &[SyncOp]) -> Result<()> {
        Err(LekisError::not_implemented("nas folder sync push"))
    }

    async fn pull(&self, _since: &[(String, Hlc)]) -> Result<Vec<SyncOp>> {
        Err(LekisError::not_implemented("nas folder sync pull"))
    }
}
