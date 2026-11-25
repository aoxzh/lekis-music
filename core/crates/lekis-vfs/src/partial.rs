//! 部分读取：扫描网络共享时只读文件的头部和尾部（NFR-03）。
//!
//! - 头部：ID3v2、FLAC metadata block、MP4 `moov`（大多数情况下在前面）、Vorbis comment。
//! - 尾部：ID3v1（128 字节）、APEv2、Lyrics3。
//!
//! 大多数文件 1~2 次请求就能拿到全部标签。如果标签解析器需要的数据超出了已读取的范围
//! （比如 MP4 的 `moov` 在文件末尾、或者内嵌了超大封面），扫描器再按需补读。

use crate::{Vfs, VfsPath};
use bytes::Bytes;
use lekis_types::Result;

/// 默认读取的头部大小。内嵌大封面的文件会超过它，此时由扫描器按需补读。
pub const DEFAULT_HEAD: u64 = 256 * 1024;
/// 默认读取的尾部大小。
pub const DEFAULT_TAIL: u64 = 128 * 1024;

/// 文件的头尾两段数据。
#[derive(Debug, Clone)]
pub struct PartialFile {
    /// 文件总大小。
    pub size: u64,
    /// 头部数据（从偏移 0 开始）。
    pub head: Bytes,
    /// 尾部数据（到文件末尾结束）。如果文件很小，头部已经覆盖全文件，这里为空。
    pub tail: Bytes,
}

impl PartialFile {
    /// 是否已经拿到了完整文件。
    pub fn is_complete(&self) -> bool {
        self.head.len() as u64 >= self.size
    }

    /// 尾部数据在文件中的起始偏移。
    pub fn tail_offset(&self) -> u64 {
        self.size - self.tail.len() as u64
    }
}

/// 读取文件的头部和尾部。小文件只发一次请求。
pub async fn read_head_tail(
    vfs: &dyn Vfs,
    path: &VfsPath,
    size: u64,
    head_len: u64,
    tail_len: u64,
) -> Result<PartialFile> {
    if size <= head_len + tail_len {
        let all = vfs.read_range(path, 0..size).await?;
        return Ok(PartialFile {
            size,
            head: all,
            tail: Bytes::new(),
        });
    }
    // 两个请求可以并发，对高延迟的 WebDAV 尤其有用。
    let (head, tail) = tokio::try_join!(
        vfs.read_range(path, 0..head_len),
        vfs.read_range(path, size - tail_len..size),
    )?;
    Ok(PartialFile { size, head, tail })
}
