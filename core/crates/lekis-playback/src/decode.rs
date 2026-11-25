//! 解码。
//!
//! 主解码器：symphonia（纯 Rust：MP3、AAC、ALAC、FLAC、WAV、AIFF、Vorbis……）。
//! 长尾无损格式（APE、TTA、DSD）：纯 Rust 解码器（`ape-decoder`、`oxideav-tta`、`dsd2pcm`），
//! 无需动态链接 FFmpeg。
//! CUE 整轨分轨播放：[`BoundedDecoder`] 把任意底层解码器裁剪到 `[start_ms, end_ms)` 区间。
//!
//! 无缝播放（PLY-01）要求：解码器必须去掉 MP3 / AAC 的编码器延迟（encoder delay）和尾部填充（padding），
//! 信息来自 LAME/Xing 头或 iTunSMPB。symphonia 的 `AudioDecoderOptions::gapless`（默认开启）
//! 会按 demuxer 给出的 `Packet::trim_start` / `trim_end` 自动裁掉这些帧，所以这里不用再手算。

pub mod ape_decoder;
pub mod bounded_decoder;
pub mod dsd_decoder;
pub mod media_source;
pub mod symphonia_decoder;
pub mod tta_decoder;
pub mod url_source;

pub use ape_decoder::ApeAudioDecoder;
pub use bounded_decoder::BoundedDecoder;
pub use dsd_decoder::DsdAudioDecoder;
pub use media_source::VfsMediaSource;
pub use symphonia_decoder::SymphoniaDecoder;
pub use tta_decoder::TtaAudioDecoder;
pub use url_source::HttpRangeSource;

use crate::vfs_access;
use crate::{MediaLocation, MediaSource};
use lekis_types::{ErrorCode, LekisError, Result};
use tokio::runtime::Handle;

/// 解码输出的音频格式。引擎内部统一用 f32 交错样本。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PcmFormat {
    /// 采样率。
    pub sample_rate: u32,
    /// 声道数。
    pub channels: u16,
}

/// 解码器的原生样本格式（PLY-05 比特完美输出用）。
///
/// 比特完美链路不经过 f32：整数源以**左对齐的 i32** 交错样本传递（16 bit 的样本在高 16 位，
/// 低位全零；24 bit 在高 24 位），这样无论设备容器是 16 / 24 / 24-in-32 / 32 bit，
/// 打包时都只是截取高位字节，不做任何算术。浮点源以 f32 的**位模式**（`f32::to_bits`）传递。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeSampleFormat {
    /// 整数 PCM，`bits` 是有效位数（8 / 16 / 20 / 24 / 32……）。
    Int {
        /// 有效位数。
        bits: u8,
    },
    /// 32 位浮点（浮点 WAV；有损编码的解码输出也是这个）。
    Float32,
}

/// 解码器。在解码线程上使用，不能在实时线程上调用。
pub trait Decoder: Send {
    /// 流信息。
    fn props(&self) -> &lekis_types::AudioProps;

    /// 输出格式。
    fn format(&self) -> PcmFormat;

    /// 总时长（毫秒），未知时为 `None`（网络电台）。
    fn duration_ms(&self) -> Option<u64>;

    /// 解码下一块样本，追加到 `out`。返回 `Ok(false)` 表示到达结尾。
    fn decode_next(&mut self, out: &mut Vec<f32>) -> Result<bool>;

    /// 跳转到指定位置（毫秒）。返回实际跳到的位置。
    fn seek(&mut self, position_ms: u64) -> Result<u64>;

    /// 原生样本格式；`None` 表示这个解码器不支持比特完美输出（例如 f64 源）。
    fn native_format(&self) -> Option<NativeSampleFormat> {
        None
    }

    /// 按 [`Self::native_format`] 解码下一块样本（左对齐 i32 或 f32 位模式），追加到 `out`。
    /// 返回 `Ok(false)` 表示到达结尾。和 [`Self::decode_next`] 共享同一个读取位置，二者择一使用。
    fn decode_next_native(&mut self, out: &mut Vec<i32>) -> Result<bool> {
        let _ = out;
        Err(LekisError::new(
            ErrorCode::Unsupported,
            "decoder has no native (bit-perfect) output",
        ))
    }
}

