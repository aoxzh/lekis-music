//! 把 [`lekis_vfs::Vfs`] 的按范围读取适配成 symphonia 的同步 [`MediaSource`]。
//!
//! symphonia 的 `MediaSource` 是同步的 `Read + Seek`，而 [`Vfs::read_range`] 是异步的。
//! 适配器跑在**专用解码线程**上（不是 tokio worker），所以可以用 `Handle::block_on`
//! 同步等待。每次 `read` 只拉需要的字节范围（默认 64 KiB 一块），不会把整个文件读进内存——
//! 这正是 PLY-08「Range 分块读取」的要求。
//!
//! [`Vfs::read_range`]: lekis_vfs::Vfs::read_range
//! [`MediaSource`]: symphonia::core::io::MediaSource

use bytes::Bytes;
use lekis_types::{LekisError, Result};
use lekis_vfs::{Vfs, VfsPath};
use std::io::{Error as IoError, ErrorKind, Read, Seek, SeekFrom};
use std::sync::Arc;
use tokio::runtime::Handle;

/// 通过 VFS 分块读取的 symphonia 媒体源。
///
/// 线程安全性：`read_range` 是 `&self` 的异步方法，内部实现都是线程安全的
/// （`Arc<dyn Vfs>` 本身 `Send + Sync`），所以这里可以直接 `impl Send + Sync`。
pub struct VfsMediaSource {
    vfs: Arc<dyn Vfs>,
    path: VfsPath,
    /// 当前读位置。
    pos: u64,
    /// 文件总长度（未知时为 `None`，此时 `byte_len` 返回 `None`，symphonia 会退化成不可 seek 的估算）。
    len: Option<u64>,
    handle: Handle,
    /// 由 `read_range` 返回、尚未消费完的缓冲。
    pending: Bytes,
    /// 累计读取字节数（用于诊断"是不是把文件整个拉下来了"）。
    bytes_read: u64,
}

impl VfsMediaSource {
    /// 创建一个新的 VFS 媒体源。
    ///
    /// `len` 是文件大小（来自 `stat`）；拿不到就传 `None`。
    /// `handle` 是宿主 tokio 运行时的句柄，用来把异步 `read_range` 变成同步读。
    pub fn new(vfs: Arc<dyn Vfs>, path: VfsPath, len: Option<u64>, handle: Handle) -> Self {
        Self {
            vfs,
            path,
            pos: 0,
            len,
            handle,
            pending: Bytes::new(),
            bytes_read: 0,
        }
    }

    /// 已经读取的字节数。
    pub fn bytes_read(&self) -> u64 {
        self.bytes_read
    }

    fn io_err(e: LekisError) -> IoError {
        IoError::other(e.to_string())
    }
}

impl Read for VfsMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        // 缓冲里还有残留就先给出去。
        if !self.pending.is_empty() {
            let n = buf.len().min(self.pending.len());
            buf[..n].copy_from_slice(&self.pending[..n]);
            let _ = self.pending.split_to(n);
            self.pos += n as u64;
            return Ok(n);
        }
        // 到文件尾了。
        if let Some(len) = self.len {
            if self.pos >= len {
                return Ok(0);
            }
        }
        let end = match self.len {
            Some(len) => (self.pos + buf.len() as u64).min(len),
            None => self.pos + buf.len() as u64,
        };
        let chunk = self
            .handle
            .block_on(self.vfs.read_range(&self.path, self.pos..end))
            .map_err(Self::io_err)?;
        if chunk.is_empty() {
            // 长度未知的源读到空块，只能当作结尾。
            return Ok(0);
        }
        self.bytes_read += chunk.len() as u64;
        let n = buf.len().min(chunk.len());
        buf[..n].copy_from_slice(&chunk[..n]);
        if n < chunk.len() {
            self.pending = chunk.slice(n..);
        }
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for VfsMediaSource {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        let new_pos = match from {
            SeekFrom::Start(off) => off as i128,
            SeekFrom::Current(delta) => self.pos as i128 + delta as i128,
            SeekFrom::End(delta) => match self.len {
                Some(len) => len as i128 + delta as i128,
                None => {
                    return Err(IoError::new(
                        ErrorKind::Unsupported,
                        "cannot seek from end with unknown length",
                    ))
                }
            },
        };
        if new_pos < 0 {
            return Err(IoError::new(
                ErrorKind::InvalidInput,
                "seek to negative offset",
            ));
        }
        self.pos = new_pos as u64;
        // 位置变了，残留缓冲作废。
        self.pending = Bytes::new();
        Ok(self.pos)
    }
}

impl symphonia::core::io::MediaSource for VfsMediaSource {
    fn is_seekable(&self) -> bool {
        self.len.is_some()
    }

    fn byte_len(&self) -> Option<u64> {
        self.len
    }
}

/// 一种"读取器"抽象：给定 `MediaLocation` 拿到可 seek 的源。
///
/// 目前只有 VFS 需要这层间接，保留成 trait object 是为了以后接 HTTP Range 流（PLY-08）。
pub type RemoteSource = Box<dyn symphonia::core::io::MediaSource + Send + Sync>;

/// 一次性读整个文件的便捷实现（给 `CachedFile` 用；本地文件其实直接用 `File` 更好）。
///
/// 注意：这只是给测试和小的缓存文件用，别拿它读大文件。
pub fn whole_file_source(path: &str) -> Result<Box<dyn Read + Send + Sync>> {
    let file = std::fs::File::open(path)
        .map_err(|e| LekisError::new(lekis_types::ErrorCode::Io, format!("open {path}: {e}")))?;
    Ok(Box::new(file))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_vfs::local::LocalVfs;

    /// VFS 适配器必须能从任意偏移读出正确的字节（symphonia 的 seek 依赖它）。
    #[test]
    fn vfs_source_reads_and_seeks() {
        // 需要 tokio 运行时：read_range 是 async，适配器内部用 Handle::block_on。
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build runtime");
        let _guard = rt.enter();

        let dir = std::env::temp_dir().join(format!("lekis-playback-vfs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        let file_path = dir.join("blob.bin");
        std::fs::write(&file_path, &data).expect("write blob");

        let vfs: Arc<dyn Vfs> =
            Arc::new(LocalVfs::new(&dir).expect("local vfs requires absolute path"));
        let path = VfsPath::parse("blob.bin").expect("valid path");
        let handle = Handle::current();
        let mut src = VfsMediaSource::new(vfs, path, Some(data.len() as u64), handle);

        let mut buf = [0u8; 64];
        let n = src.read(&mut buf).expect("read head");
        assert_eq!(n, 64);
        assert_eq!(&buf[..n], &data[..64]);

        src.seek(SeekFrom::Start(5_000)).expect("seek");
        let n = src.read(&mut buf).expect("read middle");
        assert_eq!(n, 64);
        assert_eq!(&buf[..n], &data[5_000..5_064]);

        src.seek(SeekFrom::End(-16)).expect("seek from end");
        let n = src.read(&mut buf).expect("read tail");
        assert_eq!(n, 16);
        assert_eq!(&buf[..n], &data[data.len() - 16..]);

        // 到尾部之后必须返回 0（EOF），不能无限读。
        let n = src.read(&mut buf).expect("read eof");
        assert_eq!(n, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