/// 按 [`MediaSource`] 打开解码器。
///
/// - `CachedFile`：直接读本地文件（`std::fs::File` 已经实现 symphonia 的 `MediaSource`）。
/// - `Vfs`：通过宿主注册的 VFS 解析器（`vfs_access::install_vfs_resolver`）分块读取，
///   见 [`VfsMediaSource`]。
/// - `Url`：HTTP Range 分块读取（[`HttpRangeSource`]），`MediaLocation` 里的请求头会
///   附加到每个请求上（服务器源的 token 在头里）。
///
/// **必须在一个没有 tokio 运行时上下文的线程上调用**：VFS 的 `read_range` 是异步的，
/// 这里用 `Handle::block_on` 同步等待；HTTP 用的是 reqwest 的 blocking 客户端。
/// 在 tokio worker 线程上这两者都会出问题，所以引擎总是把解码器开在专用的解码线程里。
pub fn open_decoder(media: &MediaSource, handle: &Handle) -> Result<Box<dyn Decoder>> {
    let inner: Box<dyn Decoder> = match &media.location {
        MediaLocation::CachedFile { path } => {
            let file = std::fs::File::open(path)
                .map_err(|e| LekisError::new(ErrorCode::Io, format!("cannot open {path}: {e}")))?;
            let ext = extension_of(path);
            open_for_source(Box::new(file), ext.as_deref())?
        }
        MediaLocation::Vfs { source_id, path } => {
            let Some(vfs) = vfs_access::resolve(*source_id) else {
                return Err(LekisError::new(
                    ErrorCode::NotImplemented,
                    format!(
                        "音源连接未就绪（source {}），请重新扫描或编辑音源",
                        source_id.0
                    ),
                ));
            };
            let Some(vfs_path) = lekis_vfs::VfsPath::parse(path) else {
                return Err(LekisError::invalid(format!("invalid vfs path: {path}")));
            };
            let ext = vfs_path.extension().map(|e| e.to_ascii_lowercase());
            let len = match handle.block_on(vfs.stat(&vfs_path)) {
                Ok(meta) => Some(meta.size),
                Err(e) => {
                    tracing::debug!(
                        target: "playback::decode",
                        source = %source_id,
                        path = %path,
                        error = %e,
                        "stat failed, byte length unknown"
                    );
                    None
                }
            };
            let source = VfsMediaSource::new(vfs, vfs_path, len, handle.clone());
            open_for_source(Box::new(source), ext.as_deref())?
        }
        MediaLocation::Url { url, headers } => {
            let ext = extension_of_url(url);
            let source = HttpRangeSource::new(url.clone(), headers.clone())?;
            tracing::debug!(
                target: "playback::decode",
                %url,
                byte_len = ?source.byte_len(),
                seekable = source.is_seekable(),
                headers = headers.len(),
                "opened http range source"
            );
            open_for_source(Box::new(source), ext.as_deref())?
        }
    };
    if let Some((start_ms, end_ms)) = media.range_ms {
        if start_ms > 0 || end_ms.is_some() {
            return Ok(Box::new(BoundedDecoder::new(inner, start_ms, end_ms)?));
        }
    }
    Ok(inner)
}

/// 根据扩展名和文件魔数路由到对应的解码器（APE / TTA / DSD 走纯 Rust 专用解码器，其余走 symphonia）。
fn open_for_source(
    mut source: Box<dyn symphonia::core::io::MediaSource + Send + Sync>,
    ext: Option<&str>,
) -> Result<Box<dyn Decoder>> {
    let ext_lower = ext.map(str::to_ascii_lowercase);
    match ext_lower.as_deref() {
        Some("ape") => return Ok(Box::new(ApeAudioDecoder::open(source)?)),
        Some("tta") => return Ok(Box::new(TtaAudioDecoder::open(source)?)),
        Some("dsf" | "dff") => return Ok(Box::new(DsdAudioDecoder::open(source)?)),
        _ => {}
    }
    // 无扩展名（如服务器流地址）时，如果可 seek，按前 4 字节魔数探测 APE / TTA / DSD。
    if source.is_seekable() {
        let mut magic = [0u8; 4];
        let peeked = source.read_exact(&mut magic).is_ok();
        let _ = source.seek(std::io::SeekFrom::Start(0));
        if peeked {
            match &magic {
                b"MAC " => return Ok(Box::new(ApeAudioDecoder::open(source)?)),
                b"TTA1" => return Ok(Box::new(TtaAudioDecoder::open(source)?)),
                b"DSD " | b"FRM8" => return Ok(Box::new(DsdAudioDecoder::open(source)?)),
                _ => {}
            }
        }
    }
    Ok(Box::new(SymphoniaDecoder::open_source(source, ext)?))
}

/// 从路径里取小写扩展名（symphonia 用它猜容器格式）。
fn extension_of(path: &str) -> Option<String> {
    std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
}

/// 从 URL 里取小写扩展名：去掉 query / fragment 之后再看路径的最后一段。
///
/// `https://host/a/b.flac?token=x` → `Some("flac")`；电台地址（没有扩展名）→ `None`，
/// symphonia 会退回按内容探测。
fn extension_of_url(url: &str) -> Option<String> {
    let without_fragment = url.split('#').next().unwrap_or(url);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    extension_of(without_query)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// URL 的扩展名要从路径里取，query / fragment 不能干扰。
    #[test]
    fn url_extension_ignores_query_and_fragment() {
        assert_eq!(
            extension_of_url("https://host/music/a.flac?token=abc"),
            Some("flac".to_string())
        );
        assert_eq!(
            extension_of_url("https://host/music/a.mp3#t=10"),
            Some("mp3".to_string())
        );
        assert_eq!(extension_of_url("https://host/radio/stream"), None);
        assert_eq!(extension_of_url("https://host/a.b/c"), None);
    }
}
